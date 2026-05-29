import SwiftUI

struct TranscriptView: View {
    @Environment(AppState.self) private var appState

    /// テキスト領域がこれ以上高くならない上限。これを超えると内部スクロール＋最新行追従に切り替わる。
    private let maxHeight: CGFloat = 240
    /// 1行ぶんの最低高さ（空表示・プレースホルダ時に潰れないように）。
    private let minHeight: CGFloat = 22

    @State private var measuredHeight: CGFloat = 22

    private let bottomAnchor = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    // スクロール末尾の目印。最新テキストが流れてもここへ追従する。
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TranscriptHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
            }
            .frame(height: clampedHeight)
            .onPreferenceChange(TranscriptHeightKey.self) { measuredHeight = $0 }
            .onChange(of: displayText) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: appState.phase) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if displayText.isEmpty {
            Text(placeholder)
                .foregroundStyle(.secondary)
                .font(.system(size: 15))
                .multilineTextAlignment(.leading)
        } else {
            Text(displayText)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
    }

    private var clampedHeight: CGFloat {
        min(max(measuredHeight, minHeight), maxHeight)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // あふれている時だけ末尾へ追従。アニメーションは付けない
        //（録音中は毎トークン更新されるため、アニメーションさせると Core Animation が回り続け重くなる）。
        guard measuredHeight > maxHeight else { return }
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
    }

    private var displayText: String {
        switch appState.phase {
        case .recording, .processing:
            return appState.currentText
        case .ready:
            return appState.lastFinalText
        default:
            return ""
        }
    }

    private var placeholder: String {
        switch appState.phase {
        case .booting, .downloadingModel, .loadingModel:
            return "モデルを準備しています…"
        case .ready:
            return "⌘⇧Rで録音開始 — 話し始めるとここに表示されます"
        case .recording:
            return "聞いています…"
        case .processing:
            return "文字起こし中…"
        case .error(let msg):
            return msg
        }
    }
}

/// テキスト本文の実測高さを親へ伝えるための PreferenceKey。
private struct TranscriptHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
