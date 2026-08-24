// Modification notice: Added in 2026 for the Port Radar Offline fork.
import Foundation
import XCTest

final class OfflineProductBoundaryTests: XCTestCase {
    func testShippingSourcesContainNoTunnelImplementation() throws {
        let sourceRoot = try sourceRootURL()
        let forbidden = [
            ["Cloud", "flared"].joined(),
            ["Tunnel", "Manager"].joined(),
            ["Tunnels", "Modal"].joined(),
            ["trycloud", "flare.com"].joined(),
            ["Share via ", "Cloudflare"].joined(),
        ]
        let violations = try swiftSources(at: sourceRoot).flatMap { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let relativePath = url.path.replacingOccurrences(of: sourceRoot.path + "/", with: "")
            return forbidden.compactMap { token in
                text.contains(token) ? "\(relativePath): \(token)" : nil
            }
        }
        XCTAssertEqual(violations, [])
    }

    private func sourceRootURL() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources/DevPort", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SourceDiscoveryError.missingSourceRoot(sourceRoot.path)
        }

        return sourceRoot
    }

    private func swiftSources(at sourceRoot: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SourceDiscoveryError.cannotEnumerateSourceRoot(sourceRoot.path)
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "swift",
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil
            }
            return url
        }
        .sorted { $0.path < $1.path }
    }
}

private enum SourceDiscoveryError: Error {
    case missingSourceRoot(String)
    case cannotEnumerateSourceRoot(String)
}
