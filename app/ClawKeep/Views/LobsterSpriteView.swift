import AppKit
import SwiftUI

// MARK: - Menu Bar Label

struct LobsterMenuBarLabel: View {
    @EnvironmentObject private var appState: AppState
    let state: StatusMascotState
    let tick: Int

    var body: some View {
        Image(nsImage: LobsterMenuIconRenderer.image(state: state, tick: tick))
            .renderingMode(.template)
    }
}

// MARK: - Status Badge (Popover Header)

struct LobsterStatusBadgeView: View {
    let state: StatusMascotState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(state.tint.opacity(0.15))
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(state.tint.opacity(0.4), lineWidth: 2)

            LobsterSpriteView(state: state, size: CGSize(width: 75, height: 65), showsBackdrop: false)
        }
        .frame(width: 95, height: 85)
    }
}

// MARK: - Animated Sprite Canvas

struct LobsterSpriteView: View {
    let state: StatusMascotState
    let size: CGSize
    let showsBackdrop: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
            Canvas(rendersAsynchronously: true) { context, canvasSize in
                let frameCount = LobsterRenderer.frameCount(for: state)
                let interval = frameInterval
                let t = timeline.date.timeIntervalSinceReferenceDate
                let frame = Int(t / interval) % max(1, frameCount)

                LobsterRenderer.draw(in: context, size: canvasSize, state: state, frame: frame, isIcon: false)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private var frameInterval: TimeInterval {
        switch state {
        case .busy: return 0.08
        case .fixing: return 0.1
        case .error: return 0.05
        default: return 0.15
        }
    }
}

// MARK: - Popover Lobster Renderer (Clean Chibi Style)

struct LobsterRenderer {
    static func frameCount(for state: StatusMascotState) -> Int {
        switch state {
        case .idle: return 8
        case .busy: return 4
        case .fixing: return 4
        case .success: return 6
        case .error: return 6
        case .restarting: return 8
        case .failed: return 2
        }
    }

    static func draw(in context: GraphicsContext, size: CGSize, state: StatusMascotState, frame: Int, isIcon: Bool) {
        let scale = min(size.width, size.height) / 100.0

        var ctx = context
        ctx.translateBy(x: size.width / 2.0, y: size.height / 2.0)

        // Bounce / bob
        let bob: CGFloat = {
            switch state {
            case .idle: return sin(Double(frame) * .pi / 4.0) * 1.5
            case .busy: return sin(Double(frame) * .pi / 2.0) * 3.0
            case .error: return CGFloat.random(in: -3...3)
            case .restarting: return sin(Double(frame) * .pi / 4.0) * 2.0
            default: return 0
            }
        }()
        ctx.translateBy(x: 0, y: bob * scale)
        ctx.scaleBy(x: scale, y: scale)

        let mainColor = isIcon ? Color.primary : state.tint

        drawBody(in: &ctx, color: mainColor, isIcon: isIcon)
        drawTail(in: &ctx, color: mainColor, isIcon: isIcon)
        drawAntennae(in: &ctx, color: mainColor, isIcon: isIcon, frame: frame, state: state)
        drawClaws(in: &ctx, color: mainColor, isIcon: isIcon, state: state, frame: frame)

        if !isIcon {
            drawFace(in: &ctx, state: state, frame: frame)
            drawAccessories(in: &ctx, state: state, frame: frame)
        }
    }

    // MARK: Body

    private static func drawBody(in ctx: inout GraphicsContext, color: Color, isIcon: Bool) {
        // Round chibi body
        let bodyRect = CGRect(x: -30, y: -18, width: 60, height: 50)
        let body = Path(ellipseIn: bodyRect)

        if !isIcon {
            ctx.fill(body, with: .color(color))
            // Light belly
            let bellyRect = CGRect(x: -18, y: -5, width: 36, height: 30)
            ctx.fill(Path(ellipseIn: bellyRect), with: .color(Color.white.opacity(0.35)))
        } else {
            ctx.fill(body, with: .color(color))
        }
    }

    // MARK: Tail

