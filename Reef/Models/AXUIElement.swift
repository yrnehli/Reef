//
//  AXUIElement.swift
//  Reef
//
//  Created by Xander Gouws on 16-09-2025.
//

import Foundation
import Cocoa


// Adds Swift wrappers around the accessibility object class.
extension AXUIElement {
    func getAttributeValue<T>(_ attribute: NSAccessibility.Attribute) -> T? {
        var value: AnyObject?
        
        let result = AXUIElementCopyAttributeValue(self, attribute.rawValue as CFString, &value)
        
        guard result == .success else {
            return nil
        }
        
        return value as? T
    }
    
    func performAction(_ action: NSAccessibility.Action) throws(AXError) {
        let result = AXUIElementPerformAction(self, action.rawValue as CFString)
        
        guard result == .success else {
            throw result
        }
    }
    
    func getWindowID() -> CGWindowID? {
        var windowID = CGWindowID(0)
        
        let result = _AXUIElementGetWindow(self, &windowID)
        
        guard result == .success else {
            return nil
        }
        
        return windowID
    }
    
    func test() -> Int? {
        return self.getAttributeValue(.identifier)
    }
}


// Make AXError conform to Error protocol
extension AXError: @retroactive _BridgedNSError {}
extension AXError: @retroactive _ObjectiveCBridgeableError {}
extension AXError: @retroactive Error {}


// Private Core Accessibility API
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Creates an AXUIElement from a remote token. Used to reach windows that are not
/// exposed via `kAXWindowsAttribute` (notably windows on other Spaces).
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

extension AXUIElement {
    /// Resolve AX elements for specific `CGWindowID`s that are missing from the
    /// app's current-Space `kAXWindows` list (other Spaces / inactive tabs).
    /// Scans AX element IDs via `_AXUIElementCreateWithRemoteToken` until all
    /// targets are found or `budgetMilliseconds` elapses.
    static func windowsByBruteForce(
        pid: pid_t,
        targetWindowIDs: Set<CGWindowID>,
        budgetMilliseconds: Double = 300
    ) -> [CGWindowID: AXUIElement] {
        var found: [CGWindowID: AXUIElement] = [:]
        guard !targetWindowIDs.isEmpty else { return found }

        // Token layout (20 bytes), matching AltTab / WindowServer conventions:
        // pid (4) + 0 (4) + magic 0x636f636f "coco" (4) + AXUIElementID (8)
        var remoteToken = Data(count: 20)
        remoteToken.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        remoteToken.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        remoteToken.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })

        let started = ContinuousClock.now
        var elementID: UInt64 = 0

        while found.count < targetWindowIDs.count {
            remoteToken.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })

            if let candidate = _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?.takeRetainedValue(),
               let windowID = candidate.getWindowID(),
               targetWindowIDs.contains(windowID),
               found[windowID] == nil {
                found[windowID] = candidate
            }

            let elapsed = ContinuousClock.now - started
            if elapsed >= .milliseconds(budgetMilliseconds) {
                break
            }

            if elementID == UInt64.max {
                break
            }
            elementID &+= 1
        }

        return found
    }
}
