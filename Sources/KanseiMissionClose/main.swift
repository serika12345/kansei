import AppKit
import ApplicationServices
import CoreGraphics
import PrivateAX

private let axTrustedCheckOptionPromptKey = "AXTrustedCheckOptionPrompt"
private let axCloseActionName = "AXClose"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let windowCollector = WindowCollector()
    private let missionControlDetector = MissionControlDetector()
    private let overlayController = OverlayController()
    private let clickEventTapController = ClickEventTapController()
    private var refreshTimer: Timer?
    private var overlayEnabled = true
    private var wasMissionControlActive = false
    private var missionControlActivationTime: CFAbsoluteTime?
    private var missionControlLayoutSignature: String?
    private var missionControlStableLayoutTicks = 0
    private var missionControlOverlayReady = false
    private var missionControlWindows: [WindowModel] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        requestAccessibilityPermission()

        overlayController.onClose = { [weak self] window in
            self?.windowCollector.close(window)
            self?.refreshWindowsSoon()
        }
        overlayController.onClickTargetsChanged = { [weak self] targets in
            self?.clickEventTapController.updateTargets(targets)
        }
        clickEventTapController.onClickWindowID = { [weak self] windowID in
            guard let self,
                  let window = self.missionControlWindows.first(where: { $0.id == windowID })
            else {
                return
            }

            self.windowCollector.close(window)
            self.refreshWindowsSoon()
        }
        clickEventTapController.start()

        refreshTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshWindows()
            }
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
        refreshWindows()
        fputs("KanseiMissionClose started. Accessibility trusted: \(AXIsProcessTrusted())\n", stderr)
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        clickEventTapController.stop()
        overlayController.hide()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Kansei"
        statusItem.isVisible = true

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Refresh Windows", action: #selector(refreshMenuItem(_:)), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Toggle Overlay", action: #selector(toggleOverlay(_:)), keyEquivalent: "t"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func requestAccessibilityPermission() {
        let options = [axTrustedCheckOptionPromptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func refreshMenuItem(_ sender: NSMenuItem) {
        refreshWindows()
    }

    @objc private func toggleOverlay(_ sender: NSMenuItem) {
        overlayEnabled.toggle()
        refreshWindows()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func refreshWindowsSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refreshWindows()
        }
    }

    private func refreshWindows() {
        guard overlayEnabled else {
            deactivateOverlay()
            return
        }

        let isMissionControlActive = missionControlDetector.isActive()
        guard isMissionControlActive else {
            deactivateOverlay()
            return
        }

        if !wasMissionControlActive {
            missionControlWindows = windowCollector.collect()
            wasMissionControlActive = true
            missionControlActivationTime = CFAbsoluteTimeGetCurrent()
            missionControlLayoutSignature = nil
            missionControlStableLayoutTicks = 0
            missionControlOverlayReady = false
        } else {
            missionControlWindows = windowCollector.refreshBounds(for: missionControlWindows)
        }

        updateMissionControlReadiness()
        guard missionControlOverlayReady else {
            overlayController.hide()
            statusItem.button?.title = "Kansei"
            return
        }

        overlayController.show(windows: missionControlWindows)
        statusItem.button?.title = "Kansei \(missionControlWindows.count)"
    }

    private func deactivateOverlay() {
        if wasMissionControlActive {
            missionControlWindows.removeAll()
            wasMissionControlActive = false
            missionControlActivationTime = nil
            missionControlLayoutSignature = nil
            missionControlStableLayoutTicks = 0
            missionControlOverlayReady = false
        }

        if overlayController.isShowing {
            overlayController.hide()
            statusItem.button?.title = "Kansei"
        }
    }

    private func updateMissionControlReadiness() {
        guard !missionControlWindows.isEmpty else {
            missionControlOverlayReady = false
            missionControlStableLayoutTicks = 0
            missionControlLayoutSignature = nil
            return
        }

        let signature = layoutSignature(for: missionControlWindows)
        if signature == missionControlLayoutSignature {
            missionControlStableLayoutTicks += 1
        } else {
            missionControlLayoutSignature = signature
            missionControlStableLayoutTicks = 0
            missionControlOverlayReady = false
        }

        let activeDuration = CFAbsoluteTimeGetCurrent() - (missionControlActivationTime ?? CFAbsoluteTimeGetCurrent())
        missionControlOverlayReady = activeDuration >= 0.35 && missionControlStableLayoutTicks >= 3
    }

    private func layoutSignature(for windows: [WindowModel]) -> String {
        windows
            .sorted { $0.id < $1.id }
            .map { window in
                let bounds = window.bounds.integral
                return "\(window.id):\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))"
            }
            .joined(separator: "|")
    }
}

