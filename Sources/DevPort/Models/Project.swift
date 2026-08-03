import Foundation

/// Framework/runtime guess for a detected server, with an SF Symbol for the UI.
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

    var symbolName: String {
        switch self {
        case .nextJS: "n.square.fill"
        case .vite: "bolt.fill"
        case .node: "hexagon.fill"
        case .bun: "b.square.fill"
        case .python: "p.square.fill"
        case .ruby: "diamond.fill"
        case .go: "g.square.fill"
        case .rust: "r.square.fill"
        case .docker: "shippingbox.fill"
        case .supabase: "s.square.fill"
        case .unknown: "server.rack"
        }
    }
}

/// The project a server was launched from, found via its working directory.
struct ProjectInfo: Sendable {
    let name: String
    let rootPath: String
    let framework: Framework
}
