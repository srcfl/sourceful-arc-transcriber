import SwiftUI
import AppKit

struct TranscriptsView: View {
    @ObservedObject var store: TranscriptsStore
    @State private var selection: TranscriptItem.ID?
    @State private var pendingDelete: TranscriptItem?

    var body: some View {
        NavigationSplitView {
            List(store.items, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                        if !item.uploadedToArc {
                            Image(systemName: "icloud.slash")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help("Not uploaded to Arc")
                        }
                    }
                    Text(item.modified.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !item.preview.isEmpty {
                        Text(item.preview)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .tag(item.id)
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        pendingDelete = item
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .onDeleteCommand {
                if let id = selection, let item = store.items.first(where: { $0.id == id }) {
                    pendingDelete = item
                }
            }
            .toolbar {
                Button {
                    store.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        } detail: {
            if let id = selection, let item = store.items.first(where: { $0.id == id }) {
                TranscriptDetailView(item: item)
            } else if store.items.isEmpty {
                emptyState(text: "No transcripts yet. Record something from the menu bar.")
            } else {
                emptyState(text: "Select a transcript")
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .onAppear { store.reload() }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) {
                try? store.delete(item)
                if selection == item.id { selection = nil }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { item in
            if item.uploadedToArc {
                Text("Delete \(item.title)? This cannot be undone.")
            } else {
                Text("\(item.title) hasn't been uploaded to Arc. Delete it anyway? This cannot be undone.")
            }
        }
    }

    private var deleteTitle: String {
        guard let item = pendingDelete else { return "Delete transcript?" }
        return item.uploadedToArc ? "Delete transcript?" : "Delete unuploaded transcript?"
    }

    private func emptyState(text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TranscriptDetailView: View {
    let item: TranscriptItem
    @State private var text: String = ""

    var body: some View {
        ScrollView {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .toolbar {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            // Placeholder for M5 — upload to Arc Backend with project picker.
            Button {
                // TODO: open project picker, POST to Arc.
            } label: {
                Label("Upload to Arc", systemImage: "icloud.and.arrow.up")
            }
            .disabled(true)
            .help("Upload to Arc Backend — coming soon")
        }
        .onAppear { load() }
        .onChange(of: item.id) { _, _ in load() }
    }

    private func load() {
        text = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
    }
}
