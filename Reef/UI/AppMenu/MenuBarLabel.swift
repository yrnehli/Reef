//
//  MenuBarLabel.swift
//  Reef
//
//  The menu-bar label: the Reef glyph followed by the current profile's
//  name and number (e.g. "Coding (1)"), or just the name when the profile
//  has no number assigned.
//

import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var profileManager: ProfileManager

    static func labelText(for profile: Profile?) -> String {
        guard let profile else { return "" }
        if let number = profile.profileNumber {
            return "\(profile.name) (\(number))"
        }
        return profile.name
    }

    private var text: String {
        Self.labelText(for: profileManager.currentProfile)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image("menu_placeholder")
                .renderingMode(.template)
            if !text.isEmpty {
                Text(text)
            }
        }
    }
}
