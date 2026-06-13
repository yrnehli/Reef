//
//  MenuBarLabel.swift
//  Reef
//
//  The dynamic menu-bar label showing `profile | app` (e.g. `1 | 3`).
//  A dash is shown for either part when it has no number.
//

import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var profileManager: ProfileManager
    @ObservedObject var tracker: FrontmostAppTracker

    private var profileStr: String {
        profileManager.currentProfile?.profileNumber.map(String.init) ?? "-"
    }

    private var appStr: String {
        tracker.frontmostSlot.map(String.init) ?? "-"
    }

    var body: some View {
        Text("\(profileStr) | \(appStr)")
            .monospacedDigit()
    }
}
