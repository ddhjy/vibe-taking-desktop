import Cocoa
import ApplicationServices
import Carbon.HIToolbox
import SystemConfiguration

class AppDelegate: NSObject, NSApplicationDelegate {
    private struct ShortcutConfig {
        let key: String
        let keyCode: UInt32
        let modifiers: NSEvent.ModifierFlags
    }

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var popover: NSPopover!
    private var draftPanelController: DraftPanelViewController!

    private var titleItem: NSMenuItem!
    private var ipItem: NSMenuItem!
    private var portItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var configureShortcutItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!

    private var port: UInt16 = 7788
    private var autoSend = false
    private var server: HTTPServer?
    private var serverRunning = false
    private var ipTitleResetWorkItem: DispatchWorkItem?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    private var mirroredDraftText = ""
    private var mirroredDraftSourceAddress: String?
    private var mirroredDraftCallbackPort: UInt16?
    private var draftStatusMessage = "Waiting for Fifteen sync."

    private let autoSendShortcutKeyDefaultsKey = "autoSendShortcutKey"
    private let autoSendShortcutKeyCodeDefaultsKey = "autoSendShortcutKeyCode"
    private let autoSendShortcutModifiersDefaultsKey = "autoSendShortcutModifiers"
    private let supportedShortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    private let autoSendHotKeySignature: OSType = 0x41535348 // ASSH
    private let autoSendHotKeyID: UInt32 = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()
        buildMenu()
        buildPopover()
        updateIcon()
        refreshDraftPanel()
        startServer()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        titleItem = NSMenuItem(title: "AutoPaste  :\(port)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        ipItem = NSMenuItem(title: ipMenuTitle(), action: #selector(copyIPSummary(_:)), keyEquivalent: "")
        ipItem.target = self
        menu.addItem(ipItem)

        portItem = NSMenuItem(title: "Port: \(port)", action: #selector(changePort(_:)), keyEquivalent: "")
        portItem.target = self
        menu.addItem(portItem)

        toggleItem = NSMenuItem(title: "Auto Send", action: #selector(toggleAutoSend(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = autoSend ? .on : .off
        menu.addItem(toggleItem)

        configureShortcutItem = NSMenuItem(title: "Auto Send Shortcut: None", action: #selector(configureAutoSendShortcut(_:)), keyEquivalent: "")
        configureShortcutItem.target = self
        menu.addItem(configureShortcutItem)

        applyAutoSendShortcutFromDefaults()

        menu.addItem(.separator())

        accessibilityItem = NSMenuItem(title: "Accessibility: Checking...", action: #selector(openAccessibilitySettings(_:)), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        updateAccessibilityStatus()

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusMenu = menu
    }

    private func buildPopover() {
        draftPanelController = DraftPanelViewController()
        draftPanelController.onPaste = { [weak self] in
            self?.pasteMirroredDraft()
        }
        draftPanelController.onClear = { [weak self] in
            self?.clearMirroredDraft()
        }
        draftPanelController.onOpenSettings = { [weak self] in
            self?.openSettingsMenuFromPanel()
        }

        popover = NSPopover()
        popover.animates = true
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 300)
        popover.contentViewController = draftPanelController
    }

    private func updateIcon() {
        statusItem.button?.image = StatusBarIcon.make(autoSend: autoSend, running: serverRunning)
    }

    private func refreshDraftPanel() {
        draftPanelController?.update(
            text: mirroredDraftText,
            status: draftStatusMessage,
            canPaste: !mirroredDraftText.isEmpty && checkAccessibilityPermission(),
            canClear: !mirroredDraftText.isEmpty
        )
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        if event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        refreshDraftPanel()
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showStatusMenu() {
        popover.performClose(nil)
        refreshIPItem()
        updateAccessibilityStatus()
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func openSettingsMenuFromPanel() {
        popover.performClose(nil)
        DispatchQueue.main.async { [weak self] in
            self?.showStatusMenu()
        }
    }

    private func setMirroredDraft(
        text: String,
        sourceAddress: String?,
        callbackPort: UInt16?,
        status: String
    ) {
        mirroredDraftText = text
        if let sourceAddress, !sourceAddress.isEmpty {
            mirroredDraftSourceAddress = sourceAddress
        }
        if let callbackPort {
            mirroredDraftCallbackPort = callbackPort
        }
        draftStatusMessage = status
        refreshDraftPanel()
    }

    private func pasteMirroredDraft() {
        guard !mirroredDraftText.isEmpty else { return }

        PasteService.copyAndPaste(text: mirroredDraftText, autoSend: autoSend)
        setMirroredDraft(
            text: "",
            sourceAddress: mirroredDraftSourceAddress,
            callbackPort: mirroredDraftCallbackPort,
            status: "Pasted locally. Clearing Fifteen..."
        )
        requestRemoteDraftClear(localAction: "Paste")
    }

    private func clearMirroredDraft() {
        guard !mirroredDraftText.isEmpty else { return }

        setMirroredDraft(
            text: "",
            sourceAddress: mirroredDraftSourceAddress,
            callbackPort: mirroredDraftCallbackPort,
            status: "Cleared locally. Clearing Fifteen..."
        )
        requestRemoteDraftClear(localAction: "Clear")
    }

    private func requestRemoteDraftClear(localAction: String) {
        guard let host = mirroredDraftSourceAddress,
              !host.isEmpty,
              let callbackPort = mirroredDraftCallbackPort else {
            draftStatusMessage = "\(localAction) finished locally. No Fifteen callback target."
            refreshDraftPanel()
            return
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(callbackPort)
        components.path = "/draft/clear"

        guard let url = components.url else {
            draftStatusMessage = "\(localAction) finished locally. Fifteen callback URL is invalid."
            refreshDraftPanel()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    self.draftStatusMessage = "\(localAction) finished locally. Fifteen clear failed: \(error.localizedDescription)"
                    self.refreshDraftPanel()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.draftStatusMessage = "\(localAction) finished locally. Fifteen clear returned no response."
                    self.refreshDraftPanel()
                    return
                }

                if (200...299).contains(httpResponse.statusCode) {
                    self.draftStatusMessage = "Fifteen draft cleared."
                } else {
                    self.draftStatusMessage = "\(localAction) finished locally. Fifteen clear failed with status \(httpResponse.statusCode)."
                }
                self.refreshDraftPanel()
            }
        }.resume()
    }

    private func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func updateAccessibilityStatus() {
        let granted = checkAccessibilityPermission()
        if granted {
            accessibilityItem.title = "Accessibility: Granted"
            accessibilityItem.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Granted")
        } else {
            accessibilityItem.title = "Accessibility: Not Granted (Click to Fix)"
            accessibilityItem.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Not Granted")
        }
        refreshDraftPanel()
    }

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        let granted = checkAccessibilityPermission()
        if !granted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func changePort(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Change Port"
        alert.informativeText = "Enter the new port number:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        inputField.stringValue = String(port)
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        guard let newPort = UInt16(inputField.stringValue), newPort >= 1 else { return }
        guard newPort != port else { return }

        port = newPort
        titleItem.title = "AutoPaste  :\(port)"
        portItem.title = "Port: \(port)"

        if serverRunning {
            stopServer()
            startServer()
        }
    }

    @objc private func toggleAutoSend(_ sender: NSMenuItem) {
        toggleAutoSendState()
    }

    private func toggleAutoSendState() {
        autoSend.toggle()
        toggleItem.state = autoSend ? .on : .off
        server?.autoSend = autoSend
        updateIcon()
    }

    @objc private func configureAutoSendShortcut(_ sender: NSMenuItem) {
        let currentShortcut = currentAutoSendShortcut()
        var selectedShortcut: ShortcutConfig? = currentShortcut

        let alert = NSAlert()
        alert.messageText = "Configure Auto Send Shortcut"
        alert.informativeText = "Click the box and press a global shortcut. Press Delete to clear."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let inputField = ShortcutCaptureField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        inputField.placeholderString = "Press shortcut"
        inputField.isEditable = false
        inputField.isSelectable = false
        inputField.focusRingType = .exterior
        inputField.allowedModifiers = supportedShortcutModifiers
        inputField.stringValue = currentShortcut.map { shortcutDisplay(key: $0.key, modifiers: $0.modifiers) } ?? "None"
        inputField.onCapture = { [weak self, weak inputField] captured in
            guard let self else { return }
            selectedShortcut = captured.map {
                ShortcutConfig(key: $0.key, keyCode: $0.keyCode, modifiers: $0.modifiers)
            }
            inputField?.stringValue = captured.map {
                self.shortcutDisplay(key: $0.key, modifiers: $0.modifiers)
            } ?? "None"
        }

        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if let selectedShortcut {
            saveAutoSendShortcut(selectedShortcut)
        } else {
            clearAutoSendShortcut()
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        unregisterGlobalHotKey()
        stopServer()
        NSApplication.shared.terminate(self)
    }

    private func applyAutoSendShortcutFromDefaults() {
        guard let shortcut = currentAutoSendShortcut() else {
            unregisterGlobalHotKey()
            clearShortcutOnMenuOnly()
            return
        }

        unregisterGlobalHotKey()
        if registerGlobalHotKey(shortcut) {
            applyShortcutToMenu(shortcut)
        } else {
            configureShortcutItem.title = "Auto Send Shortcut: \(shortcutDisplay(key: shortcut.key, modifiers: shortcut.modifiers)) (Unavailable)"
            print("Failed to register global shortcut: \(shortcutDisplay(key: shortcut.key, modifiers: shortcut.modifiers))")
        }
    }

    private func saveAutoSendShortcut(_ shortcut: ShortcutConfig) {
        let previousShortcut = currentAutoSendShortcut()

        unregisterGlobalHotKey()
        guard registerGlobalHotKey(shortcut) else {
            if let previousShortcut {
                _ = registerGlobalHotKey(previousShortcut)
                applyShortcutToMenu(previousShortcut)
            } else {
                clearShortcutOnMenuOnly()
            }
            showGlobalShortcutUnavailableError()
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(shortcut.key, forKey: autoSendShortcutKeyDefaultsKey)
        defaults.set(Int(shortcut.keyCode), forKey: autoSendShortcutKeyCodeDefaultsKey)
        defaults.set(Int(shortcut.modifiers.rawValue), forKey: autoSendShortcutModifiersDefaultsKey)
        applyShortcutToMenu(shortcut)
    }

    private func clearAutoSendShortcut() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: autoSendShortcutKeyDefaultsKey)
        defaults.removeObject(forKey: autoSendShortcutKeyCodeDefaultsKey)
        defaults.removeObject(forKey: autoSendShortcutModifiersDefaultsKey)
        unregisterGlobalHotKey()
        clearShortcutOnMenuOnly()
    }

    private func clearShortcutOnMenuOnly() {
        configureShortcutItem.title = "Auto Send Shortcut: None"
    }

    private func applyShortcutToMenu(_ shortcut: ShortcutConfig) {
        configureShortcutItem.title = "Auto Send Shortcut: \(shortcutDisplay(key: shortcut.key, modifiers: shortcut.modifiers))"
    }

    private func currentAutoSendShortcut() -> ShortcutConfig? {
        let defaults = UserDefaults.standard
        guard let key = defaults.string(forKey: autoSendShortcutKeyDefaultsKey), !key.isEmpty else {
            return nil
        }

        let keyCode: UInt32
        if let keyCodeNumber = defaults.object(forKey: autoSendShortcutKeyCodeDefaultsKey) as? NSNumber {
            keyCode = keyCodeNumber.uint32Value
        } else if let legacyKeyCode = legacyKeyCode(for: key) {
            keyCode = legacyKeyCode
        } else {
            return nil
        }

        let rawModifiers = defaults.integer(forKey: autoSendShortcutModifiersDefaultsKey)
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(rawModifiers)).intersection(supportedShortcutModifiers)
        return ShortcutConfig(key: key, keyCode: keyCode, modifiers: modifiers)
    }

    private func registerGlobalHotKey(_ shortcut: ShortcutConfig) -> Bool {
        installGlobalHotKeyHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: autoSendHotKeySignature, id: autoSendHotKeyID)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifiers(from: shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return status == noErr
    }

    private func unregisterGlobalHotKey() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    private func installGlobalHotKeyHandlerIfNeeded() {
        guard hotKeyHandler == nil else { return }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            return appDelegate.handleGlobalHotKeyEvent(event)
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec, userData, &hotKeyHandler)
    }

    private func handleGlobalHotKeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else { return status }
        guard hotKeyID.signature == autoSendHotKeySignature, hotKeyID.id == autoSendHotKeyID else { return noErr }

        DispatchQueue.main.async { [weak self] in
            self?.toggleAutoSendState()
        }
        return noErr
    }

    private func carbonModifiers(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func legacyKeyCode(for key: String) -> UInt32? {
        switch key.lowercased() {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        case "0": return UInt32(kVK_ANSI_0)
        case "1": return UInt32(kVK_ANSI_1)
        case "2": return UInt32(kVK_ANSI_2)
        case "3": return UInt32(kVK_ANSI_3)
        case "4": return UInt32(kVK_ANSI_4)
        case "5": return UInt32(kVK_ANSI_5)
        case "6": return UInt32(kVK_ANSI_6)
        case "7": return UInt32(kVK_ANSI_7)
        case "8": return UInt32(kVK_ANSI_8)
        case "9": return UInt32(kVK_ANSI_9)
        default: return nil
        }
    }

    private func showGlobalShortcutUnavailableError() {
        let alert = NSAlert()
        alert.messageText = "Shortcut Unavailable"
        alert.informativeText = "This global shortcut is already used by the system or another app."
        alert.runModal()
    }

    private func shortcutDisplay(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Cmd") }
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(key.uppercased())
        return parts.joined(separator: "+")
    }

    private func localIPAddresses() -> [(label: String, address: String, rank: Int)] {
        var addresses: [(label: String, address: String, rank: Int)] = []
        var seen = Set<String>()
        let interfaceKinds = networkInterfaceKinds()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return addresses }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            guard let addrPointer = ptr.pointee.ifa_addr else { continue }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            let sa = addrPointer.pointee
            guard sa.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard let info = displayInfo(for: name, kinds: interfaceKinds) else { continue }

            var addr = addrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }

            let ip = String(cString: buf)
            let key = "\(name)|\(ip)"
            guard seen.insert(key).inserted else { continue }

            addresses.append((label: "\(info.label)(\(name))", address: ip, rank: info.rank))
        }