struct ClickTarget {
    let windowID: CGWindowID
    let globalButtonBounds: CGRect
}

final class ClickEventTapController: @unchecked Sendable {
    var onClickWindowID: ((CGWindowID) -> Void)?

    private let lock = NSLock()
    private var targets: [ClickTarget] = []
    private var suppressNextLeftMouseUp = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard eventTap == nil else {
            return
        }

        let eventMask = CGEventMask(
            (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.leftMouseUp.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: clickEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            fputs("Failed to create click event tap. Close buttons will be visual only.\n", stderr)
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        updateTargets([])
    }

    func updateTargets(_ targets: [ClickTarget]) {
        lock.lock()
        self.targets = targets
        lock.unlock()
    }

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseUp, shouldSuppressLeftMouseUp() {
            return nil
        }

        guard type == .leftMouseDown,
              let windowID = targetWindowID(at: event.location)
        else {
            return Unmanaged.passUnretained(event)
        }

        setSuppressNextLeftMouseUp()
        DispatchQueue.main.async { [weak self] in
            self?.onClickWindowID?(windowID)
        }
        return nil
    }

    private func targetWindowID(at point: CGPoint) -> CGWindowID? {
        lock.lock()
        let matchedTarget = targets.last { $0.globalButtonBounds.contains(point) }
        lock.unlock()
        return matchedTarget?.windowID
    }

    private func setSuppressNextLeftMouseUp() {
        lock.lock()
        suppressNextLeftMouseUp = true
        lock.unlock()
    }

    private func shouldSuppressLeftMouseUp() -> Bool {
        lock.lock()
        let shouldSuppress = suppressNextLeftMouseUp
        suppressNextLeftMouseUp = false
        lock.unlock()
        return shouldSuppress
    }
}

private func clickEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let controller = Unmanaged<ClickEventTapController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handleEvent(type: type, event: event)
}

struct MissionControlDetector {
    func isActive() -> Bool {
        guard let rawInfos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let displayBounds = Self.activeDisplayBounds()
        return rawInfos.contains { info in
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName == "Dock",
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 18,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else {
                return false
            }

            let windowName = info[kCGWindowName as String] as? String
            guard windowName == nil || windowName == "" else {
                return false
            }

            return displayBounds.contains { Self.isFullScreenDockOverlay(bounds, on: $0) }
        }
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }

        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }

    private static func isFullScreenDockOverlay(_ bounds: CGRect, on displayBounds: CGRect) -> Bool {
        let tolerance: CGFloat = 2
        return abs(bounds.minX - displayBounds.minX) <= tolerance
            && abs(bounds.minY - displayBounds.minY) <= tolerance
            && abs(bounds.width - displayBounds.width) <= tolerance
            && abs(bounds.height - displayBounds.height) <= tolerance
    }
}

struct WindowModel: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let axWindow: AXUIElement
    let axCloseButton: AXUIElement?
    let bounds: CGRect
    let layer: Int

    func withBounds(_ bounds: CGRect, layer: Int) -> WindowModel {
        WindowModel(
            id: id,
            pid: pid,
            appName: appName,
            title: title,
            axWindow: axWindow,
            axCloseButton: axCloseButton,
            bounds: bounds,
            layer: layer
        )
    }
}

final class WindowCollector {
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func collect() -> [WindowModel] {
        guard AXIsProcessTrusted(), KanseiAXUIElementGetWindowAvailable() else {
            return []
        }

        let cgInfoByID = Self.cgWindowInfoByID()
        var result: [WindowModel] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != ownPID,
                  app.activationPolicy == .regular,
                  !app.isHidden
            else {
                continue
            }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.08)

