//
//  MenuBarLabelTests.swift
//  ReefTests
//
//  The menu-bar label shows the current profile's name and number, e.g.
//  "Coding (1)" — or just the name when no number is assigned.
//

import Testing
@testable import Reef

struct MenuBarLabelTests {
    @Test func profileWithNumber_showsNameAndNumber() {
        let profile = Profile(name: "Coding", profileNumber: 1)
        #expect(MenuBarLabel.labelText(for: profile) == "Coding (1)")
    }

    @Test func profileWithoutNumber_showsNameOnly() {
        let profile = Profile(name: "Coding", profileNumber: nil)
        #expect(MenuBarLabel.labelText(for: profile) == "Coding")
    }

    @Test func noProfile_isEmpty() {
        #expect(MenuBarLabel.labelText(for: nil) == "")
    }
}
