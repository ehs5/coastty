//
//  CoasttySessionPersistenceTests.swift
//  Ghostty
//
//  Coverage for the pure decision logic behind session-file namespacing
//  and legacy-file migration - the two branches don't touch the real
//  file system or Bundle.main, so they're exercised directly here.
//

import Foundation
import Testing
@testable import Ghostty

struct CoasttySessionPersistenceTests {
    private static let releaseBundleID = "com.espensteen.coastty"
    private static let devBundleID = "com.espensteen.coastty.dev"
    private static let base = URL(fileURLWithPath: "/tmp/coastty-tests")

    @Test func sessionFileURLNamespacesByBundleID() {
        let release = CoasttySessionPersistence.sessionFileURL(forBundleID: Self.releaseBundleID, in: Self.base)
        let dev = CoasttySessionPersistence.sessionFileURL(forBundleID: Self.devBundleID, in: Self.base)

        #expect(release != dev)
        #expect(release.path == "/tmp/coastty-tests/\(Self.releaseBundleID)/session.json")
        #expect(dev.path == "/tmp/coastty-tests/\(Self.devBundleID)/session.json")
    }

    @Test func sessionFileURLFallsBackToTheReleaseBundleIDWhenBundleIdentifierIsNil() {
        let url = CoasttySessionPersistence.sessionFileURL(forBundleID: nil, in: Self.base)
        #expect(url.path == "/tmp/coastty-tests/\(Self.releaseBundleID)/session.json")
    }

    @Test func migratesWhenReleaseBuildHasNoOwnFileButALegacyFileExists() {
        let shouldMigrate = CoasttySessionPersistence.shouldMigrateLegacySessionFile(
            bundleID: Self.releaseBundleID,
            destinationExists: false,
            legacyExists: true)
        #expect(shouldMigrate)
    }

    @Test func neverMigratesForADevBuildEvenIfALegacyFileExists() {
        let shouldMigrate = CoasttySessionPersistence.shouldMigrateLegacySessionFile(
            bundleID: Self.devBundleID,
            destinationExists: false,
            legacyExists: true)
        #expect(!shouldMigrate)
    }

    @Test func neverMigratesOverAnAlreadyExistingNamespacedFile() {
        let shouldMigrate = CoasttySessionPersistence.shouldMigrateLegacySessionFile(
            bundleID: Self.releaseBundleID,
            destinationExists: true,
            legacyExists: true)
        #expect(!shouldMigrate)
    }

    @Test func neverMigratesWhenThereIsNoLegacyFileToAdopt() {
        let shouldMigrate = CoasttySessionPersistence.shouldMigrateLegacySessionFile(
            bundleID: Self.releaseBundleID,
            destinationExists: false,
            legacyExists: false)
        #expect(!shouldMigrate)
    }
}
