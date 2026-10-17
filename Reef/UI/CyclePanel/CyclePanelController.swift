//
//  CyclePanelController.swift
//  Reef
//
//  Created by Xander Gouws on 23-01-2026.
//

import AppKit
import SwiftUI


@MainActor
final class CyclePanelController: NSObject {
    private(set) var panel: CyclePanel!
    private let state = CyclePanelState()
    private let modifierManager: ModifierManager
    private let mruTracker: AppMRUTracker
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    /// Swallows arrow keys before system shortcuts (⌃ arrows) while a switcher is open.
    private var arrowKeyTap: CFMachPort?
    private var arrowKeyTapSource: CFRunLoopSource?
    /// Cursor hover is ignored until the pointer moves after the switcher appears,
    /// so a cursor already resting on a row does not steal the keyboard selection.
    private var pointerSelectionEnabled = false
    private var pointerAnchorLocation = NSPoint.zero
    private var hoveredIndex: Int?
    private let pointerSelectionMovementThreshold: CGFloat = 2
    private var currentApplication: Application?
    private var panelAnchorTopCenter: CGPoint?
    private var isCleaningUp = false
    private var hostingView: NSView?
    private var appliedSwitcherIsDark: Bool?
    private var appearanceObservers: [NSObjectProtocol] = []

    /// Notifies the ⌘Tab interceptor when the app-switcher panel is shown/hidden.
    var appSwitcherVisibilityDidChange: ((Bool) -> Void)?

    nonisolated private static let upArrowKeyCode: UInt16 = 126
    nonisolated private static let downArrowKeyCode: UInt16 = 125
    nonisolated private static let leftArrowKeyCode: UInt16 = 123
    nonisolated private static let rightArrowKeyCode: UInt16 = 124
    nonisolated private static let arrowKeyCodes: Set<UInt16> = [
        upArrowKeyCode, downArrowKeyCode, leftArrowKeyCode, rightArrowKeyCode
    ]

    private let panelContentWidth: CGFloat = 400
    private let maxPanelFrameHeightCap: CGFloat = 520

    // Keep these aligned with CyclePanelView.
    private let headerHeight: CGFloat = 44
    private let dividerHeight: CGFloat = 1
    private let rowHeight: CGFloat = 44
    private let rowSpacing: CGFloat = 4
    private let listVerticalPadding: CGFloat = 8
    private static let releaseModifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    private var minPanelContentHeight: CGFloat {
        // Minimum height that still matches the layout for one row.
        headerHeight + dividerHeight + (listVerticalPadding * 2) + rowHeight
    }

    private var excludedAppBundleIDs: Set<String> {
        Set([Bundle.main.bundleIdentifier].compactMap { $0 })
    }
    
    init(modifierManager: ModifierManager, mruTracker: AppMRUTracker) {
        self.modifierManager = modifierManager
        self.mruTracker = mruTracker
        super.init()
        createPanel()
        startAppearanceObservation()
        applySwitcherAppearance()
    }
    
