//
//  ModifierManager.swift
//  Reef
//
//  Created by Xander Gouws on 30-01-2026.
//

import SwiftUI
import Combine
import KeyboardShortcuts

@MainActor
final class ModifierManager: ObservableObject {
    @AppStorage("bindEnabled") private var bindEnabledStored = true
    @AppStorage("bindControl") var bindControl = true {
        didSet { updateShortcuts() }
    }
    @AppStorage("bindOption") var bindOption = true {
        didSet { updateShortcuts() }
    }
    @AppStorage("bindCommand") var bindCommand = false {
        didSet { updateShortcuts() }
    }
    @AppStorage("bindShift") var bindShift = true {
        didSet { updateShortcuts() }
    }
    
    @AppStorage("activateEnabled") private var activateEnabledStored = true
    @AppStorage("activateControl") var activateControl = true {
        didSet { updateShortcuts() }
    }
    @AppStorage("activateOption") var activateOption = false {
        didSet { updateShortcuts() }
    }
    @AppStorage("activateCommand") var activateCommand = false {
        didSet { updateShortcuts() }
    }
    @AppStorage("activateShift") var activateShift = false {
        didSet { updateShortcuts() }
    }
    
    @AppStorage("cycleCurrentAppEnabled") var cycleCurrentAppEnabled = false {
        didSet { updateShortcuts() }
    }

    @AppStorage("profileEnabled") private var profileEnabledStored = true
    @AppStorage("profileControl") var profileControl = true {
        didSet { updateShortcuts() }
    }
    @AppStorage("profileOption") var profileOption = true {
        didSet { updateShortcuts() }
    }
    @AppStorage("profileCommand") var profileCommand = false {
        didSet { updateShortcuts() }
    }
    @AppStorage("profileShift") var profileShift = false {
        didSet { updateShortcuts() }
    }

    var bindEnabled: Bool { !bindModifiers.isEmpty }
    var activateEnabled: Bool { !activateModifiers.isEmpty }
    var profileEnabled: Bool { !profileModifiers.isEmpty }

    private weak var profileManager: ProfileManager?
    private var cancellables: Set<AnyCancellable> = []

    init(profileManager: ProfileManager? = nil) {
        self.profileManager = profileManager

        // Re-register hotkeys whenever bindings or profile-number assignments
        // change (bind/unbind, Preferences edits, profile switches) so that only
        // meaningful numbers hijack their global hotkey. Dispatched async so the
        // published change is committed before we read the updated state.
        if let profileManager {
            Publishers.Merge(
                profileManager.$profiles.map { _ in () },
                profileManager.$currentProfileID.map { _ in () }
            )
            .sink { [weak self] in
                Task { @MainActor in
                    self?.updateShortcuts()
                }
            }
            .store(in: &cancellables)
        }

        // Initialize shortcuts with saved modifiers on first launch
        updateShortcuts()
    }
    
    var bindModifiers: NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        if bindControl { modifiers.insert(.control) }
        if bindOption { modifiers.insert(.option) }
        if bindCommand { modifiers.insert(.command) }
        if bindShift { modifiers.insert(.shift) }
        return modifiers
    }
    
    var activateModifiers: NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        if activateControl { modifiers.insert(.control) }
        if activateOption { modifiers.insert(.option) }
        if activateCommand { modifiers.insert(.command) }
        if activateShift { modifiers.insert(.shift) }
        return modifiers
    }
    
    var profileModifiers: NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        if profileControl { modifiers.insert(.control) }
        if profileOption { modifiers.insert(.option) }
        if profileCommand { modifiers.insert(.command) }
        if profileShift { modifiers.insert(.shift) }
        return modifiers
    }
    
    var activateEventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if activateControl { modifiers.insert(.control) }
        if activateOption { modifiers.insert(.option) }
        if activateCommand { modifiers.insert(.command) }
        if activateShift { modifiers.insert(.shift) }
        return modifiers
    }
    
    var profileEventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if profileControl { modifiers.insert(.control) }
        if profileOption { modifiers.insert(.option) }
        if profileCommand { modifiers.insert(.command) }
        if profileShift { modifiers.insert(.shift) }
        return modifiers
    }
    
    var activateModifierSymbols: String {
        var symbols = ""
        if activateControl  { symbols += "⌃ " }
        if activateOption   { symbols += "⌥ " }
        if activateShift    { symbols += "⇧ " }
        if activateCommand  { symbols += "⌘ " }
        return symbols
    }

    var profileModifierSymbols: String {
        var symbols = ""
        if profileControl  { symbols += "⌃ " }
        if profileOption   { symbols += "⌥ " }
        if profileShift    { symbols += "⇧ " }
        if profileCommand  { symbols += "⌘ " }
        return symbols
    }

    func resetToDefaults() {
        activateControl = true
        activateOption = false
        activateShift = false
        activateCommand = false

        profileControl = true
        profileOption = true
        profileShift = false
        profileCommand = false

        bindControl = true
        bindOption = true
        bindShift = true
        bindCommand = false
    }
    
    private func updateShortcuts() {
        let bindMods = bindModifiers
        let activateMods = activateModifiers
        let profileMods = profileModifiers
        let bindIsEnabled = !bindMods.isEmpty
        let activateIsEnabled = !activateMods.isEmpty
        let profileIsEnabled = !profileMods.isEmpty

        bindEnabledStored = bindIsEnabled
        activateEnabledStored = activateIsEnabled
        profileEnabledStored = profileIsEnabled

        let bindings = profileManager?.currentProfile?.bindings ?? []

        for number in 0...9 {
            // Bind hotkeys stay live for every number so an empty slot can still
            // be assigned an app.
            setNumberShortcut(number, enabled: bindIsEnabled, modifiers: bindMods,
                              mainName: .bindShortcuts[number], keypadName: .bindKeypadShortcuts[number])

            // Only hijack activate/profile hotkeys for numbers that actually do
            // something; otherwise let the keystroke fall through to the OS.
            let hasBinding = number < bindings.count && bindings[number] != nil
            let hasProfile = profileManager?.profileID(forNumber: number) != nil

            setNumberShortcut(number, enabled: activateIsEnabled && hasBinding, modifiers: activateMods,
                              mainName: .activateShortcuts[number], keypadName: .activateKeypadShortcuts[number])

            setNumberShortcut(number, enabled: profileIsEnabled && hasProfile, modifiers: profileMods,
                              mainName: .profileShortcuts[number], keypadName: .profileKeypadShortcuts[number])
        }

        KeyboardShortcuts.setShortcut(
            (cycleCurrentAppEnabled && activateIsEnabled) ? .init(.tab, modifiers: activateMods) : nil,
            for: .cycleCurrentApp
        )
    }

    /// Registers a number shortcut on both the main-row key and its numeric-keypad
    /// equivalent so the shortcut fires regardless of which key the user presses.
    private func setNumberShortcut(
        _ number: Int,
        enabled: Bool,
        modifiers: NSEvent.ModifierFlags,
        mainName: KeyboardShortcuts.Name,
        keypadName: KeyboardShortcuts.Name
    ) {
        KeyboardShortcuts.setShortcut(
            enabled ? .init(numberKeys[number], modifiers: modifiers) : nil,
            for: mainName
        )
        KeyboardShortcuts.setShortcut(
            enabled ? .init(keypadKeys[number], modifiers: modifiers) : nil,
            for: keypadName
        )
    }
}
