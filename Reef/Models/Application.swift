//
//  Application.swift
//  Reef
//
//  Created by Xander Gouws on 16-09-2025.
//

import Foundation
import Cocoa


class Application {
    var title: String
    var element: AXUIElement?

    var runningApplication: NSRunningApplication?
    var pid: pid_t?
    var bundleIdentifier: String?
    var bundleUrl: URL?
    
    init(_ runningApplication: NSRunningApplication) {
        self.runningApplication = runningApplication

        self.pid = runningApplication.processIdentifier

        self.element = AXUIElementCreateApplication(self.pid!)

        self.title = runningApplication.localizedName ?? "Unknown Application"
        self.bundleIdentifier = runningApplication.bundleIdentifier
        self.bundleUrl = runningApplication.bundleURL
    }
    
    // Initialize from URL (for loading from persistence)
    init?(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        self.bundleUrl = url
        self.bundleIdentifier = Bundle(url: url)?.bundleIdentifier
        self.title = url.deletingPathExtension().lastPathComponent
        
        // Try to find running instance
        if let bundle = Bundle(url: url),
           let bundleIdentifier = bundle.bundleIdentifier,
           let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            self.runningApplication = runningApp
            self.pid = runningApp.processIdentifier
            self.element = AXUIElementCreateApplication(self.pid!)
            self.title = runningApp.localizedName ?? self.title
        } else {
            self.runningApplication = nil
            self.pid = nil
            self.element = nil
        }
    }

    convenience init?(bundleIdentifier: String) {
        if let runningApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first
        {
            self.init(runningApp)
            return
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            self.init(url: url)
            return
        }

        return nil
    }
    