    private static func drawTail(in ctx: inout GraphicsContext, color: Color, isIcon: Bool) {
        var tail = Path()
        // Simple fan tail at bottom
        tail.move(to: CGPoint(x: -10, y: 28))
        tail.addQuadCurve(to: CGPoint(x: 10, y: 28), control: CGPoint(x: 0, y: 24))
        tail.addQuadCurve(to: CGPoint(x: 18, y: 42), control: CGPoint(x: 18, y: 34))
        tail.addQuadCurve(to: CGPoint(x: -18, y: 42), control: CGPoint(x: 0, y: 48))
        tail.addQuadCurve(to: CGPoint(x: -10, y: 28), control: CGPoint(x: -18, y: 34))
        ctx.fill(tail, with: .color(color))
    }

    // MARK: Antennae

    private static func drawAntennae(in ctx: inout GraphicsContext, color: Color, isIcon: Bool, frame: Int, state: StatusMascotState) {
        let sway = sin(Double(frame) * 0.8) * 3.0

        var ant = Path()
        // Left antenna
        ant.move(to: CGPoint(x: -8, y: -16))
        ant.addQuadCurve(to: CGPoint(x: -20 + sway, y: -48), control: CGPoint(x: -18, y: -30))
        // Right antenna
        ant.move(to: CGPoint(x: 8, y: -16))
        ant.addQuadCurve(to: CGPoint(x: 20 - sway, y: -48), control: CGPoint(x: 18, y: -30))

        let lineW: CGFloat = isIcon ? 1.5 : 2.5
        ctx.stroke(ant, with: .color(color), lineWidth: lineW)

        if !isIcon {
            // Small round tips
            ctx.fill(Path(ellipseIn: CGRect(x: -23 + sway, y: -52, width: 6, height: 6)), with: .color(color))
            ctx.fill(Path(ellipseIn: CGRect(x: 17 - sway, y: -52, width: 6, height: 6)), with: .color(color))
        }
    }

    // MARK: Claws

    private static func drawClaws(in ctx: inout GraphicsContext, color: Color, isIcon: Bool, state: StatusMascotState, frame: Int) {
        let clawSwing: Double = {
            switch state {
            case .busy: return sin(Double(frame) * .pi / 2.0) * 20.0
            case .fixing: return sin(Double(frame) * .pi / 2.0) * 10.0
            default: return sin(Double(frame) * 0.5) * 5.0
            }
        }()

        // Draw each claw as a rounded pincer shape
        for side in [-1.0, 1.0] {
            var cCtx = ctx
            cCtx.translateBy(x: side * 32, y: -4)
            cCtx.rotate(by: .degrees(side * (30.0 + clawSwing)))

            // Arm segment
            let arm = Path(roundedRect: CGRect(x: -3, y: -2, width: 16, height: 7), cornerRadius: 3)
            cCtx.fill(arm, with: .color(color))

            // Pincer (two small ovals forming a V)
            var pincer = Path()
            // Upper jaw
            pincer.addEllipse(in: CGRect(x: 10, y: -5, width: 14, height: 7))
            // Lower jaw
            pincer.addEllipse(in: CGRect(x: 10, y: 1, width: 14, height: 7))
            cCtx.fill(pincer, with: .color(color))

            if !isIcon {
                // Gap between jaws (dark line)
                var gap = Path()
                gap.move(to: CGPoint(x: 12, y: 1.5))
                gap.addLine(to: CGPoint(x: 22, y: 1.5))
                cCtx.stroke(gap, with: .color(Color.black.opacity(0.3)), lineWidth: 1.5)
            }
        }
    }

    // MARK: Face

