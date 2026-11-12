import SwiftUI

// MARK: - Motion

enum Motion {
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.78)
    static let quick = Animation.easeOut(duration: 0.14)
    static let page = Animation.easeOut(duration: 0.24)
}

/// Whether looping decorations (glitches, sweeps, moving stripes) may animate. RootView turns it off while the game
/// runs, while the app is in the background and with Reduce Motion, so the launcher never competes with the game.
private struct LiveMotionKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var liveMotion: Bool {
        get { self[LiveMotionKey.self] }
        set { self[LiveMotionKey.self] = newValue }
    }
}

/// Stable pseudo-random value in 0..<1 (splitmix64), so procedural art looks the same on every redraw.
func hash01(_ n: Int) -> Double {
    var x = UInt64(bitPattern: Int64(n)) &+ 0x9E37_79B9_7F4A_7C15
    x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
    x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
    x ^= x >> 31
    return Double(x % 1_000_000) / 1_000_000
}

// MARK: - Textures

/// Diagonal hazard stripes.
struct HazardStripes: View {
    var color: Color = .black
    var spacing: CGFloat = 10
    var width: CGFloat = 4
    var phase: CGFloat = 0
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var x = -size.height - spacing + phase.truncatingRemainder(dividingBy: spacing)
            while x < size.width + spacing {
                p.move(to: .init(x: x, y: size.height)); p.addLine(to: .init(x: x + size.height, y: 0)); x += spacing
            }
            ctx.stroke(p, with: .color(color), lineWidth: width)
        }
    }
}

/// Hazard stripes that crawl sideways (an indeterminate progress bar).
struct MovingStripes: View {
    var color: Color
    @Environment(\.liveMotion) private var live
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !live)) { tl in
            HazardStripes(color: color, spacing: 12, width: 5, phase: live ? tl.date.timeIntervalSinceReferenceDate * 24 : 0)
        }
    }
}

/// The app background: near-black with film grain, a faint grid, a hatched corner, scanlines and a vignette
/// (drawn once per size), plus a slow scan band sweeping down.
struct CPBackground: View {
    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let all = Path(CGRect(origin: .zero, size: size))
                ctx.fill(all, with: .color(Theme.background))
                // Warm haze from the bottom right, like city light in smog.
                ctx.fill(all, with: .radialGradient(Gradient(colors: [Theme.red.opacity(0.07), .clear]),
                                                    center: CGPoint(x: size.width * 0.85, y: size.height * 1.05),
                                                    startRadius: 0, endRadius: max(size.width, size.height) * 0.7))
                let grid: CGFloat = 40
                var lines = Path()
                for x in stride(from: 0, through: size.width, by: grid) { lines.move(to: .init(x: x, y: 0)); lines.addLine(to: .init(x: x, y: size.height)) }
                for y in stride(from: 0, through: size.height, by: grid) { lines.move(to: .init(x: 0, y: y)); lines.addLine(to: .init(x: size.width, y: y)) }
                ctx.stroke(lines, with: .color(Theme.cyan.opacity(0.022)), lineWidth: 1)
                // Grid crosses at every 4th intersection.
                var crosses = Path()
                for x in stride(from: grid * 4, to: size.width, by: grid * 4) {
                    for y in stride(from: grid * 4, to: size.height, by: grid * 4) {
                        crosses.move(to: .init(x: x - 4, y: y)); crosses.addLine(to: .init(x: x + 4, y: y))
                        crosses.move(to: .init(x: x, y: y - 4)); crosses.addLine(to: .init(x: x, y: y + 4))
                    }
                }
                ctx.stroke(crosses, with: .color(Theme.red.opacity(0.16)), lineWidth: 1)
                // Grain.
                let count = Int(size.width * size.height / 260)
                var grain = Path()
                for i in 0..<count {
                    grain.addRect(CGRect(x: hash01(i * 2) * size.width, y: hash01(i * 2 + 1) * size.height, width: 1, height: 1))
                }
                ctx.fill(grain, with: .color(Color.white.opacity(0.045)))
                // Hatched band in the bottom-right corner.
                var hatch = Path()
                let band: CGFloat = 140
                for k in stride(from: 0, to: band, by: 9) {
                    hatch.move(to: .init(x: size.width - band + k, y: size.height)); hatch.addLine(to: .init(x: size.width, y: size.height - band + k))
                }
                ctx.stroke(hatch, with: .color(Theme.accent.opacity(0.035)), lineWidth: 2)
                var scan = Path()
                for y in stride(from: 0, through: size.height, by: 3) { scan.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)) }
                ctx.fill(scan, with: .color(Color.black.opacity(0.22)))
                ctx.fill(all, with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.55)]),
                                                    center: CGPoint(x: size.width / 2, y: size.height / 2),
                                                    startRadius: min(size.width, size.height) * 0.35, endRadius: max(size.width, size.height) * 0.8))
            }
            .drawingGroup()
            ScanSweep()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// A soft cyan band that drifts down the window every few seconds.
