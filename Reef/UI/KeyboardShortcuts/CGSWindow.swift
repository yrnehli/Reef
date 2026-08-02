//
//  CGSWindow.swift
//  Reef
//
//  Private SkyLight helpers for window metadata (titles without Screen Recording).
//

import Foundation
import CoreGraphics

enum CGSWindow {
    private typealias MainConnectionFn = @convention(c) () -> UInt32
    private typealias CopyWindowPropertyFn = @convention(c) (
        UInt32,
        CGWindowID,
        CFString,
        UnsafeMutablePointer<Unmanaged<CFTypeRef>?>
    ) -> Int32

    private static let skyLight: (mainConnection: MainConnectionFn, copyProperty: CopyWindowPropertyFn)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else {
            return nil
        }
        guard
            let mainConnectionSymbol = dlsym(handle, "CGSMainConnectionID"),
            let copyPropertySymbol = dlsym(handle, "CGSCopyWindowProperty")
        else {
            return nil
        }
        return (
            unsafeBitCast(mainConnectionSymbol, to: MainConnectionFn.self),
            unsafeBitCast(copyPropertySymbol, to: CopyWindowPropertyFn.self)
        )
    }()

    /// Window title from WindowServer. Works for other apps without Screen Recording,
    /// unlike `kCGWindowName` from `CGWindowListCopyWindowInfo`.
    static func title(for windowID: CGWindowID) -> String? {
        guard let skyLight else { return nil }

        var value: Unmanaged<CFTypeRef>?
        let result = skyLight.copyProperty(
            skyLight.mainConnection(),
            windowID,
            "kCGSWindowTitle" as CFString,
            &value
        )
        guard result == 0, let value else {
            return nil
        }

        let title = (value.takeRetainedValue() as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else {
            return nil
        }
        return title
    }
}
