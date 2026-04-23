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

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

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

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        showFloatingWindow()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "Transcriber")
        appItem.submenu = appMenu

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)

        appMenu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Transcriber", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Transcriber Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Transcriber") {
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
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard granted else {
                    self.alert("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
                    return
                }
                self.startRecording()
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
        liveTranscriber?.stop()
        liveTranscriber = nil
        state.liveText = ""
        isRecording = false
        toggleItem.title = "Start Recording"
        updateIcon()
        publishRecordingFlags()
        stopMeterPolling()

        guard let mic = micURL else {
            setStatus("Idle")
            return
        }

        setStatus("Finalizing audio…")
        let sys = systemURL
        let hadSystem = didCaptureSystemAudio

        Task { [weak self] in
            guard let self = self else { return }
            if hadSystem {
                await self.systemAudio.stop()
            }
            await MainActor.run {
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
                let options: DecodingOptions = {
                    if self.settings.language == "auto" {
                        return DecodingOptions(task: .transcribe, detectLanguage: true)
                    }
                    return DecodingOptions(task: .transcribe, language: self.settings.language, detectLanguage: false)
                }()

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

                await MainActor.run {
                    self.lastTranscriptURL = transcriptURL
                    self.lastTranscriptItem.isEnabled = true
                    self.setStatus("Done: \(transcriptURL.lastPathComponent)")
                    self.store.reload()
                    self.finishTranscribing()
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

    @MainActor
    private func finishTranscribing() {
        isTranscribing = false
        toggleItem.isEnabled = true
        updateIcon()
        publishRecordingFlags()
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
        a.messageText = "Transcriber"
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
