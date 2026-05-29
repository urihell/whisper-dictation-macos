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

    func insert(_ text: String, restoreClipboard: Bool, pressReturn: Bool = false) {
        guard !text.isEmpty else {
            Log.info("insert: skipped (empty text)")
            return
        }

        let trusted = AXIsProcessTrusted()
        Log.info("insert: \(text.count) chars, accessibilityTrusted=\(trusted)")
        if !trusted {
            // Synthetic key events are silently dropped without Accessibility
            // trust. Prompt and bail — the text stays on the clipboard.
            Log.error("insert: not trusted for Accessibility — ⌘V will be ignored. Prompting.")
            Self.ensureAccessibilityPermission(prompt: true)
        }

        let pasteboard = NSPasteboard.general
        let saved = restoreClipboard ? pasteboard.string(forType: .string) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Give the pasteboard a beat to settle, then paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.paste()
            Log.info("insert: ⌘V posted")

            // Press Return after the paste has landed, if requested.
            if pressReturn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.pressReturnKey()
                    Log.info("insert: Return posted")
                }
            }

            if restoreClipboard {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    pasteboard.clearContents()
                    if let saved {
                        pasteboard.setString(saved, forType: .string)
                    }
                }
            }
        }
    }

    private func paste() {
        postKey(9, flags: .maskCommand) // ⌘V
    }

    private func pressReturnKey() {
        postKey(36, flags: []) // Return
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
