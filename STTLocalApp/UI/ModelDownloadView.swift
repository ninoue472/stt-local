import SwiftUI

struct ModelDownloadView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("音声認識モデルを準備中")
                    .font(.system(size: 12, weight: .medium))
                Text("初回のみ、800MBほどダウンロードします")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .downloadingModel(let p) = appState.phase {
                ProgressView(value: p)
                    .frame(width: 120)
                Text("\(Int(p * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct CopiedToastView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("クリップボードにコピーしました")
                .font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .transition(.opacity)
    }
}

struct ErrorActionView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(errorMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("再試行") {
                NotificationCenter.default.post(name: .retryModelLoad, object: nil)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var errorMessage: String {
        if case .error(let msg) = appState.phase { return msg }
        return ""
    }
}
