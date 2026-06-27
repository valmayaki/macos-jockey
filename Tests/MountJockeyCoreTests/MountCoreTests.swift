import XCTest
import Security
@testable import MountJockeyCore

final class MountCoreTests: XCTestCase {
    func testDefaultShareUsesGenericSMBEndpointAndHomeMountPoint() {
        let share = ShareConfiguration.defaultShare(homeDirectory: "/Users/tester")

        XCTAssertEqual(share.host, "nas.taila7f773.ts.net")
        XCTAssertEqual(share.shareName, "data")
        XCTAssertEqual(share.username, "ubani")
        XCTAssertEqual(share.mountPoint, "/Users/tester/Volumes/data")
        XCTAssertTrue(share.isEnabled)
        XCTAssertEqual(share.mountMethod, .smbfs)
    }

    func testConfigurationEncodingNeverContainsPassword() throws {
        let share = ShareConfiguration(
            name: "NAS Data",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/Users/tester/Volumes/data",
            isEnabled: true
        )

        let encoded = try JSONEncoder().encode([share])
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(json.localizedCaseInsensitiveContains("password"))
        XCTAssertTrue(json.contains("nas.example.test"))
    }

    func testLegacyConfigurationDecodesDefaultMountMethod() throws {
        let json = """
        [
          {
            "id": "E8B2A2D4-3C4A-4D40-A0C5-0E9C52C5E1F8",
            "name": "NAS Data",
            "host": "nas.example.test",
            "shareName": "data",
            "username": "user",
            "mountPoint": "/Users/tester/Volumes/data",
            "isEnabled": true,
            "isAutoMountPaused": false
          }
        ]
        """
        let decoded = try JSONDecoder().decode([ShareConfiguration].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.mountMethod, .smbfs)
    }

    func testCredentialIdentityIgnoresMountPointAndDisplayName() {
        let first = ShareConfiguration(
            name: "NAS One",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/Users/tester/Volumes/data",
            isEnabled: true
        )
        let second = ShareConfiguration(
            name: "NAS Two",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/Users/tester/Volumes/other",
            isEnabled: true
        )

        XCTAssertEqual(first.credentialIdentity, second.credentialIdentity)
        XCTAssertFalse(first.credentialAccount.contains("\u{0}"))
        XCTAssertFalse(first.credentialAccount.isEmpty)
    }

    func testMountedShareSignatureIgnoresMountMethodOnly() {
        let smbfsShare = ShareConfiguration(
            name: "NAS",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/Users/tester/Volumes/data",
            isEnabled: true,
            mountMethod: .smbfs
        )
        let netfsShare = ShareConfiguration(
            id: smbfsShare.id,
            name: "NAS",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/Users/tester/Volumes/data",
            isEnabled: true,
            mountMethod: .netfs
        )

        XCTAssertNotEqual(smbfsShare.mountSignature, netfsShare.mountSignature)
        XCTAssertEqual(smbfsShare.mountedShareSignature, netfsShare.mountedShareSignature)
    }

    func testMountTableMatchesDecodedMountPointAndShare() {
        let output = """
        //ubani@nas.taila7f773.ts.net/data on /Users/tester/Volumes/data (smbfs, nodev, nosuid, mounted by tester)
        """
        let table = MountTable(output: output)

        XCTAssertTrue(table.isMounted(
            host: "nas.taila7f773.ts.net",
            share: "data",
            at: "/Users/tester/Volumes/data"
        ))
    }

    func testMountTableHandlesEscapedSpaces() {
        let output = """
        //user@server/Team%20Data on /Users/tester/Volumes/Team Data (smbfs, nodev, nosuid)
        """
        let table = MountTable(output: output)

        XCTAssertTrue(table.isMounted(
            host: "server",
            share: "Team Data",
            at: "/Users/tester/Volumes/Team Data"
        ))
    }

    func testMountTableDetectsAnySMBMountAtPath() {
        let output = """
        //user@server/other on /Users/tester/Volumes/data (smbfs, nodev, nosuid)
        """
        let table = MountTable(output: output)

        XCTAssertTrue(table.hasSMBMount(at: "/Users/tester/Volumes/data"))
        XCTAssertFalse(table.isMounted(
            host: "server",
            share: "data",
            at: "/Users/tester/Volumes/data"
        ))
    }

    func testMountPointHealthReportsOtherSMBMount() {
        let share = ShareConfiguration(
            name: "NAS",
            host: "server",
            shareName: "data",
            username: "user",
            mountPoint: "/Users/tester/Volumes/data",
            isEnabled: true
        )
        let table = MountTable(output: """
        //user@server/other on /Users/tester/Volumes/data (smbfs, nodev, nosuid)
        """)

        XCTAssertEqual(MountPointInspector.health(for: share, table: table), .otherSMBMount)
    }

    func testSMBURLContainsNoCredentialMaterial() throws {
        let share = ShareConfiguration(
            name: "NAS",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/tmp/data",
            isEnabled: true
        )

        let url = try share.smbURL()

        XCTAssertEqual(url.absoluteString, "smb://nas.example.test/data")
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
    }

