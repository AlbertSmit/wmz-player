import AppKit
import UniformTypeIdentifiers
import WMZKit

final class SkinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let media = MediaController()
    private var document: SkinDocument?
    private var scene: Scene?
    private var window: SkinWindow?
    private var view: SkinView?

    private var scale: CGFloat = 1
    private var alwaysOnTop = false
    private var target: MediaController.Target = .auto
    private var redrawTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        media.target = .auto
        media.onChange = { [weak self] state in
            self?.view?.update(state: state)
        }

        if ProcessInfo.processInfo.environment["WMZ_DEBUG_NP"] != nil {
            NSLog("NP %@", NowPlayingProbe.diagnostics())
        }

        if let raw = flagValue("--scale"), let ratio = Double(raw), ratio > 0 {
            scale = ratio > 1.5 ? 2 : 1
        }

        if let path = launchArgument() ?? UserDefaults.standard.string(forKey: "skinPath") {
            load(URL(fileURLWithPath: path))
        } else {
            DispatchQueue.main.async { self.promptForSkin() }
        }
        media.start()

        if let click = simulatedClick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.view?.simulateClick(at: click)
            }
        }
        if let drag = simulatedDrag() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.view?.simulateDrag(from: drag.0, to: drag.1)
            }
        }

        redrawTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let view = self.view, view.state.isPlaying else { return }
            view.needsDisplay = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        load(URL(fileURLWithPath: filename))
        return true
    }

    private func flagValue(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private func simulatedDrag() -> (CGPoint, CGPoint)? {
        guard let index = CommandLine.arguments.firstIndex(of: "--drag"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let numbers = CommandLine.arguments[index + 1].split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return (CGPoint(x: numbers[0], y: numbers[1]), CGPoint(x: numbers[2], y: numbers[3]))
    }

    private func simulatedClick() -> CGPoint? {
        guard let index = CommandLine.arguments.firstIndex(of: "--click"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let parts = CommandLine.arguments[index + 1].split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func launchArgument() -> String? {
        CommandLine.arguments.dropFirst().first { $0.lowercased().hasSuffix(".wmz") }
    }

    // MARK: - Skins

    private func promptForSkin() {
        let panel = NSOpenPanel()
        if let type = UTType(filenameExtension: "wmz") {
            panel.allowedContentTypes = [type]
        }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Windows Media Player skin (.wmz)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        do {
            let document = try SkinLoader.load(url)
            let scene = try SceneBuilder.build(document: document)
            let previous = self.document?.rootURL
            self.document = document
            self.scene = scene
            if let previous { try? FileManager.default.removeItem(at: previous) }
            UserDefaults.standard.set(url.path, forKey: "skinPath")
            show(scene: scene, title: document.title)
        } catch {
            let alert = NSAlert()
            alert.messageText = "That skin did not load"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func show(scene: Scene, title: String) {
        let size = CGSize(width: scene.size.width * scale, height: scene.size.height * scale)

        let window: SkinWindow
        let view: SkinView
        if let existing = self.window, let existingView = self.view {
            window = existing
            view = existingView
        } else {
            window = SkinWindow(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.level = alwaysOnTop ? .floating : .normal

            view = SkinView(frame: CGRect(origin: .zero, size: size))
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            view.onAction = { [weak self] action in self?.handle(action) }
            view.onContextMenu = { [weak self] event in self?.showContextMenu(event) }
            self.window = window
            self.view = view
        }

        view.frame = CGRect(origin: .zero, size: size)
        view.bounds = CGRect(origin: .zero, size: scene.size)
        view.scene = scene
        window.setContentSize(size)
        window.title = title
        window.level = alwaysOnTop ? .floating : .normal

        if window.frame.origin == .zero {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handle(_ action: MediaAction) {
        switch action {
        case .closeWindow:
            NSApp.terminate(nil)
        case .minimizeWindow:
            window?.miniaturize(nil)
        case .ignore:
            break
        default:
            media.perform(action)
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About WMZPlayer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit WMZPlayer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let open = NSMenuItem(title: "Open Skin…", action: #selector(openSkin(_:)), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)
        let reload = NSMenuItem(title: "Reload Skin", action: #selector(reloadSkin(_:)), keyEquivalent: "r")
        reload.target = self
        fileMenu.addItem(reload)
        fileItem.submenu = fileMenu

        let playerItem = NSMenuItem()
        main.addItem(playerItem)
        let playerMenu = NSMenu(title: "Player")
        playerMenu.addItem(playerMenuItem("Automatic", action: #selector(useAuto(_:)), tag: 100))
        playerMenu.addItem(playerMenuItem("Apple Music", action: #selector(useMusic(_:)), tag: 101))
        playerMenu.addItem(playerMenuItem("Spotify", action: #selector(useSpotify(_:)), tag: 102))
        playerMenu.addItem(playerMenuItem("Tidal", action: #selector(useTidal(_:)), tag: 103))
        playerItem.submenu = playerMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(playerMenuItem("Double Size", action: #selector(toggleScale(_:)), tag: 110))
        windowMenu.addItem(playerMenuItem("Always on Top", action: #selector(toggleTop(_:)), tag: 111))
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = main
    }

    private func playerMenuItem(_ title: String, action: Selector, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
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
        case 120: menuItem.state = alwaysOnTop ? .on : .off
        case 121: menuItem.state = scale > 1 ? .on : .off
        case 122: menuItem.state = target == .auto ? .on : .off
        case 123: menuItem.state = target == .music ? .on : .off
        case 124: menuItem.state = target == .spotify ? .on : .off
        case 125: menuItem.state = target == .tidal ? .on : .off
        default: break
        }
        return true
    }

    @objc private func openSkin(_ sender: Any?) { promptForSkin() }

    @objc private func reloadSkin(_ sender: Any?) {
        guard let path = UserDefaults.standard.string(forKey: "skinPath") else { return }
        load(URL(fileURLWithPath: path))
    }

    @objc private func useAuto(_ sender: Any?) { target = .auto; media.target = .auto }
    @objc private func useMusic(_ sender: Any?) { target = .music; media.target = .music }
    @objc private func useSpotify(_ sender: Any?) { target = .spotify; media.target = .spotify }
    @objc private func useTidal(_ sender: Any?) { target = .tidal; media.target = .tidal }

    @objc private func toggleScale(_ sender: Any?) {
        scale = scale > 1 ? 1 : 2
        if let scene { show(scene: scene, title: document?.title ?? "") }
    }

    @objc private func toggleTop(_ sender: Any?) {
        alwaysOnTop.toggle()
        window?.level = alwaysOnTop ? .floating : .normal
    }

    private func showContextMenu(_ event: NSEvent) {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open Skin…", action: #selector(openSkin(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let playerItem = NSMenuItem(title: "Player", action: nil, keyEquivalent: "")
        let playerMenu = NSMenu()
        playerMenu.addItem(playerMenuItem("Automatic", action: #selector(useAuto(_:)), tag: 122))
        playerMenu.addItem(playerMenuItem("Apple Music", action: #selector(useMusic(_:)), tag: 123))
        playerMenu.addItem(playerMenuItem("Spotify", action: #selector(useSpotify(_:)), tag: 124))
        playerMenu.addItem(playerMenuItem("Tidal", action: #selector(useTidal(_:)), tag: 125))
        playerItem.submenu = playerMenu
        menu.addItem(playerItem)

        menu.addItem(.separator())
        menu.addItem(playerMenuItem("Double Size", action: #selector(toggleScale(_:)), tag: 121))
        menu.addItem(playerMenuItem("Always on Top", action: #selector(toggleTop(_:)), tag: 120))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")

        for item in menu.items { _ = validateMenuItem(item) }
        NSMenu.popUpContextMenu(menu, with: event, for: view ?? window!.contentView!)
    }
}
