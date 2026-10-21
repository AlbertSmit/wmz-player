import AppKit
import WMZKit

final class SkinView: NSView {
    var scene: Scene? {
        didSet {
            renderer = scene.map(SceneRenderer.init(scene:))
            hovered = nil
            pressed = nil
            needsDisplay = true
        }
    }

    var state = PlayerState() {
        didSet { needsDisplay = true }
    }
    /// Synthetic or captured spectrum for `<effects>` panes.
    var spectrum: SpectrumFrame?

    var renderer: SceneRenderer?
    var onAction: ((MediaAction) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onPlaylistScroll: ((Int) -> Void)?
    var onSound: ((String) -> Void)?
    var onScriptClick: ((SceneNode, MediaAction?) -> Bool)?
    var onHoverScript: ((SceneNode, Bool) -> Void)?
    var onKeyScript: ((UInt16) -> Void)?

    private(set) var hovered: SceneNode?
    private var pressed: SceneNode?
    private var tracking: NSTrackingArea?
    private var sliderNode: SceneNode?
    private var stateStamp = Date()
    private var lastSliderFire = Date.distantPast

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    /// A local clock so the progress bar moves between the once-a-second polls.
    override func draw(_ dirtyRect: NSRect) {
        guard let renderer, let context = NSGraphicsContext.current?.cgContext else { return }
        var display = state
        if display.isPlaying, display.hasTrack, display.duration > 0 {
            let elapsed = Date().timeIntervalSince(stateStamp)
            display.position = min(display.duration, display.position + elapsed)
        }
        renderer.spectrum = spectrum
        renderer.draw(in: context, state: display, hovered: hovered, pressed: pressed)
    }

    func update(state: PlayerState) {
        self.state = state
        stateStamp = Date()
    }

    // MARK: - Mouse

    private func scenePoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let scene else { return }
        let node = scene.node(at: scenePoint(event), state: state)
        guard node !== hovered else { return }
        if let previous = hovered { onHoverScript?(previous, false) }
        if let node { onHoverScript?(node, true) }
        hovered = node
        needsDisplay = true
        if let node {
            let tooltip = node.element["uptooltip"] ?? node.element["tooltip"] ?? ""
            toolTip = tooltip.isEmpty ? nil : tooltip
        } else {
            toolTip = nil
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let scene else { return }

        if event.modifierFlags.contains(.control) {
            onContextMenu?(event)
            return
        }

        switch scene.hitTest(scenePoint(event), state: state) {
        case .action(_, let node):
            pressed = node
            hovered = node
            needsDisplay = true

        case .slider(let slider, let fraction, let node):
            pressed = node
            sliderNode = node
            applySlider(slider, fraction: fraction)

        case .playlistRow(_, let node):
            pressed = node
            needsDisplay = true

        case .background:
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let node = sliderNode, let slider = node.slider {
            let fraction = sliderFraction(at: scenePoint(event), in: node.frame, slider: slider)
            applySlider(slider, fraction: fraction)
            return
        }

        guard pressed != nil, let scene else { return }
        let node = scene.node(at: scenePoint(event), state: state)
        if node !== pressed {
            pressed = nil
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            sliderNode = nil
            needsDisplay = true
        }
        guard let node = pressed, let scene else { return }

        if let slider = node.slider {
            let fraction = sliderFraction(at: scenePoint(event), in: node.frame, slider: slider)
            applySlider(slider, fraction: fraction, final: true)
            return
        }

        // Fire only when released over the same control. Group hit zones carry
        // their action, so ask the scene again instead of reading node.action.
        let point = scenePoint(event)
        let hitAction: MediaAction?
        if case .action(let action, let hitNode) = scene.hitTest(point, state: state), hitNode === node {
            hitAction = action
        } else {
            hitAction = nil
        }

        // The skin's own handler runs first; navigation still goes through the
        // app (some skins only record a preference for another view to poll).
        if let onScriptClick, onScriptClick(node, hitAction) { return }

        if let sound = node.sound { onSound?(sound) }
        switch scene.hitTest(point, state: state) {
        case .action(let action, let hitNode) where hitNode === node:
            onAction?(action)
        case .playlistRow(let index, let hitNode) where hitNode === node:
            onAction?(.playTrack(index))
        default:
            break
        }
    }

    private func applySlider(_ slider: SliderInfo, fraction: Double, final: Bool = false) {
        // Update the picture immediately, but don't spam the player with an
        // AppleScript call for every mouse-moved event.
        switch slider.target {
        case .volume: state.volume = fraction * 100
        case .seek: state.position = fraction * state.duration
        case .balance, .unknown: break
        }
        stateStamp = Date()
        needsDisplay = true

        let now = Date()
        guard final || now.timeIntervalSince(lastSliderFire) > 0.12 else { return }
        lastSliderFire = now

        switch slider.target {
        case .volume: onAction?(.volume(fraction))
        case .seek: onAction?(.seekFraction(fraction))
        case .balance, .unknown: break
        }
    }

    private func sliderFraction(at point: CGPoint, in frame: CGRect, slider: SliderInfo) -> Double {
        slider.fraction(at: point, in: frame)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let scene else { return }
        if case .playlistRow = scene.hitTest(scenePoint(event), state: state) {
            if event.scrollingDeltaY != 0 {
                onPlaylistScroll?(event.scrollingDeltaY > 0 ? -1 : 1)
            }
            return
        }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onKeyScript?(event.keyCode)
        switch event.keyCode {
        case 49: onAction?(.playPause)            // space
        case 123: onAction?(.seek(state.position - 5))
        case 124: onAction?(.seek(state.position + 5))
        case 125: onAction?(.volume(max(0, state.volume - 5) / 100))
        case 126: onAction?(.volume(min(100, state.volume + 5) / 100))
        default: super.keyDown(with: event)
        }
    }

    /// A floating skin should react to the click that activates it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Test hook: drives the same code path as a real click, without the OS
    /// event queue (used by `--click x,y`).
    func simulateClick(at point: CGPoint) {
        guard let window else { return }
        let windowPoint = convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            if type == .leftMouseDown { mouseDown(with: event) } else { mouseUp(with: event) }
        }
    }

    /// Test hook for the sliders: press, move in steps, release.
    func simulateDrag(from start: CGPoint, to end: CGPoint) {
        guard let window else { return }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        if let down = event(.leftMouseDown, start) { mouseDown(with: down) }
        for step in 1...8 {
            let t = CGFloat(step) / 8
            let point = CGPoint(x: start.x + (end.x - start.x) * t,
                                y: start.y + (end.y - start.y) * t)
            if let dragged = event(.leftMouseDragged, point) { mouseDragged(with: dragged) }
        }
        if let up = event(.leftMouseUp, end) { mouseUp(with: up) }
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }
}
