import AppKit
import ApplicationServices

/// Inserts text into the focused app by placing it on the pasteboard and
/// synthesizing a ⌘V keystroke, then restoring the prior clipboard.
final class TextInserter {
    /// Returns whether the process is trusted for Accessibility. When `prompt`
    /// is true and untrusted, macOS shows its grant dialog.
    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func insert(_ text: String, restoreClipboard: Bool) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let saved = restoreClipboard ? pasteboard.string(forType: .string) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        paste()

        if restoreClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pasteboard.clearContents()
                if let saved {
                    pasteboard.setString(saved, forType: .string)
                }
            }
        }
    }

    private func paste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9 // "v"

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
