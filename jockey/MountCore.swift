import Foundation
import CryptoKit
import Network
import Security
import Darwin
import NetFS

enum MountJockeyError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case credentialMissing
    case endpointUnavailable
    case mountTimedOut
    case mountVerificationFailed
    case mountFailed(Int32)
    case unmountFailed(Int32)
    case staleMountBusy(String)

    var code: String {
        switch self {
        case .invalidConfiguration:
            return "SMB_INVALID_CONFIGURATION"
        case .credentialMissing:
            return "SMB_KEYCHAIN_PASSWORD_MISSING"
        case .endpointUnavailable:
            return "SMB_ENDPOINT_UNREACHABLE"
        case .mountTimedOut:
            return "SMB_MOUNT_TIMED_OUT"
        case .mountVerificationFailed:
            return "SMB_MOUNT_VERIFICATION_FAILED"
        case .mountFailed(let status):
            return Self.mountFailureCodeCode(for: status)
        case .unmountFailed(let status):
            return "SMB_UNMOUNT_FAILED_\(status)"
        case .staleMountBusy:
            return "SMB_STALE_MOUNT_BUSY"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .credentialMissing:
            return "No password is stored in Keychain for this share."
        case .endpointUnavailable:
            return "The SMB endpoint is not reachable."
        case .mountTimedOut:
            return "macOS did not finish mounting the SMB share within the timeout."
        case .mountVerificationFailed:
            return "macOS reported success, but the SMB share did not appear in the mount table."
        case .mountFailed(let status):
            return Self.mountFailureDescription(for: status)
        case .unmountFailed(let status):
            return "macOS could not unmount the share (status \(status))."
        case .staleMountBusy(let mountPoint):
            return "The mount at \(mountPoint) appears stale, but another process is still using it."
        }
    }

    var reportedMessage: String {
        "[\(code)] \(errorDescription ?? "Unknown error")"
    }

    private static func mountFailureDescription(for status: Int32) -> String {
        switch status {
        case Int32(EPERM):
            return "The SMB server rejected the username, password, or share permissions."
        case Int32(ENOENT):
            return "The SMB share or path was not found on the server."
        case Int32(EACCES):
            return "The SMB server rejected the username, password, or share permissions."
        case Int32(ECONNREFUSED):
            return "The SMB connection was refused."
        case Int32(ETIMEDOUT):
            return "The SMB connection timed out."
        default:
            return "macOS could not mount the share (status \(status))."
        }
    }

    private enum MountFailureCode: String {
        case authRejected = "SMB_AUTH_REJECTED"
        case shareNotFound = "SMB_SHARE_NOT_FOUND"
        case connectionRefused = "SMB_CONNECTION_REFUSED"
        case connectionTimedOut = "SMB_CONNECTION_TIMED_OUT"
    }

    private static func mountFailureCodeCode(for status: Int32) -> String {
        switch status {
        case Int32(EPERM):
            return MountFailureCode.authRejected.rawValue
        case Int32(ENOENT):
            return MountFailureCode.shareNotFound.rawValue
        case Int32(EACCES):
            return MountFailureCode.authRejected.rawValue
        case Int32(ECONNREFUSED):
            return MountFailureCode.connectionRefused.rawValue
        case Int32(ETIMEDOUT):
            return MountFailureCode.connectionTimedOut.rawValue
        default:
            return "SMB_MOUNT_STATUS_\(status)"
        }
    }
}

enum SMBMountMethod: String, Codable, CaseIterable, Sendable {
    case smbfs
    case netfs

    var displayName: String {
        switch self {
        case .smbfs:
            return "mount_smbfs"
        case .netfs:
            return "NetFS"
        }
    }

    var detail: String {
        switch self {
        case .smbfs:
            return "Recommended"
        case .netfs:
            return "Legacy"
        }
    }
}

