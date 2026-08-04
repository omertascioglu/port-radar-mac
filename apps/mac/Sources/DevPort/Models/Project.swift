import Foundation

/// Framework/runtime guess for a detected server.
enum Framework: String, Sendable {
    case nextJS = "Next.js"
    case vite = "Vite"
    case node = "Node"
    case bun = "Bun"
    case python = "Python"
    case ruby = "Ruby"
    case go = "Go"
    case rust = "Rust"
    case docker = "Docker"
    case supabase = "Supabase"
    case unknown = "Server"
}

/// The project a server was launched from, found via its working directory.
struct ProjectInfo: Sendable {
    let name: String
    let rootPath: String
    let framework: Framework
}
