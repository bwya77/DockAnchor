//
//  DockAnchorTests.swift
//  DockAnchorTests
//
//  Created by Bradley Wyatt on 7/2/25.
//

import Testing
@testable import DockAnchor

struct DockAnchorTests {

    // MARK: - UpdateChecker.isVersionNewer

    @Test func patchBumpWithMatchingComponentCountIsDetected() async throws {
        #expect(UpdateChecker.isVersionNewer("2.1.1", than: "2.1.0") == true)
    }

    @Test func patchBumpAgainstShorterCurrentVersionIsDetected() async throws {
        // Regression check: a running version with no patch component ("2.1")
        // must still see a patch-only release ("2.1.5") as newer.
        #expect(UpdateChecker.isVersionNewer("2.1.5", than: "2.1") == true)
    }

    @Test func shorterLatestVersionIsNotTreatedAsOlder() async throws {
        // "2.1" is missing a patch component, so it's compared as "2.1.0"
        // against a current version of "2.1.5" - not newer.
        #expect(UpdateChecker.isVersionNewer("2.1", than: "2.1.5") == false)
    }

    @Test func majorVersionBumpIsDetectedRegardlessOfComponentCount() async throws {
        #expect(UpdateChecker.isVersionNewer("2.0.0", than: "1.5") == true)
    }

    @Test func identicalVersionsAreNotNewer() async throws {
        #expect(UpdateChecker.isVersionNewer("2.1.0", than: "2.1.0") == false)
    }

    @Test func olderVersionIsNotNewer() async throws {
        #expect(UpdateChecker.isVersionNewer("2.0.9", than: "2.1.0") == false)
    }

    @Test func doubleDigitMinorVersionComparesNumericallyNotLexically() async throws {
        #expect(UpdateChecker.isVersionNewer("1.10", than: "1.9") == true)
    }

    @Test func malformedVersionStringsAreNotTreatedAsNewer() async throws {
        #expect(UpdateChecker.isVersionNewer("not-a-version", than: "2.1.0") == false)
        #expect(UpdateChecker.isVersionNewer("2.1.0", than: "not-a-version") == false)
    }

}
