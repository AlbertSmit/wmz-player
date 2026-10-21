import CoreGraphics
import Foundation

public enum NodeKind {
    case view
    case subview
    case button
    case group
    case slider
    case text
    case video
    case effects
    case playlist
    case other

    init(elementName: String) {
        switch elementName {
        case "view": self = .view
        case "subview": self = .subview
        case "button": self = .button
        case "buttongroup": self = .group
        case "customslider", "slider": self = .slider
        case "text": self = .text
        case "video": self = .video
        case "effects": self = .effects
        case "playlist": self = .playlist
        default: self = .other
        }
    }
}

public struct PlaylistColumn {
    public let key: String      // name, artist, album, duration, wm/tracknumber …
    public let label: String
}

public struct PlaylistInfo {
    public let columns: [PlaylistColumn]
    public let backgroundColor: RGB?
    public let foregroundColor: RGB?
    public let playingColor: RGB?
    public let playingBackgroundColor: RGB?
    public let columnsVisible: Bool
    public let gradient: Bool
    public let fontSize: CGFloat
    public let rowHeight: CGFloat
}

public struct SliderInfo {
    public let target: SliderTarget
    public let image: String?
    public let hoverImage: String?
    public let positionImage: String?
    public let frameWidth: Int
    public let frameCount: Int

    /// Sliders are not always horizontal: many skins draw them as an arc. The
    /// principal axis of the position image's track is a good stand-in for
    /// "along the slider", whatever shape the artwork uses. Geometry is kept in
    /// the position image's pixel space.
    public let axis: CGVector
    public let centroid: CGPoint
    public let lower: Double
    public let upper: Double
    public let mapSize: CGSize

    public func fraction(at point: CGPoint, in frame: CGRect) -> Double {
        guard frame.width > 0, frame.height > 0, upper > lower else { return 0 }
        let x = Double((point.x - frame.minX) / frame.width) * Double(mapSize.width)
        let y = Double((point.y - frame.minY) / frame.height) * Double(mapSize.height)
        let t = (x - Double(centroid.x)) * Double(axis.dx) + (y - Double(centroid.y)) * Double(axis.dy)
        return min(max((t - lower) / (upper - lower), 0), 1)
    }
}

public struct GroupZone {
    public let colour: RGB
    public let action: MediaAction
}

public final class SceneNode {
    public let element: Element
    public let kind: NodeKind
    public var frame: CGRect
    public var children: [SceneNode] = []
    public var action: MediaAction?
    public var slider: SliderInfo?
    public var playlist: PlaylistInfo?
    public var sound: String?
    public var zones: [GroupZone] = []
    public var zIndex: Int = 0
    public var hidden = false

    public var id: String { element.id }
    public var keyColours: [RGB] { element.keyColours }

    init(element: Element, kind: NodeKind, frame: CGRect) {
        self.element = element
        self.kind = kind
        self.frame = frame
    }

    public var hasBehaviour: Bool {
        action != nil || slider != nil || playlist != nil || !zones.isEmpty
    }
}

public struct Scene {
    public let view: Element
    public let root: SceneNode
    public let size: CGSize
    public let assets: SkinAssets
    public let title: String
    public let background: RGB?
    public let document: SkinDocument

    public init(view: Element, root: SceneNode, size: CGSize, assets: SkinAssets,
                title: String, document: SkinDocument) {
        self.view = view
        self.root = root
        self.size = size
        self.assets = assets
        self.title = title
        self.background = RGB(hex: view["backgroundcolor"])
        self.document = document
    }
}

public enum SceneBuilder {
    public static func build(document: SkinDocument, view: Element? = nil) throws -> Scene {
        let assets = SkinAssets(root: document.rootURL)
        guard let chosen = view ?? document.primaryView else { throw SkinError.noViews }
        let builder = Builder(document: document, assets: assets, view: chosen)
        return builder.build()
    }
}

private final class Builder {
    let document: SkinDocument
    let assets: SkinAssets
    let view: Element
    var frames: [String: CGRect] = [:]
    var size: CGSize = .zero

    init(document: SkinDocument, assets: SkinAssets, view: Element) {
        self.document = document
        self.assets = assets
        self.view = view
    }

