import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController {
    private let panel: FloatingPanel
    private let appState: AppState
    private let panelWidth: CGFloat = 720
    private let initialHeight: CGFloat = 148
    private let minHeight: CGFloat = 72

    init(appState: AppState) {
        self.appState = appState
        self.panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: panelWidth, height: initialHeight))
        )

        let root = PanelRootView(onHeightChange: { [weak self] height in
            self?.resizeToContentHeight(height)
        })
            .environment(appState)

        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        positionAtBottom()
    }

    func show() {
        positionAtBottom()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func togglePanelVisibility() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    /// SwiftUI 側で実測した中身の高さに合わせてパネルを伸縮させる。
    /// 画面下端からの位置（下辺）は固定し、高さの増減ぶんは上方向に伸ばす。
    private func resizeToContentHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        let newHeight = max(minHeight, height.rounded(.up))
        var frame = panel.frame
        guard abs(frame.size.height - newHeight) > 0.5 else { return }
        // macOS 座標系は左下原点。origin.y（下辺）を固定したまま高さだけ変えれば上方向に伸びる。
        frame.size.height = newHeight
        frame.size.width = panelWidth
        panel.setFrame(frame, display: true, animate: false)
    }

    private func positionAtBottom() {
        let screen = currentScreen()
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 96
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func currentScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first!
    }
}
