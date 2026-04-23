import AppKit
import AVFoundation
import Combine
import SwiftUI
import WhisperKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let mic = MicRecorder()
    private var liveTranscriber: LiveTranscriber?
    private var isRecording = false
    private var isTranscribing = false
    private var micURL: URL?
    private var systemURL: URL?
    private var toggleItem: NSMenuItem!
    private var statusLabel: NSMenuItem!
    private var lastTranscriptItem: NSMenuItem!
    private var lastTranscriptURL: URL?

    private var whisper: WhisperKit?
    private var loadedModel: String?
    private let settings = AppSettings.shared
    private let arcAuth = ArcAuthStore()

    private let systemAudio = SystemAudioRecorder()
    private var didCaptureSystemAudio = false
    private let diarization = DiarizationRunner()

    private lazy var store: TranscriptsStore = TranscriptsStore(folder: transcriptsFolder())
    private var transcriptsWindow: NSWindow?

    private let state = RecordingState()
    private var floatingWindow: NSPanel?
    private var floatingMenuItem: NSMenuItem!
    private var settingsWindow: NSWindow?
    private var meterTask: Task<Void, Never>?
    private var settingsCancellables: Set<AnyCancellable> = []

    private let updater = AutoUpdater()
    private var updateMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCommaShortcut()

        state.onToggle = { [weak self] in self?.toggleRecording() }
        state.onShowTranscripts = { [weak self] in self?.showTranscripts() }

        settings.$modelName
            .dropFirst()
            .sink { [weak self] _ in self?.whisper = nil; self?.loadedModel = nil }
            .store(in: &settingsCancellables)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()

        statusLabel = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let showWindow = NSMenuItem(title: "Show Transcriptions…", action: #selector(showTranscripts), keyEquivalent: "t")
        showWindow.target = self
        menu.addItem(showWindow)

        floatingMenuItem = NSMenuItem(title: "Hide Floating Controls", action: #selector(toggleFloatingWindow), keyEquivalent: "f")
        floatingMenuItem.target = self
        menu.addItem(floatingMenuItem)

        lastTranscriptItem = NSMenuItem(title: "Open Last Transcript", action: #selector(openLastTranscript), keyEquivalent: "")
        lastTranscriptItem.target = self
        lastTranscriptItem.isEnabled = false
        menu.addItem(lastTranscriptItem)

        let openFolder = NSMenuItem(title: "Open Transcripts Folder", action: #selector(openFolder(_:)), keyEquivalent: "o")
        openFolder.target = self
        menu.addItem(openFolder)

        menu.addItem(.separator())

        updateMenuItem = NSMenuItem(title: "Check for updates…", action: #selector(updateMenuClicked), keyEquivalent: "")
        updateMenuItem.target = self
        menu.addItem(updateMenuItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        showFloatingWindow()

        updater.$latestVersion.sink { [weak self] _ in self?.refreshUpdateMenuItem() }
            .store(in: &settingsCancellables)
        updater.startPeriodicChecks()
    }

    private func refreshUpdateMenuItem() {
        if updater.updateAvailable, let v = updater.latestVersion {
            updateMenuItem.title = "Install update v\(v) →"
        } else if updater.isChecking {
            updateMenuItem.title = "Checking for updates…"
        } else {
            updateMenuItem.title = "Check for updates…"
        }
    }

    @objc private func updateMenuClicked() {
        if updater.updateAvailable {
            confirmAndInstallUpdate()
        } else {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.updater.check()
                self.refreshUpdateMenuItem()
                if !self.updater.updateAvailable {
                    let alert = NSAlert()
                    alert.messageText = "You're up to date"
                    alert.informativeText = "Arc Transcriber \(self.updater.currentVersion) is the latest release."
                    alert.runModal()
                }
            }
        }
    }

    private func confirmAndInstallUpdate() {
        guard let v = updater.latestVersion else { return }
        let alert = NSAlert()
        alert.messageText = "Install version \(v)?"
        alert.informativeText = (updater.releaseNotes?.prefix(500).description ?? "")
            + "\n\nThe app will close, replace itself, and relaunch."
        alert.addButton(withTitle: "Install & Restart")
        alert.addButton(withTitle: "Later")
        if let url = updater.releaseURL {
            let button = alert.addButton(withTitle: "View on GitHub")
            button.tag = 99
            _ = url  // referenced via button action below
        }

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                do {
                    try await self.updater.downloadAndInstall()
                } catch {
                    let a = NSAlert()
                    a.messageText = "Update failed"
                    a.informativeText = error.localizedDescription
                    a.alertStyle = .warning
                    a.runModal()
                }
            }
        case .alertThirdButtonReturn:
            if let url = updater.releaseURL { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    /// We don't install `NSApp.mainMenu` for `.accessory` apps — it
    /// causes the system to render a ghost menu bar that intercepts
    /// clicks on `NSStatusItem`'s menu (the menu opens but mouse events
    /// don't reach its items). Instead, `⌘,` is caught locally here and
    /// routed to `showSettings()` whenever any of our windows is key.
    private func installCommaShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "," {
                self.showSettings()
                return nil
            }
            return event
        }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings, arcAuth: arcAuth))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Arc Transcriber Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - URL scheme (sourceful-transcriber://auth/callback?token=…)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleIncomingURL(url) }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "sourceful-transcriber" else { return }
        guard url.host == "auth" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let token = components?.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            alert("Sign-in callback was missing a token. Try again from Settings → Sign in to Arc.")
            return
        }
        arcAuth.save(token: token)

        // Bring the Settings window forward so the user sees the "Signed in as …" state.
        showSettings()

        let email = arcAuth.userEmail ?? "your Arc account"
        let note = NSAlert()
        note.messageText = "Signed in to Arc"
        note.informativeText = "Connected as \(email). You can close the browser tab."
        note.alertStyle = .informational
        note.runModal()
    }

    // MARK: - Icon / UI

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        if isRecording {
            symbol = "record.circle.fill"
        } else if isTranscribing {
            symbol = "waveform.badge.magnifyingglass"
        } else {
            symbol = "waveform"
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Arc Transcriber") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = isRecording ? "● REC" : (isTranscribing ? "…" : "T")
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.title = text
        state.status = text
    }

    private func publishRecordingFlags() {
        state.isRecording = isRecording
        state.isTranscribing = isTranscribing
    }

    private func startMeterPolling() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                if self.isRecording {
                    self.state.micLevel = self.mic.currentLevel
                } else {
                    self.state.micLevel *= 0.6
                }
                self.state.systemLevel = self.systemAudio.currentLevel
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopMeterPolling() {
        meterTask?.cancel()
        meterTask = nil
        state.micLevel = 0
        state.systemLevel = 0
    }

    private func startLiveTranscription() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let pipe = try await self.loadWhisperIfNeeded()
                guard self.isRecording else { return }
                let transcriber = LiveTranscriber(whisper: pipe)
                transcriber.onText = { [weak self] text in
                    self?.state.liveText = text
                }
                self.liveTranscriber = transcriber
                transcriber.start(language: self.settings.language == "auto" ? nil : self.settings.language)
            } catch {
                // Live is best-effort; silently skip if the model isn't ready.
            }
        }
    }

    // MARK: - Recording

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            requestMicAndStart()
        }
    }

    private func requestMicAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        NSLog("[Mic] authorizationStatus = %@", String(describing: status))

        switch status {
        case .authorized:
            startRecording()

        case .notDetermined:
            // First time: trigger the system prompt. LSUIElement apps
            // have no dock icon so the prompt can end up behind
            // another window and get auto-dismissed — activate first
            // to pull ourselves to the front.
            NSApp.activate(ignoringOtherApps: true)
            NSLog("[Mic] Calling AVCaptureDevice.requestAccess(.audio)")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                NSLog("[Mic] requestAccess callback: granted = %d", granted ? 1 : 0)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted { self.startRecording() }
                    else { self.showMicDeniedAlert() }
                }
            }

        case .denied, .restricted:
            // TCC has recorded a prior denial (or MDM restricts this).
            // Calling requestAccess again is a no-op — jump the user
            // to Settings with a prefilled deep link instead.
            showMicDeniedAlert()

        @unknown default:
            showMicDeniedAlert()
        }
    }

    private func showMicDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Arc Transcriber needs microphone access"
        alert.informativeText = "Enable Arc Transcriber in System Settings → Privacy & Security → Microphone, then come back and try again.\n\nIf Arc Transcriber doesn't appear in that list at all, open Terminal and run:\n    tccutil reset Microphone io.srcful.transcriber"
        alert.addButton(withTitle: "Open Privacy & Security")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func startRecording() {
        let folder = transcriptsFolder()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            alert("Could not create transcripts folder: \(error.localizedDescription)")
            return
        }

        let stamp = timestamp()
        let micFile = folder.appendingPathComponent("recording-\(stamp)-mic.caf")
        let sysFile = folder.appendingPathComponent("recording-\(stamp)-system.caf")

        let wantLive = settings.liveTranscription
        if wantLive {
            mic.onLiveSamples = { [weak self] samples in
                Task { @MainActor in self?.liveTranscriber?.feed(samples: samples) }
            }
        } else {
            mic.onLiveSamples = nil
        }

        do {
            try mic.start(to: micFile, live: wantLive)
            micURL = micFile
        } catch {
            alert("Could not start mic recording: \(error.localizedDescription)")
            return
        }

        if wantLive {
            startLiveTranscription()
        }

        isRecording = true
        toggleItem.title = "Stop Recording"
        setStatus("Recording (mic)… starting system audio")
        updateIcon()
        publishRecordingFlags()
        startMeterPolling()

        // System audio is best-effort. If permission is missing we fall back to mic-only.
        didCaptureSystemAudio = false
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.systemAudio.start(to: sysFile)
                await MainActor.run {
                    self.systemURL = sysFile
                    self.didCaptureSystemAudio = true
                    self.setStatus("Recording (mic + system)…")
                }
            } catch {
                await MainActor.run {
                    self.systemURL = nil
                    self.setStatus("Recording (mic only — \(self.shortReason(error)))")
                }
            }
        }
    }

    private func shortReason(_ error: Error) -> String {
        if let f = error as? SystemAudioRecorder.Failure {
            switch f {
            case .permissionDenied: return "no screen-recording permission"
            case .noDisplayAvailable: return "no display"
            case .writerCreationFailed: return "writer failed"
            }
        }
        return "system audio unavailable"
    }

    private func stopRecording() {
        mic.stop()
        isRecording = false
        toggleItem.title = "Start Recording"
        updateIcon()
        publishRecordingFlags()
        stopMeterPolling()

        guard let mic = micURL else {
            liveTranscriber = nil
            state.liveText = ""
            setStatus("Idle")
            return
        }

        setStatus("Finalizing audio…")
        let sys = systemURL
        let hadSystem = didCaptureSystemAudio
        let live = liveTranscriber

        Task { [weak self] in
            guard let self = self else { return }
            // Drain the live transcriber first — it shares a WhisperKit
            // instance with the final pass, and concurrent calls on the
            // same pipe corrupt decoder state (empty / truncated finals).
            await live?.stop()
            if hadSystem {
                await self.systemAudio.stop()
            }
            await MainActor.run {
                self.liveTranscriber = nil
                self.state.liveText = ""
                self.transcribe(micURL: mic, systemURL: hadSystem ? sys : nil)
            }
        }
    }

    // MARK: - Transcription

    private func transcribe(micURL: URL, systemURL: URL?) {
        isTranscribing = true
        toggleItem.isEnabled = false
        updateIcon()
        publishRecordingFlags()

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let pipe = try await self.loadWhisperIfNeeded()
                let options = Self.transcriptionOptions(
                    language: self.settings.language,
                    live: false
                )

                await MainActor.run { self.setStatus("Transcribing mic…") }
                let micResults = try await pipe.transcribe(audioPath: micURL.path, decodeOptions: options)

                var systemResults: [TranscriptionResult] = []
                var usedSystemURL: URL?
                if let sys = systemURL, self.fileHasContent(at: sys) {
                    await MainActor.run { self.setStatus("Transcribing system audio…") }
                    systemResults = try await pipe.transcribe(audioPath: sys.path, decodeOptions: options)
                    usedSystemURL = sys
                }

                let body: String
                if usedSystemURL != nil {
                    body = TranscriptMerger.merge(mic: micResults, system: systemResults)
                } else if self.settings.speakerDiarization {
                    await MainActor.run {
                        self.setStatus("Identifying speakers…")
                    }
                    let turns = (try? await self.diarization.diarize(audioURL: micURL)) ?? []
                    if turns.isEmpty {
                        body = TranscriptMerger.formatSingleSpeaker(micResults).isEmpty
                            ? "_(no speech detected)_"
                            : TranscriptMerger.formatSingleSpeaker(micResults)
                    } else {
                        body = TranscriptMerger.mergeWithDiarization(whisper: micResults, turns: turns)
                    }
                } else {
                    body = TranscriptMerger.formatSingleSpeaker(micResults).isEmpty
                        ? "_(no speech detected)_"
                        : TranscriptMerger.formatSingleSpeaker(micResults)
                }

                let allLangs = Array(Set((micResults + systemResults).map(\.language))).sorted()
                let transcriptURL = try self.writeTranscript(
                    basedOn: micURL,
                    hasSystemAudio: usedSystemURL != nil,
                    body: body,
                    detectedLanguages: allLangs
                )

                if !self.settings.keepAudioFiles {
                    try? FileManager.default.removeItem(at: micURL)
                    if let sys = systemURL {
                        try? FileManager.default.removeItem(at: sys)
                    }
                }

                let durationMinutes = self.durationEstimateMinutes(body: body)

                await MainActor.run {
                    self.lastTranscriptURL = transcriptURL
                    self.lastTranscriptItem.isEnabled = true
                    self.setStatus("Done: \(transcriptURL.lastPathComponent)")
                    self.store.reload()
                    self.finishTranscribing()
                    self.runArcUploadIfNeeded(transcriptURL: transcriptURL, body: body, durationMinutes: durationMinutes)
                }
            } catch {
                await MainActor.run {
                    self.setStatus("Transcription failed")
                    self.alert("Transcription failed: \(error.localizedDescription)")
                    self.finishTranscribing()
                }
            }
        }
    }

    private func fileHasContent(at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return (values?.fileSize ?? 0) > 1024  // >1 KB: header + some samples
    }

    /// Rough duration guess for the Arc communication record. Counts the
    /// largest `[m:ss]` timestamp in the body; falls back to nil if the
    /// transcript has none (e.g. very short mic-only recordings).
    private func durationEstimateMinutes(body: String) -> Int? {
        let pattern = #"\[(\d+):(\d{2})\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var maxSeconds = 0
        let ns = body as NSString
        regex.enumerateMatches(in: body, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 3 else { return }
            let minutes = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let seconds = Int(ns.substring(with: m.range(at: 2))) ?? 0
            maxSeconds = max(maxSeconds, minutes * 60 + seconds)
        }
        guard maxSeconds > 0 else { return nil }
        return max(1, Int((Double(maxSeconds) / 60.0).rounded()))
    }

    // MARK: - Arc upload

    private func runArcUploadIfNeeded(transcriptURL: URL, body: String, durationMinutes: Int?) {
        guard arcAuth.isSignedIn, let token = arcAuth.token else { return }
        guard let base = settings.arcAPIURL else { return }

        let mode = UploadMode(rawValue: settings.arcUploadMode) ?? .inbox
        switch mode {
        case .skip:
            return
        case .inbox:
            uploadToArc(transcriptURL: transcriptURL, body: body, projectID: nil,
                        durationMinutes: durationMinutes, token: token, base: base)
        case .ask:
            promptForProjectAndUpload(transcriptURL: transcriptURL, body: body,
                                      durationMinutes: durationMinutes, token: token, base: base)
        }
    }

    private enum UploadChoice {
        case inbox
        case project(String)
        case cancel
    }

    private func promptForProjectAndUpload(
        transcriptURL: URL, body: String, durationMinutes: Int?,
        token: String, base: URL
    ) {
        setStatus("Fetching Arc projects…")
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let client = ArcClient(baseURL: base, token: token)
            do {
                let projects = try await client.listProjects()
                    .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                switch self.showDestinationPicker(projects: projects, transcript: transcriptURL) {
                case .cancel:
                    self.setStatus("Upload skipped")
                case .inbox:
                    self.uploadToArc(transcriptURL: transcriptURL, body: body, projectID: nil,
                                     durationMinutes: durationMinutes, token: token, base: base)
                case .project(let id):
                    self.uploadToArc(transcriptURL: transcriptURL, body: body, projectID: id,
                                     durationMinutes: durationMinutes, token: token, base: base)
                }
            } catch ArcClient.Failure.unauthorized {
                self.handleArcUnauthorized()
            } catch {
                self.setStatus("Could not fetch Arc projects")
                self.alert("Fetching Arc projects failed: \(error.localizedDescription)")
            }
        }
    }

    /// Popup with `Inbox (no project)` as the first option, then each
    /// project. NSAlert accessoryView keeps it native and compact.
    private func showDestinationPicker(projects: [ArcProject], transcript: URL) -> UploadChoice {
        let alert = NSAlert()
        alert.messageText = "Upload transcript to Arc?"
        alert.informativeText = "\(transcript.lastPathComponent)\nSend to your inbox to triage in Arc, or pick a project to link it directly."

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        let inboxItem = NSMenuItem(title: "Inbox (triage in Arc)", action: nil, keyEquivalent: "")
        inboxItem.representedObject = "inbox"
        popup.menu?.addItem(inboxItem)
        popup.menu?.addItem(.separator())
        for project in projects {
            let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            item.representedObject = project.id
            popup.menu?.addItem(item)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Upload")
        alert.addButton(withTitle: "Skip")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return .cancel }
        guard let token = popup.selectedItem?.representedObject as? String else { return .cancel }
        return token == "inbox" ? .inbox : .project(token)
    }

    private func uploadToArc(
        transcriptURL: URL, body: String, projectID: String?,
        durationMinutes: Int?, token: String, base: URL
    ) {
        let destinationLabel = projectID == nil ? "inbox" : "project"
        setStatus("Uploading to Arc (\(destinationLabel))…")
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let client = ArcClient(baseURL: base, token: token)
            let subject = "Transcript — \(self.transcriptDateLabel(for: transcriptURL))"
            do {
                let created = try await client.createMeetingTranscript(
                    projectID: projectID,
                    subject: subject,
                    markdownBody: body,
                    occurredAt: self.transcriptOccurredAt(for: transcriptURL),
                    durationMinutes: durationMinutes
                )
                let marker = created.project_id ?? projectID ?? "inbox"
                self.markTranscriptUploaded(url: transcriptURL, marker: marker)
                self.setStatus("Uploaded to Arc ✓")
                self.store.reload()
            } catch ArcClient.Failure.unauthorized {
                self.handleArcUnauthorized()
            } catch {
                self.setStatus("Upload failed")
                self.alert("Arc upload failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleArcUnauthorized() {
        setStatus("Arc token expired")
        arcAuth.signOut()
        alert("Your Arc session expired. Open Settings and sign in again.")
    }

    /// Rewrite the transcript's header line so the row in the list flips
    /// from `icloud.slash` to the uploaded state. The `TranscriptsStore`
    /// parser keys on `- Arc upload: ` with any non-"none" value.
    private func markTranscriptUploaded(url: URL, marker: String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let uploadLine = "- Arc upload: \(marker) (\(stamp))"
        let updated: String
        if text.contains("- Arc upload: ") {
            updated = text.replacingOccurrences(
                of: #"- Arc upload: .*"#,
                with: uploadLine,
                options: .regularExpression
            )
        } else if let range = text.range(of: "- Created: ") {
            // Insert just after the Created line.
            let lineEnd = text.range(of: "\n", range: range.upperBound..<text.endIndex)?.lowerBound
                ?? text.endIndex
            updated = text.replacingCharacters(
                in: lineEnd..<lineEnd,
                with: "\n\(uploadLine)"
            )
        } else {
            updated = text
        }
        try? updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// "recording-2026-04-23-110027" → "2026-04-23 at 11:00"
    private func transcriptDateLabel(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "recording-", with: "")

        let inputFmt = DateFormatter()
        inputFmt.dateFormat = "yyyy-MM-dd-HHmmss"
        inputFmt.timeZone = TimeZone.current
        guard let date = inputFmt.date(from: stem) else { return stem }

        let outputFmt = DateFormatter()
        outputFmt.dateFormat = "yyyy-MM-dd 'at' HH:mm"
        outputFmt.timeZone = TimeZone.current
        return outputFmt.string(from: date)
    }

    private func transcriptOccurredAt(for url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] as? Date) ?? Date()
    }

    @MainActor
    private func finishTranscribing() {
        isTranscribing = false
        toggleItem.isEnabled = true
        updateIcon()
        publishRecordingFlags()
    }

    /// WhisperKit rejects entire 30-second windows when confidence
    /// scores dip. Default thresholds silently drop Swedish chunks
    /// even when the audio is clearly speech. Our use case — capture
    /// the meeting, accept the odd hallucination — wants the opposite
    /// bias, so we disable the logprob gates entirely and keep only a
    /// lenient no-speech check. The `compressionRatioThreshold` stays
    /// at 3.0 to still catch obvious model-loop failures.
    static func transcriptionOptions(language: String, live: Bool) -> DecodingOptions {
        let lang = language == "auto" ? nil : language
        return DecodingOptions(
            task: .transcribe,
            language: lang,
            detectLanguage: lang == nil,
            skipSpecialTokens: true,
            compressionRatioThreshold: 3.0,
            logProbThreshold: nil,            // disable — was dropping valid chunks
            firstTokenLogProbThreshold: nil,  // disable — ditto
            noSpeechThreshold: 0.9            // very lenient; only discard obvious silence
        )
    }

    private func loadWhisperIfNeeded() async throws -> WhisperKit {
        let wanted = settings.modelName
        if let whisper = whisper, loadedModel == wanted {
            return whisper
        }
        whisper = nil
        loadedModel = nil
        let label = WhisperModelOption.label(for: wanted)
        await MainActor.run {
            self.setStatus("Loading \(label)… (first run downloads the model)")
        }
        let config = WhisperKitConfig(model: wanted, verbose: false, logLevel: .error)
        let pipe = try await WhisperKit(config)
        whisper = pipe
        loadedModel = wanted
        return pipe
    }

    private func writeTranscript(
        basedOn micURL: URL,
        hasSystemAudio: Bool,
        body: String,
        detectedLanguages: [String]
    ) throws -> URL {
        // Strip the "-mic" suffix so transcripts are named `recording-<stamp>.md`.
        let stem = micURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-mic", with: "")
        let transcriptURL = micURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(stem).md")

        let langLine = detectedLanguages.isEmpty ? "auto" : detectedLanguages.joined(separator: ", ")
        let sourceLine: String
        if hasSystemAudio {
            sourceLine = "mic + system audio"
        } else if settings.speakerDiarization {
            sourceLine = "mic only (diarized)"
        } else {
            sourceLine = "mic only"
        }
        let header = """
        # Transcript

        - Source: \(sourceLine)
        - Model: \(settings.modelName)
        - Detected language: \(langLine)
        - Created: \(Date())

        ---

        """
        try (header + body + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        return transcriptURL
    }

    // MARK: - Menu actions

    @objc private func openLastTranscript() {
        guard let url = lastTranscriptURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleFloatingWindow() {
        if let win = floatingWindow, win.isVisible {
            win.orderOut(nil)
            floatingMenuItem.title = "Show Floating Controls"
        } else {
            showFloatingWindow()
        }
    }

    private func showFloatingWindow() {
        if floatingWindow == nil {
            let hosting = NSHostingController(rootView: FloatingControlView(state: state))
            hosting.sizingOptions = [.preferredContentSize]
            let size = NSSize(width: 280, height: 52)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentViewController = hosting
            panel.setContentSize(size)
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true

            // Top-right corner of the main screen, a bit below the menu bar.
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                let origin = NSPoint(
                    x: visible.maxX - size.width - 16,
                    y: visible.maxY - size.height - 16
                )
                panel.setFrameOrigin(origin)
            }

            floatingWindow = panel
        }

        floatingWindow?.orderFrontRegardless()
        floatingMenuItem.title = "Hide Floating Controls"
    }

    @objc private func showTranscripts() {
        store.reload()

        if transcriptsWindow == nil {
            let hosting = NSHostingController(rootView: TranscriptsView(store: store))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Transcriptions"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 500))
            window.isReleasedWhenClosed = false
            window.center()
            transcriptsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        transcriptsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openFolder(_ sender: Any?) {
        let folder = transcriptsFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: - Helpers

    private func transcriptsFolder() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Transcripts", isDirectory: true)
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    private func alert(_ message: String) {
        let a = NSAlert()
        a.messageText = "Arc Transcriber"
        a.informativeText = message
        a.alertStyle = .warning
        a.runModal()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
