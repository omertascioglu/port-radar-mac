// Modification notice: Added in 2026 for the Port Radar Offline fork.
import Foundation
import XCTest
@testable import DevPort

private final class LocatorSpy: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var bundleIdentifiers: [String] = []
    private(set) var canonicalizedURLs: [URL] = []

    func recordBundleIdentifier(_ identifier: String) {
        lock.withLock { bundleIdentifiers.append(identifier) }
    }

    func recordCanonicalizedURL(_ url: URL) {
        lock.withLock { canonicalizedURLs.append(url) }
    }
}

private enum CanonicalizationFailure: Error {
    case failed
}

final class OllamaExecutableLocatorTests: XCTestCase {
    private let appURL = URL(fileURLWithPath: "/Applications/Ollama.app")
    private let appExecutableURL = URL(
        fileURLWithPath: "/Applications/Ollama.app/Contents/Resources/ollama"
    )
    private let homebrewURL = URL(fileURLWithPath: "/opt/homebrew/bin/ollama")
    private let usrLocalURL = URL(fileURLWithPath: "/usr/local/bin/ollama")

    func testPrefersExecutableInsideCanonicalOllamaApplicationBundle() throws {
        let spy = LocatorSpy()
        let locator = makeLocator(
            spy: spy,
            appURL: appURL,
            regularFiles: [appExecutableURL],
            executableFiles: [appExecutableURL]
        )

        XCTAssertEqual(try locator.locate(), appExecutableURL)
        XCTAssertEqual(spy.bundleIdentifiers, ["com.electron.ollama"])
        XCTAssertFalse(spy.canonicalizedURLs.contains(homebrewURL))
        XCTAssertFalse(spy.canonicalizedURLs.contains(usrLocalURL))
    }

    func testCanonicalizesApplicationAndKeepsExecutableInsideIt() throws {
        let spy = LocatorSpy()
        let reportedApp = URL(fileURLWithPath: "/Applications/Ollama Alias.app")
        let canonicalApp = URL(fileURLWithPath: "/Applications/Ollama.app")
        let canonicalExecutable = canonicalApp
            .appendingPathComponent("Contents/Resources/ollama")
        let locator = makeLocator(
            spy: spy,
            appURL: reportedApp,
            canonicalURLs: [
                reportedApp: canonicalApp,
            ],
            regularFiles: [canonicalExecutable],
            executableFiles: [canonicalExecutable]
        )

        XCTAssertEqual(try locator.locate(), canonicalExecutable)
        XCTAssertEqual(
            spy.canonicalizedURLs,
            [reportedApp, canonicalExecutable]
        )
    }

    func testRejectsApplicationExecutableThatEscapesCanonicalBundle() throws {
        let escapedURL = URL(fileURLWithPath: "/tmp/ollama")
        let locator = makeLocator(
            appURL: appURL,
            canonicalURLs: [appExecutableURL: escapedURL],
            regularFiles: [escapedURL, usrLocalURL],
            executableFiles: [escapedURL, usrLocalURL]
        )

        XCTAssertEqual(try locator.locate(), usrLocalURL)
    }

    func testChecksHomebrewThenUsrLocalInDeterministicOrder() throws {
        let spy = LocatorSpy()
        let locator = makeLocator(
            spy: spy,
            regularFiles: [usrLocalURL],
            executableFiles: [usrLocalURL]
        )

        XCTAssertEqual(try locator.locate(), usrLocalURL)
        XCTAssertEqual(
            spy.canonicalizedURLs,
            [homebrewURL, usrLocalURL]
        )
    }

    func testUsesHomebrewBeforeUsrLocalWhenBothAreValid() throws {
        let locator = makeLocator(
            regularFiles: [homebrewURL, usrLocalURL],
            executableFiles: [homebrewURL, usrLocalURL]
        )

        XCTAssertEqual(try locator.locate(), homebrewURL)
    }

    func testRejectsNonExecutableCandidate() {
        let locator = makeLocator(regularFiles: [homebrewURL])

        XCTAssertThrowsError(try locator.locate()) { error in
            XCTAssertEqual(error as? OllamaExecutableLocatorError, .notInstalled)
        }
    }

