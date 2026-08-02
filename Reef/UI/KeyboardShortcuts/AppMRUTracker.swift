//
//  AppMRUTracker.swift
//  Reef
//
//  Tracks most-recently-used application order for the ⌘Tab app switcher.
//

import AppKit

@MainActor
final class AppMRUTracker {
    private(set) var orderedBundleIDs: [String] = []
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }

        seedFromRunningApplications()

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier
            else {
                return
            }

            Task { @MainActor in
                self?.recordActivation(bundleIdentifier: bundleID)
            }
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    func recordActivation(bundleIdentifier: String) {
        orderedBundleIDs.removeAll { $0 == bundleIdentifier }
        orderedBundleIDs.insert(bundleIdentifier, at: 0)
    }

    private func seedFromRunningApplications() {
        var seen = Set<String>()
        var seeded: [String] = []

        if let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            seeded.append(frontID)
            seen.insert(frontID)
        }

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  !seen.contains(bundleID)
            else {
                continue
            }
            seeded.append(bundleID)
            seen.insert(bundleID)
        }

        orderedBundleIDs = seeded
    }
}