    func build() -> Scene {
        let width = Expression.number(view["width"], lookup: { _ in 0 })
            ?? assets.size(named: view["backgroundimage"])?.width
            ?? 320
        let height = Expression.number(view["height"], lookup: { _ in 0 })
            ?? assets.size(named: view["backgroundimage"])?.height
            ?? 240
        size = CGSize(width: width, height: height)

        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let root = SceneNode(element: view, kind: .view, frame: frame)
        layoutChildren(of: view, into: root, parentFrame: frame)
        return Scene(view: view, root: root, size: size, assets: assets,
                     title: document.title, document: document)
    }

    // MARK: - Layout

    private func layoutChildren(of element: Element, into node: SceneNode, parentFrame: CGRect) {
        for child in element.children {
            let kind = NodeKind(elementName: child.name)
            guard kind != .other else {
                // Containers such as <player> and <controls> only carry event
                // handlers; <playlist> would need a real list view.
                if ["subview", "buttonelement", "playelement", "pauseelement",
                    "stopelement", "prevelement", "nextelement"].contains(child.name) == false {
                    continue
                }
                continue
            }
            let childNode = layout(child, kind: kind, parentFrame: parentFrame)
            node.children.append(childNode)
        }
    }

    private func layout(_ element: Element, kind: NodeKind, parentFrame: CGRect) -> SceneNode {
        let left = CGFloat(value(element["left"], parentFrame: parentFrame) ?? 0)
        let top = CGFloat(value(element["top"], parentFrame: parentFrame) ?? 0)
        let right = CGFloat(value(element["right"], parentFrame: parentFrame) ?? 0)
        let bottom = CGFloat(value(element["bottom"], parentFrame: parentFrame) ?? 0)

        let natural = naturalSize(element, kind: kind)
        let hAlign = element["horizontalalignment"]?.lowercased() ?? ""
        let vAlign = element["verticalalignment"]?.lowercased() ?? ""

        var width = CGFloat(value(element["width"], parentFrame: parentFrame) ?? 0)
        if width == 0 {
            if hAlign == "stretch" {
                width = parentFrame.width - left - right
            } else {
                width = natural?.width ?? 0
            }
        }
        if width == 0 && (kind == .text || kind == .video) {
            width = parentFrame.width - left - right
        }
        if width == 0 && (kind == .subview || kind == .view) {
            width = parentFrame.width - left - right
        }

        var height = CGFloat(value(element["height"], parentFrame: parentFrame) ?? 0)
        if height == 0 {
            if vAlign == "stretch" {
                height = parentFrame.height - top - bottom
            } else {
                height = natural?.height ?? 0
            }
        }
        if height == 0 && (kind == .text || kind == .video) {
            height = parentFrame.height - top - bottom
        }
        if height == 0 && (kind == .subview || kind == .view) {
            height = parentFrame.height - top - bottom
        }

        var x = left
        if element["left"] == nil {
            if element["right"] != nil {
                x = parentFrame.width - right - width
            } else if hAlign == "right" {
                x = parentFrame.width - width
            } else if hAlign == "center" {
                x = (parentFrame.width - width) / 2
            }
        }
        var y = top
        if element["top"] == nil {
            if element["bottom"] != nil {
                y = parentFrame.height - bottom - height
            } else if vAlign == "bottom" {
                y = parentFrame.height - height
            } else if vAlign == "center" {
                y = (parentFrame.height - height) / 2
            }
        }

        let frame = CGRect(
            x: parentFrame.minX + x,
            y: parentFrame.minY + y,
            width: max(0, width),
            height: max(0, height)
        )

        let node = SceneNode(element: element, kind: kind, frame: frame)
        node.zIndex = element.int("zindex") ?? 0

        if !element.id.isEmpty {
            frames[element.id.lowercased()] = frame
        }

        node.sound = ActionResolver.sound(for: element)

        switch kind {
        case .button:
            node.action = ActionResolver.action(for: element)
        case .group:
            for child in element.children {
                guard let raw = child["mappingcolor"], let colour = RGB(hex: raw),
                      let action = ActionResolver.action(for: child) else { continue }
                node.zones.append(GroupZone(colour: colour, action: action))
            }
        case .slider:
            node.slider = makeSlider(element, frame: frame)
        case .playlist:
            node.playlist = makePlaylist(element)
        default:
            break
        }

        // The intro shutter is a full-window overlay that the skin's script
        // animates away on load. We render the skin at rest, without it.
        let signature = (element.id + " " + (element["backgroundimage"] ?? "")).lowercased()
        if signature.contains("shutter") && element["passthrough"]?.lowercased() == "true" {
            node.hidden = true
        }
        // `visible="false"` is evaluated at draw time (ActionResolver.isVisible):
        // the rating widget, for one, starts hidden and is revealed by state.

        if kind == .subview || kind == .view || kind == .group || kind == .button || kind == .video {
            layoutChildren(of: element, into: node, parentFrame: frame)
        }
        return node
    }

