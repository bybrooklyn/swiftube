import SwiftUI

/// The guide's glyphs, drawn as paths.
///
/// SF Symbols do not have these. YouTube's guide uses its own icon set — the
/// Shorts mark, the Music ring, the two-layer Library stack, the controller —
/// and substituting the nearest SF Symbol (`play.rectangle.on.rectangle` for
/// Shorts, `music.note` for Music, `rectangle.stack` for Library) is the single
/// thing that kept this rail reading as "not YouTube" however carefully the
/// metrics were tuned. The shapes below were traced from the real client.
///
/// Everything is drawn on a **24×24 grid** with a **3-unit stroke**, both
/// measured off a 1920×1080 capture where the glyph box is 27px and its strokes
/// are ~3.5px (27 × 3/24 = 3.4).
///
/// One `Canvas` per icon rather than a stack of `Shape` views: an icon is a
/// dozen subpaths, and as views that is a dozen nodes each with its own layout
/// and layer, times fourteen rows.
enum GuideGlyph {
    case search, home, shorts, subscriptions, library, music
    case gaming, live, news, podcasts, sports, settings
}

struct GuideIcon: View {

    let glyph: GuideGlyph
    /// The current section's glyph is filled; every other one is an outline.
    /// This is the real client's behaviour and it is load-bearing — with every
    /// icon an outline, nothing in the collapsed rail says where you are.
    let isCurrent: Bool
    let size: CGFloat
    let tint: Color
    /// What sits behind the glyph. Details knocked out of a filled silhouette
    /// (the door in the house, the play triangle in a filled tile) are painted
    /// in this, so they read as holes.
    let background: Color

    var body: some View {
        Canvas { context, canvasSize in
            context.scaleBy(x: canvasSize.width / 24, y: canvasSize.height / 24)
            Self.draw(glyph, filled: isCurrent, in: &context, tint: tint, background: background)
        }
        .frame(width: size, height: size)
        // The strokes are hairline-thin geometry scaled up; without this the
        // canvas rasterises at the frame size and the diagonals crawl.
        .drawingGroup(opaque: false)
    }

