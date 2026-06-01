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

    /// Honors the system "Reduce Motion" setting — when on, we skip slide/fade
    /// and just show/hide instantly.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

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

        if reduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }

        toastHide?.cancel()
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let panel else { return }
            if self?.reduceMotion ?? true {
                panel.orderOut(nil)
            } else {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    panel.animator().alphaValue = 0
                }, completionHandler: { panel.orderOut(nil) })
            }
        }
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
        let target = panel.frame.origin

        guard !reduceMotion else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        // Rise + fade in: start a touch lower and transparent, settle to target.
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: target.x, y: target.y - 10))
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(target)
        }
    }

    func hide() {
        guard let panel else { return }
        guard !reduceMotion else { panel.orderOut(nil); return }

        let origin = panel.frame.origin
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 8))
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
