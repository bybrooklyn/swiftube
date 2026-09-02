import AppKit
import CoreImage
import SwiftUI

/// A wash of the focused thumbnail's colour behind the shelves.
///
/// Gives the glass surfaces something to refract, and ties the page to what
/// is under focus the way the real client's ambient mode does behind a
/// playing video. Sampled from the thumbnail already in `ThumbnailLoader`'s
/// cache, so it costs one tiny CoreImage reduction per focus change.
struct AmbientBackdrop: View {

    let url: URL?

    @Environment(\.viewportSize) private var viewport
    @State private var color: Color = Theme.canvas

    var body: some View {
        // Quiet on purpose: a tint the shelves sit in, not a light show. The
        // content should lead; the wash is what the glass has to refract.
        RadialGradient(colors: [color.opacity(0.38), Theme.canvas],
                       center: .init(x: 0.35, y: 0.35),
                       startRadius: 0,
                       endRadius: viewport.width * 0.8)
            .ignoresSafeArea()
            .animation(Theme.travel, value: color)
            .task(id: url) {
                guard let url else { color = Theme.canvas; return }
                // Same size the cards decode at, so this is nearly always a hit.
                var image = ThumbnailLoader.cachedImage(for: url, maxPixel: 720)
                if image == nil { image = await ThumbnailLoader.shared.image(for: url, maxPixel: 720) }
                guard let image, !Task.isCancelled else { return }
                let sampled = await Task.detached(priority: .utility) { Self.averageColor(of: image) }.value
                if !Task.isCancelled, let sampled { color = sampled }
            }
    }

    /// Mean colour of the whole image, via CIAreaAverage — one pixel out.
    nonisolated private static func averageColor(of image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return Color(.sRGB,
                     red: Double(pixel[0]) / 255,
                     green: Double(pixel[1]) / 255,
                     blue: Double(pixel[2]) / 255,
                     opacity: 1)
    }
}