    private static func drawFace(in ctx: inout GraphicsContext, state: StatusMascotState, frame: Int) {
        switch state {
        case .error, .failed:
            // X eyes
            drawXEye(in: &ctx, center: CGPoint(x: -12, y: 0), size: 10)
            drawXEye(in: &ctx, center: CGPoint(x: 12, y: 0), size: 10)
            // Flat mouth
            var mouth = Path()
            mouth.move(to: CGPoint(x: -6, y: 14))
            mouth.addLine(to: CGPoint(x: 6, y: 14))
            ctx.stroke(mouth, with: .color(Color.black.opacity(0.7)), lineWidth: 2)

            if state == .error {
                // Angry eyebrows
                var browL = Path()
                browL.move(to: CGPoint(x: -18, y: -10))
                browL.addLine(to: CGPoint(x: -6, y: -6))
                ctx.stroke(browL, with: .color(Color.black.opacity(0.7)), lineWidth: 2.5)
                var browR = Path()
                browR.move(to: CGPoint(x: 18, y: -10))
                browR.addLine(to: CGPoint(x: 6, y: -6))
                ctx.stroke(browR, with: .color(Color.black.opacity(0.7)), lineWidth: 2.5)
            }

        case .success:
            // Happy ^^ eyes
            var eyeL = Path()
            eyeL.move(to: CGPoint(x: -18, y: 0))
            eyeL.addQuadCurve(to: CGPoint(x: -6, y: 0), control: CGPoint(x: -12, y: -8))
            ctx.stroke(eyeL, with: .color(Color.black.opacity(0.8)), lineWidth: 2.5)
            var eyeR = Path()
            eyeR.move(to: CGPoint(x: 6, y: 0))
            eyeR.addQuadCurve(to: CGPoint(x: 18, y: 0), control: CGPoint(x: 12, y: -8))
            ctx.stroke(eyeR, with: .color(Color.black.opacity(0.8)), lineWidth: 2.5)
            // Smile
            var mouth = Path()
            mouth.move(to: CGPoint(x: -7, y: 12))
            mouth.addQuadCurve(to: CGPoint(x: 7, y: 12), control: CGPoint(x: 0, y: 20))
            ctx.stroke(mouth, with: .color(Color.black.opacity(0.7)), lineWidth: 2)

        default:
            // Normal dot eyes with blink
            let isBlinking = (state == .idle && frame % 6 == 0)
            let eyeH: CGFloat = isBlinking ? 2 : 10
            let eyeY: CGFloat = isBlinking ? -1 : -5

            for xOff in [-12.0, 12.0] {
                let eyeRect = CGRect(x: xOff - 5, y: eyeY, width: 10, height: eyeH)
                ctx.fill(Path(ellipseIn: eyeRect), with: .color(.white))
                if !isBlinking {
                    // Pupil
                    let pupil = CGRect(x: xOff - 3, y: eyeY + 2, width: 6, height: 6)
                    ctx.fill(Path(ellipseIn: pupil), with: .color(Color(white: 0.15)))
                    // Highlight
                    ctx.fill(Path(ellipseIn: CGRect(x: xOff - 1, y: eyeY + 2, width: 3, height: 3)), with: .color(.white))
                }
            }

            // Cheek blush
            ctx.fill(Path(ellipseIn: CGRect(x: -24, y: 5, width: 10, height: 6)), with: .color(Color.red.opacity(0.2)))
            ctx.fill(Path(ellipseIn: CGRect(x: 14, y: 5, width: 10, height: 6)), with: .color(Color.red.opacity(0.2)))

            // Small smile
            var mouth = Path()
            mouth.move(to: CGPoint(x: -5, y: 13))
            mouth.addQuadCurve(to: CGPoint(x: 5, y: 13), control: CGPoint(x: 0, y: 17))
            ctx.stroke(mouth, with: .color(Color.black.opacity(0.6)), lineWidth: 1.8)
        }
    }

    private static func drawXEye(in ctx: inout GraphicsContext, center: CGPoint, size: CGFloat) {
        let s = size / 2
        var p = Path()
        p.move(to: CGPoint(x: center.x - s, y: center.y - s))
        p.addLine(to: CGPoint(x: center.x + s, y: center.y + s))
        p.move(to: CGPoint(x: center.x + s, y: center.y - s))
        p.addLine(to: CGPoint(x: center.x - s, y: center.y + s))
        ctx.stroke(p, with: .color(Color.black.opacity(0.8)), lineWidth: 2.5)
    }

    // MARK: Accessories

