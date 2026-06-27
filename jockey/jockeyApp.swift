import AppKit
import SwiftUI

@main
struct MountJockeyApp: App {
    @StateObject private var shareManager = SMBShareManager()
    @StateObject private var preferencesWindow = PreferencesWindowPresenter()

    var body: some Scene {
        MenuBarExtra("MountJockey", systemImage: menuBarSymbol) {
            MenuBarContentView(
                shareManager: shareManager,
                preferencesWindow: preferencesWindow
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(shareManager)
        }
    }

    private var menuBarSymbol: String {
        if shareManager.shares.contains(where: {
            if case .failed = shareManager.state(for: $0) { return true }
            return false
        }) {
            return "externaldrive.badge.exclamationmark"
        }
        if shareManager.shares.contains(where: {
            shareManager.state(for: $0) == .mounted
        }) {
            return "externaldrive.fill.badge.checkmark"
        }
        return "externaldrive.badge.wifi"
    }
}

private struct MenuBarContentView: View {
    @State private var didRequestInitialSetup = false
    let shareManager: SMBShareManager
    let preferencesWindow: PreferencesWindowPresenter

    var body: some View {
        Text("MountJockey")
            .font(.headline)

        Divider()

        if shareManager.shares.isEmpty {
            Text("No shares configured")
        } else {
            ForEach(shareManager.shares) { share in
                Menu {
                    Button("Mount Now") {
                        shareManager.mount(share)
                    }
                    .disabled(
                        shareManager.state(for: share) == .mounted ||
                        !share.isEnabled
                    )

                    Button("Unmount") {
                        shareManager.unmount(share)
                    }
                    .disabled(shareManager.state(for: share) != .mounted)

                    Button(share.isAutoMountPaused ? "Resume Auto-Mount" : "Pause Auto-Mount") {
                        shareManager.setAutoMountPaused(!share.isAutoMountPaused, for: share)
                    }

                    Button("Open in Finder") {
                        shareManager.openInFinder(share)
                    }
                    .disabled(shareManager.state(for: share) != .mounted)

                    Divider()

                    Button(share.isEnabled ? "Disable" : "Enable") {
                        shareManager.setEnabled(!share.isEnabled, for: share)
                    }
                } label: {
                    Label(
                        "\(share.name) — \(shareManager.state(for: share).label)",
                        systemImage: shareManager.state(for: share).symbolName
                    )
                }
            }
        }

        Divider()

        Button("Mount All") {
            shareManager.mountAll()
        }

        Button("Preferences…") {
            preferencesWindow.show(shareManager: shareManager)
        }
        .keyboardShortcut(",")

        Button("View Log") {
            shareManager.openLog()
        }

        Divider()

        Button("Quit MountJockey") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        .task {
            guard shareManager.shouldPresentOnboarding, !didRequestInitialSetup else { return }
            didRequestInitialSetup = true
            preferencesWindow.show(shareManager: shareManager)
        }
    }
}

@MainActor
final class PreferencesWindowPresenter: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(shareManager: SMBShareManager) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = SettingsView().environmentObject(shareManager)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Preferences"
        window.setContentSize(NSSize(width: 900, height: 650))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.contentMinSize = NSSize(width: 720, height: 480)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