struct ShareConfiguration: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var shareName: String
    var username: String
    var mountPoint: String
    var isEnabled: Bool
    var isAutoMountPaused: Bool
    var mountMethod: SMBMountMethod

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        shareName: String,
        username: String,
        mountPoint: String,
        isEnabled: Bool,
        isAutoMountPaused: Bool = false,
        mountMethod: SMBMountMethod = .smbfs
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.shareName = shareName
        self.username = username
        self.mountPoint = mountPoint
        self.isEnabled = isEnabled
        self.isAutoMountPaused = isAutoMountPaused
        self.mountMethod = mountMethod
    }

    static func defaultShare(homeDirectory: String = NSHomeDirectory()) -> ShareConfiguration {
        ShareConfiguration(
            name: "NAS Data",
            host: "nas.taila7f773.ts.net",
            shareName: "data",
            username: "ubani",
            mountPoint: URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent("Volumes/data")
                .path,
            isEnabled: true,
            isAutoMountPaused: false,
            mountMethod: .smbfs
        )
    }

    static func isLegacyDefaultShare(_ share: ShareConfiguration) -> Bool {
        let defaultShare = defaultShare()
        return share.host == defaultShare.host
            && share.shareName == defaultShare.shareName
            && share.username == defaultShare.username
    }

    static func validate(_ shares: [ShareConfiguration]) throws {
        var identifiers = Set<UUID>()
        var mountPoints = Set<String>()

        for share in shares {
            guard identifiers.insert(share.id).inserted else {
                throw MountJockeyError.invalidConfiguration("Share identifiers must be unique.")
            }

            let host = share.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let shareName = share.shareName.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawMountPoint = share.mountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let mountPoint = standardizedPath(rawMountPoint)

            guard !host.isEmpty, !shareName.isEmpty, !rawMountPoint.isEmpty, !mountPoint.isEmpty else {
                throw MountJockeyError.invalidConfiguration(
                    "Host, share name, and mount point are required."
                )
            }
            guard rawMountPoint.hasPrefix("/") || rawMountPoint.hasPrefix("~") else {
                throw MountJockeyError.invalidConfiguration(
                    "Mount point must be an absolute path."
                )
            }
            guard mountPoint != "/" else {
                throw MountJockeyError.invalidConfiguration("The root filesystem cannot be used as a mount point.")
            }
            guard mountPoint != "/Volumes" else {
                throw MountJockeyError.invalidConfiguration("Use a subdirectory under /Volumes, not /Volumes itself.")
            }
            guard !isDangerousSystemPath(mountPoint) else {
                throw MountJockeyError.invalidConfiguration(
                    "Use a user-owned mount point such as ~/Volumes/data or /Volumes/data."
                )
            }
            guard !host.contains("/") && !host.contains("@") else {
                throw MountJockeyError.invalidConfiguration("Host contains invalid characters.")
            }
            guard !shareName.contains("/") else {
                throw MountJockeyError.invalidConfiguration(
                    "Nested SMB paths are not supported; enter the share name only."
                )
            }
            try validateMountPointSafety(mountPoint)
            guard mountPoints.insert(mountPoint).inserted else {
                throw MountJockeyError.invalidConfiguration(
                    "Each share must use a unique mount point."
                )
            }
        }
    }

    func smbURL() throws -> URL {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.path = "/" + shareName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = components.url else {
            throw MountJockeyError.invalidConfiguration("The SMB URL is invalid.")
        }
        return url
    }

    var normalizedMountPoint: String {
        Self.standardizedPath(mountPoint)
    }

    var mountSignature: String {
        [
            host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            shareName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            normalizedMountPoint,
            mountMethod.rawValue
        ].joined(separator: "\u{0}")
    }

    var mountedShareSignature: String {
        [
            host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            shareName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            normalizedMountPoint
        ].joined(separator: "\u{0}")
    }

    var credentialIdentity: String {
        [
            host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            shareName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "\u{0}")
    }

    var credentialAccount: String {
        let identity = [
            host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            shareName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "v2:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func standardizedPath(_ path: String) -> String {
        let expanded: String
        if path == "~" {
            expanded = NSHomeDirectory()
        } else if path.hasPrefix("~/") {
            expanded = NSHomeDirectory() + String(path.dropFirst())
        } else {
            expanded = path
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func isDangerousSystemPath(_ path: String) -> Bool {
        let forbiddenPrefixes = [
            "/Applications",
            "/Library",
            "/System",
            "/bin",
            "/private",
            "/sbin",
            "/usr",
            "/opt"
        ]

        return forbiddenPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func validateMountPointSafety(_ mountPoint: String) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: mountPoint, isDirectory: &isDirectory)
        if exists {
            guard isDirectory.boolValue else {
                throw MountJockeyError.invalidConfiguration("The mount point must be a directory.")
            }

            if let attributes = try? fileManager.attributesOfItem(atPath: mountPoint),
               let fileType = attributes[.type] as? FileAttributeType,
               fileType == .typeSymbolicLink {
                throw MountJockeyError.invalidConfiguration("The mount point cannot be a symbolic link.")
            }

            if MountTable.current().hasSMBMount(at: mountPoint) {
                return
            }

            if let contents = try? fileManager.contentsOfDirectory(atPath: mountPoint), !contents.isEmpty {
                throw MountJockeyError.invalidConfiguration("The mount point directory must be empty.")
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, shareName, username, mountPoint, isEnabled, isAutoMountPaused, mountMethod
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        shareName = try container.decode(String.self, forKey: .shareName)
        username = try container.decode(String.self, forKey: .username)
        mountPoint = try container.decode(String.self, forKey: .mountPoint)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        isAutoMountPaused = try container.decodeIfPresent(Bool.self, forKey: .isAutoMountPaused) ?? false
        mountMethod = try container.decodeIfPresent(SMBMountMethod.self, forKey: .mountMethod) ?? .smbfs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(shareName, forKey: .shareName)
        try container.encode(username, forKey: .username)
        try container.encode(mountPoint, forKey: .mountPoint)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isAutoMountPaused, forKey: .isAutoMountPaused)
        try container.encode(mountMethod, forKey: .mountMethod)
    }
}

struct MountTable: Sendable {
    private struct Entry: Sendable {
        let source: String
        let mountPoint: String
    }

    private let entries: [Entry]

    init(output: String) {
        entries = output.split(separator: "\n").compactMap { line in
            let value = String(line)
            guard value.contains("(smbfs"), let separator = value.range(of: " on ") else {
                return nil
            }
            let source = String(value[..<separator.lowerBound])
            let suffix = value[separator.upperBound...]
            let mountPoint = suffix.components(separatedBy: " (").first ?? String(suffix)
            return Entry(source: source, mountPoint: mountPoint)
        }
    }

    func isMounted(host: String, share: String, at mountPoint: String) -> Bool {
        let expectedMountPoint = URL(fileURLWithPath: mountPoint).standardizedFileURL.path
        let rawExpectedSource = "//\(host.lowercased())/\(share)"
        let expectedSource = (rawExpectedSource.removingPercentEncoding ?? rawExpectedSource)
            .lowercased()

        return entries.contains { entry in
            let decodedSource = (entry.source.removingPercentEncoding ?? entry.source).lowercased()
            let decodedMountPoint = entry.mountPoint.removingPercentEncoding ?? entry.mountPoint
            let normalizedMountPoint = URL(fileURLWithPath: decodedMountPoint)
                .standardizedFileURL.path

            let sourceWithoutUser: String
            if let atIndex = decodedSource.firstIndex(of: "@") {
                sourceWithoutUser = "//" + decodedSource[decodedSource.index(after: atIndex)...]
            } else {
                sourceWithoutUser = decodedSource
            }

            return sourceWithoutUser == expectedSource && normalizedMountPoint == expectedMountPoint
        }
    }

    func hasSMBMount(at mountPoint: String) -> Bool {
        let expectedMountPoint = URL(fileURLWithPath: mountPoint).standardizedFileURL.path
        return entries.contains { entry in
            let decodedMountPoint = entry.mountPoint.removingPercentEncoding ?? entry.mountPoint
            let normalizedMountPoint = URL(fileURLWithPath: decodedMountPoint)
                .standardizedFileURL.path
            return normalizedMountPoint == expectedMountPoint
        }
    }

    static func current() -> MountTable {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return MountTable(output: String(data: data, encoding: .utf8) ?? "")
        } catch {
            return MountTable(output: "")
        }
    }
}

enum MountPointHealth: Equatable {
    case unmounted
    case healthy
    case stale
    case otherSMBMount
}

enum MountPointInspector {
    static func health(for share: ShareConfiguration, table: MountTable = .current()) -> MountPointHealth {
        let mountPoint = share.normalizedMountPoint
        if table.isMounted(host: share.host, share: share.shareName, at: mountPoint) {
            return isAccessible(mountPoint) ? .healthy : .stale
        }
        if table.hasSMBMount(at: mountPoint) {
            return .otherSMBMount
        }
        return .unmounted
    }

    static func isAccessible(_ mountPoint: String) -> Bool {
        runProcess(
            executable: "/usr/bin/stat",
            arguments: ["-f", "%N", mountPoint],
            timeout: 5
        ) == 0
    }

    static func isBusy(_ mountPoint: String) -> Bool {
        runProcess(
            executable: "/usr/sbin/lsof",
            arguments: ["+f", "--", mountPoint],
            timeout: 5
        ) == 0
    }

    @discardableResult
    static func unmount(_ mountPoint: String, force: Bool = false) -> Int32 {
        runProcess(
            executable: "/usr/sbin/diskutil",
            arguments: force ? ["unmount", "force", mountPoint] : ["unmount", mountPoint],
            timeout: 15
        ) ?? Int32(EIO)
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return nil
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        return process.terminationStatus
    }
}

protocol CredentialStoring: Sendable {
    func save(password: String, for share: ShareConfiguration) throws
    func password(for share: ShareConfiguration) throws -> String?
    func containsPassword(for share: ShareConfiguration) throws -> Bool
    func deletePassword(for share: ShareConfiguration) throws
}

final class KeychainCredentialStore: CredentialStoring, @unchecked Sendable {
    static let shared = KeychainCredentialStore()
    private let service = "com.valmayaki.mountjockey.smb"
    private let legacyService = "com.valmayaki.mountjockey.smb.legacy"

    private func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func queries(for share: ShareConfiguration) -> [String] {
        let stable = share.credentialAccount
        let legacy = share.id.uuidString
        return stable == legacy ? [stable] : [stable, legacy]
    }

    func save(password: String, for share: ShareConfiguration) throws {
        let stableAccount = share.credentialAccount
        let legacyAccount = share.id.uuidString
        var lookup = query(for: stableAccount)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }

        attributes.forEach { lookup[$0.key] = $0.value }
        let addStatus = SecItemAdd(lookup as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }

        if stableAccount != legacyAccount {
            var legacyLookup = query(for: legacyAccount)
            attributes.forEach { legacyLookup[$0.key] = $0.value }
            let legacyStatus = SecItemUpdate(query(for: legacyAccount) as CFDictionary, attributes as CFDictionary)
            if legacyStatus != errSecSuccess && legacyStatus != errSecItemNotFound {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(legacyStatus))
            }
            if legacyStatus == errSecItemNotFound {
                let addLegacyStatus = SecItemAdd(legacyLookup as CFDictionary, nil)
                guard addLegacyStatus == errSecSuccess else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(addLegacyStatus))
                }
            }
        }

        if !legacyService.isEmpty {
            let legacyIdentityQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: stableAccount
            ]
            _ = SecItemDelete(legacyIdentityQuery as CFDictionary)
        }
    }

    func password(for share: ShareConfiguration) throws -> String? {
        for account in queries(for: share) {
            var lookup = query(for: account)
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            if status == errSecItemNotFound {
                continue
            }
            guard status == errSecSuccess, let data = result as? Data else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            let password = String(data: data, encoding: .utf8)
            if account == share.id.uuidString, let password {
                try? save(password: password, for: share)
            }
            return password
        }
        return nil
    }

    func containsPassword(for share: ShareConfiguration) throws -> Bool {
        for account in queries(for: share) {
            var lookup = query(for: account)
            lookup[kSecReturnAttributes as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            if status == errSecItemNotFound {
                continue
            }
            guard status == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return result != nil
        }
        return false
    }

    func deletePassword(for share: ShareConfiguration) throws {
        for account in queries(for: share) {
            let status = SecItemDelete(query(for: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
    }
}

protocol EndpointChecking: Sendable {
    func isReachable(host: String, port: UInt16, timeout: TimeInterval) async -> Bool
}

struct SMBEndpointChecker: EndpointChecking {
    func isReachable(host: String, port: UInt16 = 445, timeout: TimeInterval) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.valmayaki.mountjockey.endpoint-check")
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: endpointPort,
                using: .tcp
            )
            let completion = EndpointCheckCompletion(
                connection: connection,
                continuation: continuation
            )

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(true)
                case .failed, .cancelled:
                    completion.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                completion.finish(false)
            }
        }
    }
}

