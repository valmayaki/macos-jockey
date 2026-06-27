import AppKit
import Combine
import Foundation
import Network

enum ShareRuntimeState: Equatable {
    case disabled
    case unmounted
    case paused
    case waitingForNetwork
    case mounting
    case mounted
    case unmounting
    case failed(String)

    var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .unmounted: return "Unmounted"
        case .paused: return "Paused"
        case .waitingForNetwork: return "Waiting for network"
        case .mounting: return "Mounting"
        case .mounted: return "Mounted"
        case .unmounting: return "Unmounting"
        case .failed: return "Error"
        }
    }

    var symbolName: String {
        switch self {
        case .disabled: return "pause.circle"
        case .unmounted: return "externaldrive.badge.minus"
        case .paused: return "pause.circle.fill"
        case .waitingForNetwork: return "network"
        case .mounting: return "arrow.triangle.2.circlepath"
        case .mounted: return "externaldrive.fill.badge.checkmark"
        case .unmounting: return "eject"
        case .failed: return "externaldrive.badge.exclamationmark"
        }
    }
}

@MainActor
final class SMBShareManager: NSObject, ObservableObject {
    @Published private(set) var shares: [ShareConfiguration] = []
    @Published private(set) var states: [UUID: ShareRuntimeState] = [:]
    @Published private(set) var logs: [AppLogEntry] = []

    private let credentialStore: CredentialStoring
    private let endpointChecker: EndpointChecking
    private let smbfsMounter: ShareMounting
    private let netfsMounter: ShareMounting
    private let defaults: UserDefaults
    private let saveKey = "mountJockeyShares"
    private let legacyDefaultMigrationKey = "mountJockeyMigratedLegacyDefaultShare"
    private let onboardingCompleteKey = "mountJockeyOnboardingComplete"
    private let retryInterval: TimeInterval = 60
    private let reachabilityTimeout: TimeInterval = 120

    private var networkMonitor: NWPathMonitor?
    private var retryTimer: Timer?
    private var scheduledMountAllTask: Task<Void, Never>?
    private var operations: [UUID: Task<Void, Never>] = [:]

    init(
        credentialStore: CredentialStoring = KeychainCredentialStore.shared,
        endpointChecker: EndpointChecking = SMBEndpointChecker(),
        smbfsMounter: ShareMounting = SmbfsShareMounter(),
        netfsMounter: ShareMounting = NetFSShareMounter(),
        defaults: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.endpointChecker = endpointChecker
        self.smbfsMounter = smbfsMounter
        self.netfsMounter = netfsMounter
        self.defaults = defaults
        super.init()
        loadShares()
        refreshMountStates()
        startMonitoring()
        appendLog("MountJockey started.")
    }

