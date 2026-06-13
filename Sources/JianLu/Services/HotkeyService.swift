import AppKit
import Foundation
import JianLuCore

enum HotkeyAction {
    case toggleZoom
    case zoomIn
    case zoomOut
    case selectTool(AnnotationTool)
    case undo
    case toggleCamera
    case toggleCameraShape
    case stopRecording
}

@MainActor
final class HotkeyService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var handler: ((HotkeyAction) -> Void)?

    func start(handler: @escaping (HotkeyAction) -> Void) {
        self.handler = handler
        stopMonitoring()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        guard !event.isARepeat else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), flags.contains(.option), flags.contains(.command) else {
            return
        }

        switch event.keyCode {
        case 6:
            handler?(.toggleZoom)
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
        case 32:
            handler?(.undo)
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
