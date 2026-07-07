import AppKit
import SwiftUI
import QuartzCore
import ApplicationServices

/// Manages the floating, non-activating panel that displays live dictation.
/// The panel must never become key, so keyboard focus stays in the app the
/// user is dictating into.
@MainActor
final class OverlayController {
    static let shared = OverlayController()

    private var panel: NSPanel?
    private var toastPanel: NSPanel?
    private var toastHide: DispatchWorkItem?
    /// Bumped on every show()/hide() so a hide animation's completion can tell
    /// it was superseded. Without this, a show() during the ~0.16s fade-out
    /// (instant restarts via the warm mic) gets its panel ordered out by the
    /// stale completion, leaving the HUD invisible for the whole session.
    private var hideGeneration = 0

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

        if let screen = Self.targetScreen() {
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
        // Same fullscreen/level treatment as the HUD panel — a toast after
        // dictating into a fullscreen app must be visible there too.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hosting
        return panel
    }

    func show() {
        hideGeneration += 1   // invalidate any in-flight hide completion
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
        scheduleVisibilityBackstop()
    }

    /// Pending post-show visibility verification; cancelled by hide().
    private var visibilityCheck: DispatchWorkItem?

    /// Field reports of "dictation started but no HUD" (single screen, no
    /// fullscreen) that no constructible show/hide race explains. Backstop:
    /// shortly after show() — past the 0.22s fade — verify the panel really
    /// is on screen at full alpha while a session is active. If not, log the
    /// exact window state (the diagnosis for the next report) and force it
    /// visible (the user is never left dictating blind, whatever the cause).
    private func scheduleVisibilityBackstop() {
        visibilityCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            guard DictationController.shared.isActive else { return }
            if !panel.isVisible || panel.alphaValue < 0.9 {
                Log.error("HUD backstop: panel not presented after show() — visible=\(panel.isVisible), alpha=\(panel.alphaValue), frame=\(NSStringFromRect(panel.frame)), occlusion=\(panel.occlusionState.rawValue), screens=\(NSScreen.screens.count). Forcing to front.")
                self.reposition(panel)
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            }
        }
        visibilityCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func hide() {
        visibilityCheck?.cancel()
        visibilityCheck = nil
        guard let panel else { return }
        hideGeneration += 1
        let generation = hideGeneration
        guard !reduceMotion else { panel.orderOut(nil); return }

        let origin = panel.frame.origin
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 8))
        }, completionHandler: { [weak self] in
            // Only order out if no show()/hide() superseded this animation.
            guard self?.hideGeneration == generation else { return }
            panel.orderOut(nil)
        })
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
        // .statusBar level + .fullScreenAuxiliary: BOTH are required for the
        // HUD to appear over a fullscreen app. Without fullScreenAuxiliary the
        // panel is excluded from fullscreen Spaces entirely — dictation ran
        // with no visible HUD whenever the target app was fullscreen.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No window-server shadow: on a borderless, translucent, rounded panel it
        // renders as a hard rectangle tracing the square window bounds (the black
        // edge). The SwiftUI card draws its own soft rounded shadow instead, with
        // transparent padding around it so that shadow isn't clipped.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        // Never steal focus from the app being dictated into.
        panel.styleMask.insert(.nonactivatingPanel)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        return panel
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = Self.targetScreen() else { return }
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.minY + 120
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Screen targeting

    /// The screen the HUD should appear on: where the user is dictating, not
    /// the primary display. `NSScreen.main` is useless for an LSUIElement app
    /// (no key window → primary display), which parked the HUD on the wrong
    /// monitor in multi-display setups. Order: the frontmost app's focused
    /// window's screen (Accessibility — already granted for typing), else the
    /// screen under the mouse, else main.
    static func targetScreen() -> NSScreen? {
        if let windowFrame = focusedWindowFrameCocoa() {
            let best = NSScreen.screens.max { a, b in
                a.frame.intersection(windowFrame).area < b.frame.intersection(windowFrame).area
            }
            if let best, best.frame.intersects(windowFrame) { return best }
        }
        if let mouseScreen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) {
            return mouseScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Frame of the frontmost app's focused window, converted from the
    /// Accessibility coordinate space (top-left origin, y down) to Cocoa
    /// screen coordinates (bottom-left origin, y up). Nil when AX is
    /// untrusted or the app exposes no focused window.
    private static func focusedWindowFrameCocoa() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, CFGetTypeID(positionRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID(),
              AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }

        // AX y grows downward from the primary screen's top; Cocoa y grows
        // upward from its bottom. The primary screen is screens[0] with
        // origin (0,0), so its height flips the axis.
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaY = primary.frame.maxY - (position.y + size.height)
        return CGRect(x: position.x, y: cocoaY, width: size.width, height: size.height)
    }
}

private extension CGRect {
    /// Zero for null/empty intersections, so `max(by:)` picks a real overlap.
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