            var rawWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows) == .success,
                  let axWindows = rawWindows as? [AXUIElement]
            else {
                continue
            }

            for axWindow in axWindows {
                guard isNormalWindow(axWindow) else {
                    continue
                }

                var windowID: CGWindowID = 0
                guard KanseiAXUIElementGetWindow(axWindow, &windowID) == .success,
                      windowID != 0,
                      let cgInfo = cgInfoByID[windowID],
                      cgInfo.pid == app.processIdentifier,
                      cgInfo.layer == 0,
                      cgInfo.bounds.width > 48,
                      cgInfo.bounds.height > 48
                else {
                    continue
                }

                let closeButton = closeButton(for: axWindow)
                guard closeButton != nil || supportsCloseAction(axWindow) else {
                    continue
                }

                result.append(WindowModel(
                    id: windowID,
                    pid: app.processIdentifier,
                    appName: app.localizedName ?? cgInfo.ownerName ?? "App \(app.processIdentifier)",
                    title: title(for: axWindow) ?? cgInfo.title ?? "",
                    axWindow: axWindow,
                    axCloseButton: closeButton,
                    bounds: cgInfo.bounds,
                    layer: cgInfo.layer
                ))
            }
        }

        return result.sorted {
            if $0.appName == $1.appName {
                return $0.title < $1.title
            }
            return $0.appName < $1.appName
        }
    }

    func close(_ window: WindowModel) {
        if let closeButton = window.axCloseButton,
           AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success {
            return
        }

        _ = AXUIElementPerformAction(window.axWindow, axCloseActionName as CFString)
    }

    func refreshBounds(for windows: [WindowModel]) -> [WindowModel] {
        let cgInfoByID = Self.cgWindowInfoByID()
        return windows.compactMap { window in
            guard let cgInfo = cgInfoByID[window.id],
                  cgInfo.pid == window.pid,
                  cgInfo.bounds.width > 48,
                  cgInfo.bounds.height > 48
            else {
                return nil
            }

            return window.withBounds(cgInfo.bounds, layer: cgInfo.layer)
        }
    }

    private func isNormalWindow(_ axWindow: AXUIElement) -> Bool {
        guard stringAttribute(kAXRoleAttribute, of: axWindow) == kAXWindowRole as String else {
            return false
        }

        if boolAttribute(kAXMinimizedAttribute, of: axWindow) == true {
            return false
        }

        return true
    }

    private func closeButton(for axWindow: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &value) == .success else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func supportsCloseAction(_ axWindow: AXUIElement) -> Bool {
        var value: CFArray?
        guard AXUIElementCopyActionNames(axWindow, &value) == .success,
              let actions = value as? [String]
        else {
            return false
        }
        return actions.contains(axCloseActionName)
    }

    private func title(for axWindow: AXUIElement) -> String? {
        stringAttribute(kAXTitleAttribute, of: axWindow)
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func cgWindowInfoByID() -> [CGWindowID: CGInfo] {
        guard let rawInfos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var result: [CGWindowID: CGInfo] = [:]
        for info in rawInfos {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else {
                continue
            }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let title = info[kCGWindowName as String] as? String
            let ownerName = info[kCGWindowOwnerName as String] as? String
            result[id] = CGInfo(pid: pid, ownerName: ownerName, title: title, bounds: bounds, layer: layer)
        }
        return result
    }

    private struct CGInfo {
        let pid: pid_t
        let ownerName: String?
        let title: String?
        let bounds: CGRect
        let layer: Int
    }
}

@MainActor
final class OverlayController {
    var onClose: ((WindowModel) -> Void)?
    var onClickTargetsChanged: (([ClickTarget]) -> Void)?

    private var overlaysByDisplayID: [CGDirectDisplayID: OverlayPanel] = [:]

    var isShowing: Bool {
        !overlaysByDisplayID.isEmpty
    }

