import AppKit
import SwiftUI
import KeyboardShortcuts
import WhisperKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var clipboardCopy: (String) -> Void = Clipboard.copy
    private var panelController: FloatingPanelController?
    private var whisperEngine: WhisperEngine?
    private var streamingTranscriber: StreamingTranscriber?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panelController = FloatingPanelController(appState: appState)
        panelController?.show()

        registerHotkey()
        observeNotifications()

        Task { await prewarmWhisper() }
    }

    private func registerHotkey() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.appState.toggleRecording()
        }
        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in
            self?.panelController?.togglePanelVisibility()
        }
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(forName: .showPanel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panelController?.show() }
        }
        NotificationCenter.default.addObserver(forName: .togglePanel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panelController?.togglePanelVisibility() }
        }
        NotificationCenter.default.addObserver(forName: .hidePanel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panelController?.hide() }
        }
        NotificationCenter.default.addObserver(forName: .retryModelLoad, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.prewarmWhisper() }
        }
        NotificationCenter.default.addObserver(forName: .reloadModel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reloadModelIfPossible() }
        }

        appState.onRecordingChange = { [weak self] shouldRecord in
            guard let self else { return }
            Task { @MainActor in
                if shouldRecord {
                    await self.startRecording()
                } else {
                    await self.stopRecording()
                }
            }
        }
    }

    private func reloadModelIfPossible() async {
        guard appState.canChangeModel else { return }
        await prewarmWhisper()
    }

    private func prewarmWhisper() async {
        Task {
            _ = await AudioProcessor.requestRecordPermission()
        }

        do {
            let engine = WhisperEngine()
            let modelName = Settings.shared.modelName
            appState.currentModelName = modelName
            whisperEngine = nil
            streamingTranscriber = nil
            // キャッシュ済みなら初回DL文言を出さず、準備中スピナーのみ表示。
            // 毎回ダウンロード画面が出る誤解を避ける。
            let cached = await engine.isModelCached(modelName: modelName)
            appState.phase = cached ? .loadingModel : .downloadingModel(progress: 0)
            try await engine.load(
                modelName: modelName,
                progress: { [weak self] p in
                    Task { @MainActor in
                        guard let self else { return }
                        if cached || p >= 1.0 {
                            self.appState.phase = .loadingModel
                        } else {
                            self.appState.phase = .downloadingModel(progress: p)
                        }
                    }
                }
            )
            do {
                try await engine.warmupTranscription(
                    language: Settings.shared.language,
                    noSpeechThreshold: Settings.shared.noSpeechThreshold
                )
            } catch {
                print("[STT/warmup] failed: \(error.localizedDescription)")
            }
            self.whisperEngine = engine
            self.streamingTranscriber = await StreamingTranscriber(engine: engine, appState: appState)
            appState.phase = .ready
        } catch {
            appState.phase = .error(message: "モデル読込失敗: \(error.localizedDescription)")
        }
    }

    private func startRecording() async {
        guard case .ready = appState.phase else { return }
        guard let st = streamingTranscriber else {
            appState.phase = .error(message: "Whisperが未準備です")
            return
        }
        appState.confirmedText = ""
        appState.unconfirmedText = ""
        appState.isInferring = false
        appState.bufferEnergy = [0]
        appState.phase = .recording
        do {
            try await st.start()
        } catch {
            appState.phase = .error(message: "録音開始失敗: \(presentableRecordingError(error))")
        }
    }

    private func stopRecording() async {
        guard let st = streamingTranscriber else { return }
        appState.phase = .processing
        let finalText = await st.stop()
        appState.isInferring = false
        handleFinalText(finalText)
        appState.phase = .ready
    }

    func handleFinalText(_ finalText: String) {
        let trimmedFinalText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFinalText.isEmpty else { return }
        clipboardCopy(trimmedFinalText)
        appState.lastFinalText = trimmedFinalText
        appState.flashCopiedToast()
    }

    private func presentableRecordingError(_ error: Error) -> String {
        if let transcriberError = error as? StreamingTranscriber.TranscriberError {
            return transcriberError.localizedDescription
        }
        if let whisperError = error as? WhisperError {
            switch whisperError {
            case .microphoneUnavailable:
                return "利用可能なマイク入力が見つかりません"
            default:
                return whisperError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
