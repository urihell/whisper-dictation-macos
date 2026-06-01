import AppKit
import SwiftUI
import QuartzCore

/// Manages the floating, non-activating panel that displays live dictation.
/// The panel must never become key, so keyboard focus stays in the app the
/// user is dictating into.
@MainActor
final class OverlayController {
    static let shared = OverlayController()

    private var panel: NSPanel?
    private var toastPanel: NSPanel?
    private var toastHide: DispatchWorkItem?

    private init() {}

    /// Briefly shows a self-dismissing message (e.g. "Switched to Large v3").
    func toast(_ message: String, duration: TimeInterval = 3) {
        let panel = toastPanel ?? makeToastPanel()
        toastPanel = panel
        (panel.contentView as? NSHostingView<ToastView>)?.rootView = ToastView(message: message)
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)

        if let screen = NSScreen.main {
            let size = panel.frame.size
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 220))
        }
        panel.orderFrontRegardless()

        toastHide?.cancel()
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        toastHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func makeToastPanel() -> NSPanel {
        let hosting = NSHostingView(rootView: ToastView(message: ""))
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hosting
        return panel
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(
            rootView: DictationHUD(
                transcriber: DictationController.shared.transcriber,
                controller: DictationController.shared
            )
        )

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        // Never steal focus from the app being dictated into.
        panel.styleMask.insert(.nonactivatingPanel)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        return panel
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.minY + 120
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
