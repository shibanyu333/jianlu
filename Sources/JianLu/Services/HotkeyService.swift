import AppKit
import Foundation
import JianLuCore

enum HotkeyAction {
    case beginHoldZoom
    case endHoldZoom
    case beginClickZoom
    case endClickZoom
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
final class HotkeyService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var handler: ((HotkeyAction) -> Void)?
    private var zoomShortcutProvider: (() -> ZoomShortcut)?

    func start(
        zoomShortcutProvider: @escaping () -> ZoomShortcut,
        handler: @escaping (HotkeyAction) -> Void
    ) {
        self.zoomShortcutProvider = zoomShortcutProvider
        self.handler = handler
        stopMonitoring()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
            return event
        }
    }

    func stopMonitoring() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        let zoomShortcut = zoomShortcutProvider?() ?? .controlOptionCommandZ

        if event.type == .leftMouseDown {
            handler?(.beginClickZoom)
            return
        }
        if event.type == .leftMouseUp {
            handler?(.endClickZoom)
            return
        }

        if event.type == .keyUp, event.keyCode == zoomShortcut.keyCode {
            handler?(.endHoldZoom)
            return
        }
        if event.type == .flagsChanged, !zoomShortcut.matchesModifiers(event.modifierFlags) {
            handler?(.endHoldZoom)
            return
        }

        guard event.type == .keyDown, !event.isARepeat else { return }
        if zoomShortcut.matches(event) {
            handler?(.beginHoldZoom)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && matchesModifiers(event.modifierFlags)
    }

    func matchesModifiers(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), flags.contains(.option) else {
            return false
        }
        return flags.contains(.command) == requiresCommand
    }
}