    func testAllowsHomebrewSymlinkIntoCorrespondingCellar() throws {
        let cellarExecutable = URL(
            fileURLWithPath: "/opt/homebrew/Cellar/ollama/0.11.4/bin/ollama"
        )
        let locator = makeLocator(
            canonicalURLs: [homebrewURL: cellarExecutable],
            regularFiles: [cellarExecutable],
            executableFiles: [cellarExecutable]
        )

        XCTAssertEqual(try locator.locate(), cellarExecutable)
    }

    func testAllowsUsrLocalSymlinkIntoCorrespondingCellar() throws {
        let cellarExecutable = URL(
            fileURLWithPath: "/usr/local/Cellar/ollama/0.11.4/bin/ollama"
        )
        let locator = makeLocator(
            canonicalURLs: [usrLocalURL: cellarExecutable],
            regularFiles: [cellarExecutable],
            executableFiles: [cellarExecutable]
        )

        XCTAssertEqual(try locator.locate(), cellarExecutable)
    }

    func testAllowsFallbackSymlinkIntoDiscoveredApplicationBundle() throws {
        let alternateAppExecutable = URL(
            fileURLWithPath: "/Applications/Ollama.app/Contents/MacOS/ollama"
        )
        let locator = makeLocator(
            appURL: appURL,
            canonicalURLs: [homebrewURL: alternateAppExecutable],
            regularFiles: [alternateAppExecutable],
            executableFiles: [alternateAppExecutable]
        )

        XCTAssertEqual(try locator.locate(), alternateAppExecutable)
    }

    func testRejectsFallbackSymlinkToArbitraryLocation() throws {
        let arbitraryExecutable = URL(
            fileURLWithPath: "/Users/example/bin/ollama"
        )
        let locator = makeLocator(
            canonicalURLs: [homebrewURL: arbitraryExecutable],
            regularFiles: [arbitraryExecutable, usrLocalURL],
            executableFiles: [arbitraryExecutable, usrLocalURL]
        )

        XCTAssertEqual(try locator.locate(), usrLocalURL)
    }

    func testInvalidApplicationCandidateContinuesToTrustedFallback() throws {
        let locator = makeLocator(
            appURL: appURL,
            regularFiles: [appExecutableURL, homebrewURL],
            executableFiles: [homebrewURL]
        )

        XCTAssertEqual(try locator.locate(), homebrewURL)
    }

    func testCanonicalizationFailureFailsClosedAndContinues() throws {
        let homebrewURL = homebrewURL
        let usrLocalURL = usrLocalURL
        let locator = OllamaExecutableLocator(
            bundleLookup: { _ in nil },
            canonicalize: { url in
                if url == homebrewURL {
                    throw CanonicalizationFailure.failed
                }
                return url
            },
            isDirectory: { _ in false },
            isRegularFile: { $0 == usrLocalURL },
            isExecutableFile: { $0 == usrLocalURL },
            fallbackCandidates: [homebrewURL, usrLocalURL]
        )

        XCTAssertEqual(try locator.locate(), usrLocalURL)
    }

    func testThrowsExactNotInstalledErrorWhenNoCandidateIsValid() {
        let locator = makeLocator()

        XCTAssertThrowsError(try locator.locate()) { error in
            XCTAssertEqual(error as? OllamaExecutableLocatorError, .notInstalled)
        }
    }

    func testLocatorStoresNoOpenLaunchExecuteOrDownloadAction() {
        let labels = Mirror(reflecting: makeLocator()).children.compactMap(\.label)
        let prohibitedWords = ["open", "launch", "execute", "download", "action"]

        for label in labels {
            for word in prohibitedWords {
                XCTAssertFalse(label.localizedCaseInsensitiveContains(word), label)
            }
        }
    }

    private func makeLocator(
        spy: LocatorSpy = LocatorSpy(),
        appURL: URL? = nil,
        canonicalURLs: [URL: URL] = [:],
        regularFiles: Set<URL> = [],
        executableFiles: Set<URL> = []
    ) -> OllamaExecutableLocator {
        OllamaExecutableLocator(
            bundleLookup: { identifier in
                spy.recordBundleIdentifier(identifier)
                return appURL
            },
            canonicalize: { url in
                spy.recordCanonicalizedURL(url)
                return canonicalURLs[url] ?? url
            },
            isDirectory: { url in
                url.pathExtension == "app"
            },
            isRegularFile: { regularFiles.contains($0) },
            isExecutableFile: { executableFiles.contains($0) },
            fallbackCandidates: [homebrewURL, usrLocalURL]
        )
    }
}
