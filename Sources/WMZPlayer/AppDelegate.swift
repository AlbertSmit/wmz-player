import AppKit
import AVFoundation
import UniformTypeIdentifiers
import WMZKit

final class SkinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One open skin view: its window, its scene and its canvas.
final class ViewWindow: NSObject, NSWindowDelegate, JavaScriptHostDelegate {
    let viewID: String
    let isMain: Bool
    let window: SkinWindow
    let view: SkinView
    private(set) var scene: Scene
    private var scale: CGFloat
    private var jsHost: JavaScriptHost?

    let hasEffects: Bool

    var onOpenView: ((String) -> Void)?
    var onCloseView: ((String) -> Void)?
    var onReturnToMain: (() -> Void)?
    var onOpenDialog: (() -> Void)?
    var onPlaySound: ((String) -> Void)?

    init(scene: Scene, viewID: String, isMain: Bool, scale: CGFloat,
         registry: [String: SceneNode]) {
        self.scene = scene
        self.viewID = viewID
        self.isMain = isMain
        self.scale = scale

        let size = CGSize(width: scene.size.width * scale, height: scene.size.height * scale)
        window = SkinWindow(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        hasEffects = Self.containsEffects(scene.root)
        view = SkinView(frame: CGRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]
        view.bounds = CGRect(origin: .zero, size: scene.size)
        view.scene = scene
        window.contentView = view
        window.title = scene.title
        super.init()
        window.delegate = self
        startScript(registry: registry)
    }

    private func startScript(registry: [String: SceneNode]) {
        let host = JavaScriptHost(scene: scene, delegate: self, registry: registry)
        jsHost = host
        host.start()

        view.onScriptClick = { [weak self] node, action in
            guard let self else { return false }
            let scripted = node.element["onclick"].map { self.jsHost?.call($0) ?? false } ?? false
            if let action, action.isNavigation { return false }
            return scripted
        }
        view.onHoverScript = { [weak self] node, entered in
            guard let host = self?.jsHost else { return }
            if let script = node.element[entered ? "onmouseover" : "onmouseout"] { _ = host.call(script) }
        }
        view.onKeyScript = { [weak self] code in
            guard let self, let host = self.jsHost,
                  let script = self.scene.view["onkeypress"] else { return }
            host.setEventKey(Int(code))
            _ = host.call(script)
        }
    }

    private static func containsEffects(_ node: SceneNode) -> Bool {
        if node.kind == .effects { return true }
        return node.children.contains(where: containsEffects)
    }

    func apply(_ state: PlayerState) {
        view.update(state: state)
        jsHost?.update(state)
    }

    // MARK: - JavaScriptHostDelegate

    func jsPerform(_ action: MediaAction) { view.onAction?(action) }
    func jsOpenView(_ id: String) { onOpenView?(id) }
    func jsCloseView(_ id: String) { onCloseView?(id) }
    func jsReturnToMediaCenter() { onReturnToMain?() }
    func jsOpenDialog() { onOpenDialog?() }
    func jsPlaySound(_ name: String) { onPlaySound?(name) }
    func jsNeedsDisplay() { view.needsDisplay = true }

    func setScale(_ newScale: CGFloat) {
        scale = newScale
        let size = CGSize(width: scene.size.width * newScale, height: scene.size.height * newScale)
        view.frame = CGRect(origin: .zero, size: size)
        view.bounds = CGRect(origin: .zero, size: scene.size)
        window.setContentSize(size)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let media = MediaController()
    private let sounds = SoundPlayer()

    private var document: SkinDocument?
    private var loadedURL: URL?

    private let recentMenu = NSMenu(title: "Open Recent")
    private static let recentKey = "recentSkins"
    private var recentSkins: [String] = UserDefaults.standard.stringArray(forKey: "recentSkins") ?? []
    /// Scenes are built once per view so panels open instantly and every script
    /// can see every element in the skin.
    private var sceneCache: [String: Scene] = [:]
    private var elementRegistry: [String: SceneNode] = [:]
    private var main: ViewWindow?
    private var panels: [String: ViewWindow] = [:]
    private var panelsMenu = NSMenu(title: "Panels")
    private var scale: CGFloat = 1
    private var alwaysOnTop = false
    private var target: MediaController.Target = .auto
    private var redrawTimer: Timer?
    private var audioSpectrum: AudioSpectrum?
    private var spectrumBackend: String?
    private var latestBands: [Float]?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        rebuildRecentMenu()
        media.onChange = { [weak self] state in self?.apply(state) }

        if let raw = flagValue("--scale"), let ratio = Double(raw), ratio > 0 {
            scale = ratio > 1.5 ? 2 : 1
        }

        if let path = launchArgument() ?? UserDefaults.standard.string(forKey: "skinPath") {
            load(URL(fileURLWithPath: path))
        } else {
            DispatchQueue.main.async { self.promptForSkin() }
        }
        media.start()

        redrawTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.tick()
        }

        if let click = simulatedClick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.main?.view.simulateClick(at: click)
            }
        }
        if let drag = simulatedDrag() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.main?.view.simulateDrag(from: drag.0, to: drag.1)
            }
        }
        if let click = simulatedPanelClick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
                self?.panels.values.first?.view.simulateClick(at: click)
            }
        }
        if let panel = flagValue("--panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.openPanelView(panel)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        load(URL(fileURLWithPath: filename))
        return true
    }

    private func tick() {
        updateVisualizer()
        var animated = false
        for controller in allWindows() {
            let playing = controller.view.state.isPlaying
            let animating = controller.view.renderer?.lastFrameAnimated == true
            if playing || animating { controller.view.needsDisplay = true }
            if controller.view.spectrum != nil {
                controller.view.needsDisplay = true
                animated = true
            }
        }
        // A static skin only needs the once-a-second media redraw, not 15 fps.
        redrawTimer?.tolerance = animated ? 0.01 : 0.2
    }

    private func updateVisualizer() {
        let wants = UserDefaults.standard.bool(forKey: "visualizer")
            && allWindows().contains { $0.hasEffects }
        guard wants else {
            if audioSpectrum != nil {
                audioSpectrum?.stop()
                audioSpectrum = nil
                spectrumBackend = nil
                latestBands = nil
                for controller in allWindows() { controller.view.spectrum = nil }
            }
            return
        }

        let backend = media.currentBackendName
        if audioSpectrum?.isRunning != true || spectrumBackend != backend {
            audioSpectrum?.stop()
            audioSpectrum = nil
            spectrumBackend = backend
            latestBands = nil
            if let identifier = Self.bundleIdentifier(for: backend) {
                let spectrum = AudioSpectrum(bundleIdentifier: identifier, bandCount: 28)
                spectrum.onBands = { [weak self] bands in self?.latestBands = bands }
                if spectrum.start() {
                    audioSpectrum = spectrum
                } else {
                    NSLog("WMZPlayer: no audio tap for %@", backend)
                }
            }
        }

        let bands = latestBands
        for controller in allWindows() where controller.hasEffects {
            controller.view.spectrum = bands.map { SpectrumFrame(bands: $0) }
        }
    }

    private static func bundleIdentifier(for backend: String) -> String? {
        switch backend {
        case "Music": return "com.apple.Music"
        case "Spotify": return "com.spotify.client"
        case "Tidal":
            return NSWorkspace.shared.runningApplications.first {
                ($0.bundleIdentifier ?? "").lowercased().contains("tidal")
            }?.bundleIdentifier
        default: return nil
        }
    }

    private func allWindows() -> [ViewWindow] {
        var list: [ViewWindow] = []
        if let main { list.append(main) }
        list.append(contentsOf: panels.values)
        return list
    }

    private func apply(_ state: PlayerState) {
        for controller in allWindows() { controller.apply(state) }
    }

    // MARK: - Skin loading

    // MARK: - Recent skins

    private func noteRecentSkin(_ url: URL) {
        let path = url.standardizedFileURL.path
        recentSkins.removeAll { $0 == path }
        recentSkins.insert(path, at: 0)
        if recentSkins.count > 10 { recentSkins.removeLast(recentSkins.count - 10) }
        UserDefaults.standard.set(recentSkins, forKey: Self.recentKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        rebuildRecentMenu()
    }

    private func rebuildRecentMenu() {
        recentMenu.removeAllItems()
        let existing = recentSkins.filter { FileManager.default.fileExists(atPath: $0) }

        if existing.isEmpty {
            let empty = NSMenuItem(title: "No Recent Skins", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }

        for path in existing {
            let item = NSMenuItem(title: Self.displayName(for: path),
                                  action: #selector(openRecentSkin(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.toolTip = path
            recentMenu.addItem(item)
        }
        recentMenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentSkins(_:)), keyEquivalent: "")
        clear.target = self
        recentMenu.addItem(clear)
    }

    private static func displayName(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".wmz") ? String(name.dropLast(4)) : name
    }

    @objc private func openRecentSkin(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            recentSkins.removeAll { $0 == path }
            UserDefaults.standard.set(recentSkins, forKey: Self.recentKey)
            rebuildRecentMenu()
            let alert = NSAlert()
            alert.messageText = "That skin moved or was deleted"
            alert.informativeText = path
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        load(URL(fileURLWithPath: path), force: true)
    }

    @objc private func clearRecentSkins(_ sender: Any?) {
        recentSkins.removeAll()
        UserDefaults.standard.set(recentSkins, forKey: Self.recentKey)
        rebuildRecentMenu()
    }

    private func promptForSkin() {
        let panel = NSOpenPanel()
        if let type = UTType(filenameExtension: "wmz") { panel.allowedContentTypes = [type] }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Windows Media Player skin (.wmz)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL, force: Bool = false) {
        if !force, main != nil, loadedURL == url { return }
        do {
            closeAll()
            let document = try SkinLoader.load(url)
            guard let primary = document.primaryView else { throw SkinError.noViews }
            buildScenes(for: document)
            guard let scene = sceneCache[primary.id] else { throw SkinError.noViews }
            let previous = self.document?.rootURL
            self.document = document
            self.loadedURL = url
            UserDefaults.standard.set(url.path, forKey: "skinPath")
            if let previous { try? FileManager.default.removeItem(at: previous) }

            showMain(scene: scene, viewID: primary.id)
            noteRecentSkin(url)
            restorePanels()
            rebuildPanelsMenu()
            updatePlaylistNeed()
        } catch {
            let alert = NSAlert()
            alert.messageText = "That skin did not load"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Builds every readable view in one pass: it feeds the shared element
    /// registry and removes per-panel layout work.
    private func buildScenes(for document: SkinDocument) {
        sceneCache = [:]
        elementRegistry = [:]
        for view in document.views {
            let id = view.id
            let lowered = id.lowercased()
            guard !id.isEmpty else { continue }
            if lowered.contains("preview") || lowered.contains("upgrade") || lowered.contains("control") {
                continue
            }
            guard let scene = try? SceneBuilder.build(document: document, view: view) else { continue }
            sceneCache[id] = scene
            for (key, node) in scene.nodes where elementRegistry[key] == nil {
                elementRegistry[key] = node
            }
        }
    }

    private func showMain(scene: Scene, viewID: String) {
        let controller = ViewWindow(scene: scene, viewID: viewID, isMain: true, scale: scale,
                                    registry: elementRegistry)
        wire(controller)
        main = controller
        controller.window.level = alwaysOnTop ? .floating : .normal
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        controller.window.makeFirstResponder(controller.view)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func wire(_ controller: ViewWindow) {
        let viewID = controller.viewID
        controller.view.onAction = { [weak self] action in self?.handle(action, from: viewID) }
        controller.view.onContextMenu = { [weak self] event in self?.showContextMenu(event) }
        controller.view.onSound = { [weak self] name in self?.playSound(name, from: viewID) }
        controller.view.onPlaylistScroll = { [weak self] rows in self?.media.scrollPlaylist(by: rows) }
        controller.onOpenView = { [weak self] id in self?.openPanelView(id) }
        controller.onCloseView = { [weak self, weak controller] id in
            guard let self, let controller else { return }
            if let resolved = self.resolveViewID(id) {
                self.closePanel(resolved)
            } else {
                self.closePanel(controller.viewID)
            }
        }
        controller.onReturnToMain = { [weak self] in
            self?.main?.window.makeKeyAndOrderFront(nil)
        }
        controller.onOpenDialog = { [weak self] in self?.pickMediaFile() }
        controller.onPlaySound = { [weak self] name in
            self?.playSound(name, from: controller.viewID)
        }
    }

    private func closeAll() {
        for controller in allWindows() { controller.window.orderOut(nil) }
        panels.removeAll()
        main = nil
    }

    // MARK: - Panels

    private func openPanelView(_ viewID: String) {
        guard let document else { return }
        if let main, main.viewID.caseInsensitiveCompare(viewID) == .orderedSame {
            main.window.makeKeyAndOrderFront(nil)
            return
        }
        if let existing = panels[viewID] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard document.view(id: viewID) != nil, let scene = sceneCache[viewID] else { return }
        let controller = ViewWindow(scene: scene, viewID: viewID, isMain: false, scale: scale,
                                    registry: elementRegistry)
        wire(controller)
        controller.window.level = alwaysOnTop ? .floating : .normal

        let base = main?.window.frame.origin ?? CGPoint(x: 120, y: 120)
        let step = CGFloat(panels.count + 1) * 32
        controller.window.setFrameOrigin(CGPoint(x: base.x + step, y: base.y - step))
        controller.window.makeKeyAndOrderFront(nil)
        panels[viewID] = controller
        persistPanels()
        rebuildPanelsMenu()
        updatePlaylistNeed()
        controller.apply(media.state)
    }

    private func closePanel(_ viewID: String) {
        let key = panels.keys.first { $0.caseInsensitiveCompare(viewID) == .orderedSame }
        guard let key, let controller = panels.removeValue(forKey: key) else { return }
        controller.window.orderOut(nil)
        persistPanels()
        rebuildPanelsMenu()
        updatePlaylistNeed()
    }

    private func togglePanel(token: String) {
        guard let viewID = resolveViewID(token) else { return }
        if panels.keys.contains(where: { $0.caseInsensitiveCompare(viewID) == .orderedSame }) {
            closePanel(viewID)
        } else {
            openPanelView(viewID)
        }
    }

    /// "pl" -> plView, "video" -> videoView, or an exact id.
    private func resolveViewID(_ token: String) -> String? {
        guard let document else { return nil }
        let raw = token.lowercased()
        if let exact = document.views.first(where: { $0.id.lowercased() == raw }) {
            return exact.id
        }
        // Preference keys arrive as "plViewer"/"remoteCallPl"; reduce them to the
        // stem the view ids are built from.
        var lowered = raw.replacingOccurrences(of: "remotecall", with: "")
        for suffix in ["viewer", "view"] where lowered.hasSuffix(suffix) {
            lowered.removeLast(suffix.count)
        }
        if lowered == "vid" { lowered = "video" }
        guard !lowered.isEmpty else { return nil }
        let excluded = ["control", "preview", "upgrade"]
        let candidates = document.views.filter { view in
            let id = view.id.lowercased()
            guard !id.isEmpty, !excluded.contains(where: { id.contains($0) }) else { return false }
            guard id != document.primaryView?.id.lowercased() else { return false }
            return id.contains(lowered)
        }
        return candidates.first?.id
    }

    private func restorePanels() {
        guard let stored = UserDefaults.standard.stringArray(forKey: "openPanels") else { return }
        for id in stored.prefix(4) { openPanelView(id) }
    }

    private func persistPanels() {
        UserDefaults.standard.set(Array(panels.keys), forKey: "openPanels")
    }

    private func updatePlaylistNeed() {
        media.needsPlaylist = allWindows().contains { $0.scene.containsPlaylist }
    }

    private func rebuildPanelsMenu() {
        panelsMenu.removeAllItems()
        guard let document else { return }
        let excluded = ["control", "preview", "upgrade"]
        let primary = document.primaryView?.id.lowercased()
        for view in document.views {
            let id = view.id
            let lowered = id.lowercased()
            guard !id.isEmpty, lowered != primary,
                  !excluded.contains(where: { lowered.contains($0) }) else { continue }
            let item = NSMenuItem(title: Self.prettyName(id), action: #selector(togglePanelFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = panels[id] != nil ? .on : .off
            panelsMenu.addItem(item)
        }
        if panelsMenu.items.isEmpty {
            let empty = NSMenuItem(title: "No panels in this skin", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            panelsMenu.addItem(empty)
        }
    }

    private static func prettyName(_ id: String) -> String {
        var name = id
        if name.lowercased().hasSuffix("view") { name.removeLast(4) }
        if name.lowercased() == "pl" { return "Playlist" }
        if name.lowercased() == "eq" { return "Equalizer" }
        if name.lowercased() == "vis" { return "Visualization" }
        // split camel case: plView -> pl, videoView -> video
        var words: [String] = []
        var current = ""
        for character in name {
            if character.isUppercase, !current.isEmpty {
                words.append(current); current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        let joined = words.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    // MARK: - Actions

    private func handle(_ action: MediaAction, from viewID: String) {
        switch action {
        case .openView(let id):
            openPanelView(id)
        case .openPanel(let token):
            togglePanel(token: token)
        case .closePanel(let token):
            if let id = resolveViewID(token) {
                closePanel(id)
            } else {
                closePanel(viewID)
            }
        case .returnToMain:
            main?.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        case .openMedia:
            pickMediaFile()
        case .openURL(let string):
            if let url = URL(string: string) { NSWorkspace.shared.open(url) }
        case .closeWindow:
            if let main, main.viewID.caseInsensitiveCompare(viewID) == .orderedSame {
                NSApp.terminate(nil)
            } else {
                closePanel(viewID)
            }
        case .minimizeWindow:
            allWindows().first { $0.viewID == viewID }?.window.miniaturize(nil)
        default:
            media.perform(action)
        }
    }

    private func pickMediaFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Open an audio file in Music"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        media.openFile(url)
    }

    private func playSound(_ name: String, from viewID: String) {
        guard let controller = allWindows().first(where: { $0.viewID == viewID }),
              let url = controller.scene.assets.url(for: name) else { return }
        sounds.play(url)
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About WMZPlayer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit WMZPlayer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("Open Skin…", #selector(openSkin(_:)), "o"))
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(item("Reload Skin", #selector(reloadSkin(_:)), "r"))
        fileItem.submenu = fileMenu

        let playerItem = NSMenuItem()
        mainMenu.addItem(playerItem)
        let playerMenu = NSMenu(title: "Player")
        playerMenu.addItem(tagged("Automatic", #selector(useAuto(_:)), 100))
        playerMenu.addItem(tagged("Apple Music", #selector(useMusic(_:)), 101))
        playerMenu.addItem(tagged("Spotify", #selector(useSpotify(_:)), 102))
        playerMenu.addItem(tagged("Tidal", #selector(useTidal(_:)), 103))
        playerItem.submenu = playerMenu

        let panelsItem = NSMenuItem()
        mainMenu.addItem(panelsItem)
        panelsItem.submenu = panelsMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(tagged("Double Size", #selector(toggleScale(_:)), 110))
        windowMenu.addItem(tagged("Always on Top", #selector(toggleTop(_:)), 111))
        windowMenu.addItem(tagged("Visualizer (audio bars)", #selector(toggleVisualizer(_:)), 112))
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func tagged(_ title: String, _ action: Selector, _ tag: Int) -> NSMenuItem {
        let item = item(title, action, "")
        item.tag = tag
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.tag {
        case 100: menuItem.state = target == .auto ? .on : .off
        case 101: menuItem.state = target == .music ? .on : .off
        case 102: menuItem.state = target == .spotify ? .on : .off
        case 103: menuItem.state = target == .tidal ? .on : .off
        case 110: menuItem.state = scale > 1 ? .on : .off
        case 111: menuItem.state = alwaysOnTop ? .on : .off
        case 112: menuItem.state = UserDefaults.standard.bool(forKey: "visualizer") ? .on : .off
        case 120: menuItem.state = alwaysOnTop ? .on : .off
        case 121: menuItem.state = scale > 1 ? .on : .off
        case 122: menuItem.state = target == .auto ? .on : .off
        case 123: menuItem.state = target == .music ? .on : .off
        case 124: menuItem.state = target == .spotify ? .on : .off
        case 125: menuItem.state = target == .tidal ? .on : .off
        default:
            if let id = menuItem.representedObject as? String {
                menuItem.state = panels[id] != nil ? .on : .off
            }
        }
        return true
    }

    @objc private func openSkin(_ sender: Any?) { promptForSkin() }

    @objc private func reloadSkin(_ sender: Any?) {
        guard let path = UserDefaults.standard.string(forKey: "skinPath") else { return }
        load(URL(fileURLWithPath: path), force: true)
    }

    @objc private func useAuto(_ sender: Any?) { target = .auto; media.target = .auto }
    @objc private func useMusic(_ sender: Any?) { target = .music; media.target = .music }
    @objc private func useSpotify(_ sender: Any?) { target = .spotify; media.target = .spotify }
    @objc private func useTidal(_ sender: Any?) { target = .tidal; media.target = .tidal }

    @objc private func toggleScale(_ sender: Any?) {
        scale = scale > 1 ? 1 : 2
        for controller in allWindows() { controller.setScale(scale) }
    }

    @objc private func toggleVisualizer(_ sender: Any?) {
        let key = "visualizer"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        updateVisualizer()
        for controller in allWindows() { controller.view.needsDisplay = true }
    }

    @objc private func toggleTop(_ sender: Any?) {
        alwaysOnTop.toggle()
        for controller in allWindows() {
            controller.window.level = alwaysOnTop ? .floating : .normal
        }
    }

    @objc private func togglePanelFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if panels[id] != nil { closePanel(id) } else { openPanelView(id) }
    }

    private func showContextMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(item("Open Skin…", #selector(openSkin(_:)), ""))

        if !recentMenu.items.isEmpty, recentMenu.items.first?.action != nil {
            let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            recentItem.submenu = recentMenu.copy() as? NSMenu
            menu.addItem(recentItem)
        }

        let playerItem = NSMenuItem(title: "Player", action: nil, keyEquivalent: "")
        let playerMenu = NSMenu()
        playerMenu.addItem(tagged("Automatic", #selector(useAuto(_:)), 122))
        playerMenu.addItem(tagged("Apple Music", #selector(useMusic(_:)), 123))
        playerMenu.addItem(tagged("Spotify", #selector(useSpotify(_:)), 124))
        playerMenu.addItem(tagged("Tidal", #selector(useTidal(_:)), 125))
        playerItem.submenu = playerMenu
        menu.addItem(playerItem)

        if !panelsMenu.items.isEmpty, panelsMenu.items.first?.action != nil {
            let panelsItem = NSMenuItem(title: "Panels", action: nil, keyEquivalent: "")
            panelsItem.submenu = panelsMenu.copy() as? NSMenu
            menu.addItem(panelsItem)
        }

        menu.addItem(.separator())
        menu.addItem(tagged("Double Size", #selector(toggleScale(_:)), 121))
        menu.addItem(tagged("Always on Top", #selector(toggleTop(_:)), 120))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")

        for entry in menu.items { _ = validateMenuItem(entry) }
        if let view = main?.view {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    // MARK: - Test hooks

    private func flagValue(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private func launchArgument() -> String? {
        CommandLine.arguments.dropFirst().first { $0.lowercased().hasSuffix(".wmz") }
    }

    private func simulatedClick() -> CGPoint? {
        guard let raw = flagValue("--click") else { return nil }
        let parts = raw.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func simulatedPanelClick() -> CGPoint? {
        guard let raw = flagValue("--panel-click") else { return nil }
        let parts = raw.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func simulatedDrag() -> (CGPoint, CGPoint)? {
        guard let raw = flagValue("--drag") else { return nil }
        let numbers = raw.split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return (CGPoint(x: numbers[0], y: numbers[1]), CGPoint(x: numbers[2], y: numbers[3]))
    }
}

/// Short UI sounds stored inside the skin (`theme.playSound`).
final class SoundPlayer {
    private var active: [AVAudioPlayer] = []

    func play(_ url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.play()
        active.append(player)
        if active.count > 4 { active.removeFirst().stop() }
    }
}
