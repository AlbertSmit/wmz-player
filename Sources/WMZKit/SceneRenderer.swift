import AppKit
import CoreGraphics
import CoreText

/// Draws a parsed skin. The context must be in "screen" coordinates: origin at
/// the top-left, y growing downwards, one unit per skin pixel.
public final class SceneRenderer {
    public let scene: Scene
    private let assets: SkinAssets
    private var artworkCache: [String: CGImage] = [:]
    private var textCache: [String: CGImage] = [:]

    public init(scene: Scene) {
        self.scene = scene
        self.assets = scene.assets
    }

    public func draw(in ctx: CGContext, state: PlayerState, hovered: SceneNode? = nil, pressed: SceneNode? = nil) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.setAllowsAntialiasing(true)

        drawBackground(of: scene.view, in: scene.root.frame, ctx: ctx)
        drawChildren(of: scene.root, state: state, hovered: hovered, pressed: pressed, ctx: ctx)

        ctx.restoreGState()
    }

    // MARK: - Tree

    private func drawChildren(of node: SceneNode, state: PlayerState,
                              hovered: SceneNode?, pressed: SceneNode?, ctx: CGContext) {
        let ordered = node.children.enumerated().sorted { lhs, rhs in
            let l = lhs.element.zIndex, r = rhs.element.zIndex
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map { $0.element }

        for child in ordered {
            guard !child.hidden, ActionResolver.isVisible(child.element, state: state) else { continue }
            draw(node: child, state: state, hovered: hovered, pressed: pressed, ctx: ctx)
        }
    }

    private func draw(node: SceneNode, state: PlayerState,
                      hovered: SceneNode?, pressed: SceneNode?, ctx: CGContext) {
        switch node.kind {
        case .view, .subview:
            ctx.saveGState()
            ctx.clip(to: node.frame)
            drawBackground(of: node.element, in: node.frame, ctx: ctx)
            drawChildren(of: node, state: state, hovered: hovered, pressed: pressed, ctx: ctx)
            ctx.restoreGState()

        case .button:
            drawButton(node, state: state, hovered: hovered, pressed: pressed, ctx: ctx)

        case .group:
            drawGroup(node, hovered: hovered, pressed: pressed, ctx: ctx)

        case .slider:
            drawSlider(node, state: state, hovered: hovered, ctx: ctx)

        case .text:
            drawText(node, state: state, ctx: ctx)

        case .video:
            drawArtwork(node, state: state, ctx: ctx)

        case .other:
            break
        }
    }

    // MARK: - Backgrounds

    /// Artwork is stored bottom-up, while the scene uses a y-down coordinate
    /// system. Flip locally around the destination rect so images stay upright.
    private func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private func drawBackground(of element: Element, in frame: CGRect, ctx: CGContext) {
        if let colour = RGB(hex: element["backgroundcolor"]) {
            ctx.setFillColor(colour.color)
            ctx.fill(frame)
        }
        guard let name = element["backgroundimage"],
              let image = assets.keyed(named: name, colours: element.keyColours) else { return }
        if element["backgroundtiled"]?.lowercased() == "true" {
            ctx.saveGState()
            ctx.clip(to: frame)
            let tile = CGSize(width: image.width, height: image.height)
            var y = frame.minY
            while y < frame.maxY {
                var x = frame.minX
                while x < frame.maxX {
                    drawImage(image, in: CGRect(origin: CGPoint(x: x, y: y), size: tile), ctx: ctx)
                    x += tile.width
                }
                y += tile.height
            }
            ctx.restoreGState()
        } else {
            drawImage(image, in: frame, ctx: ctx)
        }
    }

    // MARK: - Controls

    private func drawButton(_ node: SceneNode, state: PlayerState,
                            hovered: SceneNode?, pressed: SceneNode?, ctx: CGContext) {
        var name = node.element["image"]
        if pressed === node, let down = node.element["downimage"] { name = down }
        else if hovered === node, let hover = node.element["hoverimage"] { name = hover }

        guard let image = assets.keyed(named: name, colours: node.element.keyColours) else { return }

        var frame = node.frame
        if let offset = digitOffset(for: node, state: state) {
            frame.origin.x += offset
        }

        let blend = node.element.int("alphablend").map { CGFloat($0) / 255 } ?? 1
        guard blend > 0 else { return }
        ctx.saveGState()
        ctx.setAlpha(blend)
        drawImage(image, in: frame, ctx: ctx)
        ctx.restoreGState()
    }

    /// The `time1`..`time4` controls in many skins are 10-digit strips that the
    /// script slides inside a narrow clipping subview.
    private func digitOffset(for node: SceneNode, state: PlayerState) -> CGFloat? {
        let id = node.id.lowercased()
        guard id.hasPrefix("time"), id.count == 5, let slot = Int(id.suffix(1)),
              let image = assets.size(named: node.element["image"]) else { return nil }

        let total = Int(max(state.position, 0))
        let minutes = min(total / 60, 99)
        let seconds = total % 60
        let digits = [minutes / 10, minutes % 10, seconds / 10, seconds % 10]
        guard slot >= 1, slot <= 4 else { return nil }

        let digitWidth = image.width / 10
        guard digitWidth * 10 == image.width else { return nil }
        return -CGFloat(digits[slot - 1]) * digitWidth
    }

    private func drawGroup(_ node: SceneNode, hovered: SceneNode?, pressed: SceneNode?, ctx: CGContext) {
        var name = node.element["image"]
        if pressed === node, let down = node.element["downimage"] { name = down }
        else if hovered === node, let hover = node.element["hoverimage"] { name = hover }
        guard let image = assets.keyed(named: name, colours: node.element.keyColours) else { return }
        drawImage(image, in: node.frame, ctx: ctx)
    }

    private func drawSlider(_ node: SceneNode, state: PlayerState, hovered: SceneNode?, ctx: CGContext) {
        guard let slider = node.slider else { return }
        let fraction = sliderFraction(slider, state: state)
        let index = Int((fraction * Double(max(slider.frameCount - 1, 0))).rounded())
        let name = (hovered === node ? slider.hoverImage : nil) ?? slider.image
        guard let image = assets.frame(named: name ?? slider.image,
                                       frameWidth: slider.frameWidth,
                                       index: index,
                                       frameCount: slider.frameCount,
                                       colours: node.element.keyColours) else { return }
        drawImage(image, in: node.frame, ctx: ctx)
    }

    private func sliderFraction(_ slider: SliderInfo, state: PlayerState) -> Double {
        switch slider.target {
        case .seek: return state.progress
        case .volume: return min(max(state.volume / 100, 0), 1)
        case .balance: return 0.5
        case .unknown: return 0
        }
    }

    private func drawText(_ node: SceneNode, state: PlayerState, ctx: CGContext) {
        guard let string = ActionResolver.text(for: node.element, state: state), !string.isEmpty else { return }
        let size = node.element.int("fontsize").map { CGFloat($0) } ?? 11
        let face = node.element["fontface"] ?? "Helvetica"
        let style = node.element["fontstyle"] ?? ""
        let colour = RGB(hex: node.element["foregroundcolor"]) ?? RGB(r: 255, g: 255, b: 255)
        let alignment = node.element["justification"]?.lowercased() ?? "left"

        guard let image = textImage(string, face: face, size: size, style: style,
                                    colour: colour, alignment: alignment,
                                    canvas: node.frame.size) else { return }
        drawImage(image, in: node.frame, ctx: ctx)
    }

    /// CoreText into a throwaway bitmap: avoids fighting the scene's flipped
    /// coordinate system and gives us a cacheable, pixel-exact label.
    private func textImage(_ string: String, face: String, size: CGFloat, style: String,
                           colour: RGB, alignment: String, canvas: CGSize) -> CGImage? {
        guard canvas.width > 1, canvas.height > 1, size > 1 else { return nil }
        let key = "\(string)|\(face)|\(size)|\(style)|\(colour.r),\(colour.g),\(colour.b)|\(alignment)|\(Int(canvas.width))x\(Int(canvas.height))"
        if let cached = textCache[key] { return cached }

        let scale: CGFloat = 2
        let width = Int(canvas.width * scale)
        let height = Int(canvas.height * scale)
        guard width > 0, height > 0, let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        var font = CTFontCreateWithName(face as CFString, size * scale, nil)
        var traits: CTFontSymbolicTraits = []
        if style.contains("bold") { traits.insert(.traitBold) }
        if style.contains("italic") { traits.insert(.traitItalic) }
        if !traits.isEmpty,
           let variant = CTFontCreateCopyWithSymbolicTraits(font, size * scale, nil, traits, traits) {
            font = variant
        }

        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: colour.color
        ]

        let lines = string.components(separatedBy: "\n").filter { !$0.isEmpty }
        let ascent = CTFontGetAscent(font)
        let lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
        // Bitmaps are y-up: the first line sits at the top, so its baseline is
        // high and each following line is lower. Text boxes in these skins are
        // sized generously and often partly covered by artwork, so text sits at
        // the top of its box rather than floating in the middle.
        let topMargin: CGFloat = 0
        var baseline = CGFloat(height) - topMargin - ascent

        ctx.textMatrix = .identity
        for text in lines {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            var drawLine = line
            if lineWidth > CGFloat(width), let truncated = CTLineCreateTruncatedLine(line, Double(width), .end, nil) {
                drawLine = truncated
            }
            let drawnWidth = CGFloat(CTLineGetTypographicBounds(drawLine, nil, nil, nil))
            let x: CGFloat
            switch alignment {
            case "center", "middle": x = (CGFloat(width) - drawnWidth) / 2
            case "right": x = CGFloat(width) - drawnWidth
            default: x = 0
            }
            ctx.textPosition = CGPoint(x: max(x, 0), y: baseline)
            CTLineDraw(drawLine, ctx)
            baseline -= lineHeight
        }

        let image = ctx.makeImage()
        if let image { textCache[key] = image }
        return image
    }

    private func drawArtwork(_ node: SceneNode, state: PlayerState, ctx: CGContext) {
        guard let path = state.artworkPath, let image = artwork(at: path) else { return }
        let source = CGSize(width: image.width, height: image.height)
        guard source.width > 0, source.height > 0 else { return }
        let scale = max(node.frame.width / source.width, node.frame.height / source.height)
        let drawn = CGSize(width: source.width * scale, height: source.height * scale)
        let rect = CGRect(
            x: node.frame.midX - drawn.width / 2,
            y: node.frame.midY - drawn.height / 2,
            width: drawn.width,
            height: drawn.height
        )
        ctx.saveGState()
        ctx.clip(to: node.frame)
        ctx.interpolationQuality = .high
        drawImage(image, in: rect, ctx: ctx)
        ctx.restoreGState()
    }

    private func artwork(at path: String) -> CGImage? {
        if let cached = artworkCache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        artworkCache[path] = cg
        return cg
    }
}

// MARK: - Offscreen rendering

extension SceneRenderer {
    public func image(state: PlayerState, scale: CGFloat = 2, background: RGB? = nil) -> CGImage? {
        let width = Int(scene.size.width * scale)
        let height = Int(scene.size.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.setShouldAntialias(true)
        context.interpolationQuality = .none
        if let background {
            context.setFillColor(background.color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(in: context, state: state)
        return context.makeImage()
    }
}
