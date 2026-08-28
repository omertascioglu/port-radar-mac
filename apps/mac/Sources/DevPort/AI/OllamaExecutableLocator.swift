// Modification notice: Added in 2026 for the Port Radar Offline fork.
import AppKit
import Foundation

protocol OllamaExecutableLocating: Sendable {
    func locate() throws -> URL
}

enum OllamaExecutableLocatorError: Error, Equatable, Sendable {
    case notInstalled
}

struct OllamaExecutableLocator: OllamaExecutableLocating, Sendable {
    private static let bundleIdentifier = "com.electron.ollama"
    private static let executableRelativePath = "Contents/Resources/ollama"
    private static let productionFallbacks = [
        URL(fileURLWithPath: "/opt/homebrew/bin/ollama"),
        URL(fileURLWithPath: "/usr/local/bin/ollama"),
    ]

    private let bundleLookup: @Sendable (String) -> URL?
    private let canonicalize: @Sendable (URL) throws -> URL
    private let isDirectory: @Sendable (URL) throws -> Bool
    private let isRegularFile: @Sendable (URL) throws -> Bool
    private let isExecutableFile: @Sendable (URL) -> Bool
    private let fallbackCandidates: [URL]

    init() {
        bundleLookup = { identifier in
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: identifier
            )
        }
        canonicalize = { url in
            guard url.isFileURL else {
                throw OllamaExecutableLocatorError.notInstalled
            }
            return url.resolvingSymlinksInPath().standardizedFileURL
        }
        isDirectory = { url in
            try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        isRegularFile = { url in
            try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
        isExecutableFile = { url in
            FileManager.default.isExecutableFile(atPath: url.path)
        }
        fallbackCandidates = Self.productionFallbacks
    }

#if DEBUG
    init(
        bundleLookup: @escaping @Sendable (String) -> URL?,
        canonicalize: @escaping @Sendable (URL) throws -> URL,
        isDirectory: @escaping @Sendable (URL) throws -> Bool,
        isRegularFile: @escaping @Sendable (URL) throws -> Bool,
        isExecutableFile: @escaping @Sendable (URL) -> Bool,
        fallbackCandidates: [URL]
    ) {
        self.bundleLookup = bundleLookup
        self.canonicalize = canonicalize
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.isExecutableFile = isExecutableFile
        self.fallbackCandidates = fallbackCandidates
    }
#endif

    func locate() throws -> URL {
        let canonicalBundleURL = locateCanonicalBundle()

        if let canonicalBundleURL,
           let executable = validateApplicationExecutable(in: canonicalBundleURL) {
            return executable
        }

        for candidate in fallbackCandidates {
            if let executable = validateFallback(
                candidate,
                canonicalBundleURL: canonicalBundleURL
            ) {
                return executable
            }
        }

        throw OllamaExecutableLocatorError.notInstalled
    }

    private func locateCanonicalBundle() -> URL? {
        guard let discoveredURL = bundleLookup(Self.bundleIdentifier) else {
            return nil
        }

        do {
            let canonicalURL = try canonicalize(discoveredURL)
            guard canonicalURL.pathExtension == "app",
                  try isDirectory(canonicalURL) else {
                return nil
            }
            return canonicalURL
        } catch {
            return nil
        }
    }

    private func validateApplicationExecutable(in bundleURL: URL) -> URL? {
        let candidate = bundleURL.appendingPathComponent(
            Self.executableRelativePath
        )

        do {
            let canonicalCandidate = try canonicalize(candidate)
            guard isDescendant(canonicalCandidate, of: bundleURL),
                  try isRegularFile(canonicalCandidate),
                  isExecutableFile(canonicalCandidate) else {
                return nil
            }
            return canonicalCandidate
        } catch {
            return nil
        }
    }

    private func validateFallback(
        _ candidate: URL,
        canonicalBundleURL: URL?
    ) -> URL? {
        do {
            let knownPath = candidate.standardizedFileURL
            let canonicalCandidate = try canonicalize(candidate)
            let isExactKnownPath = canonicalCandidate == knownPath
            let isInsideBundle = canonicalBundleURL.map {
                isDescendant(canonicalCandidate, of: $0)
            } ?? false
            let isInsideCellar = trustedCellarRoot(for: knownPath).map {
                isDescendant(canonicalCandidate, of: $0)
            } ?? false

            guard isExactKnownPath || isInsideBundle || isInsideCellar,
                  try isRegularFile(canonicalCandidate),
                  isExecutableFile(canonicalCandidate) else {
                return nil
            }
            return canonicalCandidate
        } catch {
            return nil
        }
    }

    private func trustedCellarRoot(for candidate: URL) -> URL? {
        switch candidate.path {
        case "/opt/homebrew/bin/ollama":
            return URL(fileURLWithPath: "/opt/homebrew/Cellar/ollama")
        case "/usr/local/bin/ollama":
            return URL(fileURLWithPath: "/usr/local/Cellar/ollama")
        default:
            return nil
        }
    }

    private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let directoryComponents = directory.standardizedFileURL.pathComponents
        guard candidateComponents.count > directoryComponents.count else {
            return false
        }
        return candidateComponents.prefix(directoryComponents.count)
            .elementsEqual(directoryComponents)
    }
}