struct ScanSweep: View {
    var period: Double = 7
    @Environment(\.liveMotion) private var live
    var body: some View {
        if live {
            TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                GeometryReader { g in
                    let f = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    LinearGradient(colors: [.clear, Theme.cyan.opacity(0.035), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 140)
                        .offset(y: f * (g.size.height + 280) - 140)
                }
            }
        }
    }
}

// MARK: - Glitch

/// A red/cyan chromatic split around `label` that glitches in short bursts (a sideways jolt and a sliced band).
struct Glitch<Label: View>: View {
    let label: Label
    var color: Color = Theme.accent
    var split: Color = Theme.red
    var period: Double = 4.2
    /// Scales the split offsets (thin lettering needs a thinner rim).
    var spread: CGFloat = 1
    @Environment(\.liveMotion) private var live

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !live)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let burst = live && t.truncatingRemainder(dividingBy: period) < 0.24
            let tick = Int(t * 24)
            let dx = burst ? (hash01(tick) - 0.5) * 10 : 0
            let band = hash01(tick &+ 99)
            ZStack(alignment: .leading) {
                label.foregroundStyle(Theme.cyan.opacity(burst ? 0.9 : 0.35)).offset(x: (-1.5 - dx * 0.6) * spread, y: burst ? -spread : 0)
                label.foregroundStyle(split).offset(x: (2.5 + dx * 0.8) * spread, y: 1.5 * spread)
                label.foregroundStyle(color)
                if burst {
                    label.foregroundStyle(color).offset(x: dx * 2.2)
                        .mask(GeometryReader { g in
                            Rectangle().frame(height: g.size.height * 0.16).offset(y: band * g.size.height * 0.84)
                        })
                        .background(GeometryReader { g in
                            Rectangle().fill(Theme.background)
                                .frame(height: g.size.height * 0.16).offset(y: band * g.size.height * 0.84)
                        })
                }
            }
        }
    }
}

// MARK: - Logo titles

/// A title in the fan-made logo font (launcher/Resources/Cyberpunk-Regular.ttf) with a cyan rim and glitch bursts.
struct LogoTitle: View {
    let text: String
    var size: CGFloat
    var color: Color = Theme.accent
    var period: Double = 4.2

    var body: some View {
        // The font spaces letters wide and its blades overhang the glyph bounds: tighten, and pad so nothing clips.
        Glitch(label: Text(text).font(.cpLogo(size)).kerning(-size * 0.08).lineLimit(1).fixedSize(),
               color: color, split: Theme.cyan.opacity(0.85), period: period, spread: min(1, size / 80))
            .padding(.horizontal, size * 0.12)
            .accessibilityElement().accessibilityLabel(text)
    }
}

/// The game's own logo: Steam's library-cache copy recoloured for a dark background (launcher/Resources, bundled by
/// make-app.sh; for private use only). Falls back to the logo font without it.
struct GameLogo: View {
    var height: CGFloat
    var body: some View {
        if let logo = Bundle.main.image(forResource: "CyberpunkLogo") {
            Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                .frame(height: height)
                .shadow(color: Theme.red.opacity(0.4), radius: height / 8)
                .accessibilityLabel("Cyberpunk 2077")
        } else {
            LogoTitle(text: "Cyberpunk", size: height * 0.7)
        }
    }
}

