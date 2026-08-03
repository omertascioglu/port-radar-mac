import SwiftUI

/// Compact monochrome framework marks that match the menu-bar chrome.
struct FrameworkIcon: View {
    let framework: Framework
    var size: CGFloat = 13

    var body: some View {
        Group {
            switch framework {
            case .nextJS: NextMark()
            case .vite: Image(systemName: "bolt.fill")
            case .node: NodeMark()
            case .bun: BunMark()
            case .python: PythonMark()
            case .ruby: Image(systemName: "diamond.fill")
            case .go: GoMark()
            case .rust: Image(systemName: "gearshape.fill")
            case .docker: DockerMark()
            case .supabase: Image(systemName: "bolt.fill")
            case .unknown: Image(systemName: "server.rack")
            }
        }
        .font(.system(size: size * 0.72, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
        .help(framework.rawValue)
        .accessibilityLabel(framework.rawValue)
    }
}

// MARK: - Custom monochrome marks

private struct NextMark: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: w * 0.22, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: w * 0.1))
                Path { path in
                    path.move(to: CGPoint(x: w * 0.32, y: h * 0.76))
                    path.addLine(to: CGPoint(x: w * 0.32, y: h * 0.24))
                    path.addLine(to: CGPoint(x: w * 0.70, y: h * 0.76))
                    path.move(to: CGPoint(x: w * 0.70, y: h * 0.76))
                    path.addLine(to: CGPoint(x: w * 0.70, y: h * 0.24))
                }
                .stroke(style: StrokeStyle(lineWidth: w * 0.1, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private struct NodeMark: View {
    var body: some View {
        Image(systemName: "hexagon")
            .font(.system(size: 12, weight: .semibold))
    }
}

private struct BunMark: View {
    var body: some View {
        ZStack {
            Capsule()
                .strokeBorder(lineWidth: 1.2)
            HStack(spacing: 2) {
                Circle().frame(width: 1.8, height: 1.8)
                Circle().frame(width: 1.8, height: 1.8)
            }
            .offset(y: -1)
        }
        .padding(1)
    }
}

private struct PythonMark: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(lineWidth: 1.1)
                .frame(width: 7, height: 7)
                .offset(x: -1.8, y: -1.4)
            Circle()
                .strokeBorder(lineWidth: 1.1)
                .frame(width: 7, height: 7)
                .offset(x: 1.8, y: 1.4)
        }
    }
}

private struct GoMark: View {
    var body: some View {
        Text("Go")
            .font(.system(size: 7, weight: .bold, design: .rounded))
    }
}

private struct DockerMark: View {
    var body: some View {
        ZStack {
            HStack(spacing: 1) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 0.5)
                        .strokeBorder(lineWidth: 0.9)
                        .frame(width: 2.6, height: 2.6)
                }
            }
            .offset(y: -1.8)
            Capsule()
                .strokeBorder(lineWidth: 1)
                .frame(width: 10, height: 3)
                .offset(y: 2.2)
        }
    }
}
