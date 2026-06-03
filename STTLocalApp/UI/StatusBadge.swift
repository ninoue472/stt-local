import SwiftUI

struct StatusBadge: View {
    @Environment(AppState.self) private var appState
    @State private var isAnimatingPulse = false

    var body: some View {
        Group {
            if let presentation = presentation {
                HStack(spacing: 6) {
                    Circle()
                        .fill(presentation.dotColor)
                        .frame(width: 7, height: 7)
                        .scaleEffect(presentation.pulses && isAnimatingPulse ? 1.18 : 0.92)
                        .opacity(presentation.pulses && isAnimatingPulse ? 1.0 : presentation.restingOpacity)

                    Text(presentation.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear(perform: updatePulseAnimation)
                .onChange(of: appState.phase) { _, _ in
                    updatePulseAnimation()
                }
            }
        }
    }

    private var presentation: Presentation? {
        // バッジは「推論ステータス」専用。入力の有無（聞いているか）は波形が担うので
        // ここでは扱わない。録音中は新規音声をためる合間も含め実質ずっと推論サイクルが
        // 回っているため、isInferring の細かな ON/OFF でラベルをチラつかせず、録音中・
        // 処理中は安定して「推論中…」を表示する。
        switch appState.phase {
        case .recording, .processing:
            return Presentation(label: "推論中…", dotColor: .orange, restingOpacity: 0.5, pulses: true)
        default:
            return nil
        }
    }

    private func updatePulseAnimation() {
        guard let presentation else {
            isAnimatingPulse = false
            return
        }

        guard presentation.pulses else {
            isAnimatingPulse = false
            return
        }

        isAnimatingPulse = false
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            isAnimatingPulse = true
        }
    }
}

private struct Presentation {
    let label: String
    let dotColor: Color
    let restingOpacity: Double
    let pulses: Bool
}
