import Cocoa
import ApplicationServices
import Carbon.HIToolbox
import SystemConfiguration

private struct DraftHistoryEntry: Codable {
    enum Reason: String, Codable {
        case stoppedInput
        case pastedDraft
        case directPaste
        case remoteCleared
        case replacedBeforeInput

        var displayTitle: String {
            switch self {
            case .stoppedInput:
                return "停止输入"
            case .pastedDraft:
                return "已粘贴"
            case .directPaste:
                return "直接粘贴"
            case .remoteCleared:
                return "草稿被清空"
            case .replacedBeforeInput:
                return "开始新输入"
            }
        }
    }

    let id: UUID
    let text: String
    let createdAt: Date
    let reason: Reason
    let sourceAddress: String?
}

private final class DraftHistoryStore {
    private let maxItemCount = 100
    private let fileURL: URL?

    init() {
        let fm = FileManager.default
        guard let appSupportDirectory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fileURL = nil
            return
        }

        fileURL = appSupportDirectory
            .appendingPathComponent("AutoPaste", isDirectory: true)
            .appendingPathComponent("draft-history.json")
    }

    func load() -> [DraftHistoryEntry] {
        guard let fileURL else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DraftHistoryEntry].self, from: data).prefix(maxItemCount).map { $0 }) ?? []
    }

    func save(_ entries: [DraftHistoryEntry]) {
        guard let fileURL else { return }

        let fm = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()

        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(Array(entries.prefix(maxItemCount)))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save draft history: \(error)")
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let sharedHistoryTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private struct ShortcutConfig {
        let key: String
        let keyCode: UInt32
        let modifiers: NSEvent.ModifierFlags
    }

    private enum RemoteDraftClearContext: Equatable {
        case startInput
        case paste
    }

    private enum GlobalShortcutAction: UInt32, CaseIterable {
        case autoSendToggle = 1
        case inputToggle = 2
        case pasteDraft = 3

        var defaultsPrefix: String {
            switch self {
            case .autoSendToggle: return "autoSend"
            case .inputToggle: return "inputToggle"
            case .pasteDraft: return "pasteDraft"
            }
        }

        var menuTitlePrefix: String {
            switch self {
            case .autoSendToggle: return "自动发送"
            case .inputToggle: return "输入切换"
            case .pasteDraft: return "粘贴/发送"
            }
        }

        var configurationTitle: String {
            switch self {
            case .autoSendToggle: return "设置\u{201C}自动发送\u{201D}快捷键"
            case .inputToggle: return "设置\u{201C}输入切换\u{201D}快捷键"
            case .pasteDraft: return "设置\u{201C}粘贴/发送\u{201D}快捷键"
            }
        }
    }

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var popover: NSPopover!
    private var draftPanelController: DraftPanelViewController!

    private var titleItem: NSMenuItem!
    private var ipItem: NSMenuItem!
    private var portItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var autoSendShortcutItem: NSMenuItem!
    private var inputShortcutItem: NSMenuItem!
    private var pasteShortcutItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!

    private var port: UInt16 = 7788
    private var autoSend = false
    private var server: HTTPServer?
    private var serverRunning = false
    private var ipTitleResetWorkItem: DispatchWorkItem?
    private var hotKeyRefs: [GlobalShortcutAction: EventHotKeyRef] = [:]
    private var hotKeyHandler: EventHandlerRef?

    private var mirroredDraftText = ""
    private var mirroredDraftSourceAddress: String?
    private var mirroredDraftCallbackPort: UInt16?
    private var draftStatusMessage = "点击\u{201C}开始输入\u{201D}，从手机同步文字到这里。"
    private let historyStore = DraftHistoryStore()
    private var historyEntries: [DraftHistoryEntry] = []
    private var lastActiveAppBeforePopover: NSRunningApplication?
    private var pendingRemoteDraftClearContext: RemoteDraftClearContext?
    private var isInputModeActive = false
    private var isPopoverClosing = false
    private var shouldReopenPopoverAfterClose = false

    private let supportedShortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    private let globalHotKeySignature: OSType = 0x41505348 // APSH

    func applicationDidFinishLaunching(_ notification: Notification) {
        historyEntries = historyStore.load()
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

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        titleItem = NSMenuItem(title: "AutoPaste", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "关于 AutoPaste", action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        ipItem = NSMenuItem(title: ipMenuTitle(), action: #selector(copyIPSummary(_:)), keyEquivalent: "")
        ipItem.target = self
        menu.addItem(ipItem)

        portItem = NSMenuItem(title: "端口：\(port)", action: #selector(changePort(_:)), keyEquivalent: "")
        portItem.target = self
        menu.addItem(portItem)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "自动发送", action: #selector(toggleAutoSend(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = autoSend ? .on : .off
        menu.addItem(toggleItem)

        let shortcutSubmenu = NSMenu()

        autoSendShortcutItem = NSMenuItem(title: "自动发送：未设置", action: #selector(configureAutoSendShortcut(_:)), keyEquivalent: "")
        autoSendShortcutItem.target = self
        shortcutSubmenu.addItem(autoSendShortcutItem)

        inputShortcutItem = NSMenuItem(title: "输入切换：未设置", action: #selector(configureInputShortcut(_:)), keyEquivalent: "")
        inputShortcutItem.target = self
        shortcutSubmenu.addItem(inputShortcutItem)

        pasteShortcutItem = NSMenuItem(title: "粘贴/发送：未设置", action: #selector(configurePasteShortcut(_:)), keyEquivalent: "")
        pasteShortcutItem.target = self
        shortcutSubmenu.addItem(pasteShortcutItem)

        let shortcutItem = NSMenuItem(title: "快捷键", action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcutSubmenu
        menu.addItem(shortcutItem)

        applyShortcutsFromDefaults()

        menu.addItem(.separator())

        accessibilityItem = NSMenuItem(title: "辅助功能", action: #selector(openAccessibilitySettings(_:)), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        updateAccessibilityStatus()

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 AutoPaste", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusMenu = menu
    }

    // MARK: - Popover

    private func buildPopover() {
        draftPanelController = DraftPanelViewController()
        draftPanelController.onPrimaryAction = { [weak self] in
            self?.performDraftPanelPrimaryAction()
        }
        draftPanelController.onStartInput = { [weak self] in
            self?.toggleInputSession()
        }
        draftPanelController.onOpenSettings = { [weak self] in
            self?.openSettingsMenuFromPanel()
        }
        draftPanelController.onDismiss = { [weak self] in
            guard let self else { return }
            if self.isInputModeActive {
                self.cancelInputSession()
            } else {
                self.popover.performClose(nil)
            }
        }

        popover = NSPopover()
        popover.animates = true
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 360)
        popover.contentViewController = draftPanelController
    }

    private func updateIcon() {
        statusItem.button?.image = StatusBarIcon.make(
            autoSend: autoSend,
            running: serverRunning,
            inputActive: isInputModeActive
        )
        updatePopoverBehavior()
    }

    private func updatePopoverBehavior() {
        popover?.behavior = isInputModeActive ? .applicationDefined : .transient
    }

    private func refreshDraftPanel() {
        let hasMirroredDraft = !mirroredDraftText.isEmpty
        draftPanelController?.update(
            text: mirroredDraftText,
            status: draftStatusMessage,
            startInputButtonTitle: isInputModeActive ? "停止输入" : "开始输入",
            primaryActionTitle: hasMirroredDraft ? "粘贴" : "发送",
            canTriggerPrimaryAction: checkAccessibilityPermission(),
            canStartInput: true,
            historyText: formattedHistoryText(),
            hasHistory: !historyEntries.isEmpty
        )
    }

    // MARK: - Status Item Interaction

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
            if isInputModeActive {
                return
            }
            popover.performClose(nil)
            return
        }

        showPopoverIfNeeded()
    }

    private func showPopoverIfNeeded(captureTargetContext: Bool = true) {
        if popover.isShown {
            refreshDraftPanel()
            if isPopoverClosing {
                shouldReopenPopoverAfterClose = true
            }
            return
        }

        if isPopoverClosing {
            shouldReopenPopoverAfterClose = true
            return
        }

        if captureTargetContext {
            captureLastTargetContext()
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

    // MARK: - Draft Management

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

    private func appendHistoryEntry(
        text: String,
        reason: DraftHistoryEntry.Reason,
        sourceAddress: String? = nil
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let entry = DraftHistoryEntry(
            id: UUID(),
            text: text,
            createdAt: Date(),
            reason: reason,
            sourceAddress: sourceAddress
        )

        historyEntries.insert(entry, at: 0)
        if historyEntries.count > 100 {
            historyEntries = Array(historyEntries.prefix(100))
        }

        historyStore.save(historyEntries)
        refreshDraftPanel()
    }

    private func appendCurrentDraftToHistoryIfNeeded(reason: DraftHistoryEntry.Reason) {
        appendHistoryEntry(
            text: mirroredDraftText,
            reason: reason,
            sourceAddress: mirroredDraftSourceAddress
        )
    }

    private func formattedHistoryText() -> String {
        guard !historyEntries.isEmpty else { return "" }

        return historyEntries.map { entry in
            var header = "[\(entry.reason.displayTitle)] \(historyTimestampFormatter.string(from: entry.createdAt))"
            if let sourceAddress = entry.sourceAddress, !sourceAddress.isEmpty {
                header += " · \(sourceAddress)"
            }
            return "\(header)\n\(entry.text)"
        }.joined(separator: "\n\n──────────\n\n")
    }

    private var historyTimestampFormatter: DateFormatter {
        Self.sharedHistoryTimestampFormatter
    }

    private func statusMessageForStartInputReady() -> String {
        if let sourceAddress = mirroredDraftSourceAddress, !sourceAddress.isEmpty {
            return "已连接 \(sourceAddress)，等待输入中…"
        }
        return "等待输入中…"
    }

    private func statusMessageForPasteCleared() -> String {
        "已粘贴，同步完成"
    }

    private func remoteClearLocalFallbackStatus(for context: RemoteDraftClearContext) -> String {
        switch context {
        case .startInput:
            return "草稿已清除，等待输入中…"
        case .paste:
            return "已粘贴（离线模式，未同步到手机）"
        }
    }

    private func pasteMirroredDraft() {
        guard !mirroredDraftText.isEmpty else { return }

        let textToPaste = mirroredDraftText
        appendHistoryEntry(
            text: textToPaste,
            reason: .pastedDraft,
            sourceAddress: mirroredDraftSourceAddress
        )
        isInputModeActive = false
        updateIcon()
        popover.performClose(nil)
        pendingRemoteDraftClearContext = .paste

        setMirroredDraft(
            text: "",
            sourceAddress: mirroredDraftSourceAddress,
            callbackPort: mirroredDraftCallbackPort,
            status: "已粘贴，正在同步…"
        )

        pasteIntoLastTargetApp(textToPaste)
        requestRemoteDraftClear(context: .paste)
    }

    private func performDraftPanelPrimaryAction() {
        if mirroredDraftText.isEmpty {
            sendFromLastTargetApp()
        } else {
            pasteMirroredDraft()
        }
    }

    // MARK: - Input Session

    private func toggleInputSession() {
        if isInputModeActive {
            cancelInputSession()
        } else {
            startInputSession()
        }
    }

    private func startInputSession() {
        appendCurrentDraftToHistoryIfNeeded(reason: .replacedBeforeInput)
        isInputModeActive = true
        shouldReopenPopoverAfterClose = isPopoverClosing
        updateIcon()
        pendingRemoteDraftClearContext = .startInput

        setMirroredDraft(
            text: "",
            sourceAddress: mirroredDraftSourceAddress,
            callbackPort: mirroredDraftCallbackPort,
            status: "正在准备输入…"
        )
        requestRemoteDraftClear(context: .startInput)
    }

    private func cancelInputSession() {
        appendCurrentDraftToHistoryIfNeeded(reason: .stoppedInput)
        isInputModeActive = false
        shouldReopenPopoverAfterClose = false
        pendingRemoteDraftClearContext = .startInput
        mirroredDraftText = ""
        draftStatusMessage = "输入已停止"
        updateIcon()
        refreshDraftPanel()
        popover.performClose(nil)
        requestRemoteDraftClear(context: .startInput)
    }

    // MARK: - Target App

    private func reactivateLastTargetAppIfNeeded() {
        guard let targetApp = lastActiveAppBeforePopover,
              !targetApp.isTerminated else { return }
        targetApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func waitUntilTargetAppIsFrontmost(
        _ targetApp: NSRunningApplication?,
        remainingAttempts: Int = 12,
        completion: @escaping () -> Void
    ) {
        guard let targetApp, !targetApp.isTerminated else {
            completion()
            return
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier {
            completion()
            return
        }

        guard remainingAttempts > 0 else {
            completion()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitUntilTargetAppIsFrontmost(
                targetApp,
                remainingAttempts: remainingAttempts - 1,
                completion: completion
            )
        }
    }

    private func captureLastTargetContext() {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        lastActiveAppBeforePopover = frontmostApp
    }

    private func pasteIntoLastTargetApp(_ text: String) {
        let targetApp = lastActiveAppBeforePopover
        reactivateLastTargetAppIfNeeded()

        waitUntilTargetAppIsFrontmost(targetApp) { [autoSend] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                PasteService.copyAndPaste(
                    text: text,
                    autoSend: autoSend,
                    targetPID: targetApp?.processIdentifier
                )
            }
        }
    }

    private func sendFromLastTargetApp() {
        guard checkAccessibilityPermission() else { return }

        let targetApp = lastActiveAppBeforePopover
        popover.performClose(nil)
        reactivateLastTargetAppIfNeeded()

        waitUntilTargetAppIsFrontmost(targetApp) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                PasteService.send()
            }
        }
    }

    // MARK: - Remote Sync

    private func requestRemoteDraftClear(context: RemoteDraftClearContext) {
        guard let host = mirroredDraftSourceAddress,
              !host.isEmpty,
              let callbackPort = mirroredDraftCallbackPort else {
            pendingRemoteDraftClearContext = nil
            draftStatusMessage = remoteClearLocalFallbackStatus(for: context)
            refreshDraftPanel()
            return
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(callbackPort)
        components.path = "/draft/clear"

        guard let url = components.url else {
            pendingRemoteDraftClearContext = nil
            draftStatusMessage = "无法连接手机端，请检查网络连接。"
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
                    guard self.pendingRemoteDraftClearContext == context else { return }
                    self.pendingRemoteDraftClearContext = nil
                    self.draftStatusMessage = "同步失败：\(error.localizedDescription)"
                    self.refreshDraftPanel()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    guard self.pendingRemoteDraftClearContext == context else { return }
                    self.pendingRemoteDraftClearContext = nil
                    self.draftStatusMessage = "同步失败：手机端无响应。"
                    self.refreshDraftPanel()
                    return
                }

                guard self.pendingRemoteDraftClearContext == context else { return }
                self.pendingRemoteDraftClearContext = nil

                if (200...299).contains(httpResponse.statusCode) {
                    self.draftStatusMessage = context == .startInput
                        ? self.statusMessageForStartInputReady()
                        : self.statusMessageForPasteCleared()
                } else {
                    self.draftStatusMessage = "同步失败：手机端返回错误，请重试。"
                }
                self.refreshDraftPanel()
            }
        }.resume()
    }

    // MARK: - Accessibility

    private func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func updateAccessibilityStatus() {
        let granted = checkAccessibilityPermission()
        if granted {
            accessibilityItem.title = "辅助功能：已授权"
            accessibilityItem.state = .on
            accessibilityItem.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已授权")
        } else {
            accessibilityItem.title = "辅助功能：未授权"
            accessibilityItem.state = .off
            accessibilityItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "未授权")
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

    // MARK: - About

    @objc private func showAboutPanel(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - Port

    @objc private func changePort(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "修改监听端口"
        alert.informativeText = "输入新端口号（1–65535）："
        alert.addButton(withTitle: "更改")
        alert.addButton(withTitle: "取消")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        inputField.stringValue = String(port)
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        guard let newPort = UInt16(inputField.stringValue), newPort >= 1 else { return }
        guard newPort != port else { return }

        port = newPort
        portItem.title = "端口：\(port)"

        if serverRunning {
            stopServer()
            startServer()
        }
    }

    // MARK: - Auto Send

    @objc private func toggleAutoSend(_ sender: NSMenuItem) {
        toggleAutoSendState()
    }

    private func toggleAutoSendState() {
        autoSend.toggle()
        toggleItem.state = autoSend ? .on : .off
        server?.autoSend = autoSend
        updateIcon()
    }

    // MARK: - Shortcut Configuration

    @objc private func configureAutoSendShortcut(_ sender: NSMenuItem) {
        configureShortcut(for: .autoSendToggle)
    }

    @objc private func configureInputShortcut(_ sender: NSMenuItem) {
        configureShortcut(for: .inputToggle)
    }

    @objc private func configurePasteShortcut(_ sender: NSMenuItem) {
        configureShortcut(for: .pasteDraft)
    }

    private func configureShortcut(for action: GlobalShortcutAction) {
        let currentShortcut = currentShortcut(for: action)
        var selectedShortcut: ShortcutConfig? = currentShortcut

        let alert = NSAlert()
        alert.messageText = action.configurationTitle
        alert.informativeText = "在下方框内按下组合键录制快捷键。按 Delete 清除。"
        alert.addButton(withTitle: "设定")
        alert.addButton(withTitle: "取消")

        let inputField = ShortcutCaptureField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        inputField.placeholderString = "按下快捷键…"
        inputField.isEditable = false
        inputField.isSelectable = false
        inputField.focusRingType = .exterior
        inputField.allowedModifiers = supportedShortcutModifiers
        inputField.stringValue = currentShortcut.map { shortcutDisplay(key: $0.key, modifiers: $0.modifiers) } ?? "无"
        inputField.onCapture = { [weak self, weak inputField] captured in
            guard let self else { return }
            selectedShortcut = captured.map {
                ShortcutConfig(key: $0.key, keyCode: $0.keyCode, modifiers: $0.modifiers)
            }
            inputField?.stringValue = captured.map {
                self.shortcutDisplay(key: $0.key, modifiers: $0.modifiers)
            } ?? "无"
        }

        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if let selectedShortcut {
            saveShortcut(selectedShortcut, for: action)
        } else {
            clearShortcut(for: action)
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        unregisterAllGlobalHotKeys()
        stopServer()
        NSApplication.shared.terminate(self)
    }

    // MARK: - Shortcut Persistence

    private func applyShortcutsFromDefaults() {
        for action in GlobalShortcutAction.allCases {
            applyShortcutFromDefaults(for: action)
        }
    }

    private func applyShortcutFromDefaults(for action: GlobalShortcutAction) {
        guard let shortcut = currentShortcut(for: action) else {
            unregisterGlobalHotKey(for: action)
            clearShortcutOnMenuOnly(for: action)
            return
        }

        unregisterGlobalHotKey(for: action)
        if registerGlobalHotKey(shortcut, for: action) {
            applyShortcutToMenu(shortcut, for: action)
        } else {
            shortcutMenuItem(for: action)?.title = "\(action.menuTitlePrefix)：\(shortcutDisplay(key: shortcut.key, modifiers: shortcut.modifiers))（冲突）"
            print("Failed to register global shortcut for \(action.menuTitlePrefix): \(shortcutDisplay(key: shortcut.key, modifiers: shortcut.modifiers))")
        }
    }

    private func saveShortcut(_ shortcut: ShortcutConfig, for action: GlobalShortcutAction) {
        let previousShortcut = currentShortcut(for: action)

        unregisterGlobalHotKey(for: action)
        guard registerGlobalHotKey(shortcut, for: action) else {
            if let previousShortcut {
                _ = registerGlobalHotKey(previousShortcut, for: action)
                applyShortcutToMenu(previousShortcut, for: action)
            } else {
                clearShortcutOnMenuOnly(for: action)
            }
            showGlobalShortcutUnavailableError(for: action)
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(shortcut.key, forKey: shortcutDefaultsKey(for: action, suffix: "Key"))
        defaults.set(Int(shortcut.keyCode), forKey: shortcutDefaultsKey(for: action, suffix: "KeyCode"))
        defaults.set(Int(shortcut.modifiers.rawValue), forKey: shortcutDefaultsKey(for: action, suffix: "Modifiers"))
        applyShortcutToMenu(shortcut, for: action)
    }

    private func clearShortcut(for action: GlobalShortcutAction) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: shortcutDefaultsKey(for: action, suffix: "Key"))
        defaults.removeObject(forKey: shortcutDefaultsKey(for: action, suffix: "KeyCode"))
        defaults.removeObject(forKey: shortcutDefaultsKey(for: action, suffix: "Modifiers"))
        unregisterGlobalHotKey(for: action)
        clearShortcutOnMenuOnly(for: action)
    }

    private func clearShortcutOnMenuOnly(for action: GlobalShortcutAction) {
        shortcutMenuItem(for: action)?.title = "\(action.menuTitlePrefix)：未设置"
    }

    private func applyShortcutToMenu(_ shortcut: ShortcutConfig, for action: GlobalShortcutAction) {
        shortcutMenuItem(for: action)?.title = "\(action.menuTitlePrefix)：\(shortcutDisplay(key: shortcut.key, modifiers: shortcut.modifiers))"
    }

    private func shortcutMenuItem(for action: GlobalShortcutAction) -> NSMenuItem? {
        switch action {
        case .autoSendToggle: return autoSendShortcutItem
        case .inputToggle: return inputShortcutItem
        case .pasteDraft: return pasteShortcutItem
        }
    }

    private func shortcutDefaultsKey(for action: GlobalShortcutAction, suffix: String) -> String {
        "\(action.defaultsPrefix)Shortcut\(suffix)"
    }

    private func currentShortcut(for action: GlobalShortcutAction) -> ShortcutConfig? {
        let defaults = UserDefaults.standard
        guard let key = defaults.string(forKey: shortcutDefaultsKey(for: action, suffix: "Key")), !key.isEmpty else {
            return nil
        }

        let keyCode: UInt32
        if let keyCodeNumber = defaults.object(forKey: shortcutDefaultsKey(for: action, suffix: "KeyCode")) as? NSNumber {
            keyCode = keyCodeNumber.uint32Value
        } else if let legacyKeyCode = legacyKeyCode(for: key) {
            keyCode = legacyKeyCode
        } else {
            return nil
        }

        let rawModifiers = defaults.integer(forKey: shortcutDefaultsKey(for: action, suffix: "Modifiers"))
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(rawModifiers)).intersection(supportedShortcutModifiers)
        return ShortcutConfig(key: key, keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: - Global Hot Keys

    private func registerGlobalHotKey(_ shortcut: ShortcutConfig, for action: GlobalShortcutAction) -> Bool {
        installGlobalHotKeyHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: globalHotKeySignature, id: action.rawValue)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifiers(from: shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr, let hotKeyRef {
            hotKeyRefs[action] = hotKeyRef
        }
        return status == noErr
    }

    private func unregisterGlobalHotKey(for action: GlobalShortcutAction) {
        guard let hotKeyRef = hotKeyRefs[action] else { return }
        UnregisterEventHotKey(hotKeyRef)
        hotKeyRefs[action] = nil
    }

    private func unregisterAllGlobalHotKeys() {
        for action in GlobalShortcutAction.allCases {
            unregisterGlobalHotKey(for: action)
        }
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
        guard hotKeyID.signature == globalHotKeySignature,
              let action = GlobalShortcutAction(rawValue: hotKeyID.id) else { return noErr }

        DispatchQueue.main.async { [weak self] in
            self?.performGlobalShortcutAction(action)
        }
        return noErr
    }

    private func performGlobalShortcutAction(_ action: GlobalShortcutAction) {
        switch action {
        case .autoSendToggle:
            toggleAutoSendState()
        case .inputToggle:
            toggleInputSession()
            if isInputModeActive {
                showPopoverIfNeeded()
            }
        case .pasteDraft:
            captureLastTargetContext()
            performDraftPanelPrimaryAction()
        }
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

    private func showGlobalShortcutUnavailableError(for action: GlobalShortcutAction? = nil) {
        let alert = NSAlert()
        alert.messageText = "快捷键冲突"
        alert.informativeText = "这个快捷键已被系统或其他应用占用，请换一个组合键。"
        alert.addButton(withTitle: "重新设置")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let action {
            configureShortcut(for: action)
        }
    }

    private func shortcutDisplay(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + key.uppercased()
    }

    // MARK: - Network Info

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

            addresses.append((label: info.label, address: ip, rank: info.rank))
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
        let lines = ipSummaryLines()
        guard !lines.isEmpty else { return "未检测到局域网地址" }

        if copied {
            if lines.count == 1 {
                return "\(lines[0])（已复制）"
            }
            var displayLines = lines
            displayLines[displayLines.count - 1] = "\(displayLines[displayLines.count - 1])（已复制）"
            return displayLines.joined(separator: "\n")
        }

        return lines.joined(separator: "\n")
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

    // MARK: - Server

    private func startServer() {
        guard !serverRunning else { return }
        let srv = HTTPServer()
        srv.autoSend = autoSend
        srv.onPasteRequest = { [weak self] text, autoSend in
            DispatchQueue.main.async {
                self?.appendHistoryEntry(text: text, reason: .directPaste)
            }
            PasteService.copyAndPaste(text: text, autoSend: autoSend)
        }
        srv.onDraftUpdate = { [weak self] update in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isInputModeActive else { return }

                if update.text.isEmpty,
                   !self.mirroredDraftText.isEmpty,
                   self.pendingRemoteDraftClearContext == nil {
                    self.appendHistoryEntry(
                        text: self.mirroredDraftText,
                        reason: .remoteCleared,
                        sourceAddress: self.mirroredDraftSourceAddress
                    )
                }

                let status: String
                if update.text.isEmpty {
                    switch self.pendingRemoteDraftClearContext {
                    case .startInput:
                        status = self.statusMessageForStartInputReady()
                    case .paste:
                        status = self.statusMessageForPasteCleared()
                    case nil:
                        status = "草稿已清除"
                    }
                } else {
                    status = "正在接收输入…"
                }
                self.pendingRemoteDraftClearContext = nil

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

// MARK: - Draft Panel View Controller

private final class DraftPanelViewController: NSViewController {
    private enum PanelMode: Int {
        case draft = 0
        case history = 1
    }

    var onPrimaryAction: (() -> Void)?
    var onStartInput: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "输入同步")
    private let statusLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl(labels: ["当前", "历史"], trackingMode: .selectOne, target: nil, action: nil)
    private let contentContainer = NSView()
    private let draftTextView = NSTextView(frame: .zero)
    private let draftScrollView = NSScrollView()
    private let draftPlaceholderLabel = NSTextField(labelWithString: "等待手机端输入…")
    private let historyTextView = NSTextView(frame: .zero)
    private let historyScrollView = NSScrollView()
    private let historyPlaceholderLabel = NSTextField(labelWithString: "还没有历史记录")
    private let startInputButton = NSButton(title: "开始输入", target: nil, action: nil)
    private let pasteButton = NSButton(title: "粘贴", target: nil, action: nil)
    private let settingsButton = NSButton(frame: .zero)
    private var panelMode: PanelMode = .draft

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.setAccessibilityLabel("标题")

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        modeControl.segmentStyle = .rounded
        modeControl.selectedSegment = panelMode.rawValue
        modeControl.target = self
        modeControl.action = #selector(handleModeChange)

        configureTextView(draftTextView, accessibilityLabel: "草稿内容")
        configureTextView(historyTextView, accessibilityLabel: "历史记录")
        configureScrollView(draftScrollView, documentView: draftTextView)
        configureScrollView(historyScrollView, documentView: historyTextView)

        draftPlaceholderLabel.font = .systemFont(ofSize: 13)
        draftPlaceholderLabel.textColor = .tertiaryLabelColor
        draftPlaceholderLabel.isHidden = false

        historyPlaceholderLabel.font = .systemFont(ofSize: 13)
        historyPlaceholderLabel.textColor = .tertiaryLabelColor
        historyPlaceholderLabel.isHidden = true

        startInputButton.bezelStyle = .rounded
        startInputButton.target = self
        startInputButton.action = #selector(handleStartInput)
        startInputButton.setAccessibilityLabel("切换输入模式")

        pasteButton.bezelStyle = .rounded
        pasteButton.target = self
        pasteButton.action = #selector(handlePaste)
        pasteButton.setAccessibilityLabel("粘贴到当前窗口")

        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        settingsButton.bezelStyle = .rounded
        settingsButton.isBordered = false
        settingsButton.imagePosition = .imageOnly
        settingsButton.target = self
        settingsButton.action = #selector(handleOpenSettings)
        settingsButton.setAccessibilityLabel("打开设置")

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        for subview in [draftScrollView, historyScrollView, draftPlaceholderLabel, historyPlaceholderLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(subview)
        }

        let buttonRow = NSStackView(views: [startInputButton, pasteButton, NSView(), settingsButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [titleLabel, statusLabel, modeControl, contentContainer, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(14, after: contentContainer)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            contentContainer.heightAnchor.constraint(equalToConstant: 210),

            draftScrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            draftScrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            draftScrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            draftScrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            historyScrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            historyScrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            historyScrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            historyScrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            draftPlaceholderLabel.leadingAnchor.constraint(equalTo: draftScrollView.leadingAnchor, constant: 14),
            draftPlaceholderLabel.topAnchor.constraint(equalTo: draftScrollView.topAnchor, constant: 12),
            draftPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: draftScrollView.trailingAnchor, constant: -14),

            historyPlaceholderLabel.leadingAnchor.constraint(equalTo: historyScrollView.leadingAnchor, constant: 14),
            historyPlaceholderLabel.topAnchor.constraint(equalTo: historyScrollView.topAnchor, constant: 12),
            historyPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: historyScrollView.trailingAnchor, constant: -14)
        ])

        updateVisiblePanel()
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        layoutTextView(draftTextView, in: draftScrollView)
        layoutTextView(historyTextView, in: historyScrollView)
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    func update(
        text: String,
        status: String,
        startInputButtonTitle: String,
        primaryActionTitle: String,
        canTriggerPrimaryAction: Bool,
        canStartInput: Bool,
        historyText: String,
        hasHistory: Bool
    ) {
        if draftTextView.string != text {
            draftTextView.string = text
        }
        if historyTextView.string != historyText {
            historyTextView.string = historyText
        }
        statusLabel.stringValue = status
        startInputButton.title = startInputButtonTitle
        startInputButton.isEnabled = canStartInput
        pasteButton.title = primaryActionTitle
        pasteButton.isEnabled = canTriggerPrimaryAction
        draftPlaceholderLabel.isHidden = !text.isEmpty || panelMode != .draft
        historyPlaceholderLabel.isHidden = hasHistory || panelMode != .history
        updateVisiblePanel()
    }

    @objc private func handleStartInput() {
        onStartInput?()
    }

    @objc private func handlePaste() {
        onPrimaryAction?()
    }

    @objc private func handleOpenSettings() {
        onOpenSettings?()
    }

    @objc private func handleModeChange() {
        panelMode = PanelMode(rawValue: modeControl.selectedSegment) ?? .draft
        updateVisiblePanel()
    }

    private func configureTextView(_ textView: NSTextView, accessibilityLabel: String) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(accessibilityLabel)
    }

    private func configureScrollView(_ scrollView: NSScrollView, documentView: NSView) {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    private func layoutTextView(_ textView: NSTextView, in scrollView: NSScrollView) {
        let size = scrollView.contentSize
        textView.frame = NSRect(origin: .zero, size: size)
        textView.minSize = NSSize(width: size.width, height: size.height)
        textView.maxSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
    }

    private func updateVisiblePanel() {
        let showingDraft = panelMode == .draft
        draftScrollView.isHidden = !showingDraft
        historyScrollView.isHidden = showingDraft
        draftPlaceholderLabel.isHidden = !showingDraft || !draftTextView.string.isEmpty
        historyPlaceholderLabel.isHidden = showingDraft || !historyTextView.string.isEmpty
    }
}

// MARK: - Shortcut Capture Field

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

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshIPItem()
        updateAccessibilityStatus()
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    func popoverWillClose(_ notification: Notification) {
        isPopoverClosing = true
    }

    func popoverDidClose(_ notification: Notification) {
        isPopoverClosing = false

        guard shouldReopenPopoverAfterClose, isInputModeActive else {
            shouldReopenPopoverAfterClose = false
            return
        }

        shouldReopenPopoverAfterClose = false
        DispatchQueue.main.async { [weak self] in
            self?.showPopoverIfNeeded(captureTargetContext: false)
        }
    }
}
