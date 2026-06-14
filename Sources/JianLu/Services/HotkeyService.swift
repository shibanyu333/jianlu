import AppKit
@preconcurrency import ApplicationServices
import Foundation
import JianLuCore
import os

enum HotkeyAction {
    case beginHoldZoom
    case endHoldZoom
    case zoomIn
    case zoomOut
    case selectTool(AnnotationTool)
    case undo
    case clearAnnotations
    case toggleCamera
    case toggleCameraShape
    case stopRecording
}

@MainActor
final class HotkeyService: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.local.JianLu", category: "Hotkeys")
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var shortcutPollTimer: Timer?
    private var isPollingHoldZoomActive = false
    private var handler: ((HotkeyAction) -> Void)?
    private var zoomShortcutProvider: (() -> ZoomShortcut)?

    func start(
        zoomShortcutProvider: @escaping () -> ZoomShortcut,
        handler: @escaping (HotkeyAction) -> Void
    ) {
        self.zoomShortcutProvider = zoomShortcutProvider
        self.handler = handler
        stopMonitoring()
        startShortcutPolling()

        if startEventTap() {
            return
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
            return event
        }
    }

    func stopMonitoring() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        shortcutPollTimer?.invalidate()
        shortcutPollTimer = nil
        if isPollingHoldZoomActive {
            handler?(.endHoldZoom)
            isPollingHoldZoomActive = false
        }
        globalMonitor = nil
        localMonitor = nil
        eventTap = nil
        eventTapSource = nil
    }

    private func handle(_ event: NSEvent) {
        handle(
            HotkeyEvent(
                type: HotkeyEventType(event.type),
                keyCode: event.keyCode,
                modifierFlagsRawValue: event.modifierFlags.rawValue,
                isRepeat: event.isARepeat
            )
        )
    }

    fileprivate func handle(_ event: HotkeyEvent) {
        guard let eventType = event.type else { return }
        let zoomShortcut = zoomShortcutProvider?() ?? .controlOptionCommandZ

        if eventType == .keyUp, event.keyCode == zoomShortcut.keyCode {
            handler?(.endHoldZoom)
            return
        }
        let modifierFlags = NSEvent.ModifierFlags(rawValue: event.modifierFlagsRawValue)
        if eventType == .flagsChanged, !zoomShortcut.matchesModifiers(modifierFlags) {
            handler?(.endHoldZoom)
            return
        }

        guard eventType == .keyDown, !event.isRepeat else { return }
        if zoomShortcut.matches(keyCode: event.keyCode, modifierFlags: modifierFlags) {
            handler?(.beginHoldZoom)
            return
        }

        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), flags.contains(.option), flags.contains(.command) else {
            return
        }

        switch event.keyCode {
        case 24:
            handler?(.zoomIn)
        case 27:
            handler?(.zoomOut)
        case 35:
            handler?(.selectTool(.pen))
        case 4:
            handler?(.selectTool(.highlight))
        case 37:
            handler?(.selectTool(.line))
        case 0:
            handler?(.selectTool(.arrow))
        case 11:
            handler?(.selectTool(.rectangle))
        case 31:
            handler?(.selectTool(.ellipse))
        case 32:
            handler?(.undo)
        case 7:
            handler?(.clearAnnotations)
        case 8:
            handler?(.toggleCamera)
        case 1:
            handler?(.toggleCameraShape)
        case 15:
            handler?(.stopRecording)
        default:
            break
        }
    }

    private func startEventTap() -> Bool {
        let eventMask =
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: hotkeyEventTapCallback,
            userInfo: refcon
        ) else {
            logger.warning("System event tap is unavailable; falling back to NSEvent monitors")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            logger.warning("System event tap source could not be created")
            return false
        }

        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("System event tap started")
        return true
    }

    fileprivate func restartEventTapAfterTimeout() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func startShortcutPolling() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollZoomShortcutState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shortcutPollTimer = timer
    }

    private func pollZoomShortcutState() {
        let zoomShortcut = zoomShortcutProvider?() ?? .controlOptionCommandZ
        let keyIsDown = CGEventSource.keyState(
            .combinedSessionState,
            key: CGKeyCode(zoomShortcut.keyCode)
        )
        let modifierFlags = NSEvent.ModifierFlags(
            rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)
        )
        let isActive = keyIsDown && zoomShortcut.matchesModifiers(modifierFlags)
        guard isActive != isPollingHoldZoomActive else { return }

        isPollingHoldZoomActive = isActive
        handler?(isActive ? .beginHoldZoom : .endHoldZoom)
    }
}

private extension ZoomShortcut {
    var keyCode: UInt16 {
        switch self {
        case .controlOptionCommandZ, .controlOptionZ:
            6
        case .controlOptionCommandSpace, .controlOptionSpace:
            49
        }
    }

    var requiresCommand: Bool {
        switch self {
        case .controlOptionCommandZ, .controlOptionCommandSpace:
            true
        case .controlOptionZ, .controlOptionSpace:
            false
        }
    }

    func matches(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        keyCode == self.keyCode && matchesModifiers(modifierFlags)
    }

    func matchesModifiers(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), flags.contains(.option) else {
            return false
        }
        return flags.contains(.command) == requiresCommand
    }
}

private struct HotkeyEvent: Sendable {
    var type: HotkeyEventType?
    var keyCode: UInt16
    var modifierFlagsRawValue: NSEvent.ModifierFlags.RawValue
    var isRepeat: Bool
}

private enum HotkeyEventType: Sendable {
    case keyDown
    case keyUp
    case flagsChanged

    init?(_ eventType: NSEvent.EventType) {
        switch eventType {
        case .keyDown:
            self = .keyDown
        case .keyUp:
            self = .keyUp
        case .flagsChanged:
            self = .flagsChanged
        default:
            return nil
        }
    }

    init?(_ eventType: CGEventType) {
        switch eventType {
        case .keyDown:
            self = .keyDown
        case .keyUp:
            self = .keyUp
        case .flagsChanged:
            self = .flagsChanged
        default:
            return nil
        }
    }
}

private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in
            service.restartEventTapAfterTimeout()
        }
        return Unmanaged.passUnretained(event)
    }

    let hotkeyEvent = HotkeyEvent(
        type: HotkeyEventType(type),
        keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
        modifierFlagsRawValue: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).rawValue,
        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    )
    Task { @MainActor in
        service.handle(hotkeyEvent)
    }
    return Unmanaged.passUnretained(event)
}
