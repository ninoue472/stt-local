import SwiftUI

struct PanelRootView: View {
    @Environment(AppState.self) private var appState

    /// 中身の実測高さが変わるたびに呼ばれる。コントローラがこれを使ってパネルを動的リサイズする。
    var onHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                MainBar()
                if case .downloadingModel = appState.phase {
                    Divider().opacity(0.2)
                    ModelDownloadView()
                }
                if case .error = appState.phase {
                    Divider().opacity(0.2)
                    ErrorActionView()
                }
                if appState.justCopied {
                    Divider().opacity(0.2)
                    CopiedToastView()
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
                }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
        .onPreferenceChange(PanelHeightKey.self) { onHeightChange($0) }
    }
}

/// パネル中身（VStack）の実測高さを親へ伝えるための PreferenceKey。
private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MainBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 8) {
                TranscriptView()
                // 推論中/確定のステータスは文字色（確定=濃 / 未確定=薄）と左上 StatusIcon で
                // 伝わるため、専用バッジは冗長として非表示。入力の有無は波形が担う。
                // 復活させたい場合は StatusBadge() を再配置する（StatusBadge.swift は残置）。
                if shouldShowWaveform {
                    WaveformView(energies: Array(appState.bufferEnergy.suffix(80)))
                        .frame(height: 16)
                        .opacity(0.9)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 8) {
                    RecordingHintLabel()
                    LanguageMenu()
                    ModelMenu()
                }
                HStack(spacing: 8) {
                    CopyButton()
                    MicButton()
                    CloseButton()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var shouldShowWaveform: Bool {
        guard !appState.bufferEnergy.isEmpty else { return false }
        switch appState.phase {
        case .recording, .processing:
            return true
        default:
            return false
        }
    }
}

private struct LanguageMenu: View {
    @Environment(AppState.self) private var appState
    @State private var hovering = false

    var body: some View {
        Menu {
            languageButton(code: "ja", title: "日本語")
            languageButton(code: "ko", title: "한국어")
        } label: {
            HStack(spacing: 6) {
                Text(selectedLanguageLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isEnabled ? .white : .secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(isEnabled ? 0.08 : 0.04), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.7)
        .help(helpText)
        .onHover { hovering = $0 }
    }

    private var isEnabled: Bool {
        if case .ready = appState.phase {
            return true
        }
        return false
    }

    private var helpText: String {
        if isEnabled {
            return "文字起こし言語: \(selectedLanguageLabel)"
        }
        return "文字起こし言語: \(selectedLanguageLabel)（待機中のみ変更可）"
    }

    private var selectedLanguageLabel: String {
        appState.language == "ko" ? "한국어" : "日本語"
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return Color.white.opacity(0.05)
        }
        return hovering ? Color.white.opacity(0.18) : Color.white.opacity(0.10)
    }

    @ViewBuilder
    private func languageButton(code: String, title: String) -> some View {
        Button {
            appState.language = code
        } label: {
            if appState.language == code {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

private struct ModelMenu: View {
    @Environment(AppState.self) private var appState
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(ModelCatalog.all) { entry in
                Button {
                    appState.selectModel(entry)
                } label: {
                    if appState.currentModelName == entry.id {
                        Label(entry.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(entry.menuTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedModelLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isEnabled ? .white : .secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(isEnabled ? 0.08 : 0.04), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.7)
        .help(helpText)
        .onHover { hovering = $0 }
    }

    private var isEnabled: Bool {
        appState.canChangeModel
    }

    private var helpText: String {
        if isEnabled {
            return "文字起こしモデル: \(selectedModelLabel)"
        }
        return "文字起こしモデル: \(selectedModelLabel)（待機中のみ変更可）"
    }

    private var selectedModelLabel: String {
        selectedModelEntry?.displayName ?? appState.currentModelName
    }

    private var selectedModelEntry: ModelCatalogEntry? {
        ModelCatalog.all.first { $0.id == appState.currentModelName }
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return Color.white.opacity(0.05)
        }
        return hovering ? Color.white.opacity(0.18) : Color.white.opacity(0.10)
    }
}

private struct CloseButton: View {
    @State private var hovering = false

    var body: some View {
        Button(action: {
            NotificationCenter.default.post(name: .hidePanel, object: nil)
        }) {
            ZStack {
                Circle()
                    .fill(hovering ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                    .frame(width: 22, height: 22)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("パネルを隠す (Esc / ⌘⇧P)")
    }
}

private struct CopyButton: View {
    @Environment(AppState.self) private var appState
    @State private var hovering = false

    var body: some View {
        Button(action: {
            let text = appState.copyableText
            guard !text.isEmpty else { return }
            Clipboard.copy(text)
            appState.flashCopiedToast()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)
                    .frame(width: 32, height: 32)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isEnabled ? .white : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.45)
        .help("テキストをコピー")
        .onHover { hovering = $0 }
    }

    private var isEnabled: Bool {
        !appState.copyableText.isEmpty
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return .gray.opacity(0.6)
        }
        return hovering ? Color.white.opacity(0.18) : Color.white.opacity(0.10)
    }
}

private struct StatusIcon: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            switch appState.phase {
            case .recording:
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                    .foregroundStyle(.orange)
                    .font(.system(size: 20, weight: .medium))
            case .processing:
                ProgressView().controlSize(.small)
            case .downloadingModel, .loadingModel:
                ProgressView().controlSize(.small)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 20))
            case .booting, .ready:
                Image(systemName: "sparkles")
                    .foregroundStyle(LinearGradient(
                        colors: [.orange, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .font(.system(size: 20, weight: .medium))
            }
        }
    }
}

private struct RecordingHintLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.phase {
            case .ready:
                Text("⌘⇧R")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            case .recording:
                Text("録音中")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            case .processing:
                Text("処理中")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .downloadingModel(let p):
                Text("モデルDL \(Int(p * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .loadingModel:
                Text("読込中")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }
}
