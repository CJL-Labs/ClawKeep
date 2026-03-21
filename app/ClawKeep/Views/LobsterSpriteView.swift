import AppKit
import SwiftUI

struct LobsterMenuBarLabel: View {
    let state: StatusMascotState
    let tick: Int

    var body: some View {
        Image(nsImage: LobsterMenuIconRenderer.image(state: state, tick: tick))
            .renderingMode(.template)
            .interpolation(.none)
            .frame(width: 18, height: 14)
            .accessibilityLabel("ClawKeep \(state.title)")
    }
}

struct LobsterStatusBadgeView: View {
    let state: StatusMascotState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(state.tint.opacity(0.13))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(state.tint.opacity(0.45), lineWidth: 1.2)

            LobsterSpriteView(state: state, size: CGSize(width: 64, height: 38), showsBackdrop: true)
                .padding(.top, 1)
        }
        .frame(width: 78, height: 68)
    }
}

struct LobsterSpriteView: View {
    let state: StatusMascotState
    let size: CGSize
    let showsBackdrop: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
            Canvas(rendersAsynchronously: true) { context, canvasSize in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let pose = LobsterPose(state: state, t: t)
                drawLobster(in: &context, size: canvasSize, pose: pose)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private var frameInterval: TimeInterval {
        switch state {
        case .busy, .fixing, .error:
            return 1.0 / 22.0
        default:
            return 1.0 / 14.0
        }
    }

    private func drawLobster(in context: inout GraphicsContext, size: CGSize, pose: LobsterPose) {
        let shellColor = shellColor(for: state, t: pose.flash)
        let outlineColor = Color.black.opacity(0.68)
        let eyeColor = Color.white.opacity(0.96)

        context.translateBy(x: size.width * 0.5 + pose.shake, y: size.height * 0.52 + pose.bob + pose.drop)
        context.rotate(by: .degrees(pose.rotation))

        let bodyWidth = size.width * 0.52
        let bodyHeight = size.height * 0.46
        let bodyRect = CGRect(
            x: -bodyWidth * 0.5,
            y: -bodyHeight * 0.5,
            width: bodyWidth,
            height: bodyHeight
        )

        if showsBackdrop {
            let glow = Path(ellipseIn: bodyRect.insetBy(dx: -bodyWidth * 0.35, dy: -bodyHeight * 0.3))
            context.fill(glow, with: .color(shellColor.opacity(0.17)))
        }

        var tail = Path()
        tail.move(to: CGPoint(x: -bodyWidth * 0.56, y: 0))
        tail.addLine(to: CGPoint(x: -bodyWidth * 0.82, y: -bodyHeight * 0.2))
        tail.addLine(to: CGPoint(x: -bodyWidth * 0.8, y: bodyHeight * 0.2))
        tail.closeSubpath()
        context.fill(tail, with: .color(shellColor.opacity(0.92)))
        context.stroke(tail, with: .color(outlineColor), lineWidth: size.width * 0.035)

        let body = Path(roundedRect: bodyRect, cornerSize: CGSize(width: bodyHeight * 0.45, height: bodyHeight * 0.45))
        context.fill(body, with: .color(shellColor))
        context.stroke(body, with: .color(outlineColor), lineWidth: size.width * 0.04)

        drawLegs(in: &context, bodyWidth: bodyWidth, bodyHeight: bodyHeight, phase: pose.legPhase, lineWidth: size.width * 0.038, color: outlineColor)

        drawClaw(in: &context, side: -1, bodyWidth: bodyWidth, bodyHeight: bodyHeight, offset: pose.clawPhase, lineWidth: size.width * 0.043, color: outlineColor, fill: shellColor)
        drawClaw(in: &context, side: 1, bodyWidth: bodyWidth, bodyHeight: bodyHeight, offset: -pose.clawPhase, lineWidth: size.width * 0.043, color: outlineColor, fill: shellColor)

        let eyeOffsetY = bodyHeight * 0.2
        let eyeX = bodyWidth * 0.2
        let eyeSize = size.width * 0.072
        let pupilHeight = pose.blink ? eyeSize * 0.22 : eyeSize * 0.55
        for sign in [-1.0, 1.0] {
            let eyeRect = CGRect(x: eyeX - eyeSize * 0.5, y: sign * eyeOffsetY - eyeSize * 0.5, width: eyeSize, height: eyeSize)
            let eye = Path(ellipseIn: eyeRect)
            context.fill(eye, with: .color(eyeColor))
            context.stroke(eye, with: .color(outlineColor), lineWidth: max(1, size.width * 0.018))

            let pupilRect = CGRect(
                x: eyeX - eyeSize * 0.11,
                y: sign * eyeOffsetY - pupilHeight * 0.5,
                width: eyeSize * 0.22,
                height: max(1, pupilHeight)
            )
            let pupil = Path(roundedRect: pupilRect, cornerRadius: pupilRect.width * 0.5)
            context.fill(pupil, with: .color(.black.opacity(0.86)))
        }
    }

    private func drawLegs(in context: inout GraphicsContext, bodyWidth: CGFloat, bodyHeight: CGFloat, phase: CGFloat, lineWidth: CGFloat, color: Color) {
        for idx in 0..<3 {
            let x = -bodyWidth * 0.22 + CGFloat(idx) * bodyWidth * 0.2
            let swing = sin(phase + CGFloat(idx) * 1.4)
            let upperY = bodyHeight * 0.45

            var top = Path()
            top.move(to: CGPoint(x: x, y: upperY))
            top.addLine(to: CGPoint(x: x + bodyWidth * 0.1, y: upperY + bodyHeight * 0.18 + swing * bodyHeight * 0.06))
            context.stroke(top, with: .color(color), lineWidth: lineWidth)

            var bottom = Path()
            bottom.move(to: CGPoint(x: x, y: -upperY))
            bottom.addLine(to: CGPoint(x: x + bodyWidth * 0.1, y: -upperY - bodyHeight * 0.18 - swing * bodyHeight * 0.06))
            context.stroke(bottom, with: .color(color), lineWidth: lineWidth)
        }
    }

    private func drawClaw(in context: inout GraphicsContext, side: CGFloat, bodyWidth: CGFloat, bodyHeight: CGFloat, offset: CGFloat, lineWidth: CGFloat, color: Color, fill: Color) {
        let baseY = side * bodyHeight * 0.24
        let armStart = CGPoint(x: bodyWidth * 0.2, y: baseY)
        let armEnd = CGPoint(
            x: bodyWidth * 0.47,
            y: baseY + side * bodyHeight * 0.26 + side * offset * bodyHeight * 0.06
        )

        var arm = Path()
        arm.move(to: armStart)
        arm.addLine(to: armEnd)
        context.stroke(arm, with: .color(color), lineWidth: lineWidth)

        let clawRadius = bodyHeight * 0.14
        let clawRect = CGRect(
            x: armEnd.x - clawRadius,
            y: armEnd.y - clawRadius,
            width: clawRadius * 2,
            height: clawRadius * 2
        )
        let claw = Path(ellipseIn: clawRect)
        context.fill(claw, with: .color(fill.opacity(0.95)))
        context.stroke(claw, with: .color(color), lineWidth: lineWidth * 0.85)
    }

    private func shellColor(for state: StatusMascotState, t: CGFloat) -> Color {
        switch state {
        case .idle:
            return Color(red: 0.88, green: 0.45, blue: 0.36)
        case .busy:
            return Color(red: 0.91, green: 0.35, blue: 0.3)
        case .restarting:
            return Color(red: 0.92, green: 0.55, blue: 0.31)
        case .error:
            return Color(red: 0.84 + 0.08 * t, green: 0.22, blue: 0.2)
        case .fixing:
            return Color(red: 0.96, green: 0.5, blue: 0.24)
        case .success:
            return Color(red: 0.96, green: 0.58, blue: 0.33)
        case .failed:
            return Color(red: 0.58, green: 0.44, blue: 0.4)
        }
    }
}

private struct LobsterPose {
    let bob: CGFloat
    let clawPhase: CGFloat
    let legPhase: CGFloat
    let rotation: Double
    let shake: CGFloat
    let drop: CGFloat
    let blink: Bool
    let flash: CGFloat