        return addresses.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.label != $1.label { return $0.label < $1.label }
            return $0.address < $1.address
        }
    }

    private func networkInterfaceKinds() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var kinds: [String: String] = [:]

        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let interfaceType = SCNetworkInterfaceGetInterfaceType(interface) as String? else {
                continue
            }

            if interfaceType == kSCNetworkInterfaceTypeIEEE80211 as String {
                kinds[bsdName] = "Wi-Fi"
            } else if interfaceType == kSCNetworkInterfaceTypeEthernet as String {
                kinds[bsdName] = "Ethernet"
            }
        }

        return kinds
    }

    private func displayInfo(for bsdName: String, kinds: [String: String]) -> (label: String, rank: Int)? {
        if let kind = kinds[bsdName] {
            return kind == "Wi-Fi" ? ("Wi-Fi", 0) : ("Ethernet", 1)
        }

        if bsdName.hasPrefix("en") {
            return ("Ethernet", 1)
        }

        return nil
    }

    private func refreshIPItem() {
        ipItem.title = ipMenuTitle()
    }

    private func ipSummaryLines() -> [String] {
        localIPAddresses().map { "\($0.label): \($0.address)" }
    }

    private func ipMenuTitle(copied: Bool = false) -> String {
        let status = copied ? "Copied" : "Click to Copy"
        let lines = ipSummaryLines()
        guard !lines.isEmpty else { return "IP: Unknown (\(status))" }

        if lines.count == 1 {
            return "IP: \(lines[0]) (\(status))"
        }

        var displayLines = lines
        displayLines[0] = "IP: \(displayLines[0])"
        displayLines[displayLines.count - 1] = "\(displayLines[displayLines.count - 1]) (\(status))"
        return displayLines.joined(separator: "\n")
    }

    private func ipCopyValue() -> String? {
        let entries = localIPAddresses()
        guard !entries.isEmpty else { return nil }
        return entries.map { $0.address }.joined(separator: " | ")
    }

    @objc private func copyIPSummary(_ sender: NSMenuItem) {
        guard let value = ipCopyValue() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)

        ipTitleResetWorkItem?.cancel()
        ipItem.title = ipMenuTitle(copied: true)

        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshIPItem()
        }
        ipTitleResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    private func startServer() {
        guard !serverRunning else { return }
        let srv = HTTPServer()
        srv.autoSend = autoSend
        srv.onPasteRequest = { text, autoSend in
            PasteService.copyAndPaste(text: text, autoSend: autoSend)
        }
        srv.onDraftUpdate = { [weak self] update in
            DispatchQueue.main.async {
                guard let self else { return }

                let status: String
                if update.text.isEmpty {
                    status = update.remoteAddress.isEmpty ? "Draft cleared from Fifteen." : "Draft cleared from \(update.remoteAddress)."
                } else {
                    status = update.remoteAddress.isEmpty ? "Draft synced from Fifteen." : "Draft synced from \(update.remoteAddress)."
                }

                self.setMirroredDraft(
                    text: update.text,
                    sourceAddress: update.remoteAddress,
                    callbackPort: update.callbackPort,
                    status: status
                )
            }
        }

        do {
            try srv.start(port: port)
            server = srv
            serverRunning = true
            updateIcon()
            print("AutoPaste listening on http://0.0.0.0:\(port)")
        } catch {
            print("Failed to start server: \(error)")
        }
    }

    private func stopServer() {
        guard serverRunning else { return }
        popover.performClose(nil)
        server?.stop()
        server = nil
        serverRunning = false
        updateIcon()
    }
}