    func testValidationRejectsDuplicateMountPoints() {
        let first = ShareConfiguration(
            name: "One",
            host: "one.test",
            shareName: "data",
            username: "a",
            mountPoint: "/tmp/shared",
            isEnabled: true
        )
        let second = ShareConfiguration(
            name: "Two",
            host: "two.test",
            shareName: "data",
            username: "b",
            mountPoint: "/tmp/shared",
            isEnabled: true
        )

        XCTAssertThrowsError(try ShareConfiguration.validate([first, second]))
    }

    func testValidationRejectsRelativeMountPoints() {
        let share = ShareConfiguration(
            name: "Relative",
            host: "relative.test",
            shareName: "data",
            username: "user",
            mountPoint: "Volumes/data",
            isEnabled: true
        )

        XCTAssertThrowsError(try ShareConfiguration.validate([share]))
    }

    func testValidationRejectsNonEmptyExistingMountPoints() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fileURL = temporaryDirectory.appendingPathComponent("occupied.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("busy".utf8))

        let share = ShareConfiguration(
            name: "Occupied",
            host: "occupied.test",
            shareName: "data",
            username: "user",
            mountPoint: temporaryDirectory.path,
            isEnabled: true
        )

        XCTAssertThrowsError(try ShareConfiguration.validate([share]))
    }

    func testLegacyDefaultShareDetectorMatchesBakedInPreset() {
        let legacyShare = ShareConfiguration.defaultShare(homeDirectory: "/Users/tester")

        XCTAssertTrue(ShareConfiguration.isLegacyDefaultShare(legacyShare))
    }

    func testLegacyDefaultShareDetectorRejectsCustomHost() {
        let customShare = ShareConfiguration(
            name: "My NAS",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/Users/tester/Volumes/data",
            isEnabled: true
        )

        XCTAssertFalse(ShareConfiguration.isLegacyDefaultShare(customShare))
    }

    func testMountErrorCodesAreSpecific() {
        XCTAssertEqual(MountJockeyError.credentialMissing.code, "SMB_KEYCHAIN_PASSWORD_MISSING")
        XCTAssertEqual(MountJockeyError.mountTimedOut.code, "SMB_MOUNT_TIMED_OUT")
        XCTAssertEqual(MountJockeyError.mountFailed(Int32(EPERM)).code, "SMB_AUTH_REJECTED")
        XCTAssertEqual(MountJockeyError.mountFailed(Int32(ENOENT)).code, "SMB_SHARE_NOT_FOUND")
        XCTAssertEqual(MountJockeyError.mountFailed(12345).code, "SMB_MOUNT_STATUS_12345")
    }

    func testSMBFSPasswordResponseUsesLineFeed() {
        let response = SmbfsShareMounter.passwordPromptResponse(for: "secret")

        XCTAssertEqual(response, Data("secret\n".utf8))
        XCTAssertNotEqual(response, Data("secret\r".utf8))
    }


    func testStablePasswordSaveDeletesAppOwnedLegacyCredentials() throws {
        let store = KeychainCredentialStore()
        let share = ShareConfiguration(
            name: "Cleanup",
            host: "cleanup-\(UUID().uuidString).example.test",
            shareName: "data",
            username: "tester",
            mountPoint: "/tmp/cleanup",
            isEnabled: true
        )

        defer { try? store.deletePassword(for: share) }
        defer { share.legacyCredentialAccounts.forEach { deleteAppCredential(account: $0) } }

        for account in share.legacyCredentialAccounts {
            try addAppCredential(account: account, password: "old-password")
            XCTAssertTrue(appCredentialExists(account: account))
        }

        try store.save(password: "new-password", for: share)

        XCTAssertTrue(try store.containsPassword(for: share))
        XCTAssertEqual(try store.password(for: share), "new-password")
        for account in share.legacyCredentialAccounts {
            XCTAssertFalse(appCredentialExists(account: account))
        }
    }

    func testKeychainCredentialRoundTrip() throws {
        let store = KeychainCredentialStore()
        let share = ShareConfiguration(
            name: "Round Trip",
            host: "nas.example.test",
            shareName: "data",
            username: "tester",
            mountPoint: "/tmp/round-trip",
            isEnabled: true
        )

        defer { try? store.deletePassword(for: share) }

        try store.save(password: "super-secret-password", for: share)

        XCTAssertTrue(try store.containsPassword(for: share))
        XCTAssertEqual(try store.password(for: share), "super-secret-password")
    }
    private func addAppCredential(account: String, password: String) throws {
        deleteAppCredential(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.valmayaki.mountjockey.smb",
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func deleteAppCredential(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.valmayaki.mountjockey.smb",
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func appCredentialExists(account: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.valmayaki.mountjockey.smb",
            kSecAttrAccount as String: account
        ]
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess && result != nil
    }

}
