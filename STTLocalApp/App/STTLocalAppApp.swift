import SwiftUI

@main
struct STTLocalAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("STT", systemImage: "waveform") {
            MenuBarContent()
                .environment(appDelegate.appState)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button("パネルを表示") {
            NotificationCenter.default.post(name: .showPanel, object: nil)
        }
        Button("パネルを隠す") {
            NotificationCenter.default.post(name: .hidePanel, object: nil)
        }
        Button("パネル表示切替 (⌘⇧P)") {
            NotificationCenter.default.post(name: .togglePanel, object: nil)
        }
        Divider()
        Button("録音トグル (⌘⇧R)") {
            appState.toggleRecording()
        }
        Divider()
        Section("モデル") {
            ForEach(ModelCatalog.all) { model in
                Button(modelTitle(for: model)) {
                    selectModel(model)
                }
                .disabled(!appState.canChangeModel)
            }
        }
        Divider()
        Text(statusText)
        Divider()
        Button("終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        switch appState.phase {
        case .booting:               return "起動中"
        case .downloadingModel(let p): return "モデルDL中 \(Int(p * 100))%"
        case .loadingModel:          return "モデル読込中"
        case .ready:                 return "待機中"
        case .recording:             return "録音中"
        case .processing:            return "処理中"
        case .error(let msg):        return "エラー: \(msg)"
        }
    }

    private func modelTitle(for model: ModelCatalogEntry) -> String {
        let title = model.menuTitle
        if model.id == appState.currentModelName {
            return "✓ \(title)"
        }
        return title
    }

    private func selectModel(_ model: ModelCatalogEntry) {
        appState.selectModel(model)
    }
}

extension Notification.Name {
    static let showPanel = Notification.Name("STTLocalApp.showPanel")
    static let togglePanel = Notification.Name("STTLocalApp.togglePanel")
    static let hidePanel = Notification.Name("STTLocalApp.hidePanel")
    static let retryModelLoad = Notification.Name("STTLocalApp.retryModelLoad")
    static let reloadModel = Notification.Name("STTLocalApp.reloadModel")
}
