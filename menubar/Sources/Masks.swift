import SwiftUI

/// Each agent's face, cut from its seat's art the way imd.fun's Telegram page shows it: the mask alone, close.
/// Kept on disk, so the menu shows them at once, and read again a few times a day.
@MainActor
final class Masks: ObservableObject {
    static let shared = Masks()

    @Published private(set) var faces: [String: NSImage] = [:]
    private var asked: [String: Date] = [:]
    private let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("fun.imd.workerbar/masks", isDirectory: true)

    func load(_ tokenId: String) {
        guard Int(tokenId) != nil else { return }
        let file = dir.appendingPathComponent("\(tokenId).svg")
        if faces[tokenId] == nil, let data = try? Data(contentsOf: file), let face = Self.face(from: data) { faces[tokenId] = face }
        if let at = asked[tokenId], Date().timeIntervalSince(at) < 6 * 3600 { return }
        asked[tokenId] = Date()
        Task {
            guard let url = URL(string: "https://api.imd.fun/agents/by-token/\(tokenId).svg"),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, let face = Self.face(from: data) else { return }
            faces[tokenId] = face
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: file)
        }
    }

    /// The seat's art with all but the mask taken out (imd-website globals.css `.telegram-face`): the stars, grid,
    /// curves, orbits, ticks, side text and bars go. Smaller than imd.fun shows it, so the frame closes in to the face
    /// itself and its lines are drawn heavier, the way a small type size is cut bolder. Drawn once.
    static func face(from svg: Data) -> NSImage? {
        guard let doc = try? XMLDocument(data: svg, options: [.nodeLoadExternalEntitiesNever]), let root = doc.rootElement() else { return nil }
        let hidden = [
            "//*[local-name()='g'][@opacity='.68' or @opacity='.42' or @opacity='.72' or @font-family or @stroke-opacity='.5' or (contains(@filter,'glow') and @fill='none')]",
            "/*[local-name()='svg']/*[local-name()='path']",
            "//*[local-name()='g'][contains(@filter,'glow') and not(@fill='none')]/*[local-name()='path']",
            "/*[local-name()='svg']/*[local-name()='rect'][@width='900' and @height='900']",
            "//*[local-name()='g'][@text-anchor='middle']",
        ]
        for path in hidden { for node in (try? doc.nodes(forXPath: path)) ?? [] { node.detach() } }
        for node in (try? doc.nodes(forXPath: "//*[local-name()='g'][contains(@filter,'shadow')]//*[@stroke-width]")) ?? [] {
            guard let width = (node as? XMLElement)?.attribute(forName: "stroke-width"), let value = Double(width.stringValue ?? "") else { continue }
            width.stringValue = String(value * 2.2)
        }
        // The face runs from 201 to 724 down the art, centred on 450 across; a square around it and its edge.
        root.attribute(forName: "viewBox")?.stringValue = "184 196 532 532"
        root.attribute(forName: "shape-rendering")?.stringValue = "geometricPrecision"
        guard let vector = NSImage(data: doc.xmlData) else { return nil }
        // Drawn into pixels once, three to a point at the largest size the menu uses, so scrolling never redraws the SVG.
        let points: CGFloat = 40, pixels = Int(points * 3)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        vector.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// An agent as its mask, its state a dot at the corner the way Messages shows who is around: green while it is on,
/// moving while it changes, orange when it is held, grey and faded when it is off.
struct MaskBadge: View {
    let tokenId: String?
    let phase: Phase
    var size: CGFloat = 36
    @ObservedObject private var masks = Masks.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        let dot = (size * 0.28).rounded()
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let tokenId, let face = masks.faces[tokenId] {
                    Image(nsImage: face).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Color.primary.opacity(0.08)).padding(size * 0.1)
                }
            }
            .frame(width: size, height: size)
            .saturation(phase.isAway ? 0 : 1)
            .opacity(phase.isAway ? 0.5 : 1)
            // A notch where the dot sits, so it reads on the face and off it alike.
            .mask {
                Rectangle()
                    .overlay(alignment: .bottomTrailing) {
                        Circle().frame(width: dot + 4, height: dot + 4).offset(x: 2, y: 2).blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }

            ZStack {
                if phase.isWorking && !reduceMotion {
                    Circle().fill(phase.tint).scaleEffect(breathing ? 1.9 : 1).opacity(breathing ? 0 : 0.5)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: breathing)
                        .onAppear { breathing = true }
                }
                Circle().fill(phase.tint)
                if phase.isChanging { Spinner(lineWidth: 1.5).padding(1.5) }
            }
            .frame(width: dot, height: dot)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: phase)
        .onAppear { if let tokenId { masks.load(tokenId) } }
        .onChange(of: tokenId) { _, token in if let token { masks.load(token) } }
    }
}

// MARK: - State, in colour

extension Phase {
    var tint: Color {
        switch self {
        case .idle, .working: return .green
        case .starting, .stopping, .reconnecting, .checking: return .blue
        case .holding, .paused: return .orange
        case .dockerDown: return .red
        case .stopped, .offline, .held: return Color(nsColor: .systemGray)
        }
    }
    var isWorking: Bool { if case .working = self { return true } else { return false } }
    var isChanging: Bool {
        switch self { case .starting, .stopping, .reconnecting, .checking: return true; default: return false }
    }
    /// Off, or not heard from: the agent's picture fades.
    var isAway: Bool {
        switch self { case .stopped, .offline, .dockerDown: return true; default: return false }
    }
}