private final class EndpointCheckCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Bool, Never>?

    init(
        connection: NWConnection,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        connection.cancel()
        continuation.resume(returning: result)
    }
}

protocol ShareMounting: Sendable {
    func mount(_ share: ShareConfiguration, password: String) throws
    func unmount(_ share: ShareConfiguration) throws
}

struct NetFSShareMounter: ShareMounting {
    func mount(_ share: ShareConfiguration, password: String) throws {
        let mountPoint = share.normalizedMountPoint
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        switch MountPointInspector.health(for: share) {
        case .healthy:
            return
        case .stale:
            try recoverStaleMount(at: mountPoint)
        case .otherSMBMount:
            throw MountJockeyError.mountFailed(Int32(EBUSY))
        case .unmounted:
            break
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var outcome: Result<Void, Error>?

        DispatchQueue.global(qos: .utility).async {
            defer { semaphore.signal() }
            do {
                let url = try share.smbURL() as CFURL
                let mountURL = URL(fileURLWithPath: mountPoint, isDirectory: true) as CFURL
                let openOptions = NSMutableDictionary(dictionary: [
                    kNAUIOptionKey as String: kNAUIOptionNoUI,
                    kNetFSForceNewSessionKey as String: true
                ])
                let mountOptions = NSMutableDictionary(dictionary: [
                    kNetFSSoftMountKey as String: true,
                    kNetFSMountAtMountDirKey as String: true
                ])
                let userName = NSString(string: share.username)
                let secret = NSString(string: password)
                var mountPoints: Unmanaged<CFArray>?

                let status = NetFSMountURLSync(
                    url,
                    mountURL,
                    userName,
                    secret,
                    openOptions,
                    mountOptions,
                    &mountPoints
                )
                mountPoints?.release()

                guard status == 0 else {
                    throw MountJockeyError.mountFailed(status)
                }
                lock.lock()
                outcome = .success(())
                lock.unlock()
            } catch {
                lock.lock()
                outcome = .failure(error)
                lock.unlock()
            }
        }

        guard semaphore.wait(timeout: .now() + 45) == .success else {
            throw MountJockeyError.mountTimedOut
        }

        lock.lock()
        let result = outcome
        lock.unlock()

        switch result {
        case .success:
            break
        case .failure(let error):
            throw error
        case .none:
            throw MountJockeyError.mountVerificationFailed
        }

        guard MountTable.current().isMounted(
            host: share.host,
            share: share.shareName,
            at: share.normalizedMountPoint
        ) else {
            throw MountJockeyError.mountVerificationFailed
        }
    }

    func unmount(_ share: ShareConfiguration) throws {
        let status = MountPointInspector.unmount(share.normalizedMountPoint)
        guard status == 0 else {
            throw MountJockeyError.unmountFailed(status)
        }
    }

    private func recoverStaleMount(at mountPoint: String) throws {
        guard !MountPointInspector.isBusy(mountPoint) else {
            throw MountJockeyError.staleMountBusy(mountPoint)
        }

        let status = MountPointInspector.unmount(mountPoint)
        if status == 0 {
            return
        }

        let forceStatus = MountPointInspector.unmount(mountPoint, force: true)
        guard forceStatus == 0 else {
            throw MountJockeyError.unmountFailed(forceStatus)
        }
    }
}

struct SmbfsShareMounter: ShareMounting {
    func mount(_ share: ShareConfiguration, password: String) throws {
        let mountPoint = share.normalizedMountPoint
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        switch MountPointInspector.health(for: share) {
        case .healthy:
            return
        case .stale:
            try recoverStaleMount(at: mountPoint)
        case .otherSMBMount:
            throw MountJockeyError.mountFailed(Int32(EBUSY))
        case .unmounted:
            break
        }

        try mountWithInteractiveSMBFS(
            share: share,
            password: password,
            mountPoint: mountPoint
        )

        guard MountTable.current().isMounted(
            host: share.host,
            share: share.shareName,
            at: share.normalizedMountPoint
        ) else {
            throw MountJockeyError.mountVerificationFailed
        }
    }