    private static func drawAccessories(in ctx: inout GraphicsContext, state: StatusMascotState, frame: Int) {
        switch state {
        case .idle:
            // Zzz particles (float upward)
            if frame % 3 == 0 || frame % 3 == 1 {
                let zTexts = ["z", "Z"]
                let offsets: [(CGFloat, CGFloat, CGFloat)] = [(-28, -30, 0.5), (-35, -42, 0.7)]
                for i in 0..<min(zTexts.count, offsets.count) {
                    let (x, y, opacity) = offsets[i]
                    let yOff = -CGFloat(frame % 4) * 2
                    ctx.draw(
                        Text(zTexts[i]).font(.system(size: 10, weight: .bold)).foregroundColor(Color.primary.opacity(opacity)),
                        at: CGPoint(x: x, y: y + yOff)
                    )
                }
            }

        case .busy:
            // Small laptop
            let laptopBase = Path(roundedRect: CGRect(x: -14, y: 16, width: 28, height: 3), cornerRadius: 1)
            ctx.fill(laptopBase, with: .color(Color(white: 0.65)))
            var screen = Path()
            screen.addRoundedRect(in: CGRect(x: -11, y: 4, width: 22, height: 14), cornerSize: CGSize(width: 2, height: 2))
            ctx.fill(screen, with: .color(Color(white: 0.8)))
            ctx.stroke(screen, with: .color(Color(white: 0.5)), lineWidth: 1)
            // Screen glow dot
            let glowPhase = frame % 4
            if glowPhase < 3 {
                ctx.fill(Path(ellipseIn: CGRect(x: -2, y: 8, width: 4, height: 4)), with: .color(Color.cyan.opacity(0.6)))
            }

        case .fixing:
            // Hard hat
            var hat = Path()
            hat.move(to: CGPoint(x: -22, y: -16))
            hat.addQuadCurve(to: CGPoint(x: 22, y: -16), control: CGPoint(x: 0, y: -38))
            hat.addLine(to: CGPoint(x: -22, y: -16))
            ctx.fill(hat, with: .color(.yellow))
            // Hat brim
            let brim = Path(roundedRect: CGRect(x: -25, y: -18, width: 50, height: 5), cornerRadius: 2)
            ctx.fill(brim, with: .color(Color.yellow.opacity(0.9)))

        case .success:
            // Sparkle stars
            let t = Double(frame) * 0.8
            for i in 0..<4 {
                let angle = t + Double(i) * .pi / 2.0
                let r: CGFloat = 38 + CGFloat(i % 2) * 8
                let x = cos(angle) * r
                let y = sin(angle) * r - 10
                drawSparkle(in: &ctx, at: CGPoint(x: x, y: y), size: 5)
            }

        case .error:
            // Smoke puffs rising
            let puffPositions: [(CGFloat, CGFloat)] = [(-20, -35), (15, -40), (-5, -45)]
            for (i, (px, py)) in puffPositions.enumerated() {
                let yOff = -CGFloat(frame % 6) * 2
                let alpha = max(0, 0.4 - Double(frame % 6) * 0.06)
                let size: CGFloat = 8 + CGFloat(i) * 2
                ctx.fill(
                    Path(ellipseIn: CGRect(x: px - size/2, y: py + yOff - size/2, width: size, height: size)),
                    with: .color(Color.gray.opacity(alpha))
                )
            }

        case .restarting:
            // Spinning motion arcs
            let angle = Double(frame) * .pi / 4.0
            for i in 0..<3 {
                let a = angle + Double(i) * .pi * 2.0 / 3.0
                var arc = Path()
                arc.addArc(
                    center: CGPoint(x: 0, y: 5),
                    radius: 40,
                    startAngle: .radians(a),
                    endAngle: .radians(a + 0.5),
                    clockwise: false
                )
                ctx.stroke(arc, with: .color(state.tint.opacity(0.5)), lineWidth: 2)
            }

        case .failed:
            break
        }
    }