    private func makePlaylist(_ element: Element) -> PlaylistInfo {
        let raw = element["columns"] ?? "name=Name;duration=Time"
        var columns: [PlaylistColumn] = []
        for part in raw.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = pieces.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            guard !key.isEmpty else { continue }
            let label = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespaces) : key
            columns.append(PlaylistColumn(key: key, label: label))
        }
        if columns.isEmpty { columns = [PlaylistColumn(key: "name", label: "Name")] }

        let fontSize = CGFloat(element.int("fontsize") ?? 11)
        return PlaylistInfo(
            columns: columns,
            backgroundColor: RGB(hex: element["backgroundcolor"]),
            foregroundColor: RGB(hex: element["foregroundcolor"]),
            playingColor: RGB(hex: element["itemplayingcolor"]),
            playingBackgroundColor: RGB(hex: element["itemplayingbackgroundcolor"]),
            columnsVisible: element.bool("columnsvisible") ?? false,
            gradient: element["backgroundimage"]?.lowercased() == "gradient",
            fontSize: fontSize,
            rowHeight: ceil(fontSize * 1.5)
        )
    }

    private func makeSlider(_ element: Element, frame: CGRect) -> SliderInfo {
        let position = element["positionimage"]
        let mapSize = assets.size(named: position) ?? assets.size(named: element["image"])
        let imageWidth = assets.size(named: element["image"])?.width ?? 0
        let frameWidth = Int(mapSize?.width ?? frame.width)
        let frames = frameWidth > 0 ? max(1, Int(imageWidth / CGFloat(frameWidth))) : 1
        let geometry = sliderGeometry(position,
                                      keyColours: element.keyColours,
                                      sprite: element["image"],
                                      frameWidth: frameWidth,
                                      frameCount: frames)
        return SliderInfo(
            target: ActionResolver.sliderTarget(for: element),
            image: element["image"],
            hoverImage: element["hoverimage"],
            positionImage: position,
            frameWidth: frameWidth,
            frameCount: frames,
            axis: geometry.axis,
            centroid: geometry.centroid,
            lower: geometry.lower,
            upper: geometry.upper,
            mapSize: mapSize ?? frame.size
        )
    }

    /// Fits the slider's usable track from the position image: principal axis of
    /// the coloured track, its projection range, and which way the sprite fills.
    private func sliderGeometry(_ name: String?, keyColours: [RGB], sprite: String?,
                                frameWidth: Int, frameCount: Int)
        -> (axis: CGVector, centroid: CGPoint, lower: Double, upper: Double) {
        let fallback = (CGVector(dx: 1, dy: 0), CGPoint(x: 0.5, y: 0.5), 0.0, 1.0)
        guard let bitmap = assets.bitmap(named: name), bitmap.width > 2, bitmap.height > 2 else {
            return fallback
        }

        // The track is everything that is neither transparent, nor a key colour,
        // nor the flat background colour the map was exported on.
        let background = dominantColour(in: bitmap)
        var points: [(Double, Double)] = []
        points.reserveCapacity(bitmap.width * bitmap.height)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let pixel = bitmap.rgba(x: x, y: y)
                if pixel.a < 8 { continue }
                let rgb = (pixel.r, pixel.g, pixel.b)
                if let background, background.matches(rgb, tolerance: 24) { continue }
                if keyColours.contains(where: { $0.matches(rgb) }) { continue }
                points.append((Double(x) + 0.5, Double(y) + 0.5))
            }
        }
        guard points.count > 16 else { return fallback }

        let count = Double(points.count)
        let centre = (points.reduce(0) { $0 + $1.0 } / count, points.reduce(0) { $0 + $1.1 } / count)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for (x, y) in points {
            let dx = x - centre.0, dy = y - centre.1
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        var axis = (cos(angle), sin(angle))

        if frameCount > 1, frameWidth > 0, let sheet = assets.bitmap(named: sprite),
           sheet.height == bitmap.height, sheet.width >= frameWidth * frameCount,
           let growing = growthDirection(sheet, frameWidth: frameWidth, frameCount: frameCount,
                                         axis: axis, centre: centre) {
            if growing < 0 {
                axis = (-axis.0, -axis.1)
            }
        }

        var lower = Double.infinity, upper = -Double.infinity
        for (x, y) in points {
            let t = (x - centre.0) * axis.0 + (y - centre.1) * axis.1
            lower = min(lower, t)
            upper = max(upper, t)
        }
        guard upper - lower > 1 else { return fallback }
        return (CGVector(dx: axis.0, dy: axis.1), CGPoint(x: centre.0, y: centre.1), lower, upper)
    }

    private func dominantColour(in bitmap: Bitmap) -> RGB? {
        var counts: [Int: Int] = [:]
        for y in stride(from: 0, to: bitmap.height, by: 2) {
            for x in stride(from: 0, to: bitmap.width, by: 2) {
                let pixel = bitmap.rgba(x: x, y: y)
                guard pixel.a > 8 else { continue }
                let key = (pixel.r >> 3) << 10 | (pixel.g >> 3) << 5 | (pixel.b >> 3)
                counts[key, default: 0] += 1
            }
        }
        guard let (key, _) = counts.max(by: { $0.value < $1.value }) else { return nil }
        return RGB(r: ((key >> 10) & 31) << 3, g: ((key >> 5) & 31) << 3, b: (key & 31) << 3)
    }

    /// Which way the sprite fills. Consecutive frames are compared: the pixels
    /// that appear in frame N+1 but not in frame N sit at the growing end of the
    /// slider, so their projection decides the axis sign.
    private func growthDirection(_ sheet: Bitmap, frameWidth: Int, frameCount: Int,
                                 axis: (Double, Double), centre: (Double, Double)) -> Double? {
        func mask(_ frame: Int) -> [Bool] {
            var result = [Bool](repeating: false, count: frameWidth * sheet.height)
            let origin = frame * frameWidth
            for y in 0..<sheet.height {
                for x in 0..<frameWidth where origin + x < sheet.width {
                    if sheet.rgba(x: origin + x, y: y).a > 8 {
                        result[y * frameWidth + x] = true
                    }
                }
            }
            return result
        }

        var previous = mask(0)
        for frame in 1..<frameCount {
            let current = mask(frame)
            var sumX = 0.0, sumY = 0.0, added = 0, base = 0, baseX = 0.0, baseY = 0.0
            for y in 0..<sheet.height {
                for x in 0..<frameWidth {
                    let index = y * frameWidth + x
                    if previous[index] {
                        base += 1; baseX += Double(x); baseY += Double(y)
                    }
                    if current[index] && !previous[index] {
                        added += 1; sumX += Double(x); sumY += Double(y)
                    }
                }
            }
            if added >= 4 && base >= 4 {
                let dx = sumX / Double(added) - baseX / Double(base)
                let dy = sumY / Double(added) - baseY / Double(base)
                let projection = dx * axis.0 + dy * axis.1
                if abs(projection) > 0.5 { return projection }
            }
            previous = current
        }
        return nil
    }

    private func naturalSize(_ element: Element, kind: NodeKind) -> CGSize? {
        switch kind {
        case .button:
            return assets.size(named: element["image"])
        case .group:
            return assets.size(named: element["image"])
        case .slider:
            return assets.size(named: element["positionimage"]) ?? assets.size(named: element["image"])
        case .view, .subview:
            return assets.size(named: element["backgroundimage"])
        default:
            return nil
        }
    }

    private func value(_ raw: String?, parentFrame: CGRect) -> Double? {
        Expression.number(raw, lookup: lookup(parentFrame: parentFrame))
    }

    private func lookup(parentFrame: CGRect) -> (String) -> Double {
        { key in
            let parts = key.lowercased().split(separator: ".")
            guard let name = parts.first else { return 0 }
            let property = parts.count > 1 ? String(parts[1]) : "width"

            switch name {
            case "view":
                return property == "height" ? Double(self.size.height) : Double(self.size.width)
            case "parent":
                switch property {
                case "height": return Double(parentFrame.height)
                case "left", "x": return Double(parentFrame.minX)
                case "top", "y": return Double(parentFrame.minY)
                default: return Double(parentFrame.width)
                }
            case "player", "theme", "wmpprop", "math", "event":
                return 0
            default:
                guard let rect = self.frames[String(name)] else { return 0 }
                switch property {
                case "height": return Double(rect.height)
                case "left", "x": return Double(rect.minX)
                case "top", "y": return Double(rect.minY)
                default: return Double(rect.width)
                }
            }
        }
    }
}