/// Coloured slivers that flash across the content when `trigger` changes (page switches).
struct GlitchFlash<T: Equatable>: View {
    let trigger: T
    @LocalState private var seed = 0
    @LocalState private var visible = false

    var body: some View {
        GeometryReader { g in
            ForEach(0..<6, id: \.self) { i in
                let r = { (k: Int) in hash01(seed * 31 + i * 7 + k) }
                Rectangle().fill([Theme.cyan, Theme.red, Theme.accent][i % 3].opacity(0.55))
                    .frame(width: g.size.width * (0.15 + r(1) * 0.5), height: 1 + r(2) * 6)
                    .offset(x: r(3) * g.size.width * 0.6, y: r(4) * g.size.height)
            }
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            seed += 1
            visible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { withAnimation(.easeOut(duration: 0.22)) { visible = false } }
        }
    }
}

// MARK: - Appear and hover

private struct Appear: ViewModifier {
    let delay: Double
    @LocalState private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear { withAnimation(.easeOut(duration: 0.32).delay(delay)) { shown = true } }
    }
}

private struct HoverWash: ViewModifier {
    let tint: Color
    @LocalState private var hover = false
    func body(content: Content) -> some View {
        content
            .background(alignment: .leading) {
                LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .opacity(hover ? 1 : 0)
            }
            .onHover { h in withAnimation(Motion.quick) { hover = h } }
    }
}

extension View {
    /// Fades and slides the view in when it appears.
    func cpAppear(_ delay: Double = 0) -> some View { modifier(Appear(delay: delay)) }
    /// A tinted wash from the left edge while the pointer is over the view.
    func hoverWash(_ tint: Color = Theme.cyan) -> some View { modifier(HoverWash(tint: tint)) }
}

// MARK: - Corner ticks

/// L-shaped brackets at the top-right and bottom-left corners of a frame.
struct CornerTicks: Shape {
    var length: CGFloat = 10
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: .init(x: r.maxX - length, y: r.minY)); p.addLine(to: .init(x: r.maxX, y: r.minY)); p.addLine(to: .init(x: r.maxX, y: r.minY + length))
        p.move(to: .init(x: r.minX, y: r.maxY - length)); p.addLine(to: .init(x: r.minX, y: r.maxY)); p.addLine(to: .init(x: r.minX + length, y: r.maxY))
        return p
    }
}

// MARK: - Key art

