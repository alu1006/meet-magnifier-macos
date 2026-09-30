import AppKit
import Carbon
import ScreenCaptureKit
import OSLog

private let appName = "Meet 放大鏡"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var imageView: NSImageView!
    private var globalScrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var timer: Timer?
    private var zoom: CGFloat = 1
    private var isEnabled = false
    private var cachedContent: SCShareableContent?
    private var contentDate = Date.distantPast
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var captureInProgress = false
    private var hotKeyRef: EventHotKeyRef?
    private var resetHotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private let logger = Logger(subsystem: "local.codex.MeetMagnifier", category: "diagnostics")
    private var permissionTimer: Timer?
    private var permissionItem: NSMenuItem!
    private var permissionAlertShown = false
    private var frameCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        createPanel()
        createMenu()
        installScrollMonitors()
        installHotKey()
        setEnabled(false)
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        logger.notice("Started. Screen capture: \(CGPreflightScreenCaptureAccess()), accessibility: \(AXIsProcessTrusted())")
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in
                await runSelfTest()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = globalScrollMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localScrollMonitor { NSEvent.removeMonitor(monitor) }
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = resetHotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = hotKeyHandler { RemoveEventHandler(handler) }
    }

    private func createPanel() {
        let size = NSScreen.main?.frame.size ?? NSSize(width: 1440, height: 900)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = appName
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.animationBehavior = .none

        imageView = NSImageView(frame: panel.contentView!.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.layer?.cornerRadius = 0
        imageView.layer?.masksToBounds = true
        panel.contentView?.addSubview(imageView)

        positionPanel()
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return }
        panel.setFrame(screen.frame, display: false)
    }

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass.circle.fill", accessibilityDescription: appName)

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "開啟／關閉放大鏡", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.keyEquivalent = "m"
        menu.addItem(toggle)
        let reset = NSMenuItem(title: "強制回到原大小", action: #selector(resetZoom), keyEquivalent: "0")
        reset.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(reset)
        menu.addItem(.separator())
        let help = NSMenuItem(title: "操作：⌃ + 滾輪調整倍率", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
        menu.addItem(.separator())
        permissionItem = NSMenuItem(title: "檢查權限中…", action: nil, keyEquivalent: "")
        menu.addItem(permissionItem)
        menu.addItem(NSMenuItem(title: "設定螢幕錄製權限…", action: #selector(openCaptureSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "設定輔助使用權限…", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "結束", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    @objc private func openCaptureSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func refreshPermissions() {
        let capture = CGPreflightScreenCaptureAccess()
        let trusted = AXIsProcessTrusted()
        permissionItem.title = "螢幕錄製：\(capture ? "已授權" : "未生效") ｜ 滾輪攔截：\(eventTap != nil ? "就緒" : "需輔助使用")"
        if trusted && eventTap == nil {
            if let monitor = globalScrollMonitor { NSEvent.removeMonitor(monitor); globalScrollMonitor = nil }
            if let monitor = localScrollMonitor { NSEvent.removeMonitor(monitor); localScrollMonitor = nil }
            installScrollMonitors()
        }
        if capture { permissionAlertShown = false }
    }

    private func installScrollMonitors() {
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated {
                    if let tap = owner.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                }
                return Unmanaged.passUnretained(event)
            }
            guard type == .scrollWheel, event.flags.contains(.maskControl),
                  CGPreflightScreenCaptureAccess(), let scroll = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }
            MainActor.assumeIsolated { owner.handleScroll(scroll) }
            return nil
        }
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let eventTap {
            logger.notice("Control-scroll event tap installed")
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return
        }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            Task { @MainActor in self?.handleScroll(event) }
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
            return event
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard event.modifierFlags.contains(.control) else { return }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        // Additive changes make returning to exactly 1x predictable. A sufficiently
        // strong reverse gesture always closes the overlay instead of approaching 1x forever.
        let amount = event.hasPreciseScrollingDeltas ? -delta * 0.025 : -delta * 0.25
        zoom = min(8, max(1, zoom + amount))
        if zoom < 1.08 { zoom = 1 }
        logger.debug("Control-scroll received; zoom \(self.zoom)")
        if isEnabled != (zoom > 1) { setEnabled(zoom > 1) }
    }

    private func installHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            if let event {
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            }
            Task { @MainActor in
                if hotKeyID.id == 2 { delegate.resetZoom() }
                else { delegate.toggleEnabled() }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        let id = EventHotKeyID(signature: OSType(0x4D41474E), id: 1) // MAGN
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
        let resetID = EventHotKeyID(signature: OSType(0x4D41474E), id: 2)
        let resetResult = RegisterEventHotKey(UInt32(kVK_ANSI_0), UInt32(controlKey | optionKey), resetID,
                            GetApplicationEventTarget(), 0, &resetHotKeyRef)
        logger.notice("Hotkey registration result: \(result)")
        logger.notice("Reset hotkey registration result: \(resetResult)")
    }

    private func requestScreenRecordingPermission() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    @objc private func toggleEnabled() {
        logger.notice("Toggle hotkey/menu received")
        if isEnabled { resetZoom() } else { zoom = 2.5; setEnabled(true) }
    }

    @objc private func resetZoom() { zoom = 1; setEnabled(false) }

    private func setEnabled(_ enabled: Bool) {
        if enabled && !CGPreflightScreenCaptureAccess() {
            logger.error("Screen capture preflight denied")
            zoom = 1
            if !permissionAlertShown {
                permissionAlertShown = true
                DispatchQueue.main.async { [weak self] in self?.showPermissionHelp() }
            }
            return
        }
        isEnabled = enabled
        timer?.invalidate()
        timer = nil
        if enabled {
            positionPanel()
            timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.captureCursorArea() }
            }
            RunLoop.main.add(timer!, forMode: .common)
        } else {
            panel.orderOut(nil)
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: enabled ? "magnifyingglass.circle.fill" : "magnifyingglass.circle",
            accessibilityDescription: appName
        )
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func runSelfTest() async {
        // Local test event: never posted to the OS or other applications.
        guard let up = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                               wheelCount: 1, wheel1: -4, wheel2: 0, wheel3: 0) else { return }
        up.flags = .maskControl
        guard let event = NSEvent(cgEvent: up) else { return }
        handleScroll(event)
        let raised = zoom > 1 && isEnabled
        await captureCursorArea()
        let captured = frameCount > 0
        logger.notice("SELFTEST scroll magnification=\(raised), capture=\(captured), eventTap=\(self.eventTap != nil)")
        try? await Task.sleep(for: .seconds(8))
        guard let down = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                 wheelCount: 1, wheel1: 100, wheel2: 0, wheel3: 0),
              let downEvent = { () -> NSEvent? in down.flags = .maskControl; return NSEvent(cgEvent: down) }() else { return }
        handleScroll(downEvent)
        logger.notice("SELFTEST return to 1x=\(self.zoom == 1 && !self.isEnabled && !self.panel.isVisible)")
    }

    private func showPermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "螢幕錄製授權尚未對目前版本生效"
        alert.informativeText = "請在系統設定將「Meet 放大鏡」的螢幕錄製權限關閉再開啟，並選擇結束並重新打開。若仍無效，移除該筆項目，再加入目前這個 App。要攔截 Control＋滾輪，也需在「輔助使用」允許此 App。"
        alert.addButton(withTitle: "打開螢幕錄製設定")
        alert.addButton(withTitle: "稍後")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openCaptureSettings() }
    }

    private func captureCursorArea() async {
        guard isEnabled, !captureInProgress else { return }
        captureInProgress = true
        defer { captureInProgress = false }

        do {
            if cachedContent == nil || Date().timeIntervalSince(contentDate) > 3 {
                cachedContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                contentDate = Date()
            }
            guard let content = cachedContent else { return }
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
                  let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == screenID.uint32Value }) else { return }
            let frame = screen.frame
            let destination = frame

            let outputSize = frame.size
            let sourceWidth = outputSize.width / zoom
            let sourceHeight = outputSize.height / zoom

            // AppKit uses a bottom-left origin; ScreenCaptureKit sourceRect uses display-local top-left coordinates.
            var x = mouse.x - frame.minX - (mouse.x - frame.minX) / zoom
            var y = frame.maxY - mouse.y - (frame.maxY - mouse.y) / zoom
            x = min(max(0, x), frame.width - sourceWidth)
            y = min(max(0, y), frame.height - sourceHeight)

            let excluded = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: x, y: y, width: sourceWidth, height: sourceHeight)
            config.width = Int(outputSize.width * (panel.screen?.backingScaleFactor ?? 2))
            config.height = Int(outputSize.height * (panel.screen?.backingScaleFactor ?? 2))
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard isEnabled else { return }
            panel.setFrame(destination, display: false)
            imageView.image = NSImage(cgImage: image, size: outputSize)
            panel.orderFrontRegardless()
            frameCount += 1
            if frameCount == 1 { logger.notice("First magnified frame displayed: \(image.width)x\(image.height)") }
        } catch {
            let failure = error as NSError
            logger.error("Capture failed: \(failure.domain, privacy: .public) / \(failure.code) / \(failure.localizedDescription, privacy: .public)")
            imageView.image = nil
            panel.orderOut(nil)
            // Stop retrying a denied capture every frame; retry on the next user gesture.
            setEnabled(false)
            statusItem.button?.toolTip = "擷取失敗：\(failure.localizedDescription)（\(failure.code)）"
        }
    }
}

@main
@MainActor
struct MeetMagnifierApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
