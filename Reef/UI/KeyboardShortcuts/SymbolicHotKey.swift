//
//  SymbolicHotKey.swift
//  Reef
//
//  Private SkyLight shim to enable/disable the Dock's ⌘Tab / ⌘⇧Tab switcher.
//

import Foundation

enum SymbolicHotKey {
    private typealias SetEnabledFn = @convention(c) (Int32, Bool) -> Int32

    /// Enables or disables the system application switcher (⌘Tab / ⌘⇧Tab).
    /// Resolved via `dlsym` so a missing symbol fails soft instead of crashing.
    static func setNativeCommandTabEnabled(_ enabled: Bool) {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else {
            print("Reef: SkyLight.framework unavailable; cannot toggle native ⌘Tab")
            return
        }

        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") else {
            print("Reef: CGSSetSymbolicHotKeyEnabled unavailable; cannot toggle native ⌘Tab")
            return
        }

        let setEnabled = unsafeBitCast(symbol, to: SetEnabledFn.self)
        // Symbolic hotkey IDs used by AltTab and similar tools:
        // 1 = move focus to next application (⌘Tab)
        // 2 = move focus to previous application (⌘⇧Tab)
        _ = setEnabled(1, enabled)
        _ = setEnabled(2, enabled)
    }
}
