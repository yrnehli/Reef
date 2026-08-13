//
//  CyclePanelState.swift
//  Reef
//
//  Created by Xander Gouws on 23-01-2026.
//

import Foundation

enum CyclePanelAction {
    case launchApp
    case openWindow
    
    var title: String {
        switch self {
        case .launchApp:
            return "Launch app"
        case .openWindow:
            return "Focus app"
        }
    }
}

enum CyclePanelItem {
    case window(Window)
    case action(CyclePanelAction)
    case app(Application)
}

enum CyclePanelMode {
    case windows
    case apps
}

@MainActor
final class CyclePanelState: ObservableObject {
    @Published var applicationTitle: String = ""
    @Published var items: [CyclePanelItem] = []
    @Published var selectedIndex: Int = 0
    @Published var mode: CyclePanelMode = .windows
    /// Bumped only by keyboard cycling so the list can scroll without fighting hover selection.
    @Published private(set) var keyboardSelectionGeneration: UInt = 0
    
    var windows: [Window] {
        items.compactMap { item in
            if case let .window(window) = item {
                return window
            }
            
            return nil
        }
    }
    
    var currentItem: CyclePanelItem? {
        guard !items.isEmpty, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }
    
    var currentWindow: Window? {
        guard let currentItem else { return nil }
        
        if case let .window(window) = currentItem {
            return window
        }
        
        return nil
    }
    
    var currentAction: CyclePanelAction? {
        guard let currentItem else { return nil }
        
        if case let .action(action) = currentItem {
            return action
        }
        
        return nil
    }

    var currentApp: Application? {
        guard let currentItem else { return nil }

        if case let .app(application) = currentItem {
            return application
        }

        return nil
    }
    
    func setApplication(_ application: Application) {
        mode = .windows
        applicationTitle = application.title
        
        let windows = application.getWindows()
        if windows.isEmpty {
            let action: CyclePanelAction = application.isRunning ? .openWindow : .launchApp
            items = [.action(action)]
        } else {
            items = windows.map(CyclePanelItem.window)
        }
        
        selectedIndex = 0
    }

    func setApps(_ apps: [Application]) {
        mode = .apps
        applicationTitle = "Apps"
        items = apps.map(CyclePanelItem.app)
        selectedIndex = 0
    }
    
    func cycleNext() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
        keyboardSelectionGeneration &+= 1
    }

    func cyclePrevious() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        keyboardSelectionGeneration &+= 1
    }

    func selectIndex(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }
    
    func removeCurrentWindow() {
        guard case .window = currentItem else { return }
        removeCurrentItem()
    }

    func removeCurrentItem() {
        guard !items.isEmpty, selectedIndex < items.count else { return }
        items.remove(at: selectedIndex)
        if items.isEmpty {
            selectedIndex = 0
        } else if selectedIndex >= items.count {
            selectedIndex = items.count - 1
        }
    }
    
    func reset() {
        items = []
        selectedIndex = 0
        applicationTitle = ""
        mode = .windows
    }
}
