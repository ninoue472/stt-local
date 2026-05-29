import SwiftUI

struct MicButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button(action: { appState.toggleRecording() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(buttonBackground)
                    .frame(width: 32, height: 32)
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.4)
        .help(helpText)
    }

    private var iconName: String {
        switch appState.phase {
        case .recording: return "stop.fill"
        case .processing, .loadingModel, .downloadingModel: return "hourglass"
        default: return "mic.fill"
        }
    }

    private var buttonBackground: Color {
        switch appState.phase {
        case .recording: return .red
        case .ready: return .orange
        default: return .gray
        }
    }

    private var isEnabled: Bool {
        switch appState.phase {
        case .ready, .recording: return true
        default: return false
        }
    }

    private var helpText: String {
        switch appState.phase {
        case .ready: return "録音開始 (⌘⇧R)"
        case .recording: return "停止してコピー (⌘⇧R)"
        default: return ""
        }
    }
}
