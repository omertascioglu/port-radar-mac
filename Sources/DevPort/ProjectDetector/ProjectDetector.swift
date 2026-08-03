import Foundation

enum ProjectDetector {

    /// Finds the project a server belongs to by walking up from its working
    /// directory to a `.git` root (or the nearest directory with a manifest).
    static func detect(workingDirectory: String?, command: String?) -> ProjectInfo? {
        guard let workingDirectory, workingDirectory != "/" else { return nil }

        let root = projectRoot(from: workingDirectory) ?? workingDirectory
        // Only label real project directories; a bare cwd like ~ isn't one.
        guard hasProjectMarker(root) else { return nil }

        let name = packageJSONName(in: root)
            ?? URL(fileURLWithPath: root).lastPathComponent

        return ProjectInfo(
            name: name,
            rootPath: root,
            framework: framework(root: root, command: command)
        )
    }

    // MARK: - root discovery

    private static func projectRoot(from directory: String) -> String? {
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path || url.path == home || url.path == "/" { break }
            url = parent
        }
        return nil
    }

    private static let manifests = [
        "package.json", "pyproject.toml", "requirements.txt",
        "go.mod", "Cargo.toml", "Gemfile", "docker-compose.yml", "supabase",
    ]

    private static func hasProjectMarker(_ root: String) -> Bool {
        let url = URL(fileURLWithPath: root)
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
            return true
        }
        return manifests.contains {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    // MARK: - name

    private static func packageJSONName(in root: String) -> String? {
        let url = URL(fileURLWithPath: root).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String, !name.isEmpty
        else { return nil }
        return name
    }

    // MARK: - framework guess

    /// The running command is the strongest signal; project manifests break ties.
    private static func framework(root: String, command: String?) -> Framework {
        if let command = command?.lowercased() {
            let commandMatches: [(String, Framework)] = [
                ("next", .nextJS), ("vite", .vite), ("supabase", .supabase),
                ("docker", .docker), ("bun", .bun), ("python", .python),
                ("ruby", .ruby), ("rails", .ruby), ("cargo", .rust),
                ("node", .node),
            ]
            for (needle, fw) in commandMatches where command.contains(needle) {
                return fw
            }
            if command.contains("go run") || command.hasSuffix("/go") { return .go }
        }

        let url = URL(fileURLWithPath: root)
        if let deps = packageJSONDependencies(in: root) {
            if deps.contains("next") { return .nextJS }
            if deps.contains("vite") { return .vite }
            return .node
        }
        let fileMatches: [(String, Framework)] = [
            ("pyproject.toml", .python), ("requirements.txt", .python),
            ("go.mod", .go), ("Cargo.toml", .rust), ("Gemfile", .ruby),
            ("docker-compose.yml", .docker),
        ]
        for (file, fw) in fileMatches
        where FileManager.default.fileExists(atPath: url.appendingPathComponent(file).path) {
            return fw
        }
        return .unknown
    }

    private static func packageJSONDependencies(in root: String) -> Set<String>? {
        let url = URL(fileURLWithPath: root).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var deps: Set<String> = []
        for key in ["dependencies", "devDependencies"] {
            if let section = json[key] as? [String: Any] {
                deps.formUnion(section.keys)
            }
        }
        return deps
    }
}