    init(state: StatusMascotState, t: TimeInterval) {
        let baseBlink = sin(t * 1.4) > 0.975
        switch state {
        case .idle:
            bob = sin(t * 2.2) * 0.6
            clawPhase = sin(t * 2.5) * 0.4
            legPhase = CGFloat(t * 4.2)
            rotation = sin(t * 1.8) * 1.4
            shake = 0
            drop = 0
            blink = baseBlink
            flash = 0
        case .busy:
            bob = sin(t * 10) * 0.9
            clawPhase = sin(t * 18) * 1.0
            legPhase = CGFloat(t * 18)
            rotation = sin(t * 9) * 2.6
            shake = sin(t * 19) * 0.6
            drop = 0
            blink = false
            flash = 0
        case .restarting:
            bob = 0
            clawPhase = sin(t * 8) * 0.7
            legPhase = CGFloat(t * 12)
            rotation = t * 240
            shake = 0
            drop = 0
            blink = false
            flash = 0
        case .error:
            bob = 0
            clawPhase = sin(t * 20) * 1.0
            legPhase = CGFloat(t * 22)
            rotation = sin(t * 18) * 4.5
            shake = sin(t * 30) * 1.8
            drop = 0
            blink = false
            flash = CGFloat(abs(sin(t * 10)))
        case .fixing:
            bob = sin(t * 11) * 0.7
            clawPhase = abs(sin(t * 16)) * 1.3
            legPhase = CGFloat(t * 16)
            rotation = sin(t * 11) * 1.9
            shake = 0
            drop = 0
            blink = false
            flash = 0
        case .success:
            bob = 0
            clawPhase = abs(sin(t * 10)) * 1.2
            legPhase = CGFloat(t * 12)
            rotation = sin(t * 8) * 3
            shake = 0
            drop = -abs(sin(t * 8)) * 2.2
            blink = false
            flash = 0
        case .failed:
            bob = sin(t * 1.5) * 0.2
            clawPhase = 0.12
            legPhase = CGFloat(t * 1.2)
            rotation = -6
            shake = 0
            drop = 1.5
            blink = true
            flash = 0
        }
    }
}

private enum LobsterMenuIconRenderer {
    static func image(state: StatusMascotState, tick: Int) -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size)
        image.lockFocusFlipped(false)
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let time = Double(tick) * 0.12
        let pose = LobsterPose(state: state, t: time)
        drawLobsterIcon(size: size, pose: pose)