    func unmount(_ share: ShareConfiguration) throws {
        let status = MountPointInspector.unmount(share.normalizedMountPoint)
        guard status == 0 else {
            throw MountJockeyError.unmountFailed(status)
        }
    }

    private func recoverStaleMount(at mountPoint: String) throws {
        guard !MountPointInspector.isBusy(mountPoint) else {
            throw MountJockeyError.staleMountBusy(mountPoint)
        }

        let status = MountPointInspector.unmount(mountPoint)
        if status == 0 {
            return
        }

        let forceStatus = MountPointInspector.unmount(mountPoint, force: true)
        guard forceStatus == 0 else {
            throw MountJockeyError.unmountFailed(forceStatus)
        }
    }

    private func mountWithInteractiveSMBFS(
        share: ShareConfiguration,
        password: String,
        mountPoint: String
    ) throws {
        var controlFD: Int32 = -1
        let pid = forkpty(&controlFD, nil, nil, nil)
        guard pid >= 0 else {
            throw MountJockeyError.mountFailed(Int32(errno))
        }

        if pid == 0 {
            let remote = smbfsRemotePath(for: share)
            let argv: [UnsafeMutablePointer<CChar>?] = [
                strdup("/sbin/mount_smbfs"),
                strdup("-s"),
                strdup("-o"),
                strdup("soft,nobrowse"),
                strdup(remote),
                strdup(mountPoint),
                nil
            ]
            execv("/sbin/mount_smbfs", argv)
            _exit(127)
        }

        defer { close(controlFD) }
        guard fcntl(controlFD, F_SETFL, O_NONBLOCK) != -1 else {
            kill(pid, SIGKILL)
            _ = waitForChild(pid)
            throw MountJockeyError.mountFailed(Int32(errno))
        }

        var output = Data()
        var passwordSent = false
        let start = ProcessInfo.processInfo.systemUptime
        let timeout: TimeInterval = 45

        while true {
            if ProcessInfo.processInfo.systemUptime - start > timeout {
                kill(pid, SIGTERM)
                _ = waitForChild(pid)
                throw MountJockeyError.mountTimedOut
            }

            if !passwordSent, outputContainsPasswordPrompt(output) {
                try writePassword(password, to: controlFD)
                passwordSent = true
            }

            var status: Int32 = 0
            let exited = waitpid(pid, &status, WNOHANG)
            if exited == pid {
                let outputText = String(decoding: output, as: UTF8.self)
                if status == 0 {
                    return
                }
                throw classifyMountFailure(
                    exitCode: exitCode(from: status),
                    output: outputText
                )
            }

            var pollFD = pollfd(fd: controlFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, 1_000)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                kill(pid, SIGTERM)
                _ = waitForChild(pid)
                throw MountJockeyError.mountFailed(Int32(errno))
            }

            if ready > 0, (pollFD.revents & Int16(POLLIN)) != 0 {
                var buffer = [UInt8](repeating: 0, count: 4_096)
                let bytesRead = read(controlFD, &buffer, buffer.count)
                if bytesRead > 0 {
                    output.append(buffer, count: bytesRead)
                } else if bytesRead == 0 {
                    continue
                } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    kill(pid, SIGTERM)
                    _ = waitForChild(pid)
                    throw MountJockeyError.mountFailed(Int32(errno))
                }
            }
        }
    }

    private func smbfsRemotePath(for share: ShareConfiguration) -> String {
        let username = share.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let shareName = share.shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
        let encodedShareName = shareName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? shareName
        return "//\(encodedUsername)@\(share.host)/\(encodedShareName)"
    }

    private func writePassword(_ password: String, to fd: Int32) throws {
        var payload = Array(password.utf8)
        payload.append(0x0d)
        let written = payload.withUnsafeBytes { bytes -> ssize_t in
            guard let base = bytes.baseAddress else { return -1 }
            return Darwin.write(fd, base, bytes.count)
        }
        guard written >= 0 else {
            throw MountJockeyError.mountFailed(Int32(errno))
        }
    }

    private func outputContainsPasswordPrompt(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("password")
    }

    private func classifyMountFailure(exitCode: Int32, output: String) -> MountJockeyError {
        let lowered = output.lowercased()
        if lowered.contains("permission denied") || lowered.contains("authentication") || lowered.contains("access denied") {
            return .mountFailed(Int32(EPERM))
        }
        if lowered.contains("no such file") || lowered.contains("not found") || lowered.contains("does not exist") {
            return .mountFailed(Int32(ENOENT))
        }
        if lowered.contains("connection refused") {
            return .mountFailed(Int32(ECONNREFUSED))
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            return .mountFailed(Int32(ETIMEDOUT))
        }
        if exitCode > 0 {
            return .mountFailed(exitCode)
        }
        return .mountFailed(Int32(EIO))
    }

    private func exitCode(from waitStatus: Int32) -> Int32 {
        let code = (waitStatus >> 8) & 0xff
        return code == 0 ? 1 : code
    }

    private func waitForChild(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        return status
    }
}
