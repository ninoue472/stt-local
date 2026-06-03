import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    enum Phase: Equatable {
        case booting
        case downloadingModel(progress: Double)
        case loadingModel
        case ready
        case recording
        case processing
        case error(message: String)
    }

    var phase: Phase = .booting
    var confirmedText: String = ""
    var unconfirmedText: String = ""
    var isInferring: Bool = false
    var lastFinalText: String = ""
    var bufferEnergy: [Float] = []
    var justCopied: Bool = false

    var onRecordingChange: ((Bool) -> Void)?

    func toggleRecording() {
        switch phase {
        case .ready:
            onRecordingChange?(true)
        case .recording:
            onRecordingChange?(false)
        default:
            break
        }
    }

    var isModelReady: Bool {
        switch phase {
        case .ready, .recording, .processing: return true
        default: return false
        }
    }

    var currentText: String {
        confirmedText + unconfirmedText
    }

    var copyableText: String {
        let text: String
        switch phase {
        case .recording, .processing:
            text = currentText
        case .ready:
            text = lastFinalText
        default:
            text = ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func flashCopiedToast() {
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if justCopied { justCopied = false }
        }
    }
}