    private static func drawSparkle(in ctx: inout GraphicsContext, at center: CGPoint, size: CGFloat) {
        // 4-point star sparkle
        var p = Path()
        p.move(to: CGPoint(x: center.x, y: center.y - size))
        p.addLine(to: CGPoint(x: center.x + size * 0.3, y: center.y - size * 0.3))
        p.addLine(to: CGPoint(x: center.x + size, y: center.y))
        p.addLine(to: CGPoint(x: center.x + size * 0.3, y: center.y + size * 0.3))
        p.addLine(to: CGPoint(x: center.x, y: center.y + size))
        p.addLine(to: CGPoint(x: center.x - size * 0.3, y: center.y + size * 0.3))
        p.addLine(to: CGPoint(x: center.x - size, y: center.y))
        p.addLine(to: CGPoint(x: center.x - size * 0.3, y: center.y - size * 0.3))
        p.closeSubpath()
        ctx.fill(p, with: .color(.yellow))
    }
}

// MARK: - Menu Bar Icon Renderer (Front-Facing Chibi Head Silhouette)

private enum LobsterMenuIconRenderer {

    static func image(state: StatusMascotState, tick: Int) -> NSImage {
        let w: CGFloat = 20
        let h: CGFloat = 18
        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.set()
        NSRect(origin: .zero, size: NSSize(width: w, height: h)).fill()

        // Effective frame speed per state
        let frame: Int
        switch state {
        case .idle:       frame = tick / 8
        case .busy:       frame = tick
        case .fixing:     frame = tick / 2
        case .error:      frame = tick
        case .restarting: frame = tick / 3
        case .success:    frame = tick / 4
        case .failed:     frame = 0
        }

        NSColor.black.set()

        let cx = w / 2
        // Note: AppKit y-axis is bottom-up. cy is vertical center of the head.
        let baseY: CGFloat = 5.0 // head center baseline

        // Per-state vertical offset
        let yOff: CGFloat = {
            switch state {
            case .idle: return CGFloat(sin(Double(frame) * .pi / 4.0) * 0.4)
            case .busy: return (frame % 2 == 0) ? 1.0 : -0.5
            case .error: return CGFloat.random(in: -1.5...1.5)
            default: return 0
            }
        }()
        let cy = baseY + yOff

        // --- Head (round) ---
        let headR: CGFloat = 6.0
        NSBezierPath(ovalIn: NSRect(x: cx - headR, y: cy - headR, width: headR * 2, height: headR * 2)).fill()

        // --- Antennae (curving upward, symmetric) ---
        let antSway: CGFloat = {
            switch state {
            case .busy: return (frame % 2 == 0) ? -1.0 : 1.0
            case .error: return CGFloat.random(in: -1.5...1.5)
            case .failed: return 0 // droopy handled separately
            default: return CGFloat(sin(Double(frame) * .pi / 3.0) * 0.6)
            }
        }()

        if state == .failed {
            // Droopy antennae (curve outward and down)
            let ant = NSBezierPath()
            ant.lineWidth = 1.2
            ant.move(to: NSPoint(x: cx - 3, y: cy + headR - 1))
            ant.curve(to: NSPoint(x: cx - 8, y: cy + headR - 2),
                      controlPoint1: NSPoint(x: cx - 5, y: cy + headR + 1),
                      controlPoint2: NSPoint(x: cx - 7, y: cy + headR))
            ant.move(to: NSPoint(x: cx + 3, y: cy + headR - 1))
            ant.curve(to: NSPoint(x: cx + 8, y: cy + headR - 2),
                      controlPoint1: NSPoint(x: cx + 5, y: cy + headR + 1),
                      controlPoint2: NSPoint(x: cx + 7, y: cy + headR))
            ant.stroke()
        } else {
            let ant = NSBezierPath()
            ant.lineWidth = 1.2
            // Left antenna
            ant.move(to: NSPoint(x: cx - 3, y: cy + headR - 1))
            ant.curve(to: NSPoint(x: cx - 7 + antSway, y: cy + headR + 6),
                      controlPoint1: NSPoint(x: cx - 4, y: cy + headR + 2),
                      controlPoint2: NSPoint(x: cx - 6 + antSway, y: cy + headR + 5))
            // Right antenna
            ant.move(to: NSPoint(x: cx + 3, y: cy + headR - 1))
            ant.curve(to: NSPoint(x: cx + 7 + antSway, y: cy + headR + 6),
                      controlPoint1: NSPoint(x: cx + 4, y: cy + headR + 2),
                      controlPoint2: NSPoint(x: cx + 6 + antSway, y: cy + headR + 5))
            ant.stroke()
            // Antenna tips (small dots)
            NSBezierPath(ovalIn: NSRect(x: cx - 8 + antSway, y: cy + headR + 5.5, width: 2, height: 2)).fill()
            NSBezierPath(ovalIn: NSRect(x: cx + 6 + antSway, y: cy + headR + 5.5, width: 2, height: 2)).fill()
        }

        // --- Claws (symmetric on sides, animated swing) ---
        let clawSwing: CGFloat = {
            switch state {
            case .busy: return CGFloat(sin(Double(frame) * .pi / 2.0)) * 2.5
            case .fixing: return CGFloat(sin(Double(frame) * .pi / 2.0)) * 1.5
            case .error: return 2.0 // wide open
            case .success: return 1.5 // raised
            default: return CGFloat(sin(Double(frame) * 0.3)) * 0.5
            }
        }()

        let clawSize: CGFloat = 3.5
        for side: CGFloat in [-1, 1] {
            let clawCx = cx + side * (headR + 3)
            let clawCy = cy + clawSwing * side * 0.3

            // Arm stub connecting head to claw
            let arm = NSBezierPath()
            arm.lineWidth = 2.0
            arm.move(to: NSPoint(x: cx + side * headR, y: cy))
            arm.line(to: NSPoint(x: clawCx - side * clawSize * 0.3, y: clawCy))
            arm.stroke()

            // Pincer: two small ovals
            let gap: CGFloat = 0.8 + abs(clawSwing) * 0.15
            NSBezierPath(ovalIn: NSRect(x: clawCx - clawSize/2, y: clawCy + gap, width: clawSize, height: clawSize * 0.7)).fill()
            NSBezierPath(ovalIn: NSRect(x: clawCx - clawSize/2, y: clawCy - gap - clawSize * 0.7, width: clawSize, height: clawSize * 0.7)).fill()
        }

        // --- State-specific indicators ---
        switch state {
        case .error:
            // Exclamation mark above head
            let ep = NSBezierPath()
            ep.lineWidth = 1.5
            ep.move(to: NSPoint(x: cx, y: cy + headR + 7))
            ep.line(to: NSPoint(x: cx, y: cy + headR + 10))
            ep.stroke()
            NSBezierPath(ovalIn: NSRect(x: cx - 0.7, y: cy + headR + 5.5, width: 1.4, height: 1.4)).fill()

        case .success:
            // Small sparkle
            if frame % 3 != 0 {
                let sp = NSBezierPath()
                sp.lineWidth = 0.8
                let sx = cx + 8
                let sy = cy + headR + 4
                sp.move(to: NSPoint(x: sx, y: sy - 2)); sp.line(to: NSPoint(x: sx, y: sy + 2))
                sp.move(to: NSPoint(x: sx - 2, y: sy)); sp.line(to: NSPoint(x: sx + 2, y: sy))
                sp.stroke()
            }

        case .restarting:
            // Small circular arrow
            let arc = NSBezierPath()
            arc.lineWidth = 0.8
            arc.appendArc(withCenter: NSPoint(x: cx, y: cy + headR + 5),
                          radius: 2.0,
                          startAngle: CGFloat(Double(frame % 8) * 45),
                          endAngle: CGFloat(Double(frame % 8) * 45 + 270))
            arc.stroke()

        case .fixing:
            // Tiny wrench near right claw
            let wp = NSBezierPath()
            wp.lineWidth = 1.0
            let wy = cy + ((frame % 4 < 2) ? 2.0 : -1.0)
            wp.move(to: NSPoint(x: cx + headR + 5, y: wy))
            wp.line(to: NSPoint(x: cx + headR + 8, y: wy + 1.5))
            wp.stroke()

        default:
            break
        }

        image.isTemplate = true
        return image
    }
}