// MARK: - Hit testing

public enum SceneHit {
    case action(MediaAction, SceneNode)
    case slider(SliderInfo, Double, SceneNode)
    case playlistRow(Int, SceneNode)
    case background
}

extension Scene {
    /// Walks the interactive nodes from the top of the z-stack down.
    public func hitTest(_ point: CGPoint, state: PlayerState) -> SceneHit {
        var nodes: [SceneNode] = []
        collect(root, into: &nodes)
        nodes.sort { $0.zIndex < $1.zIndex }

        for node in nodes.reversed() {
            guard node.hasBehaviour, node.frame.contains(point), !node.hidden else { continue }
            guard ActionResolver.isVisible(node.element, state: state),
                  ActionResolver.isInteractive(node.element) else { continue }

            switch node.kind {
            case .slider:
                guard let slider = node.slider else { continue }
                return .slider(slider, slider.fraction(at: point, in: node.frame), node)

            case .playlist:
                guard let info = node.playlist else { continue }
                let row = Int((point.y - node.frame.minY) / info.rowHeight) + state.playlistOffset
                let index = state.playlistStart + row
                guard row >= 0, row < state.playlistRows.count else { continue }
                return .playlistRow(index, node)

            case .group:
                guard !node.zones.isEmpty else { continue }
                if let zone = zone(at: point, in: node) {
                    return .action(zone.action, node)
                }

            case .button:
                guard let action = node.action else { continue }
                if isOpaque(at: point, in: node) {
                    return .action(action, node)
                }

            default:
                continue
            }
        }
        return .background
    }