    deinit {
        networkMonitor?.cancel()
        retryTimer?.invalidate()
        scheduledMountAllTask?.cancel()
        operations.values.forEach { $0.cancel() }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func state(for share: ShareConfiguration) -> ShareRuntimeState {
        if let state = states[share.id] {
            return state
        }
        if !share.isEnabled {
            return .disabled
        }
        return share.isAutoMountPaused ? .paused : .unmounted
    }

    func passwordExists(for share: ShareConfiguration) -> Bool {
        (try? credentialStore.containsPassword(for: share)) == true
    }

    func saveShare(_ share: ShareConfiguration, password: String?) throws {
        try persistShare(share, password: password, autoMountIfNeeded: true)
    }

    func removeShare(_ share: ShareConfiguration, removeCredential: Bool = false) {
        operations[share.id]?.cancel()
        operations[share.id] = nil
        if MountTable.current().isMounted(host: share.host, share: share.shareName, at: share.normalizedMountPoint) {
            try? mounter(for: share).unmount(share)
        }
        if removeCredential {
            try? credentialStore.deletePassword(for: share)
        }
        shares.removeAll { $0.id == share.id }
        states[share.id] = nil
        saveShares()
        appendLog("Removed \(share.name).")
    }

    func forgetPassword(for share: ShareConfiguration) {
        do {
            try credentialStore.deletePassword(for: share)
            appendLog("Forgot password for \(share.name).")
        } catch {
            appendLog("Failed forgetting password for \(share.name): \(formattedErrorMessage(error))", level: .error)
        }
    }

    func resetSavedConfiguration(removeCredentials: Bool = true) {
        operations.values.forEach { $0.cancel() }
        operations.removeAll()

        for share in shares {
            if MountTable.current().isMounted(host: share.host, share: share.shareName, at: share.normalizedMountPoint) {
                try? mounter(for: share).unmount(share)
            }
            if removeCredentials {
                try? credentialStore.deletePassword(for: share)
            }
        }

        shares = []
        states.removeAll()
        defaults.removeObject(forKey: saveKey)
        defaults.removeObject(forKey: onboardingCompleteKey)
        defaults.removeObject(forKey: legacyDefaultMigrationKey)
        appendLog("Reset saved configuration.")
    }

    func setEnabled(_ enabled: Bool, for share: ShareConfiguration) {
        guard var updated = shares.first(where: { $0.id == share.id }) else { return }
        updated.isEnabled = enabled
        if !enabled {
            operations[share.id]?.cancel()
            operations[share.id] = nil
        }
        try? persistShare(updated, password: nil, autoMountIfNeeded: true)
    }

    func setAutoMountPaused(_ paused: Bool, for share: ShareConfiguration) {
        guard var updated = shares.first(where: { $0.id == share.id }) else { return }
        updated.isAutoMountPaused = paused
        try? persistShare(updated, password: nil, autoMountIfNeeded: !paused)
    }

    func mountAll() {
        refreshMountStates()
        for share in shares where share.isEnabled && !share.isAutoMountPaused && state(for: share) != .mounted {
            mount(share)
        }
    }

    func mount(_ share: ShareConfiguration) {
        guard var currentShare = shares.first(where: { $0.id == share.id }) else { return }
        guard currentShare.isEnabled, operations[currentShare.id] == nil else { return }

        if currentShare.isAutoMountPaused {
            currentShare.isAutoMountPaused = false
            do {
                try persistShare(currentShare, password: nil, autoMountIfNeeded: false)
            } catch {
                let message = formattedErrorMessage(error)
                states[currentShare.id] = .failed(message)
                appendLog("Failed resuming \(currentShare.name): \(message)", level: .error)
                return
            }
        }

        guard !MountTable.current().isMounted(
            host: currentShare.host,
            share: currentShare.shareName,
            at: currentShare.normalizedMountPoint
        ) else {
            states[currentShare.id] = .mounted
            return
        }

        states[currentShare.id] = .waitingForNetwork
        appendLog("Waiting for SMB endpoint \(currentShare.host):445 for \(currentShare.name).")

        operations[currentShare.id] = Task { [weak self] in
            guard let self else { return }
            defer { operations[currentShare.id] = nil }

            let deadline = Date().addingTimeInterval(reachabilityTimeout)
            var reachable = false
            while !Task.isCancelled && Date() < deadline {
                if await endpointChecker.isReachable(
                    host: currentShare.host,
                    port: 445,
                    timeout: 5
                ) {
                    reachable = true
                    break
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            guard !Task.isCancelled else { return }
            guard reachable else {
                let error = MountJockeyError.mountTimedOut
                states[currentShare.id] = .failed(error.reportedMessage)
                appendLog("Timed out waiting for \(currentShare.host):445. \(error.reportedMessage)", level: .warning)
                return
            }

            states[currentShare.id] = .mounting
            appendLog("SMB endpoint is reachable; mounting \(currentShare.name) (\(mountContext(currentShare))).")

            do {
                guard let password = try credentialStore.password(for: currentShare), !password.isEmpty else {
                    throw MountJockeyError.credentialMissing
                }
                let selectedMounter = mounter(for: currentShare)
                try await Task.detached(priority: .utility) {
                    try selectedMounter.mount(currentShare, password: password)
                }.value
                states[currentShare.id] = .mounted
                appendLog("Mounted \(currentShare.name) at \(currentShare.normalizedMountPoint).")
            } catch {
                let message = formattedErrorMessage(error)
                states[currentShare.id] = .failed(message)
                appendLog("Failed mounting \(currentShare.name): \(message)", level: .error)
                if isAuthenticationFailure(error) {
                    appendLog(
                        "Authentication rejected for \(mountContext(currentShare)). Check the share name and password, then save again if needed.",
                        level: .warning
                    )
                }
            }
        }
    }

    func unmount(_ share: ShareConfiguration) {
        guard operations[share.id] == nil else { return }
        setAutoMountPaused(true, for: share)
        states[share.id] = .unmounting
        operations[share.id] = Task { [weak self] in
            guard let self else { return }
            defer { operations[share.id] = nil }

            do {
                let selectedMounter = mounter(for: share)
                try await Task.detached(priority: .utility) {
                    try selectedMounter.unmount(share)
                }.value
                states[share.id] = share.isEnabled ? .paused : .disabled
                appendLog("Unmounted \(share.name).")
            } catch {
                let message = formattedErrorMessage(error)
                states[share.id] = .failed(message)
                appendLog("Failed unmounting \(share.name): \(message)", level: .error)
            }
        }
    }

    func openInFinder(_ share: ShareConfiguration) {
        NSWorkspace.shared.open(URL(fileURLWithPath: share.normalizedMountPoint))
    }

    func openLog() {
        NSWorkspace.shared.open(AppLogger.shared.logURL)
    }

    var shouldPresentOnboarding: Bool {
        shares.isEmpty && defaults.bool(forKey: onboardingCompleteKey) == false
    }

    func markOnboardingComplete() {
        defaults.set(true, forKey: onboardingCompleteKey)
    }

    func refreshMountStates() {
        let table = MountTable.current()
        for share in shares {
            if table.isMounted(
                host: share.host,
                share: share.shareName,
                at: share.normalizedMountPoint
            ) {
                states[share.id] = .mounted
            } else if operations[share.id] == nil {
                if !share.isEnabled {
                    states[share.id] = .disabled
                } else if share.isAutoMountPaused {
                    states[share.id] = .paused
                } else {
                    states[share.id] = .unmounted
                }
            }
        }
    }

    private func loadShares() {
        guard
            let data = defaults.data(forKey: saveKey),
            let decoded = try? JSONDecoder().decode([ShareConfiguration].self, from: data),
            (try? ShareConfiguration.validate(decoded)) != nil
        else {
            shares = []
            saveShares()
            return
        }

        let migratedShares = decoded.filter { !ShareConfiguration.isLegacyDefaultShare($0) }
        if migratedShares.count != decoded.count {
            shares = migratedShares
            defaults.set(true, forKey: legacyDefaultMigrationKey)
            saveShares()
            appendLog("Removed legacy default NAS configuration; add your own SMB share in Preferences.")
            return
        }

        shares = decoded
    }

    private func persistShare(
        _ share: ShareConfiguration,
        password: String?,
        autoMountIfNeeded: Bool
    ) throws {
        let previousShare = shares.first(where: { $0.id == share.id })
        let savedShares = try sortedShares(replacing: share)
        let shouldReplaceMountedShare = previousShare?.mountedShareSignature != share.mountedShareSignature
            && previousShare.map {
                MountTable.current().isMounted(
                    host: $0.host,
                    share: $0.shareName,
                    at: $0.normalizedMountPoint
                )
            } == true

        if let password, !password.isEmpty {
            try credentialStore.save(password: password, for: share)
        }

        if let previousShare, previousShare.mountSignature != share.mountSignature {
            operations[previousShare.id]?.cancel()
            operations[previousShare.id] = nil
        }

        shares = savedShares
        saveShares()
        if MountTable.current().isMounted(
            host: share.host,
            share: share.shareName,
            at: share.normalizedMountPoint
        ) {
            states[share.id] = .mounted
        } else {
            states[share.id] = share.isEnabled ? (share.isAutoMountPaused ? .paused : .unmounted) : .disabled
        }
        appendLog("Saved configuration for \(share.name).")

        if let previousShare, shouldReplaceMountedShare {
            scheduleConfigurationReplacement(previousShare, with: share)
            return
        }

        if autoMountIfNeeded, share.isEnabled, !share.isAutoMountPaused {
            mount(share)
        }
    }

    private func scheduleConfigurationReplacement(
        _ previousShare: ShareConfiguration,
        with updatedShare: ShareConfiguration
    ) {
        states[updatedShare.id] = .unmounting
        appendLog("Configuration changed for mounted share \(updatedShare.name); replacing previous mount asynchronously.")
        Task { [weak self] in
            do {
                let selectedMounter = await self?.mounter(for: previousShare)
                try await Task.detached(priority: .utility) {
                    try selectedMounter?.unmount(previousShare)
                }.value
                await MainActor.run {
                    self?.states[updatedShare.id] = .unmounted
                    if updatedShare.isEnabled, !updatedShare.isAutoMountPaused {
                        self?.mount(updatedShare)
                    }
                }
            } catch {
                await MainActor.run {
                    let message = self?.formattedErrorMessage(error) ?? error.localizedDescription
                    self?.states[updatedShare.id] = .failed(message)
                    self?.appendLog(
                        "Failed replacing previous configuration for \(updatedShare.name): \(message)",
                        level: .error
                    )
                }
            }
        }
    }

    private func mounter(for share: ShareConfiguration) -> ShareMounting {
        switch share.mountMethod {
        case .smbfs:
            return smbfsMounter
        case .netfs:
            return netfsMounter
        }
    }

    private func sortedShares(replacing share: ShareConfiguration) throws -> [ShareConfiguration] {
        var updated = shares
        if let index = updated.firstIndex(where: { $0.id == share.id }) {
            updated[index] = share
        } else {
            updated.append(share)
        }
        try ShareConfiguration.validate(updated)
        return updated.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func saveShares() {
        guard let data = try? JSONEncoder().encode(shares) else { return }
        defaults.set(data, forKey: saveKey)
    }

    private func formattedErrorMessage(_ error: Error) -> String {
        if let mountError = error as? MountJockeyError {
            return mountError.reportedMessage
        }
        return "[SMB_UNKNOWN_ERROR] \(error.localizedDescription)"
    }

    private func mountContext(_ share: ShareConfiguration) -> String {
        "\(share.username)@\(share.host)/\(share.shareName) -> \(share.normalizedMountPoint)"
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        guard case let MountJockeyError.mountFailed(status) = error else { return false }
        return status == Int32(EPERM) || status == Int32(EACCES)
    }

    private func startMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                self?.scheduleMountAll(reason: "Network path changed", delay: 5)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.valmayaki.mountjockey.network"))
        networkMonitor = monitor

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeDidUnmount),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )

        retryTimer = Timer.scheduledTimer(
            withTimeInterval: retryInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleMountAll(reason: "Retry timer fired", delay: 0)
            }
        }

        Task { @MainActor in
            mountAll()
        }
    }

    @objc private func didWake() {
        scheduleMountAll(reason: "Mac woke from sleep", delay: 10)
    }

    @objc private func volumeDidUnmount() {
        refreshMountStates()
        scheduleMountAll(reason: "Volume unmounted", delay: 3)
    }

    private func scheduleMountAll(reason: String, delay: TimeInterval) {
        scheduledMountAllTask?.cancel()
        appendLog("\(reason); checking configured shares\(delay > 0 ? " after debounce." : ".")")
        scheduledMountAllTask = Task { [weak self] in
            guard delay > 0 else {
                await MainActor.run {
                    self?.mountAll()
                    self?.scheduledMountAllTask = nil
                }
                return
            }

            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.mountAll()
                self?.scheduledMountAllTask = nil
            }
        }
    }

    private func appendLog(_ message: String, level: LogLevel = .info) {
        let entry = AppLogEntry(level: level, message: message)
        logs.append(entry)
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
        AppLogger.shared.write(message, level: level)
    }
}
