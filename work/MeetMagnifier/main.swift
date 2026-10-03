import AppKit
import Carbon
import ScreenCaptureKit
import OSLog

private let appName = "Meet 放大鏡"

private enum DrawingMode {
    case arrow
    case rectangle
}

private struct AnnotationShape {
    let mode: DrawingMode
    let start: NSPoint
    let end: NSPoint
}

@MainActor
private final class AnnotationView: NSView {
    var mode: DrawingMode?
    var onFinished: (() -> Void)?
    var magnifiedCursorPoint: NSPoint? { didSet { needsDisplay = true } }
    private(set) var shapes: [AnnotationShape] = []
    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?

    override var isFlipped: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard mode != nil else { return }
        dragStart = convert(event.locationInWindow, from: nil)
        dragEnd = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragEnd = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let mode, let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        if hypot(end.x - start.x, end.y - start.y) > 8 {
            shapes.append(AnnotationShape(mode: mode, start: start, end: end))
        }
        dragStart = nil
        dragEnd = nil
        self.mode = nil
        needsDisplay = true
        onFinished?()
    }

    func clear() {
        shapes.removeAll()
        dragStart = nil
        dragEnd = nil
        mode = nil
        needsDisplay = true
    }

    func addTestShapes() {
        shapes.append(AnnotationShape(mode: .arrow, start: NSPoint(x: 80, y: 80), end: NSPoint(x: 220, y: 180)))
        shapes.append(AnnotationShape(mode: .rectangle, start: NSPoint(x: 280, y: 80), end: NSPoint(x: 480, y: 220)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.systemRed.setStroke()
        for shape in shapes { draw(shape) }
        if let mode, let start = dragStart, let end = dragEnd {
            draw(AnnotationShape(mode: mode, start: start, end: end))
        }
        if let point = magnifiedCursorPoint { drawLargeCursor(at: point) }
    }

    private func draw(_ shape: AnnotationShape) {
        let path = NSBezierPath()
        path.lineWidth = 6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch shape.mode {
        case .rectangle:
            path.appendRect(NSRect(x: min(shape.start.x, shape.end.x),
                                   y: min(shape.start.y, shape.end.y),
                                   width: abs(shape.end.x - shape.start.x),
                                   height: abs(shape.end.y - shape.start.y)))
        case .arrow:
            path.move(to: shape.start)
            path.line(to: shape.end)
            let angle = atan2(shape.end.y - shape.start.y, shape.end.x - shape.start.x)
            let head: CGFloat = 24
            path.move(to: shape.end)
            path.line(to: NSPoint(x: shape.end.x - head * cos(angle - .pi / 6),
                                  y: shape.end.y - head * sin(angle - .pi / 6)))
            path.move(to: shape.end)
            path.line(to: NSPoint(x: shape.end.x - head * cos(angle + .pi / 6),
                                  y: shape.end.y - head * sin(angle + .pi / 6)))
        }
        path.stroke()
    }

    private func drawLargeCursor(at point: NSPoint) {
        // Large, high-contrast arrow with its tip exactly on the real pointer hotspot.
        let path = NSBezierPath()
        path.move(to: point)
        path.line(to: NSPoint(x: point.x + 2, y: point.y - 58))
        path.line(to: NSPoint(x: point.x + 17, y: point.y - 44))
        path.line(to: NSPoint(x: point.x + 29, y: point.y - 68))
        path.line(to: NSPoint(x: point.x + 43, y: point.y - 61))
        path.line(to: NSPoint(x: point.x + 31, y: point.y - 39))
        path.line(to: NSPoint(x: point.x + 53, y: point.y - 38))
        path.close()
        path.lineWidth = 4
        path.lineJoinStyle = .round
        NSColor.white.setFill()
        NSColor.black.setStroke()
        path.fill()
        path.stroke()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var imageView: NSImageView!
    private var annotationView: AnnotationView!
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
    private var isFrozen = false
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private let logger = Logger(subsystem: "local.codex.MeetMagnifier", category: "diagnostics")
    private var permissionTimer: Timer?
    private var permissionItem: NSMenuItem!
    private var permissionAlertShown = false
    private var frameCount = 0
    private var cursorMagnified = false
    private var cursorTimer: Timer?

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
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
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

        annotationView = AnnotationView(frame: panel.contentView!.bounds)
        annotationView.autoresizingMask = [.width, .height]
        annotationView.wantsLayer = true
        annotationView.layer?.backgroundColor = NSColor.clear.cgColor
        annotationView.onFinished = { [weak self] in self?.finishDrawing() }
        panel.contentView?.addSubview(annotationView)

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
        let toggle = NSMenuItem(title: "放大／還原滑鼠游標", action: #selector(toggleCursorMagnifier), keyEquivalent: "")
        toggle.keyEquivalentModifierMask = [.control]
        toggle.keyEquivalent = "m"
        menu.addItem(toggle)
        let arrow = NSMenuItem(title: "畫箭頭", action: #selector(beginArrow), keyEquivalent: "a")
        arrow.keyEquivalentModifierMask = [.control]
        menu.addItem(arrow)
        let rectangle = NSMenuItem(title: "畫方框", action: #selector(beginRectangle), keyEquivalent: "r")
        rectangle.keyEquivalentModifierMask = [.control]
        menu.addItem(rectangle)
        let reset = NSMenuItem(title: "清除並強制回到原大小", action: #selector(resetAll), keyEquivalent: "0")
        reset.keyEquivalentModifierMask = [.control]
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
        if isFrozen {
            isFrozen = false
            logger.notice("Magnified view unfrozen by Control-scroll")
        }
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
                switch hotKeyID.id {
                case 2: delegate.resetAll()
                case 3: delegate.beginArrow()
                case 4: delegate.beginRectangle()
                default: delegate.toggleCursorMagnifier()
                }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        let keys: [(UInt32, UInt32, String)] = [
            (1, UInt32(kVK_ANSI_M), "magnify"),
            (2, UInt32(kVK_ANSI_0), "reset"),
            (3, UInt32(kVK_ANSI_A), "arrow"),
            (4, UInt32(kVK_ANSI_R), "rectangle")
        ]
        for (idNumber, keyCode, name) in keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D41474E), id: idNumber)
            let result = RegisterEventHotKey(keyCode, UInt32(controlKey), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if let ref { hotKeyRefs.append(ref) }
            logger.notice("Hotkey \(name, privacy: .public) registration result: \(result)")
        }
    }

    private func requestScreenRecordingPermission() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    @objc private func toggleEnabled() {
        logger.notice("Toggle hotkey/menu received")
        if isEnabled {
            zoom = 1
            setEnabled(false)
        } else {
            zoom = 2.5
            setEnabled(true)
        }
    }

    @objc private func toggleCursorMagnifier() {
        cursorMagnified.toggle()
        cursorTimer?.invalidate()
        cursorTimer = nil
        if cursorMagnified {
            positionPanel()
            updateMagnifiedCursor()
            cursorTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateMagnifiedCursor() }
            }
            RunLoop.main.add(cursorTimer!, forMode: .common)
        } else {
            annotationView.magnifiedCursorPoint = nil
        }
        updatePanelVisibility()
        logger.notice("Large cursor: \(self.cursorMagnified)")
    }

    private func updateMagnifiedCursor() {
        guard cursorMagnified else { return }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }), panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
        }
        annotationView.magnifiedCursorPoint = NSPoint(x: mouse.x - panel.frame.minX,
                                                       y: mouse.y - panel.frame.minY)
        panel.orderFrontRegardless()
    }

    @objc private func beginArrow() { beginDrawing(.arrow) }

    @objc private func beginRectangle() { beginDrawing(.rectangle) }

    private func beginDrawing(_ mode: DrawingMode) {
        positionPanel()
        if isEnabled && zoom > 1 {
            isFrozen = true
            logger.notice("Magnified view frozen for drawing")
        }
        annotationView.mode = mode
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        NSCursor.crosshair.set()
        logger.notice("Drawing mode started: \(String(describing: mode), privacy: .public)")
    }

    private func finishDrawing() {
        panel.ignoresMouseEvents = true
        NSCursor.arrow.set()
        updatePanelVisibility()
    }

    @objc private func resetAll() {
        zoom = 1
        isFrozen = false
        cursorMagnified = false
        cursorTimer?.invalidate()
        cursorTimer = nil
        annotationView.clear()
        annotationView.magnifiedCursorPoint = nil
        panel.ignoresMouseEvents = true
        NSCursor.arrow.set()
        setEnabled(false)
    }

    private func updatePanelVisibility() {
        if isEnabled || cursorMagnified || !annotationView.shapes.isEmpty || annotationView.mode != nil {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

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
        if !enabled { isFrozen = false }
        timer?.invalidate()
        timer = nil
        if enabled {
            positionPanel()
            imageView.isHidden = false
            timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.captureCursorArea() }
            }
            RunLoop.main.add(timer!, forMode: .common)
        } else {
            imageView.image = nil
            imageView.isHidden = true
            updatePanelVisibility()
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
        annotationView.addTestShapes()
        let drawing = annotationView.shapes.count == 2
        toggleCursorMagnifier()
        let largeCursor = cursorMagnified && annotationView.magnifiedCursorPoint != nil
        logger.notice("SELFTEST scroll magnification=\(raised), capture=\(captured), drawing=\(drawing), largeCursor=\(largeCursor), eventTap=\(self.eventTap != nil)")
        try? await Task.sleep(for: .seconds(8))
        guard let down = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                 wheelCount: 1, wheel1: 100, wheel2: 0, wheel3: 0),
              let downEvent = { () -> NSEvent? in down.flags = .maskControl; return NSEvent(cgEvent: down) }() else { return }
        handleScroll(downEvent)
        resetAll()
        logger.notice("SELFTEST reset=\(self.zoom == 1 && !self.isEnabled && !self.panel.isVisible && self.annotationView.shapes.isEmpty)")
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
        guard isEnabled, !isFrozen, !captureInProgress else { return }
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
            guard isEnabled, !isFrozen else { return }
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
