//
//  CommandTabInterceptor.swift
//  Reef
//
//  Disables the Dock's ⌘Tab switcher and routes ⌘Tab / ⌘⇧Tab into Reef's app switcher.
//

import AppKit
import ApplicationServices

/// Intercepts ⌘Tab / ⌘⇧Tab via a session event tap and drives `CyclePanelController`.
/// Not MainActor-isolated: the tap callback runs on a background run-loop thread.
final class CommandTabInterceptor: @unchecked Sendable {
    private weak var cycleController: CyclePanelController?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var isRunning = false

    private let lock = NSLock()
    private var _appSwitcherVisible = false

    /// Set from the main actor when the app-switcher panel opens/closes so Q/W/Esc
    /// can be swallowed before they hit Reef (e.g. ⌘Q quitting the app).
    var isAppSwitcherVisible: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _appSwitcherVisible
        }
        set {
            lock.lock()
            _appSwitcherVisible = newValue
            lock.unlock()
        }
    }

    private let tabKeyCode: Int64 = 48
    private let escapeKeyCode: Int64 = 53
    private let wKeyCode: Int64 = 13
    private let qKeyCode: Int64 = 12

    func start(cycleController: CyclePanelController) {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            print("Reef: Accessibility required to replace ⌘Tab")
            return
        }

        self.cycleController = cycleController
        SymbolicHotKey.setNativeCommandTabEnabled(false)

        let mask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let interceptor = Unmanaged<CommandTabInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handleEvent(type: type, event: event)
            },
            userInfo: unmanagedSelf
        ) else {
            print("Reef: Failed to create ⌘Tab event tap")
            SymbolicHotKey.setNativeCommandTabEnabled(true)
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        isRunning = true

        let source = runLoopSource
        tapThread = Thread { [weak self] in
            self?.tapRunLoop = CFRunLoopGetCurrent()
            if let source {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        tapThread?.name = "Reef.CommandTabInterceptor"
        tapThread?.qualityOfService = .userInteractive
        tapThread?.start()
    }

    func stop() {
        // Always attempt to restore native ⌘Tab, even if we weren't fully running.
        defer {
            isAppSwitcherVisible = false
            SymbolicHotKey.setNativeCommandTabEnabled(true)
        }

        guard isRunning else { return }
        isRunning = false

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopSourceInvalidate(source)
        }
        if let runLoop = tapRunLoop {
            CFRunLoopStop(runLoop)
        }

        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        cycleController = nil
    }

    private func handleEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let commandHeld = flags.contains(.maskCommand)

            if commandHeld, keyCode == tabKeyCode {
                let reversed = flags.contains(.maskShift)
                DispatchQueue.main.async { [weak self] in
                    self?.cycleController?.handleCommandTab(reversed: reversed)
                }
                return nil
            }

            // While the app switcher is open, claim Esc / Q / W so ⌘Q doesn't quit Reef.
            if isAppSwitcherVisible {
                switch keyCode {
                case escapeKeyCode:
                    DispatchQueue.main.async { [weak self] in
                        self?.cycleController?.dismissSwitcher()
                    }
                    return nil
                case qKeyCode:
                    DispatchQueue.main.async { [weak self] in
                        self?.cycleController?.quitSelectedAppFromHotkey()
                    }
                    return nil
                case wKeyCode:
                    DispatchQueue.main.async { [weak self] in
                        self?.cycleController?.closeSelectedAppWindowFromHotkey()
                    }
                    return nil
                default:
                    break
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    deinit {
        stop()
    }
}
