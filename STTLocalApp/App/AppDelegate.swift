import AppKit
import SwiftUI
import KeyboardShortcuts
import WhisperKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
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

    private func prewarmWhisper() async {
        appState.phase = .downloadingModel(progress: 0)
        do {
            let engine = WhisperEngine()
            try await engine.load(
                modelName: Settings.shared.modelName,
                progress: { [weak self] p in
                    Task { @MainActor in
                        if p < 1.0 {
                            self?.appState.phase = .downloadingModel(progress: p)
                        } else {
                            self?.appState.phase = .loadingModel
                        }
                    }
                }
            )
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
        appState.currentText = ""
        appState.bufferEnergy = []
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
        Clipboard.copy(finalText)
        appState.lastFinalText = finalText
        appState.flashCopiedToast()
        appState.phase = .ready
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
