import AppKit
import Foundation
import WMZKit

// A small companion to the player: inspect a WMZ, or render a preview PNG
// without opening a window. Handy for checking a skin before you wear it.

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    wmz — Windows Media Player skin toolkit

      wmz inspect <skin.wmz>        List views and controls
                  [--view <id>]
      wmz render  <skin.wmz>        Render a PNG preview
                  [--out <file>] [--scale <n>] [--view <id>] [--on <hex>] [--playing] [--spectrum]
      wmz hit     <skin.wmz>        What does a click at x,y do?
                  --at <x,y> [--view <id>] [--playing]
      wmz queue                      Print the current Music queue window
      wmz media                     Print what the media controller sees
                  [--target music|spotify|auto] [--seconds <n>]

    """)
    exit(0)
}

func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func previewState(playing: Bool) -> PlayerState {
    var state = PlayerState()
    state.title = "The Last Spartan"
    state.artist = "Martin O'Donnell & Michael Salvatori"
    state.album = "Halo 2, Vol. 1"
    state.hasTrack = true
    state.isPlaying = playing
    state.duration = 245
    state.position = 87
    state.volume = 68
    state.backendName = "Preview"
    if let raw = value("--rating"), let rating = Int(raw) { state.rating = rating }
    if ProcessInfo.processInfo.arguments.contains("--playlist") {
        state.playlistName = "Preview Queue"
        state.playlistRows = (1...10).map {
            PlaylistRow(index: $0, title: "Track \($0)", artist: "Artist \($0)",
                        album: "Album", duration: Double(150 + $0 * 7))
        }
        state.playlistTotal = 10
        state.playlistCurrent = 3
        state.playlistStart = 1
    }
    return state
}

func dump(_ node: SceneNode, depth: Int = 0) {
    let indent = String(repeating: "  ", count: depth)
    var description = "\(indent)\(node.element.name)"
    if !node.id.isEmpty { description += " #\(node.id)" }
    let frame = node.frame
    description += String(format: "  [%.0f, %.0f  %.0fx%.0f] z=%d",
                          frame.minX, frame.minY, frame.width, frame.height, node.zIndex)
    if let image = node.element["backgroundimage"] { description += "  bg=\(image)" }
    if let image = node.element["image"] { description += "  img=\(image)" }
    if node.element["transparencycolor"] != nil || node.element["clippingcolor"] != nil {
        description += "  key=\(node.keyColours.map { String(format: "#%02x%02x%02x", $0.r, $0.g, $0.b) })"
    }
    if let action = node.action { description += "  → \(action)" }
    if let slider = node.slider { description += "  ⇔ \(slider.target)" }
    if !node.zones.isEmpty { description += "  zones: \(node.zones.map(\.action))" }
    print(description)
    for child in node.children.sorted(by: { $0.zIndex < $1.zIndex }) {
        dump(child, depth: depth + 1)
    }
}

guard let command = arguments.first, !command.hasPrefix("-") else { usage() }

if command == "queue" {
    if let snapshot = PlaylistLoader.load(application: "Music", radius: 5) {
        print("playlist:", snapshot.name, "total:", snapshot.total, "current:", snapshot.currentIndex, "start:", snapshot.startIndex)
        for row in snapshot.rows {
            print(row.index, "|", row.title, "|", row.artist, "|", row.album, "|", Int(row.duration))
        }
    } else {
        print("no queue (nothing playing, or the current source has no playlist)")
    }
    exit(0)
}

if command == "media" {
    let target = MediaController.Target(rawValue: value("--target") ?? "auto") ?? .auto
    let seconds = Double(value("--seconds") ?? "6") ?? 6

    if let bundle = value("--bundle") {
        // Debug helper: read any app through the Now Playing channel, e.g.
        //   wmz media --bundle music
        NowPlayingProbe.run(bundleFragment: bundle, seconds: seconds)
        exit(0)
    }

    let controller = MediaController(target: target)
    var last = ""
    controller.onChange = { state in
        let line = "\(state.backendName): \(state.isPlaying ? "playing" : "paused")  \(state.title) — \(state.artist)  \(Int(state.position))/\(Int(state.duration))s  vol \(Int(state.volume))  art:\(state.artworkPath == nil ? "no" : "yes")"
        if line != last { print(line); last = line }
    }
    controller.start()
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    controller.stop()
    exit(0)
}

guard let path = arguments.dropFirst().first, !path.hasPrefix("-") else { usage() }
let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL

do {
    let document = try SkinLoader.load(url)

    switch command {
    case "inspect":
        print("\(document.title)")
        if !document.author.isEmpty { print("by \(document.author)") }
        print("\(document.views.count) view(s), \(url.lastPathComponent)\n")
        for view in document.views {
            let width = view.int("width") ?? 0
            let height = view.int("height") ?? 0
            let mark = view.id == document.primaryView?.id ? "●" : " "
            print("\(mark) \(view.id.isEmpty ? "(untitled)" : view.id)  \(width)x\(height)")
        }
        print("")
        let view = value("--view").flatMap { document.view(id: $0) }
        let scene = try SceneBuilder.build(document: document, view: view)
        dump(scene.root)

    case "render":
        let view = value("--view").flatMap { document.view(id: $0) }
        let scene = try SceneBuilder.build(document: document, view: view)
        let renderer = SceneRenderer(scene: scene)
        let scale = CGFloat(Double(value("--scale") ?? "2") ?? 2)
        let state = previewState(playing: arguments.contains("--playing"))
        let background = RGB(hex: value("--on"))
        let spectrum = arguments.contains("--spectrum")
            ? SyntheticSpectrum(bandCount: 28).next(at: 1.7) : nil
        guard let image = renderer.image(state: state, scale: scale, background: background, spectrum: spectrum) else {
            FileHandle.standardError.write(Data("Could not render the skin.\n".utf8))
            exit(1)
        }
        let output = value("--out") ?? "\(url.deletingPathExtension().lastPathComponent).png"
        let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, "public.png" as CFString, 1, nil
        ) else { exit(1) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { exit(1) }
        print("Wrote \(outputURL.path) (\(Int(scene.size.width))x\(Int(scene.size.height)) @\(Int(scale))x)")

    case "hit":
        guard let coordinates = value("--at")?.split(separator: ","),
              coordinates.count == 2,
              let x = Double(coordinates[0]), let y = Double(coordinates[1]) else {
            FileHandle.standardError.write(Data("Expected --at x,y\n".utf8))
            exit(1)
        }
        let view = value("--view").flatMap { document.view(id: $0) }
        let scene = try SceneBuilder.build(document: document, view: view)
        let state = previewState(playing: arguments.contains("--playing"))
        switch scene.hitTest(CGPoint(x: x, y: y), state: state) {
        case .action(let action, let node):
            print("action \(action) on \(node.element.name) \(node.id.isEmpty ? "" : "#\(node.id)")")
        case .slider(let slider, let fraction, let node):
            print("slider \(slider.target) = \(Int(fraction * 100))% on \(node.id)")
        case .playlistRow(let index, _):
            print("playlist row \(index)")
        case .background:
            print("background")
        }

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