    public var containsPlaylist: Bool {
        func walk(_ node: SceneNode) -> Bool {
            if node.kind == .playlist { return true }
            return node.children.contains(where: walk)
        }
        return walk(root)
    }

    public func node(at point: CGPoint, state: PlayerState) -> SceneNode? {
        switch hitTest(point, state: state) {
        case .action(_, let node), .slider(_, _, let node), .playlistRow(_, let node): return node
        case .background: return nil
        }
    }

    private func collect(_ node: SceneNode, into nodes: inout [SceneNode]) {
        if node.hasBehaviour { nodes.append(node) }
        for child in node.children { collect(child, into: &nodes) }
    }

    private func zone(at point: CGPoint, in node: SceneNode) -> GroupZone? {
        guard let name = node.element["mappingimage"], let bitmap = assets.bitmap(named: name) else {
            return nil
        }
        let x = Int((point.x - node.frame.minX) / node.frame.width * CGFloat(bitmap.width))
        let y = Int((point.y - node.frame.minY) / node.frame.height * CGFloat(bitmap.height))
        let pixel = bitmap.rgba(x: x, y: y)
        guard pixel.a > 8 else { return nil }
        return node.zones.first { $0.colour.matches((pixel.r, pixel.g, pixel.b), tolerance: 8) }
    }

    private func isOpaque(at point: CGPoint, in node: SceneNode) -> Bool {
        guard let name = node.element["image"], let bitmap = assets.bitmap(named: name) else {
            return true
        }
        let x = Int((point.x - node.frame.minX) / max(node.frame.width, 1) * CGFloat(bitmap.width))
        let y = Int((point.y - node.frame.minY) / max(node.frame.height, 1) * CGFloat(bitmap.height))
        let pixel = bitmap.rgba(x: x, y: y)
        if pixel.a <= 8 { return false }
        if node.keyColours.contains(where: { $0.matches((pixel.r, pixel.g, pixel.b)) }) { return false }
        return true
    }
}
