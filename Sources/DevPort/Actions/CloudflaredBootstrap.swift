import Foundation

/// Downloads and caches `cloudflared` under Application Support so Share works
/// without Homebrew.
enum CloudflaredBootstrap {
    static var supportDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Port Radar", isDirectory: true)
    }

    static var cachedBinaryURL: URL {
        supportDirectory.appendingPathComponent("cloudflared", isDirectory: false)
    }

    /// Returns a usable cloudflared path, downloading once if needed.
    static func resolveBinary() async throws -> String {
        let cached = cachedBinaryURL.path
        if FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }

        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let arch: String
#if arch(arm64)
        arch = "arm64"
#else
        arch = "amd64"
#endif
        let downloadURL = URL(string:
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-\(arch).tgz"
        )!

        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BootstrapError.downloadFailed(http.statusCode)
        }

        let extractDir = supportDirectory.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        try extractTarball(tempURL, into: extractDir)

        guard let extracted = findCloudflared(in: extractDir) else {
            throw BootstrapError.binaryMissing
        }

        let destination = cachedBinaryURL
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: extracted, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )
        clearQuarantine(at: destination.path)

        guard FileManager.default.isExecutableFile(atPath: destination.path) else {
            throw BootstrapError.notExecutable
        }
        return destination.path
    }

    private static func extractTarball(_ tarball: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tarball.path, "-C", directory.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BootstrapError.extractFailed
        }
    }

    private static func findCloudflared(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "cloudflared" {
                return fileURL
            }
        }
        // Some archives unpack a single binary named with arch suffix.
        if let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            return contents.first { $0.lastPathComponent.hasPrefix("cloudflared") }
        }
        return nil
    }

    private static func clearQuarantine(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "com.apple.quarantine", path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    enum BootstrapError: LocalizedError {
        case downloadFailed(Int)
        case extractFailed
        case binaryMissing
        case notExecutable

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let code):
                return "Couldn’t download cloudflared (HTTP \(code)). Check your network and try again."
            case .extractFailed:
                return "Couldn’t unpack the cloudflared download."
            case .binaryMissing:
                return "Downloaded archive didn’t contain cloudflared."
            case .notExecutable:
                return "cloudflared couldn’t be made executable."
            }
        }
    }
}
