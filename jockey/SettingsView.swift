import AppKit
import LaunchAtLogin
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var manager: SMBShareManager
    @State private var editedShare: ShareConfiguration?
    @State private var isAddingShare = false
    @State private var pendingRemoval: ShareConfiguration?
    @State private var pendingReset = false
    @State private var lastAuthFailureShareID: UUID?

    var body: some View {
        Group {
            if manager.shouldPresentOnboarding {
                FirstRunSetupView(
                    onCreate: { share, password in
                        try manager.saveShare(share, password: password)
                        manager.markOnboardingComplete()
                    },
                    onSkip: {
                        manager.markOnboardingComplete()
                    }
                )
                .frame(minWidth: 720, minHeight: 520)
            } else {
                TabView {
                    sharesView
                        .tabItem {
                            Label("Shares", systemImage: "externaldrive.connected.to.line.below")
                        }

                    LogsView()
                        .tabItem {
                            Label("Logs", systemImage: "doc.text")
                        }

                    generalView
                        .tabItem {
                            Label("General", systemImage: "gear")
                        }
                }
                .frame(minWidth: 720, minHeight: 480)
                .sheet(item: $editedShare) { share in
                    ShareEditorView(
                        share: share,
                        hasStoredPassword: manager.passwordExists(for: share)
                    ) { updated, password in
                        try manager.saveShare(updated, password: password)
                    }
                }
                .sheet(isPresented: $isAddingShare) {
                    ShareEditorView(
                        share: ShareConfiguration(
                            name: "",
                            host: "",
                            shareName: "",
                            username: "",
                            mountPoint: ShareConfiguration.defaultShare(
                                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
                            ).mountPoint,
                            isEnabled: true,
                            mountMethod: .smbfs
                        ),
                        hasStoredPassword: false
                    ) { share, password in
                        try manager.saveShare(share, password: password)
                    }
                }
                .onChange(of: manager.states) { _ in
                    promptForAuthenticationFixIfNeeded()
                }
                .onAppear {
                    promptForAuthenticationFixIfNeeded()
                }
            }
        }
    }

    private var sharesView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Network Shares")
                        .font(.title2.bold())
                    Text("Mounts begin only after the configured SMB endpoint is reachable.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isAddingShare = true
                } label: {
                    Label("Add Share", systemImage: "plus")
                }
            }
            .padding()

            Divider()

            if manager.shares.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No Shares")
                        .font(.title2.bold())
                    Text("Add an SMB share to begin.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(manager.shares) { share in
                        ShareSettingsRow(
                            share: share,
                            state: manager.state(for: share),
                            hasPassword: manager.passwordExists(for: share),
                            mount: { manager.mount(share) },
                            unmount: { manager.unmount(share) },
                            open: { manager.openInFinder(share) },
                            edit: { editedShare = share },
                            forgetPassword: { manager.forgetPassword(for: share) },
                            toggle: { manager.setEnabled(!share.isEnabled, for: share) },
                            togglePause: { manager.setAutoMountPaused(!share.isAutoMountPaused, for: share) },
                            remove: { pendingRemoval = share }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .alert(item: $pendingRemoval) { share in
            Alert(
                title: Text("Remove \(share.name)?"),
                message: Text("This deletes the share configuration. The stored Keychain password remains unless you forget it separately."),
                primaryButton: .destructive(Text("Remove")) {
                    manager.removeShare(share)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var generalView: some View {
        Form {
            Section("Startup") {
                LaunchAtLogin.Toggle("Launch MountJockey at login")
                Text("MountJockey stays in the menu bar and reacts to network and wake events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connectivity") {
                Text("MountJockey probes DNS and TCP port 445 on each SMB host. This works over Tailscale, WireGuard, OpenVPN, ordinary LANs, and other routed networks.")
            }

            Section("Diagnostics") {
                Button("Open Log File") {
                    manager.openLog()
                }
                Text(AppLogger.shared.logURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            Section("Reset") {
                Button("Reset Saved Configuration…", role: .destructive) {
                    pendingReset = true
                }
                Text("Clears saved shares, stored passwords, and onboarding state. Use this if a previous install left stale settings behind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Reset saved configuration?", isPresented: $pendingReset) {
            Button("Reset", role: .destructive) {
                manager.resetSavedConfiguration()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved SMB shares and stored passwords from this app.")
        }
    }

    private func promptForAuthenticationFixIfNeeded() {
        guard editedShare == nil else { return }

        let failingShare = manager.shares.first { share in
            guard case let .failed(message) = manager.state(for: share) else {
                return false
            }
            return message.localizedCaseInsensitiveContains("SMB_AUTH_REJECTED")
                || message.localizedCaseInsensitiveContains("SMB_PERMISSION_DENIED")
                || message.localizedCaseInsensitiveContains("SMB_ACCESS_DENIED")
                || message.localizedCaseInsensitiveContains("SMB_KEYCHAIN_PASSWORD_MISSING")
        }

        guard let failingShare else { return }
        guard lastAuthFailureShareID != failingShare.id else { return }

        lastAuthFailureShareID = failingShare.id
        editedShare = failingShare
    }
}

private struct FirstRunSetupView: View {
    @State private var share = ShareConfiguration(
        name: "My Share",
        host: "",
        shareName: "",
        username: "",
        mountPoint: ShareConfiguration.defaultShare(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        ).mountPoint,
        isEnabled: true,
        mountMethod: .smbfs
    )
    @State private var password = ""
    @State private var errorMessage: String?

    let onCreate: (ShareConfiguration, String?) throws -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add your SMB share")
                        .font(.largeTitle.bold())
                    Text("Enter the server details once. MountJockey stores the password only in your login Keychain and mounts automatically after the host becomes reachable.")
                        .foregroundStyle(.secondary)
                    Text("Backend choice is per-share. mount_smbfs is recommended; NetFS is still available.")
                        .foregroundStyle(.secondary)
                    Text("Recommended mount point: \(share.mountPoint)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("A password is required for a new share.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.top, .horizontal])

            Divider()

            Form {
                TextField("Display name", text: $share.name)
                TextField("Host", text: $share.host)
                TextField("Share", text: $share.shareName)
                TextField("Username", text: $share.username)
                    .textContentType(.username)
                Picker("Mount method", selection: $share.mountMethod) {
                    ForEach(SMBMountMethod.allCases, id: \.self) { method in
                        Text("\(method.displayName) — \(method.detail)").tag(method)
                    }
                }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Text("Password is saved in your login Keychain and reused automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Mount point", text: $share.mountPoint)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Skip for now") {
                    onSkip()
                }

                Spacer()

                Button("Create Share") {
                    do {
                        try onCreate(share, password.isEmpty ? nil : password)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    share.host.trimmingCharacters(in: .whitespaces).isEmpty ||
                    share.shareName.trimmingCharacters(in: .whitespaces).isEmpty ||
                    share.username.trimmingCharacters(in: .whitespaces).isEmpty ||
                    share.mountPoint.trimmingCharacters(in: .whitespaces).isEmpty ||
                    password.isEmpty
                )
            }
            .padding()
        }
    }
}

private struct ShareSettingsRow: View {
    let share: ShareConfiguration
    let state: ShareRuntimeState
    let hasPassword: Bool
    let mount: () -> Void
    let unmount: () -> Void
    let open: () -> Void
    let edit: () -> Void
    let forgetPassword: () -> Void
    let toggle: () -> Void
    let togglePause: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.symbolName)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(share.name)
                        .font(.headline)
                    Text(share.mountMethod.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !share.isEnabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if share.isAutoMountPaused {
                        Text("Auto-mount paused")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !hasPassword {
                        Label("Password required", systemImage: "key.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("smb://\(share.host)/\(share.shareName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(share.normalizedMountPoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Mount method: \(share.mountMethod.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(state.label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                Button("Mount Now", action: mount)
                    .disabled(state == .mounted || !share.isEnabled)
                Button("Unmount", action: unmount)
                    .disabled(state != .mounted)
                Button(share.isAutoMountPaused ? "Resume Auto-Mount" : "Pause Auto-Mount", action: togglePause)
                Button("Open in Finder", action: open)
                    .disabled(state != .mounted)
                Divider()
                Button("Edit…", action: edit)
                Button("Forget Password", role: .destructive, action: forgetPassword)
                    .disabled(!hasPassword)
                Button(share.isEnabled ? "Disable" : "Enable", action: toggle)
                Button("Remove", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch state {
        case .mounted: return .green
        case .failed: return .red
        case .waitingForNetwork, .mounting, .unmounting: return .orange
        case .disabled, .unmounted, .paused: return .secondary
        }
    }
}

private struct ShareEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var share: ShareConfiguration
    @State private var password = ""
    @State private var errorMessage: String?
    let hasStoredPassword: Bool
    let onSave: (ShareConfiguration, String?) throws -> Void

    init(
        share: ShareConfiguration,
        hasStoredPassword: Bool,
        onSave: @escaping (ShareConfiguration, String?) throws -> Void
    ) {
        _share = State(initialValue: share)
        self.hasStoredPassword = hasStoredPassword
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Display name", text: $share.name)
                TextField("Host", text: $share.host)
                TextField("Share", text: $share.shareName)
                TextField("Username", text: $share.username)
                    .textContentType(.username)
                Picker("Mount method", selection: $share.mountMethod) {
                    ForEach(SMBMountMethod.allCases, id: \.self) { method in
                        Text("\(method.displayName) — \(method.detail)").tag(method)
                    }
                }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Text(hasStoredPassword
                    ? "Leave this blank to keep the existing Keychain password."
                    : "Enter a password now to save it in Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Mount point", text: $share.mountPoint)
                Toggle("Automatically mount", isOn: $share.isEnabled)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                Text("Passwords are stored only in your macOS login Keychain. Leave the password blank when editing to keep the existing credential.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    do {
                        if !hasStoredPassword && password.isEmpty {
                            throw MountJockeyError.credentialMissing
                        }
                        try onSave(share, password.isEmpty ? nil : password)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    share.host.trimmingCharacters(in: .whitespaces).isEmpty ||
                    share.shareName.trimmingCharacters(in: .whitespaces).isEmpty ||
                    share.mountPoint.trimmingCharacters(in: .whitespaces).isEmpty ||
                    (!hasStoredPassword && password.isEmpty)
                )
            }
            .padding()
        }
        .frame(width: 520, height: 500)
    }
}
