//
//  CyclePanel.swift
//  Reef
//
//  Created by Xander Gouws on 19-01-2026.
//

import AppKit
import SwiftUI

enum SwitcherAppearance: String {
    case light
    case dark
    case system

    static var preference: SwitcherAppearance {
        let raw = UserDefaults.standard.string(forKey: "appearance") ?? SwitcherAppearance.system.rawValue
        return SwitcherAppearance(rawValue: raw) ?? .system
    }

    var resolvesDark: Bool {
        switch self {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
}

final class CyclePanel: NSPanel, NSWindowDelegate {
    /// Called when the panel resigns key (and orders out). Used to clear switcher state/monitors.
    var onDidResignKey: (() -> Void)?

    private let effectView = NSVisualEffectView(frame: .zero)
    private let tintView = NSView(frame: .zero)

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior.insert(.fullScreenAuxiliary)
        self.collectionBehavior.insert(.canJoinAllSpaces)
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.delegate = self
        self.backgroundColor = .clear
        self.hidesOnDeactivate = true
        self.acceptsMouseMovedEvents = true
        self.ignoresMouseEvents = false
        
        effectView.autoresizingMask = [.width, .height]
        effectView.blendingMode = .behindWindow
        effectView.state = .active

        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true

        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        effectView.addSubview(tintView)
        NSLayoutConstraint.activate([
            tintView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: effectView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])

        applyChrome(isDark: true)
        self.contentView = effectView
    }

    func applyChrome(isDark: Bool) {
        // HUD material is the frosted glass. The tint is only a light wash so the blur stays visible.
        effectView.material = .hudWindow
        effectView.appearance = NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
        let tint = isDark ? NSColor.black : NSColor.white
        tintView.layer?.backgroundColor = tint.withAlphaComponent(0.28).cgColor
    }
    
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
    
    func windowDidResignKey(_ notification: Notification) {
        self.orderOut(nil)
        onDidResignKey?()
    }
}