        image.isTemplate = true
        return image
    }

    private static func drawLobsterIcon(size: NSSize, pose: LobsterPose) {
        let stroke = NSColor.labelColor.withAlphaComponent(0.95)
        let fill = NSColor.labelColor.withAlphaComponent(0.7)

        let centerX = size.width * 0.52 + pose.shake * 0.22
        let centerY = size.height * 0.52 + pose.bob * 0.16 + pose.drop * 0.16

        let bodyRect = NSRect(x: centerX - 4.8, y: centerY - 3.3, width: 9.6, height: 6.6)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.4, yRadius: 2.4)
        fill.setFill()
        bodyPath.fill()
        stroke.setStroke()
        bodyPath.lineWidth = 0.9
        bodyPath.stroke()

        let tailPath = NSBezierPath()
        tailPath.move(to: CGPoint(x: centerX - 4.8, y: centerY))
        tailPath.line(to: CGPoint(x: centerX - 8.4, y: centerY + 2.2))
        tailPath.line(to: CGPoint(x: centerX - 8.2, y: centerY - 2.2))
        tailPath.close()
        fill.setFill()
        tailPath.fill()
        stroke.setStroke()
        tailPath.lineWidth = 0.85
        tailPath.stroke()

        let clawOffset = pose.clawPhase * 0.45
        drawClaw(center: CGPoint(x: centerX + 5.2, y: centerY + 2.2 + clawOffset), fill: fill, stroke: stroke)
        drawClaw(center: CGPoint(x: centerX + 5.2, y: centerY - 2.2 - clawOffset), fill: fill, stroke: stroke)

        for index in 0..<3 {
            let x = centerX - 1 + CGFloat(index) * 2
            let swing = sin(pose.legPhase + CGFloat(index) * 1.1) * 0.4
            let top = NSBezierPath()
            top.move(to: CGPoint(x: x, y: centerY + 3))
            top.line(to: CGPoint(x: x + 1.3, y: centerY + 4.3 + swing))
            top.lineWidth = 0.8
            stroke.setStroke()
            top.stroke()

            let bottom = NSBezierPath()
            bottom.move(to: CGPoint(x: x, y: centerY - 3))
            bottom.line(to: CGPoint(x: x + 1.3, y: centerY - 4.3 - swing))
            bottom.lineWidth = 0.8
            stroke.setStroke()
            bottom.stroke()
        }

        let eyeTop = NSBezierPath(ovalIn: NSRect(x: centerX + 1.2, y: centerY + 1.05, width: 1.3, height: pose.blink ? 0.45 : 1.3))
        let eyeBottom = NSBezierPath(ovalIn: NSRect(x: centerX + 1.2, y: centerY - 2.35, width: 1.3, height: pose.blink ? 0.45 : 1.3))
        stroke.setFill()
        eyeTop.fill()
        eyeBottom.fill()
    }

    private static func drawClaw(center: CGPoint, fill: NSColor, stroke: NSColor) {
        let arm = NSBezierPath()
        arm.move(to: CGPoint(x: center.x - 2.5, y: center.y))
        arm.line(to: CGPoint(x: center.x - 0.8, y: center.y))
        arm.lineWidth = 0.82
        stroke.setStroke()
        arm.stroke()

        let claw = NSBezierPath(ovalIn: NSRect(x: center.x - 0.8, y: center.y - 1.1, width: 2.2, height: 2.2))
        fill.setFill()
        claw.fill()
        stroke.setStroke()
        claw.lineWidth = 0.78
        claw.stroke()
    }
}
