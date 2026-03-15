import Cocoa
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox

enum PasteService {
    private static func eventSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        return source
    }

    private static func post(_ event: CGEvent, delay: useconds_t = 20_000) {
        event.post(tap: .cgSessionEventTap)
        usleep(delay)
    }

    private static func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], delay: useconds_t = 20_000) {
        let src = eventSource()
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }
        post(down, delay: delay)
        post(up, delay: delay)
    }

    private static func pressCommandShortcut(_ keyCode: CGKeyCode, delay: useconds_t = 20_000) {
        let src = eventSource()
        guard let commandDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Command), keyDown: false) else { return }

        commandDown.flags = [.maskCommand]
        keyDown.flags = [.maskCommand]
        keyUp.flags = [.maskCommand]

        post(commandDown, delay: delay)
        post(keyDown, delay: delay)
        post(keyUp, delay: delay)
        post(commandUp, delay: delay)
    }

    private static func simulatePaste() {
        pressCommandShortcut(CGKeyCode(kVK_ANSI_V))
    }

    private static func simulateSend() {
        pressKey(CGKeyCode(kVK_Return))
        usleep(100_000)
        pressCommandShortcut(CGKeyCode(kVK_Return))
    }

    private static func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private static func copySelectedRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard result == .success, let axValue = value else { return nil }
        guard CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }

        let rangeValue = unsafeBitCast(axValue, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func insertTextViaAccessibility(_ text: String, into element: AXUIElement) -> Bool {
        guard let currentValue = copyStringAttribute(kAXValueAttribute as String, from: element),
              let selectedRange = copySelectedRange(from: element) else {
            return false
        }

        let currentNSString = currentValue as NSString
        let insertionText = text as NSString
        let safeLocation = max(0, min(selectedRange.location, currentNSString.length))
        let safeLength = max(0, min(selectedRange.length, currentNSString.length - safeLocation))
        let replacementRange = NSRange(location: safeLocation, length: safeLength)
        let updatedValue = currentNSString.replacingCharacters(in: replacementRange, with: text)

        let setValueResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        guard setValueResult == .success else { return false }

        var caretRange = CFRange(location: safeLocation + insertionText.length, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &caretRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }

        return true
    }

    private static func copyAXChildren(from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private static func findPasteMenuItem(in element: AXUIElement) -> AXUIElement? {
        if let title = copyStringAttribute(kAXTitleAttribute as String, from: element) {
            let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "paste" || normalized == "粘贴" {
                return element
            }
        }

        for child in copyAXChildren(from: element) {
            if let match = findPasteMenuItem(in: child) {
                return match
            }
        }

        return nil
    }

    private static func performPasteMenuAction(targetPID: pid_t?) -> Bool {
        guard let targetPID else { return false }

        let appElement = AXUIElementCreateApplication(targetPID)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &value)
        guard result == .success, let menuBarRef = value else { return false }
        guard CFGetTypeID(menuBarRef) == AXUIElementGetTypeID() else { return false }

        let menuBar = unsafeBitCast(menuBarRef, to: AXUIElement.self)
        guard let pasteMenuItem = findPasteMenuItem(in: menuBar) else { return false }

        return AXUIElementPerformAction(pasteMenuItem, kAXPressAction as CFString) == .success
    }

    static func copyAndPaste(
        text: String,
        autoSend: Bool,
        focusedElement: AXUIElement? = nil,
        targetPID: pid_t? = nil
    ) {
        writeToPasteboard(text)

        if let focusedElement, insertTextViaAccessibility(text, into: focusedElement) {
            if autoSend {
                usleep(150_000)
                simulateSend()
            }
            return
        }

        if performPasteMenuAction(targetPID: targetPID) {
            if autoSend {
                usleep(150_000)
                simulateSend()
            }
            return
        }

        usleep(50_000)
        simulatePaste()

        if autoSend {
            usleep(150_000)
            simulateSend()
        }
    }
}