//    // Ensure application is running and refresh internal state
//    func ensureRunning() -> Bool {
//        guard let bundleUrl = self.bundleUrl else {
//            return false
//        }
//        
//        // Check if already running
//        if let runningApp = self.runningApplication,
//           runningApp.isTerminated == false {
//            return true
//        }
//        
//        // Try to find if it's running but we lost the reference
//        if let bundle = Bundle(url: bundleUrl),
//           let bundleIdentifier = bundle.bundleIdentifier,
//           let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
//            self.runningApplication = runningApp
//            self.pid = runningApp.processIdentifier
//            self.element = AXUIElementCreateApplication(self.pid!)
//            return true
//        }
//        
//        return false
//    }
    
    func focus() {
        self.activate()
    }
    
    var isRunning: Bool {
        refreshRunningApplication() != nil
    }

    func activate(options: NSApplication.ActivationOptions = []) {
        if let runningApplication = refreshRunningApplication() {
            // App is running, just activate it
            runningApplication.activate(options: options)
        } else {
            // App not running, launch it
            try? reopen()
        }
    }
    
    func getFocusedWindow() -> Window? {
        guard let element = element,
              let windowElement: AXUIElement = element.getAttributeValue(.focusedWindow) else {
            return nil
        }
        
        return Window(windowElement, self)
    }
    
    func getFirstWindow() -> Window? {
        guard let element = element,
              let windowElements: [AXUIElement] = element.getAttributeValue(.windows) else {
            return nil
        }
        
        if let firstWindowElement = windowElements.first {
            return Window(firstWindowElement, self)
        }
        
        return nil
    }
    
    func reopen(
        configuration: NSWorkspace.OpenConfiguration = Application.defaultOpenConfiguration(),
        completion: @escaping (Result<NSRunningApplication, Error>) -> Void
    ) throws {
        guard let bundleUrl = self.bundleUrl else {
            throw ApplicationError.noBundleURL
        }
        
        NSWorkspace.shared.openApplication(
            at: bundleUrl,
            configuration: configuration,
            completionHandler: { runningApplication, error in
                if let runningApplication {
                    self.setRunningApplication(runningApplication)
                    completion(.success(runningApplication))
                    return
                }
                
                completion(.failure(error ?? ApplicationError.openFailed))
            }
        )
    }
    
    func reopen(
        configuration: NSWorkspace.OpenConfiguration = Application.defaultOpenConfiguration()
    ) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try reopen(configuration: configuration) { result in
                    continuation.resume(with: result)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    func reopen() throws {
        try reopen(configuration: Self.defaultOpenConfiguration()) { _ in }
    }
    
    func performNoWindowAction() async -> Bool {
        if let existingWindow = getWindows().first {
            existingWindow.focus()
            return true
        }
        
        do {
            _ = try await reopen(configuration: Self.defaultOpenConfiguration(activates: true))
            return true
        } catch {
            return false
        }
    }
    
    static func getFrontApplication() -> Application? {
        guard let runningApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        
        return Application(runningApplication)
    }

    /// Running regular apps that have at least one user-facing window on any Space,
    /// excluding hidden/closed apps and the given bundle IDs.
    /// Sorted by `mruOrder` (front of list = most recently used).
    static func appsWithOpenWindows(
        excludingBundleIDs: Set<String> = [],
        mruOrder: [String] = []
    ) -> [Application] {
        let cgWindowsByPID = cgWindowsByOwnerPID()

        var apps: [Application] = []
        var seenBundleIDs = Set<String>()

        for runningApp in NSWorkspace.shared.runningApplications {
            guard runningApp.activationPolicy == .regular,
                  !runningApp.isHidden,
                  !runningApp.isTerminated,
                  let bundleID = runningApp.bundleIdentifier,
                  !excludingBundleIDs.contains(bundleID),
                  !seenBundleIDs.contains(bundleID)
            else {
                continue
            }

            let app = Application(runningApp)
            // Belt-and-suspenders: AX can report hidden even when NSRunningApplication lags.
            guard !app.isHidden else { continue }

            let cgWindows = cgWindowsByPID[runningApp.processIdentifier] ?? []
            guard app.hasUserFacingWindows(prefetchedCGWindows: cgWindows) else {
                continue
            }

            seenBundleIDs.insert(bundleID)
            apps.append(app)
        }

        apps.sort { lhs, rhs in
            let leftID = lhs.bundleIdentifier ?? ""
            let rightID = rhs.bundleIdentifier ?? ""
            let leftIndex = mruOrder.firstIndex(of: leftID) ?? Int.max
            let rightIndex = mruOrder.firstIndex(of: rightID) ?? Int.max
            if leftIndex != rightIndex {
                return leftIndex < rightIndex
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        return apps
    }
    
    static func activateOrLaunch(
        bundleIdentifier: String,
        bundleURL: URL,
        options: NSApplication.ActivationOptions = []
    ) {
        if let runningApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first
        {
            runningApplication.activate(options: options)
            return
        }
        
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in }
    }

    func getAXWindows() -> [AXUIElement] {
        guard let element = element else {
            return []
        }

        // Current-Space windows only. Other Spaces come from CGWindowList in `getWindows()`.
        guard let windows: [AXUIElement] = element.getAttributeValue(.windows) else {
            return []
        }

        return windows
    }

    /// True when this process is Cmd+H-hidden (NSRunningApplication and/or AX).
    var isHidden: Bool {
        if refreshRunningApplication()?.isHidden == true {
            return true
        }
        if let hidden: Bool = element?.getAttributeValue(.hidden), hidden {
            return true
        }
        return false
    }

    /// True when the app has a real window the user can switch to (not hidden-app
    /// chrome / closed-app phantom CG windows).
    func hasUserFacingWindows(prefetchedCGWindows: [CGWindowInfo]? = nil) -> Bool {
        if isHidden {
            return false
        }

        // Prefer Accessibility: accurate for open windows on the current Space.
        for axWindow in getAXWindows() {
            if Window(axWindow, self).isUserSwitchable {
                return true
            }
        }

        // Other Spaces: only count CG windows that have a real title. Untitled
        // off-screen surfaces are almost always leftovers from closed apps.
        let cgWindows = prefetchedCGWindows ?? Self.cgWindows(forPID: pid)
        return cgWindows.contains { !$0.isOnscreen && $0.isLikelyUserWindow }
    }

    /// User-switchable windows across **all Spaces** (not just the active Desktop).
    /// Listing is cheap (AX + CGWindowList). AX for other-Space windows is resolved
    /// lazily on focus/close, not while opening the switcher.
    func getWindows() -> [Window] {
        if isHidden {
            return []
        }

        let axWindows = getAXWindows()
        var seenWindowIDs = Set<CGWindowID>()
        var windows: [Window] = []

        // Current Space: AX list with existing filters (drops phantoms). Deduped by ID —
        // macOS sometimes returns duplicate AX entries for the same window.
        for axWindow in axWindows {
            let window = Window(axWindow, self)
            guard window.isUserSwitchable else { continue }
            if let windowID = window.cgWindowID, windowID != 0 {
                if seenWindowIDs.contains(windowID) { continue }
                seenWindowIDs.insert(windowID)
            }
            windows.append(window)
        }

        // Other Spaces / minimized: only CG windows that look like real user windows.
        // Skip on-screen CG entries — those belong on the current Space and were
        // already handled (or intentionally filtered) by AX.
        for info in Self.cgWindows(forPID: pid) {
            guard !info.isOnscreen,
                  info.isLikelyUserWindow,
                  !seenWindowIDs.contains(info.id)
            else {
                continue
            }

            let window = Window(cgWindowID: info.id, cgTitle: info.title, application: self)
            guard window.isUserSwitchable else { continue }
            seenWindowIDs.insert(info.id)
            windows.append(window)
        }

        // Finder can expose a trailing generic "Finder" window that is not useful for switching.
        if bundleIdentifier == "com.apple.finder",
           let lastWindow = windows.last,
           lastWindow.title == "Finder" {
            windows.removeLast()
        }

        return windows
    }

    struct CGWindowInfo {
        let id: CGWindowID
        let title: String?
        let isOnscreen: Bool
        let alpha: Double
        let bounds: CGRect

        /// Heuristic for real windows vs closed-app / helper phantoms in CGWindowList.
        var isLikelyUserWindow: Bool {
            guard id != 0 else { return false }
            guard alpha > 0.01 else { return false }
            // Tiny surfaces are almost always status/helper chrome, not switch targets.
            guard bounds.width >= 80, bounds.height >= 60 else { return false }
            // Require a real title — untitled off-screen windows are typically phantoms
            // left behind after an app's windows were closed.
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return false }
            return true
        }
    }

    /// One CGWindowList pass, grouped by owner PID.
    private static func cgWindowsByOwnerPID() -> [pid_t: [CGWindowInfo]] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }

        var grouped: [pid_t: [CGWindowInfo]] = [:]
        var seenPerPID: [pid_t: Set<CGWindowID>] = [:]

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  windowID != 0
            else {
                continue
            }

            if seenPerPID[ownerPID, default: []].contains(windowID) {
                continue
            }

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else {
                continue
            }

            // Prefer public CG name; fall back to WindowServer title for off-screen
            // windows only (other Spaces). Avoids a CGS call per on-screen window.
            let cgName = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isOnscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let title: String?
            if let cgName, !cgName.isEmpty {
                title = cgName
            } else if !isOnscreen {
                title = CGSWindow.title(for: windowID)
            } else {
                title = nil
            }

            let alpha = (info[kCGWindowAlpha as String] as? Double)
                ?? (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
                ?? 1.0

            seenPerPID[ownerPID, default: []].insert(windowID)
            grouped[ownerPID, default: []].append(
                CGWindowInfo(
                    id: windowID,
                    title: title,
                    isOnscreen: isOnscreen,
                    alpha: alpha,
                    bounds: bounds
                )
            )
        }

        return grouped
    }

    /// Normal (layer 0) windows owned by `pid`, including windows on other Spaces.
    private static func cgWindows(forPID pid: pid_t?) -> [CGWindowInfo] {
        guard let pid else { return [] }
        return cgWindowsByOwnerPID()[pid] ?? []
    }
    
    func listAvailableAttributes() -> [String] {
        guard let element = element else {
            return []
        }
        
        var attributesRef: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &attributesRef)
        
        guard result == .success, let attributes = attributesRef as? [String] else {
            return []
        }
        
        return attributes
    }
    
    @discardableResult
    private func refreshRunningApplication() -> NSRunningApplication? {
        if let runningApplication,
           runningApplication.isTerminated == false {
            return runningApplication
        }
        
        guard let bundleIdentifier else {
            setRunningApplication(nil)
            return nil
        }
        
        guard let detectedRunningApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first
        else {
            setRunningApplication(nil)
            return nil
        }
        
        setRunningApplication(detectedRunningApp)
        return detectedRunningApp
    }
    
    private func setRunningApplication(_ runningApplication: NSRunningApplication?) {
        self.runningApplication = runningApplication
        
        if let runningApplication {
            self.pid = runningApplication.processIdentifier
            self.element = AXUIElementCreateApplication(runningApplication.processIdentifier)
            self.title = runningApplication.localizedName ?? self.title
            return
        }
        
        self.pid = nil
        self.element = nil
    }
    
    private static func defaultOpenConfiguration(activates: Bool = true) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        return configuration
    }
    
}


enum ApplicationError: Error {
    case noBundleURL
    case openFailed
}