    private static let stroke = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
    private static let thinStroke = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)

    // MARK: - Drawing

    private static func draw(_ glyph: GuideGlyph,
                             filled: Bool,
                             in context: inout GraphicsContext,
                             tint: Color,
                             background: Color) {
        let ink = GraphicsContext.Shading.color(tint)
        let hole = GraphicsContext.Shading.color(background)

        /// Outline when idle, solid when current — with `details` knocked back
        /// out in the background colour so a filled tile still shows its play
        /// triangle.
        func body(_ outline: Path, details: [Path] = []) {
            if filled {
                context.fill(outline, with: ink)
                for detail in details { context.fill(detail, with: hole) }
            } else {
                context.stroke(outline, with: ink, style: stroke)
                for detail in details { context.fill(detail, with: ink) }
            }
        }

        switch glyph {
        case .search:
            // Never a "current" section — it opens the search surface — so this
            // one is always the outline.
            context.stroke(Path(ellipseIn: CGRect(x: 4.2, y: 4.2, width: 12.6, height: 12.6)),
                           with: ink, style: stroke)
            var handle = Path()
            handle.move(to: CGPoint(x: 15.6, y: 15.6))
            handle.addLine(to: CGPoint(x: 20.4, y: 20.4))
            context.stroke(handle, with: ink, style: stroke)

        case .home:
            var house = Path()
            house.move(to: CGPoint(x: 2.6, y: 11.4))
            house.addLine(to: CGPoint(x: 12, y: 3.2))
            house.addLine(to: CGPoint(x: 21.4, y: 11.4))
            house.addLine(to: CGPoint(x: 21.4, y: 20.8))
            house.addLine(to: CGPoint(x: 2.6, y: 20.8))
            house.closeSubpath()
            let door = Path(roundedRect: CGRect(x: 9.6, y: 14.6, width: 4.8, height: 6.2),
                            cornerRadius: 0.6)
            // The door is a hole in the solid house and simply absent from the
            // outline, which is how the real pair of states is drawn.
            body(house, details: filled ? [door] : [])

        case .shorts:
            // Two identical rounded rectangles at the same tilt, offset along
            // the diagonal — that is the whole construction of the Shorts mark.
            // Filling the union (non-zero winding) and then filling an inset
            // copy in the background colour gives a seamless outline; stroking
            // both would draw the seam where they overlap.
            let outer = shortsSilhouette(inset: 0)
            let inner = shortsSilhouette(inset: 3)
            let play = playTriangle(x: 10.0, y: 8.6, height: 6.8, width: 5.6)
            if filled {
                context.fill(outer, with: ink)
                context.fill(play, with: hole)
            } else {
                context.fill(outer, with: ink)
                context.fill(inner, with: hole)
                context.fill(play, with: ink)
            }

        case .subscriptions:
            // A tile with a play triangle, and the lid of the tile behind it.
            let lid = Path(roundedRect: CGRect(x: 5.4, y: 2.8, width: 13.2, height: 2.2),
                           cornerRadius: 1.1)
            context.fill(lid, with: ink)
            let tile = Path(roundedRect: CGRect(x: 2.6, y: 6.4, width: 18.8, height: 14.4),
                            cornerRadius: 2.6)
            body(tile, details: [playTriangle(x: 10.2, y: 10.1, height: 7, width: 6)])

        case .library:
            // Two tiles stacked back-left, the front one carrying the play mark.
            let front = CGRect(x: 8, y: 5.6, width: 13.4, height: 13.4)
            let back = Path(roundedRect: front.offsetBy(dx: -5, dy: 2.6).insetBy(dx: 0, dy: 1.4),
                            cornerRadius: 2.2)
            context.stroke(back, with: ink, style: thinStroke)
            // Knocked out so the tile behind does not show through the front one.
            context.fill(Path(roundedRect: front.insetBy(dx: -1, dy: -1), cornerRadius: 2.8), with: hole)
            body(Path(roundedRect: front, cornerRadius: 2.4),
                 details: [playTriangle(x: 12.1, y: 9.1, height: 6.4, width: 5.4)])

        case .music:
            // The YouTube Music mark: a ring, an inner ring, and a play triangle.
            let ring = Path(ellipseIn: CGRect(x: 2.2, y: 2.2, width: 19.6, height: 19.6))
            let inner = Path(ellipseIn: CGRect(x: 7.4, y: 7.4, width: 9.2, height: 9.2))
            if filled {
                context.fill(ring, with: ink)
                context.fill(inner, with: hole)
                context.fill(playTriangle(x: 10.2, y: 9.4, height: 5.2, width: 4.4), with: ink)
            } else {
                context.stroke(ring, with: ink, style: stroke)
                context.stroke(inner, with: ink, style: thinStroke)
                context.fill(playTriangle(x: 10.2, y: 9.4, height: 5.2, width: 4.4), with: ink)
            }

        case .gaming:
            // A heart, which is what the Gaming mark actually is — a rounded
            // pad with a flat top reads as a visor.
            var pad = Path()
            pad.move(to: CGPoint(x: 12, y: 20.6))
            pad.addCurve(to: CGPoint(x: 2.4, y: 10.4),
                         control1: CGPoint(x: 8.4, y: 17.8), control2: CGPoint(x: 2.4, y: 14.4))
            pad.addCurve(to: CGPoint(x: 7.2, y: 5.4),
                         control1: CGPoint(x: 2.4, y: 7.3), control2: CGPoint(x: 4.5, y: 5.4))
            pad.addCurve(to: CGPoint(x: 12, y: 8.4),
                         control1: CGPoint(x: 9.5, y: 5.4), control2: CGPoint(x: 11, y: 6.9))
            pad.addCurve(to: CGPoint(x: 16.8, y: 5.4),
                         control1: CGPoint(x: 13, y: 6.9), control2: CGPoint(x: 14.5, y: 5.4))
            pad.addCurve(to: CGPoint(x: 21.6, y: 10.4),
                         control1: CGPoint(x: 19.5, y: 5.4), control2: CGPoint(x: 21.6, y: 7.3))
            pad.addCurve(to: CGPoint(x: 12, y: 20.6),
                         control1: CGPoint(x: 21.6, y: 14.4), control2: CGPoint(x: 15.6, y: 17.8))
            pad.closeSubpath()

            var dpad = Path()
            dpad.move(to: CGPoint(x: 6.1, y: 11.4)); dpad.addLine(to: CGPoint(x: 10.3, y: 11.4))
            dpad.move(to: CGPoint(x: 8.2, y: 9.3));  dpad.addLine(to: CGPoint(x: 8.2, y: 13.5))
            let buttons = [CGRect(x: 13.7, y: 9.1, width: 2.5, height: 2.5),
                           CGRect(x: 16.4, y: 11.6, width: 2.5, height: 2.5)]

            if filled {
                context.fill(pad, with: ink)
                context.stroke(dpad, with: hole, style: thinStroke)
                for rect in buttons { context.fill(Path(ellipseIn: rect), with: hole) }
            } else {
                context.stroke(pad, with: ink, style: stroke)
                context.stroke(dpad, with: ink, style: thinStroke)
                for rect in buttons { context.fill(Path(ellipseIn: rect), with: ink) }
            }

        case .live:
            context.fill(Path(ellipseIn: CGRect(x: 9.9, y: 9.9, width: 4.2, height: 4.2)), with: ink)
            // Two arcs a side, opening outwards — the broadcast mark.
            for radius in [CGFloat(5.6), 8.8] {
                for mirrored in [false, true] {
                    var arc = Path()
                    let centre = CGPoint(x: 12, y: 12)
                    let sweep: (start: Angle, end: Angle) = mirrored
                        ? (.degrees(140), .degrees(220))
                        : (.degrees(-40), .degrees(40))
                    arc.addArc(center: centre, radius: radius,
                               startAngle: sweep.start, endAngle: sweep.end, clockwise: false)
                    context.stroke(arc, with: ink, style: thinStroke)
                }
            }

        case .news:
            let sheet = Path(roundedRect: CGRect(x: 2.4, y: 4.4, width: 19.2, height: 15.2),
                             cornerRadius: 2.2)
            let masthead = Path(roundedRect: CGRect(x: 5.2, y: 7.2, width: 13.6, height: 2.6),
                                cornerRadius: 0.8)
            let block = Path(roundedRect: CGRect(x: 5.2, y: 12, width: 5.2, height: 4.4),
                             cornerRadius: 0.7)
            let lineA = Path(roundedRect: CGRect(x: 12.2, y: 12.2, width: 6.6, height: 1.7),
                             cornerRadius: 0.85)
            let lineB = Path(roundedRect: CGRect(x: 12.2, y: 14.9, width: 6.6, height: 1.7),
                             cornerRadius: 0.85)
            body(sheet, details: [masthead, block, lineA, lineB])

        case .podcasts:
            // A microphone inside a ring that opens at the bottom. Sweeping
            // from 140° through 400° with y pointing down covers left, top and
            // right and leaves the gap under the stand.
            var ring = Path()
            ring.addArc(center: CGPoint(x: 12, y: 11.4), radius: 8.2,
                        startAngle: .degrees(148), endAngle: .degrees(392), clockwise: false)
            context.stroke(ring, with: ink, style: stroke)

            // Always solid: an outlined capsule inside an outlined ring reads as
            // a letter, not a microphone.
            context.fill(Path(roundedRect: CGRect(x: 9.9, y: 4.8, width: 4.2, height: 8.6),
                              cornerRadius: 2.1),
                         with: ink)
            var stand = Path()
            stand.move(to: CGPoint(x: 12, y: 14.4))
            stand.addLine(to: CGPoint(x: 12, y: 19.6))
            stand.move(to: CGPoint(x: 9.4, y: 20.6))
            stand.addLine(to: CGPoint(x: 14.6, y: 20.6))
            context.stroke(stand, with: ink, style: thinStroke)

        case .sports:
            var cup = Path()
            cup.move(to: CGPoint(x: 6.4, y: 3.6))
            cup.addLine(to: CGPoint(x: 17.6, y: 3.6))
            cup.addLine(to: CGPoint(x: 17.6, y: 9.4))
            cup.addCurve(to: CGPoint(x: 12, y: 15.4),
                         control1: CGPoint(x: 17.6, y: 12.8), control2: CGPoint(x: 15.2, y: 15.4))
            cup.addCurve(to: CGPoint(x: 6.4, y: 9.4),
                         control1: CGPoint(x: 8.8, y: 15.4), control2: CGPoint(x: 6.4, y: 12.8))
            cup.closeSubpath()
            var handles = Path()
            handles.move(to: CGPoint(x: 6.4, y: 5.4))
            handles.addCurve(to: CGPoint(x: 6.4, y: 11),
                             control1: CGPoint(x: 3, y: 5.4), control2: CGPoint(x: 3, y: 11))
            handles.move(to: CGPoint(x: 17.6, y: 5.4))
            handles.addCurve(to: CGPoint(x: 17.6, y: 11),
                             control1: CGPoint(x: 21, y: 5.4), control2: CGPoint(x: 21, y: 11))
            var stem = Path()
            stem.move(to: CGPoint(x: 12, y: 15.4)); stem.addLine(to: CGPoint(x: 12, y: 18.4))
            stem.move(to: CGPoint(x: 7.8, y: 20.4)); stem.addLine(to: CGPoint(x: 16.2, y: 20.4))
            context.stroke(handles, with: ink, style: thinStroke)
            context.stroke(stem, with: ink, style: stroke)
            body(cup)

        case .settings:
            // A gear: a ring with eight teeth, and a hub.
            var teeth = Path()
            for index in 0..<8 {
                let angle = Double(index) / 8 * 2 * .pi
                let tooth = CGRect(x: -1.7, y: -10.6, width: 3.4, height: 4.4)
                var path = Path(roundedRect: tooth, cornerRadius: 1)
                path = path.applying(CGAffineTransform(rotationAngle: angle)
                    .concatenating(CGAffineTransform(translationX: 12, y: 12)))
                teeth.addPath(path)
            }
            context.fill(teeth, with: ink)
            context.stroke(Path(ellipseIn: CGRect(x: 4.4, y: 4.4, width: 15.2, height: 15.2)),
                           with: ink, style: stroke)
            context.fill(Path(ellipseIn: CGRect(x: 9.4, y: 9.4, width: 5.2, height: 5.2)),
                         with: filled ? ink : hole)
        }
    }

    // MARK: - Shared geometry

    private static func playTriangle(x: CGFloat, y: CGFloat,
                                     height: CGFloat, width: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x, y: y + height))
        path.addLine(to: CGPoint(x: x + width, y: y + height / 2))
        path.closeSubpath()
        return path
    }

    /// The Shorts mark: two rounded rectangles at the same tilt, offset along
    /// the diagonal. `inset` shrinks each one to produce the inner knock-out.
    private static func shortsSilhouette(inset: CGFloat) -> Path {
        // Offset **perpendicular** to the tilt. Offsetting along the long axis
        // instead just elongates the pair into a peanut — which is what the
        // first attempt drew, and nothing like the mark.
        // The capsule's long axis after a clockwise `tilt` is (sin, -cos), so
        // the perpendicular is (cos, sin). Using (cos, -sin) is not
        // perpendicular at all — it shears the pair into a blob, which is what
        // the previous attempt drew.
        let tilt = 28.0 * .pi / 180
        let perpendicular = CGPoint(x: cos(tilt), y: sin(tilt))
        let spread: CGFloat = 3.0

        var path = Path()
        for direction in [CGFloat(1), -1] {
            let centre = CGPoint(x: 12 + perpendicular.x * spread * direction,
                                 y: 12 + perpendicular.y * spread * direction)
            let rect = CGRect(x: -5.5 + inset / 2, y: -8.8 + inset / 2,
                              width: 11 - inset, height: 17.6 - inset)
            // Fully rounded ends: the lobes are capsules, not rounded rects.
            var lobe = Path(roundedRect: rect, cornerRadius: max(5.5 - inset / 2, 0.4))
            lobe = lobe.applying(CGAffineTransform(rotationAngle: tilt)
                .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y)))
            path.addPath(lobe)
        }
        return path
    }
}