private final class DraftPanelViewController: NSViewController {
    var onPaste: (() -> Void)?
    var onClear: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Fifteen Draft")
    private let statusLabel = NSTextField(labelWithString: "Waiting for Fifteen sync.")
    private let textView = NSTextView()
    private let pasteButton = NSButton(title: "Paste", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Settings", target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        pasteButton.bezelStyle = .rounded
        pasteButton.target = self
        pasteButton.action = #selector(handlePaste)

        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(handleClear)

        settingsButton.bezelStyle = .rounded
        settingsButton.target = self
        settingsButton.action = #selector(handleOpenSettings)

        let buttonRow = NSStackView(views: [pasteButton, clearButton, NSView(), settingsButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [titleLabel, statusLabel, scrollView, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            scrollView.heightAnchor.constraint(equalToConstant: 190)
        ])
    }

    func update(text: String, status: String, canPaste: Bool, canClear: Bool) {
        if textView.string != text {
            textView.string = text
        }
        statusLabel.stringValue = status
        pasteButton.isEnabled = canPaste
        clearButton.isEnabled = canClear
    }

    @objc private func handlePaste() {
        onPaste?()
    }

    @objc private func handleClear() {
        onClear?()
    }

    @objc private func handleOpenSettings() {
        onOpenSettings?()
    }
}

private final class ShortcutCaptureField: NSTextField {
    var onCapture: (((key: String, keyCode: UInt32, modifiers: NSEvent.ModifierFlags)?) -> Void)?
    var allowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onCapture?(nil)
            return
        }

        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 {
            super.keyDown(with: event)
            return
        }

        guard let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first,
              scalar.isASCII,
              !CharacterSet.controlCharacters.contains(scalar) else {
            NSSound.beep()
            return
        }

        let key = String(scalar).lowercased()
        let keyCode = UInt32(event.keyCode)
        let modifiers = event.modifierFlags.intersection(allowedModifiers)
        onCapture?((key: key, keyCode: keyCode, modifiers: modifiers))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 {
            return super.performKeyEquivalent(with: event)
        }

        keyDown(with: event)
        return true
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshIPItem()
        updateAccessibilityStatus()
    }
}
