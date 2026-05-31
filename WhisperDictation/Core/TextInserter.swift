import AppKit
import ApplicationServices

/// Inserts text into the focused app. Two strategies:
///   • Direct typing (default) — synthesizes the characters as Unicode key
///     events. The text never touches the clipboard, so no clipboard manager
///     can capture it. Strongest privacy.
///   • Clipboard paste — puts the text on the pasteboard and synthesizes ⌘V,
///     then restores the prior clipboard. Fallback for apps that mishandle
///     synthesized Unicode input.
final class TextInserter {
    /// Markers honored by clipboard managers (Maccy, Raycast, Paste, …) to skip
    /// recording an item. We set both so the dictated text — which can be a
    /// password, 2FA code, or private message — isn't captured into clipboard
    /// history during the brief paste-then-restore window. See nspasteboard.org.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Returns whether the process is trusted for Accessibility. When `prompt`
    /// is true and untrusted, macOS shows its grant dialog.
    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func insert(_ text: String, directType: Bool, restoreClipboard: Bool, pressReturn: Bool = false) {
        guard !text.isEmpty else {
            Log.info("insert: skipped (empty text)")
            return
        }

        let trusted = AXIsProcessTrusted()
        Log.info("insert: \(text.count) chars, accessibilityTrusted=\(trusted), directType=\(directType)")
        if !trusted {
            // Synthetic events are silently dropped without Accessibility trust.
            Log.error("insert: not trusted for Accessibility — synthesized input will be ignored. Prompting.")
            Self.ensureAccessibilityPermission(prompt: true)
        }

        if directType {
            typeDirectly(text)
            Log.info("insert: typed \(text.count) chars directly (clipboard untouched)")
            if pressReturn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.pressReturnKey()
                    Log.info("insert: Return posted")
                }
            }
            return
        }

        let pasteboard = NSPasteboard.general
        let saved = restoreClipboard ? pasteboard.string(forType: .string) : nil

        // Declare the concealed/transient markers alongside the string so
        // clipboard-history tools don't archive the dictated text. declareTypes
        // clears the pasteboard and bumps the change count itself.
        pasteboard.declareTypes([.string, Self.concealedType, Self.transientType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.concealedType)
        pasteboard.setData(Data(), forType: Self.transientType)

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

    /// Types `text` by synthesizing Unicode key events — no clipboard involved.
    /// Layout-independent (the character is set on the event directly, so it
    /// doesn't depend on the user's keyboard layout). `keyboardSetUnicodeString`
    /// is reliable only for short strings, so we send it in small UTF-16 chunks.
    private func typeDirectly(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        let chunkSize = 20
        var i = 0
        while i < units.count {
            let chunk = Array(units[i ..< min(i + chunkSize, units.count)])
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = [] // no modifiers — emit the raw characters
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.post(tap: .cghidEventTap)
            }
            i += chunkSize
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
