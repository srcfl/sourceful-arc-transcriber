import Foundation
import Combine

struct TranscriptItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let modified: Date
    let preview: String
    let uploadedToArc: Bool
    var title: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
final class TranscriptsStore: ObservableObject {
    @Published private(set) var items: [TranscriptItem] = []
    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let entries = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        items = entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { url -> TranscriptItem in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let modified = values?.contentModificationDate ?? .distantPast
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return TranscriptItem(
                    url: url,
                    modified: modified,
                    preview: previewBody(from: text),
                    uploadedToArc: text.contains("- Arc upload: ") && !text.contains("- Arc upload: none")
                )
            }
            .sorted { $0.modified > $1.modified }
    }

    func delete(_ item: TranscriptItem) throws {
        try FileManager.default.removeItem(at: item.url)
        // Also remove any co-located audio files with the same stem.
        let stem = item.url.deletingPathExtension().lastPathComponent
        let parent = item.url.deletingLastPathComponent()
        for ext in ["wav", "caf"] {
            let audio = parent.appendingPathComponent("\(stem).\(ext)")
            try? FileManager.default.removeItem(at: audio)
            let micAudio = parent.appendingPathComponent("\(stem)-mic.\(ext)")
            try? FileManager.default.removeItem(at: micAudio)
            let sysAudio = parent.appendingPathComponent("\(stem)-system.\(ext)")
            try? FileManager.default.removeItem(at: sysAudio)
        }
        reload()
    }

    private func previewBody(from markdown: String) -> String {
        // Skip the frontmatter/header block, take the first content line.
        let parts = markdown.components(separatedBy: "---")
        let body = parts.count > 1 ? parts.dropFirst().joined(separator: "---") : markdown
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? ""
        return String(firstLine.prefix(140))
    }
}
