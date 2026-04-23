import Foundation
import Combine

@MainActor
final class RecordingState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var status: String = "Idle"
    @Published var micLevel: Float = 0       // 0…1
    @Published var systemLevel: Float = 0    // 0…1
    @Published var liveText: String = ""

    var onToggle: @MainActor () -> Void = {}
    var onShowTranscripts: @MainActor () -> Void = {}
}