    private func createPanel() {
        let contentRect = NSRect(x: 0, y: 0, width: panelContentWidth, height: 300)
        panel = CyclePanel(contentRect: contentRect)
        
        let contentView = CyclePanelView(
            state: state,
            onHoverIndex: { [weak self] index in
                self?.handleHover(index)
            },
            onHoverEnd: { [weak self] index in
                self?.handleHoverEnd(index)
            },
            onActivateIndex: { [weak self] index in
                guard let self else { return }
                self.state.selectIndex(index)
                self.activateSelectedWindow()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        self.hostingView = hostingView
        
        guard let containerView = panel.contentView else { return }
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        panel.onDidResignKey = { [weak self] in
            self?.resetSwitcherState()
        }
    }

    private func startAppearanceObservation() {
        let defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applySwitcherAppearance()
            }
        }
        appearanceObservers.append(defaultsObserver)

        let interfaceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                Task { @MainActor in
                    // effectiveAppearance updates after the theme notification is delivered.
                    self?.appliedSwitcherIsDark = nil
                    self?.applySwitcherAppearance()
                }
            }
        }
        appearanceObservers.append(interfaceObserver)
    }

    private func applySwitcherAppearance() {
        let isDark = SwitcherAppearance.preference.resolvesDark
        guard appliedSwitcherIsDark != isDark else { return }
        appliedSwitcherIsDark = isDark

        panel.applyChrome(isDark: isDark)
        hostingView?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
    
    // Called when user presses the configured window-switching shortcut.
    func showSwitcher(for application: Application, startIndex: Int = 0) {
        currentApplication = application
        state.setApplication(application)
        
        // Instant switch if the user opted in and there is one actual window
        if UserDefaults.standard.string(forKey: "instantSwitch") == "whenOnlyOneWindowOpen",
           state.items.count == 1,
           case .window = state.currentItem {
            activateSelectedWindow()
            return
        }
        
        // If starting index is provided (e.g., already on that app), use it
        if startIndex > 0 && startIndex < state.items.count {
            state.selectedIndex = startIndex
        }
        
        presentPanelIfNeeded()
    }

    /// Entry point for the ⌘Tab / ⌘⇧Tab app switcher.
    func handleCommandTab(reversed: Bool) {
        if panel.isVisible, state.mode == .apps {
            if reversed {
                state.cyclePrevious()
            } else {
                state.cycleNext()
            }
            return
        }

        let apps = Application.appsWithOpenWindows(
            excludingBundleIDs: excludedAppBundleIDs,
            mruOrder: mruTracker.orderedBundleIDs
        )
        guard !apps.isEmpty else { return }

        let startIndex: Int
        if apps.count == 1 {
            startIndex = 0
        } else if reversed {
            startIndex = apps.count - 1
        } else {
            startIndex = 1
        }

        showAppSwitcher(apps: apps, startIndex: startIndex)
    }

    func showAppSwitcher(apps: [Application], startIndex: Int = 0) {
        currentApplication = nil
        state.setApps(apps)

        if startIndex > 0 && startIndex < state.items.count {
            state.selectedIndex = startIndex
        }

        presentPanelIfNeeded()
    }

    private func presentPanelIfNeeded() {
        if !panel.isVisible {
            beginPointerSelectionGate()
            panelAnchorTopCenter = defaultPanelAnchorTopCenter()
            // Size first so the frame matches content, pinned so the top stays put.
            updatePanelSize()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            installFlagsMonitor()
            installKeyDownMonitor()
            installArrowKeyTap()
            installOutsideClickMonitor()
            // Modifier may already be up if the user released before monitors were installed
            // (common on quick Alt/⌘Tab). Catch that with a snapshot check.
            activateIfSwitcherModifierWasReleased(NSEvent.modifierFlags)
        } else {
            if panelAnchorTopCenter == nil {
                panelAnchorTopCenter = defaultPanelAnchorTopCenter()
            }
            updatePanelSize()
        }

        appSwitcherVisibilityDidChange?(state.mode == .apps && panel.isVisible)
    }

    /// Horizontally centered; top edge at 1/4 of the screen height from the top.
    private func defaultPanelAnchorTopCenter() -> CGPoint {
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(
            x: visible.midX,
            y: visible.minY + visible.height * (3.0 / 4.0)
        )
    }

    private func updatePanelSize() {
        let itemCount = state.items.count
        let rowsHeight = CGFloat(itemCount) * rowHeight
        let spacingHeight = CGFloat(max(0, itemCount - 1)) * rowSpacing
        let listHeight = rowsHeight + spacingHeight + (listVerticalPadding * 2)
        let desiredContentHeight = headerHeight + dividerHeight + listHeight

        let maxContentHeightByScreen: CGFloat = {
            let visibleFrameHeight = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? maxPanelFrameHeightCap
            let maxFrameHeight = min(maxPanelFrameHeightCap, visibleFrameHeight * 0.6)
            let maxFrameRect = NSRect(x: 0, y: 0, width: panelContentWidth, height: maxFrameHeight)
            return panel.contentRect(forFrameRect: maxFrameRect).height
        }()

        let clampedContentHeight = max(minPanelContentHeight, min(desiredContentHeight, maxContentHeightByScreen))
        let targetContentRect = NSRect(x: 0, y: 0, width: panelContentWidth, height: clampedContentHeight)
        let targetFrameSize = panel.frameRect(forContentRect: targetContentRect).size

        // Keep the panel's top edge fixed while content height changes.
        let anchor = panelAnchorTopCenter ?? CGPoint(x: panel.frame.midX, y: panel.frame.maxY)
        let newOrigin = CGPoint(
            x: anchor.x - targetFrameSize.width / 2,
            y: anchor.y - targetFrameSize.height
        )
        let newFrame = NSRect(origin: newOrigin, size: targetFrameSize)

        panel.setFrame(newFrame, display: true, animate: false)
    }
    
    // Called when user presses the switcher shortcut again while panel is visible.
    func cycleNext() {
        state.cycleNext()
    }

    func cyclePrevious() {
        state.cyclePrevious()
    }
    
    func isShowingSwitcher(for application: Application) -> Bool {
        guard state.mode == .windows, let currentApplication else { return false }
        
        if let currentBundleID = currentApplication.bundleIdentifier,
           let targetBundleID = application.bundleIdentifier {
            return currentBundleID == targetBundleID
        }
        
        if let currentURL = currentApplication.bundleUrl,
           let targetURL = application.bundleUrl {
            return currentURL == targetURL
        }
        
        return currentApplication.title == application.title
    }
    
    // Called when user releases a configured switcher modifier.
    func activateSelectedWindow() {
        guard let item = state.currentItem else {
            hideSwitcher()
            return
        }
        
        switch item {
        case .window(let window):
            window.focus()
            hideSwitcher()
        case .app(let application):
            if let window = application.getFocusedWindow() ?? application.getFirstWindow() {
                window.focus()
            } else {
                application.activate()
            }
            hideSwitcher()
        case .action:
            let application = currentApplication
            hideSwitcher()
            
            Task { @MainActor in
                guard let application else {
                    NSSound.beep()
                    return
                }
                
                let success = await application.performNoWindowAction()
                if !success {
                    NSSound.beep()
                }
            }
        }
    }
    
    // Called when user presses W to close the currently selected window.
    private func closeSelectedWindow() {
        guard let window = state.currentWindow else { return }
        
        if !window.close() {
            NSSound.beep()
            return
        }
        
        state.removeCurrentWindow()
        if state.items.isEmpty {
            hideSwitcher()
        } else {
            updatePanelSize()
        }
    }

    private func closeSelectedAppWindow() {
        guard let application = state.currentApp else { return }

        guard let window = application.getFocusedWindow() ?? application.getFirstWindow() else {
            NSSound.beep()
            return
        }

        if !window.close() {
            NSSound.beep()
            return
        }

        if application.getWindows().isEmpty {
            state.removeCurrentItem()
            if state.items.isEmpty {
                hideSwitcher()
            } else {
                updatePanelSize()
            }
        }
    }

    private func quitSelectedApp() {
        guard let application = state.currentApp,
              let runningApplication = application.runningApplication
        else {
            NSSound.beep()
            return
        }

        if !runningApplication.terminate() {
            NSSound.beep()
            return
        }

        state.removeCurrentItem()
        if state.items.isEmpty {
            hideSwitcher()
        } else {
            updatePanelSize()
        }
    }
    
    /// Dismisses without activating (Escape / interceptor).
    func dismissSwitcher() {
        hideSwitcher()
    }

    /// Quit selected app from the ⌘Tab event tap (Q while switcher is open).
    func quitSelectedAppFromHotkey() {
        guard panel.isVisible, state.mode == .apps else { return }
        quitSelectedApp()
    }

    /// Close selected app's front window from the ⌘Tab event tap (W while switcher is open).
    func closeSelectedAppWindowFromHotkey() {
        guard panel.isVisible, state.mode == .apps else { return }
        closeSelectedAppWindow()
    }

    private func resetSwitcherState() {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        defer { isCleaningUp = false }

        removeFlagsMonitor()
        removeKeyDownMonitor()
        removeArrowKeyTap()
        removeOutsideClickMonitor()
        endPointerSelectionGate()
        state.reset()
        currentApplication = nil
        panelAnchorTopCenter = nil
        appSwitcherVisibilityDidChange?(false)
    }

    private func hideSwitcher() {
        resetSwitcherState()
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }
    
    private func beginPointerSelectionGate() {
        pointerSelectionEnabled = false
        hoveredIndex = nil
        pointerAnchorLocation = NSEvent.mouseLocation
        removeMouseMoveMonitor()
        installMouseMoveMonitor()
    }

    private func endPointerSelectionGate() {
        pointerSelectionEnabled = false
        hoveredIndex = nil
        pointerAnchorLocation = .zero
        removeMouseMoveMonitor()
    }

    /// Arms pointer selection once the cursor has moved away from where it was when the switcher opened.
    @discardableResult
    private func armPointerSelectionIfMoved() -> Bool {
        if pointerSelectionEnabled { return true }

        let current = NSEvent.mouseLocation
        let dx = current.x - pointerAnchorLocation.x
        let dy = current.y - pointerAnchorLocation.y
        guard hypot(dx, dy) >= pointerSelectionMovementThreshold else { return false }

        pointerSelectionEnabled = true
        removeMouseMoveMonitor()
        return true
    }

    private func handleHover(_ index: Int) {
        hoveredIndex = index
        guard armPointerSelectionIfMoved() else { return }
        state.selectIndex(index)
    }

    private func handleHoverEnd(_ index: Int) {
        guard hoveredIndex == index else { return }
        hoveredIndex = nil
    }

    private func handlePointerMovement() {
        guard armPointerSelectionIfMoved() else { return }
        if let hoveredIndex {
            state.selectIndex(hoveredIndex)
        }
    }

    private func installMouseMoveMonitor() {
        guard mouseMoveMonitor == nil else { return }

        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            guard let self else { return event }
            self.handlePointerMovement()
            return event
        }
    }

    private func removeMouseMoveMonitor() {
        if let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMoveMonitor = nil
        }
    }

    private func installFlagsMonitor() {
        guard localFlagsMonitor == nil, globalFlagsMonitor == nil else { return }
        
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return event }
            
            self.activateIfSwitcherModifierWasReleased(event.modifierFlags)
            
            return event
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.activateIfSwitcherModifierWasReleased(event.modifierFlags)
            }
        }
    }

    private func requiredReleaseModifiers() -> NSEvent.ModifierFlags {
        switch state.mode {
        case .apps:
            return .command
        case .windows:
            return modifierManager.activateModifiers.intersection(Self.releaseModifierMask)
        }
    }

    private func activateIfSwitcherModifierWasReleased(_ modifierFlags: NSEvent.ModifierFlags) {
        guard panel.isVisible else { return }

        let requiredModifiers = requiredReleaseModifiers()
        guard !requiredModifiers.isEmpty else { return }

        let pressedModifiers = modifierFlags.intersection(Self.releaseModifierMask)
        if !requiredModifiers.isSubset(of: pressedModifiers) {
            activateSelectedWindow()
        }
    }
    
    private func removeFlagsMonitor() {
        if let monitor = localFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsMonitor = nil
        }

        if let monitor = globalFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            globalFlagsMonitor = nil
        }
    }

    /// Move the selection from an arrow key while a switcher is open.
    /// Up/left go backward; down/right go forward. Returns whether the key was handled.
    func moveSelection(forArrowKeyCode keyCode: UInt16) -> Bool {
        guard panel.isVisible else { return false }

        switch keyCode {
        case Self.upArrowKeyCode, Self.leftArrowKeyCode:
            cyclePrevious()
            return true
        case Self.downArrowKeyCode, Self.rightArrowKeyCode:
            cycleNext()
            return true
        default:
            return false
        }
    }

    /// Session tap so ⌃/⌘+arrow moves the selection instead of Mission Control or Spaces.
    private func installArrowKeyTap() {
        guard arrowKeyTap == nil else { return }
        guard AXIsProcessTrusted() else { return }

        let mask =
            (1 << CGEventType.keyDown.rawValue)
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
                let controller = Unmanaged<CyclePanelController>.fromOpaque(refcon).takeUnretainedValue()
                return controller.handleArrowKeyEvent(type: type, event: event)
            },
            userInfo: unmanagedSelf
        ) else {
            return
        }

        arrowKeyTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        arrowKeyTapSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeArrowKeyTap() {
        if let arrowKeyTap {
            CGEvent.tapEnable(tap: arrowKeyTap, enable: false)
        }
        if let arrowKeyTapSource {
            CFRunLoopSourceInvalidate(arrowKeyTapSource)
        }
        arrowKeyTap = nil
        arrowKeyTapSource = nil
    }

    /// Called from the event-tap callback. Not isolated to the main actor.
    nonisolated private func handleArrowKeyEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                guard let tap = self?.arrowKeyTap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        guard Self.arrowKeyCodes.contains(keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [weak self] in
            _ = self?.moveSelection(forArrowKeyCode: keyCode)
        }
        return nil
    }

    private func installKeyDownMonitor() {
        guard keyDownMonitor == nil else { return }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Escape closes the switcher.
            if self.panel.isVisible, event.keyCode == 53 {
                Task { @MainActor in
                    self.hideSwitcher()
                }
                return nil
            }

            // Arrow keys move the selection in both the window and app switchers.
            if self.panel.isVisible, Self.arrowKeyCodes.contains(event.keyCode) {
                let keyCode = event.keyCode
                Task { @MainActor in
                    _ = self.moveSelection(forArrowKeyCode: keyCode)
                }
                return nil
            }

            // W closes the selected window (window mode) or the selected app's front window (app mode).
            if self.panel.isVisible, event.keyCode == 13 {
                Task { @MainActor in
                    switch self.state.mode {
                    case .windows:
                        self.closeSelectedWindow()
                    case .apps:
                        self.closeSelectedAppWindow()
                    }
                }
                return nil
            }

            // Q quits the selected app (app mode only).
            if self.panel.isVisible, self.state.mode == .apps, event.keyCode == 12 {
                Task { @MainActor in
                    self.quitSelectedApp()
                }
                return nil
            }

            return event
        }
    }

    private func removeKeyDownMonitor() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
    }

    /// Dismiss on a click outside the panel, same as Escape. Clicks on a row still activate it.
    private func installOutsideClickMonitor() {
        guard localMouseDownMonitor == nil, globalMouseDownMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            guard self.panel.isVisible, !self.isClickInsidePanel(event) else { return event }

            Task { @MainActor in
                self.hideSwitcher()
            }
            return event
        }

        // Clicks in other apps are not delivered locally.
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                self.hideSwitcher()
            }
        }
    }

    private func isClickInsidePanel(_ event: NSEvent) -> Bool {
        if event.window === panel { return true }

        let screenLocation: NSPoint
        if let window = event.window {
            screenLocation = window.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenLocation = NSEvent.mouseLocation
        }
        return panel.frame.contains(screenLocation)
    }

    private func removeOutsideClickMonitor() {
        if let monitor = localMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseDownMonitor = nil
        }
        if let monitor = globalMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseDownMonitor = nil
        }
    }
    
    deinit {
        // Capture the monitor in a local variable before deinit (while still on main actor)
        let localMonitor = localFlagsMonitor
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        let globalMonitor = globalFlagsMonitor
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }

        let keyMonitor = keyDownMonitor
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }

        let mouseMonitor = mouseMoveMonitor
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }

        let localClickMonitor = localMouseDownMonitor
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }

        let globalClickMonitor = globalMouseDownMonitor
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }

        let arrowTap = arrowKeyTap
        if let arrowTap {
            CGEvent.tapEnable(tap: arrowTap, enable: false)
        }
        let arrowSource = arrowKeyTapSource
        if let arrowSource {
            CFRunLoopSourceInvalidate(arrowSource)
        }

        let observers = appearanceObservers
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
