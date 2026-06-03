import SwiftUI

struct TranscriptView: View {
    @Environment(AppState.self) private var appState

    /// テキスト領域がこれ以上高くならない上限。これを超えると内部スクロール＋最新行追従に切り替わる。
    private let maxHeight: CGFloat = 240
    /// 1行ぶんの最低高さ（空表示・プレースホルダ時に潰れないように）。
    private let minHeight: CGFloat = 22

    @State private var measuredHeight: CGFloat = 22

    private let bottomAnchor = "transcript-bottom"
    // 未確定（＝再デコードで変わりうる「推論中」の末尾）はかなり薄く落として、確定テキストと
    // 一目で区別できるようにする。読めるが明確に控えめ、が狙い。好みで 0.25〜0.4 で調整可。
    private let unconfirmedColor = Color.white.opacity(0.3)

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
        if visibleText.isEmpty {
            Text(placeholder)
                .foregroundStyle(.secondary)
                .font(.system(size: 15))
                .multilineTextAlignment(.leading)
        } else {
            transcriptText
                .font(.system(size: 15))
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
            return appState.confirmedText + appState.unconfirmedText
        case .ready:
            return appState.lastFinalText
        default:
            return ""
        }
    }

    private var visibleText: String {
        switch appState.phase {
        case .recording, .processing:
            let segments = trimmedDisplaySegments
            return segments.confirmed + segments.unconfirmed
        case .ready:
            return appState.lastFinalText.trimmingLeadingWhitespace()
        default:
            return ""
        }
    }

    private var transcriptText: Text {
        switch appState.phase {
        case .recording, .processing:
            let segments = trimmedDisplaySegments
            return Text(segments.confirmed)
                .foregroundStyle(.primary)
            + Text(segments.unconfirmed)
                .foregroundStyle(unconfirmedColor)
            + Text(showsProgressEllipsis ? "…" : "")
                .foregroundStyle(unconfirmedColor)
        case .ready:
            return Text(visibleText).foregroundStyle(.primary)
        default:
            return Text("")
        }
    }

    private var trimmedDisplaySegments: (confirmed: String, unconfirmed: String) {
        trimLeadingWhitespace(
            confirmed: appState.confirmedText,
            unconfirmed: appState.unconfirmedText
        )
    }

    private var showsProgressEllipsis: Bool {
        appState.phase == .recording
    }

    private func trimLeadingWhitespace(confirmed: String, unconfirmed: String) -> (String, String) {
        let combined = confirmed + unconfirmed
        let trimmedCombined = combined.trimmingLeadingWhitespace()
        let removedCount = combined.count - trimmedCombined.count
        guard removedCount > 0 else {
            return (confirmed, unconfirmed)
        }

        if removedCount <= confirmed.count {
            let trimmedConfirmed = String(confirmed.dropFirst(removedCount))
            return (trimmedConfirmed, unconfirmed)
        }

        let unconfirmedTrimCount = removedCount - confirmed.count
        return ("", String(unconfirmed.dropFirst(unconfirmedTrimCount)))
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

private extension String {
    func trimmingLeadingWhitespace() -> String {
        guard let firstNonWhitespace = firstIndex(where: { !$0.isWhitespace }) else {
            return ""
        }
        return String(self[firstNonWhitespace...])
    }
}

/// テキスト本文の実測高さを親へ伝えるための PreferenceKey。
private struct TranscriptHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
