//
//  ReefApp.swift
//  Reef
//
//  Created by Xander Gouws on 12-09-2025.
//

import SwiftUI
import KeyboardShortcuts
import ServiceManagement

@main
struct ReefApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var profileManager: ProfileManager
    @StateObject private var sparkleConnector = SparkleConnector()
    @AppStorage("launchOnLogin") private var launchOnLogin = true

    init() {
        let profileManager = ProfileManager()
        _profileManager = StateObject(wrappedValue: profileManager)
        AppDelegate.profileManager = profileManager
        
        // Sync launch at login state with system
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            _launchOnLogin = AppStorage(wrappedValue: status == .enabled, "launchOnLogin")
        }
    }

    var body: some Scene {
        Settings {
            PreferencesView()
                .environmentObject(profileManager)
                .environmentObject(sparkleConnector)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(profileManager)
                .environmentObject(sparkleConnector)
        } label: {
            MenuBarLabel(profileManager: profileManager)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var instance: AppDelegate!
    static var profileManager: ProfileManager!
    static private(set) var modifierManager: ModifierManager!
    
    private var cycleController: CyclePanelController!
    private var shortcutManager: ShortcutController!
    private var windowManager: PreferencesController!
    private var mruTracker: AppMRUTracker!
    private var commandTabInterceptor: CommandTabInterceptor!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        AppDelegate.modifierManager = ModifierManager(profileManager: AppDelegate.profileManager)

        mruTracker = AppMRUTracker()
        mruTracker.start()

        cycleController = CyclePanelController(
            modifierManager: AppDelegate.modifierManager,
            mruTracker: mruTracker
        )
        shortcutManager = ShortcutController(cycleController, AppDelegate.profileManager)
        windowManager = PreferencesController()
        commandTabInterceptor = CommandTabInterceptor()

        cycleController.appSwitcherVisibilityDidChange = { [weak self] visible in
            self?.commandTabInterceptor.isAppSwitcherVisible = visible
        }

        AppDelegate.modifierManager.appSwitcherEnabledDidChange = { [weak self] enabled in
            self?.updateCommandTabInterceptor(enabled: enabled)
        }
        if AppDelegate.modifierManager.appSwitcherEnabled {
            updateCommandTabInterceptor(enabled: true)
        }
        
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        commandTabInterceptor?.stop()
        mruTracker?.stop()
        AppDelegate.profileManager.saveNow()
    }

    private func updateCommandTabInterceptor(enabled: Bool) {
        if enabled {
            commandTabInterceptor.start(cycleController: cycleController)
        } else {
            commandTabInterceptor.stop()
        }
    }
}