    func show(windows: [WindowModel]) {
        let displays = DisplayGeometry.activeDisplays()
        let mouseLocation = NSEvent.mouseLocation
        var clickTargets: [ClickTarget] = []

        for display in displays {
            let panel = overlaysByDisplayID[display.id] ?? OverlayPanel(screen: display.screen)
            overlaysByDisplayID[display.id] = panel

            let screenWindows = windows.compactMap { window -> OverlayItem? in
                guard display.cgBounds.intersects(window.bounds) else {
                    return nil
                }
                let clipped = window.bounds.intersection(display.cgBounds)
                let localBounds = CGRect(
                    x: clipped.minX - display.cgBounds.minX,
                    y: clipped.minY - display.cgBounds.minY,
                    width: clipped.width,
                    height: clipped.height
                )
                return OverlayItem(window: window, windowBounds: localBounds)
            }

            let visibleItems: [OverlayItem]
            if let mousePoint = display.localTopLeftPoint(forAppKitMouseLocation: mouseLocation),
               let hoveredItem = screenWindows.last(where: { $0.windowBounds.contains(mousePoint) }) {
                visibleItems = [hoveredItem]
                clickTargets.append(ClickTarget(
                    windowID: hoveredItem.window.id,
                    globalButtonBounds: display.globalTopLeftRect(forLocalTopLeftRect: hoveredItem.closeButtonBounds)
                ))
            } else {
                visibleItems = []
            }

            panel.update(items: visibleItems, onClose: onClose)
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }

        let activeDisplayIDs = Set(displays.map(\.id))
        for (displayID, panel) in overlaysByDisplayID where !activeDisplayIDs.contains(displayID) {
            panel.close()
        }
        overlaysByDisplayID = overlaysByDisplayID.filter { activeDisplayIDs.contains($0.key) }
        onClickTargetsChanged?(clickTargets)
    }

    func hide() {
        overlaysByDisplayID.values.forEach { $0.close() }
        overlaysByDisplayID.removeAll()
        onClickTargetsChanged?([])
    }
}

struct OverlayItem {
    let window: WindowModel
    let windowBounds: CGRect

    var closeButtonBounds: CGRect {
        let diameter: CGFloat = 24
        return CGRect(
            x: windowBounds.minX + 8,
            y: windowBounds.minY + 8,
            width: diameter,
            height: diameter
        )
    }
}

@MainActor
final class OverlayPanel {
    private let panel: NSPanel
    private let overlayView: OverlayView

    init(screen: NSScreen) {
        overlayView = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = overlayView
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func orderFrontRegardless() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
    }

    func update(items: [OverlayItem], onClose: ((WindowModel) -> Void)?) {
        overlayView.update(items: items, onClose: onClose)
    }
}

final class OverlayView: NSView {
    private var items: [OverlayItem] = []
    private var onClose: ((WindowModel) -> Void)?
    private let buttonColor = NSColor.systemRed

    override var isFlipped: Bool { true }

    func update(items: [OverlayItem], onClose: ((WindowModel) -> Void)?) {
        self.items = items
        self.onClose = onClose
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        item(at: point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let item = item(at: location) else {
            return
        }
        onClose?(item.window)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for item in items {
            drawButton(item.closeButtonBounds, title: item.window.appName)
        }
    }

    private func item(at point: CGPoint) -> OverlayItem? {
        items.last { $0.closeButtonBounds.contains(point) }
    }

    private func drawButton(_ rect: CGRect, title: String) {
        let path = NSBezierPath(ovalIn: rect)
        buttonColor.setFill()
        path.fill()

        NSColor.white.setStroke()
        let mark = NSBezierPath()
        mark.lineWidth = 2.4
        let inset = rect.width * 0.32
        mark.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
        mark.line(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        mark.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
        mark.line(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
        mark.stroke()

        drawTooltipLabel(title, nextTo: rect)
    }

    private func drawTooltipLabel(_ title: String, nextTo rect: CGRect) {
        guard !title.isEmpty else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.45),
        ]
        let text = NSString(string: title)
        text.draw(at: CGPoint(x: rect.maxX + 5, y: rect.minY + 4), withAttributes: attributes)
    }
}

struct DisplayGeometry {
    let id: CGDirectDisplayID
    let screen: NSScreen
    let cgBounds: CGRect

    func localTopLeftPoint(forAppKitMouseLocation mouseLocation: CGPoint) -> CGPoint? {
        guard screen.frame.contains(mouseLocation) else {
            return nil
        }

        return CGPoint(
            x: mouseLocation.x - screen.frame.minX,
            y: screen.frame.maxY - mouseLocation.y
        )
    }

    func globalTopLeftRect(forLocalTopLeftRect rect: CGRect) -> CGRect {
        CGRect(
            x: cgBounds.minX + rect.minX,
            y: cgBounds.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )
    }

    static func activeDisplays() -> [DisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            return DisplayGeometry(
                id: displayID,
                screen: screen,
                cgBounds: CGDisplayBounds(displayID)
            )
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.finishLaunching()
app.run()