/// Original procedural key art for the Play page: a hazy megacity skyline with lit windows, a yellow signal slab
/// with hazard stripes, HUD marks and scanlines. Nothing here is taken from the game.
struct CityscapeArt: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let horizon = h * 0.78
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(stops: [.init(color: Color(red: 0.03, green: 0.02, blue: 0.04), location: 0),
                                 .init(color: Color(red: 0.16, green: 0.03, blue: 0.06), location: 0.62),
                                 .init(color: Color(red: 0.42, green: 0.07, blue: 0.09), location: 1)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            // Glow behind the towers.
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [Theme.red.opacity(0.35), .clear]), center: CGPoint(x: w * 0.62, y: horizon),
                startRadius: 0, endRadius: w * 0.45))

            // Three skyline layers, far to near.
            let layers: [(seed: Int, minH: Double, maxH: Double, color: Color, windows: Double)] = [
                (100, 0.25, 0.62, Color(red: 0.30, green: 0.07, blue: 0.10), 0),
                (200, 0.18, 0.50, Color(red: 0.12, green: 0.03, blue: 0.06), 0.10),
                (300, 0.08, 0.32, Color(red: 0.03, green: 0.02, blue: 0.03), 0.05),
            ]
            for layer in layers {
                var x: CGFloat = -10, i = 0
                var towers = Path()
                var lit = Path(), litCyan = Path()
                while x < w {
                    let bw = 18 + hash01(layer.seed + i) * 46
                    let bh = h * (layer.minH + hash01(layer.seed + i + 500) * (layer.maxH - layer.minH))
                    let top = horizon + (layer.seed == 300 ? h * 0.22 : 0) - bh
                    let rect = CGRect(x: x, y: top, width: bw, height: h - top)
                    towers.addRect(rect)
                    if hash01(layer.seed + i + 900) > 0.7 { // antenna
                        towers.addRect(CGRect(x: x + bw / 2, y: top - 18, width: 1.5, height: 18))
                    }
                    if layer.windows > 0 {
                        var wy = top + 6
                        var k = 0
                        while wy < h - 4 {
                            var wx = x + 4
                            while wx < x + bw - 4 {
                                let r = hash01(layer.seed * 7 + i * 131 + k)
                                if r < layer.windows { lit.addRect(CGRect(x: wx, y: wy, width: 2, height: 2)) }
                                else if r < layer.windows * 1.35 { litCyan.addRect(CGRect(x: wx, y: wy, width: 2, height: 2)) }
                                wx += 5; k += 1
                            }
                            wy += 6
                        }
                    }
                    x += bw + 2; i += 1
                }
                ctx.fill(towers, with: .color(layer.color))
                ctx.fill(lit, with: .color(Theme.accent.opacity(0.55)))
                ctx.fill(litCyan, with: .color(Theme.cyan.opacity(0.5)))
            }

            // Yellow signal slab on the right, with a hazard band and a code block.
            let slab = Chamfer(cut: 26, corners: [.topLeft, .bottomRight])
                .path(in: CGRect(x: w * 0.74, y: h * 0.12, width: w * 0.2, height: h * 0.4))
            ctx.fill(slab, with: .color(Theme.accent.opacity(0.92)))
            ctx.drawLayer { l in
                l.clip(to: slab)
                var stripes = Path()
                let band = CGRect(x: w * 0.74, y: h * 0.43, width: w * 0.2, height: h * 0.06)
                var sx = band.minX - band.height
                while sx < band.maxX { stripes.move(to: .init(x: sx, y: band.maxY)); stripes.addLine(to: .init(x: sx + band.height, y: band.minY)); sx += 12 }
                l.clip(to: Path(band))
                l.stroke(stripes, with: .color(.black.opacity(0.85)), lineWidth: 5)
            }
            ctx.draw(Text("NC-77\nGRID//ONLINE\nSEC 0xA7F3").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.black),
                     at: CGPoint(x: w * 0.76, y: h * 0.16), anchor: .topLeading)
            ctx.fill(Path(CGRect(x: w * 0.74 + 12, y: h * 0.36, width: w * 0.2 - 24, height: 3)), with: .color(.black.opacity(0.8)))

            // Ground haze and HUD marks.
            ctx.fill(Path(CGRect(x: 0, y: h * 0.7, width: w, height: h * 0.3)), with: .linearGradient(
                Gradient(colors: [.clear, Theme.background.opacity(0.95)]), startPoint: CGPoint(x: 0, y: h * 0.7), endPoint: CGPoint(x: 0, y: h)))
            var hud = Path()
            for k in 0..<24 { // ruler along the top
                let tx = w * 0.42 + CGFloat(k) * 12
                hud.move(to: .init(x: tx, y: 14)); hud.addLine(to: .init(x: tx, y: k % 4 == 0 ? 24 : 19))
            }
            ctx.stroke(hud, with: .color(Theme.cyan.opacity(0.5)), lineWidth: 1)
            ctx.draw(Text("47.6062 N // 122.3321 W").font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.cyan.opacity(0.6)),
                     at: CGPoint(x: w * 0.42, y: 30), anchor: .topLeading)
            // Scanlines.
            var scan = Path()
            for y in stride(from: 0, through: h, by: 3) { scan.addRect(CGRect(x: 0, y: y, width: w, height: 1)) }
            ctx.fill(scan, with: .color(.black.opacity(0.28)))
        }
        .drawingGroup()
    }
}
