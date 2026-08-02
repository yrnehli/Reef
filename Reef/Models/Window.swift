//
//  Window.swift
//  Reef
//
//  Created by Xander Gouws on 12-09-2025.
//

import Foundation
import Cocoa


class Window: Identifiable {
    var id: CGWindowID { cgWindowID ?? 0 }
    /// Present for current-Space windows; may be nil for other-Space windows until focus/close resolves it.
    private(set) var element: AXUIElement?
    var cgWindowID: CGWindowID?
    private var cgTitle: String?
    var application: Application

    init(_ element: AXUIElement, _ application: Application) {
        self.element = element
        self.cgWindowID = element.getWindowID()
        self.application = application
    }

    /// Other-Space (or otherwise AX-unavailable) window discovered via CGWindowList.
    init(cgWindowID: CGWindowID, cgTitle: String?, application: Application) {
        self.element = nil
        self.cgWindowID = cgWindowID
        self.cgTitle = cgTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.application = application
    }
    
    var title: String {
        if let title = axTitle, !title.isEmpty {
            return title
        }
        if let cgTitle, !cgTitle.isEmpty {
            return cgTitle
        }
        
        return application.title
    }

    /// Accessibility title with whitespace trimmed. `nil` means the attribute was missing.
    private var axTitle: String? {
        guard let element,
              let title: String = element.getAttributeValue(.title)
        else {
            return nil
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this window is useful for user-facing window switching.
    /// Drops Chrome fullscreen phantoms and other non-standard untitled AX windows.
    var isUserSwitchable: Bool {
        // CG-only other-Space windows: already filtered to normal layer-0 windows.
        guard let element else {
            return true
        }

        if let role: String = element.getAttributeValue(.role),
           role != NSAccessibility.Role.window.rawValue {
            return false
        }

        if let subrole: String = element.getAttributeValue(.subrole),
           !subrole.isEmpty,
           subrole != NSAccessibility.Subrole.standardWindow.rawValue,
           subrole != NSAccessibility.Subrole.dialog.rawValue {
            return false
        }

        // Present-but-empty titles are typically phantom windows (e.g. Chrome
        // YouTube fullscreen). Missing titles still count via the app-name fallback.
        if let axTitle, axTitle.isEmpty {
            return false
        }

        return true
    }
    
    func focus() {
        if resolveElementIfNeeded() == nil {
            // Fall back to activating the app (macOS will usually switch Space).
            application.activate()
            return
        }

        guard let element else {
            application.activate()
            return
        }

        do {
            try element.performAction(.raise)
            application.activate()
        } catch {
            try? application.reopen()
        }
    }
    
    @discardableResult
    func close() -> Bool {
        guard resolveElementIfNeeded() != nil,
              let element,
              let closeButton: AXUIElement = element.getAttributeValue(.closeButton)
        else {
            return false
        }
        
        do {
            try closeButton.performAction(.press)
            return true
        } catch {
            return false
        }
    }

    /// Lazily resolve an AX element for other-Space windows (expensive; only on focus/close).
    @discardableResult
    private func resolveElementIfNeeded() -> AXUIElement? {
        if let element {
            return element
        }

        guard let cgWindowID,
              let pid = application.pid
        else {
            return nil
        }

        let resolved = AXUIElement.windowsByBruteForce(
            pid: pid,
            targetWindowIDs: [cgWindowID],
            budgetMilliseconds: 250
        )
        if let axWindow = resolved[cgWindowID] {
            element = axWindow
            return axWindow
        }

        return nil
    }
    
    static func getFrontWindow() -> Window? {
        guard let frontApplication = Application.getFrontApplication() else {
            return nil
        }
        
        if let focusedWindow = frontApplication.getFocusedWindow() {
            return focusedWindow
        }
        
        if let firstWindow = frontApplication.getFirstWindow() {
            return firstWindow
        }
        
        return nil
    }
}
