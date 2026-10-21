import AppKit
import Foundation

/// Drives Apple Music or Spotify through AppleScript.
///
/// Scripts run on the main thread on purpose: NSAppleScript pumps the calling
/// thread's run loop while it waits for the target app, and scripts that resolve
/// object references (`current track`) deadlock on a plain dispatch queue.
public final class MediaController {

    public enum Target: String, CaseIterable {
        case auto
        case music
        case spotify
        case tidal

        public var title: String {
            switch self {
            case .auto: return "Automatic"
            case .music: return "Apple Music"
            case .spotify: return "Spotify"
            case .tidal: return "Tidal"
            }
        }
    }

    public private(set) var state = PlayerState()
    public var onChange: ((PlayerState) -> Void)?

    /// Set while a playlist panel is open; keeps the queue fetch out of the
    /// normal polling path.
    public var needsPlaylist = false

    public var target: Target {
        didSet {
            guard target != oldValue else { return }
            refreshNow()
        }
    }

    private let music = AppleScriptPlayer(application: "Music", bundleIdentifier: "com.apple.Music", durationUnit: 1)
    private let spotify = AppleScriptPlayer(application: "Spotify", bundleIdentifier: "com.spotify.client", durationUnit: 1000)
    private let tidal = SystemPlayer(name: "Tidal", bundleFragment: "tidal")
    private var timer: Timer?
    private var activeName = "Music"
    private var lastArtworkKey = ""
    private var lastVolume: Double = 60
    private var busy = false

    // Apple Music applies overlapping `set sound volume` / `set player position`
    // events out of order and can drop the newer one, so writes are coalesced to
    // one every 0.25 s and always end with the latest value.
    private var pendingVolume: Double?
    private var pendingSeek: Double?
    private var volumeScheduled = false
    private var seekScheduled = false
    private var lastVolumeWrite = Date.distantPast
    private var lastSeekWrite = Date.distantPast
    private var lastPlaylistFetch = Date.distantPast
    private var lastPlaylistKey = ""

    public init(target: Target = .auto) {
        self.target = target
    }

    // MARK: - Polling

    public func start() {
        stop()
        let timer = Timer(timeInterval: 0.9, repeats: true) { [weak self] _ in self?.refreshNow() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refreshNow()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refreshNow() {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        let backend = activeBackend()
        activeName = backend.name

        var next = backend.snapshot()
        next.backendName = backend.name

        if next.hasTrack {
            let key = "\(backend.name)|\(next.title)|\(next.artist)|\(next.album)"
            if key != lastArtworkKey {
                lastArtworkKey = key
                next.artworkPath = backend.fetchArtwork(key: key)
            } else {
                next.artworkPath = state.artworkPath
            }
        } else {
            next.artworkPath = nil
            lastArtworkKey = ""
        }

        if needsPlaylist {
            attachPlaylist(to: &next, backend: backend)
        }

        state = next
        onChange?(state)
    }

    private func activeBackend() -> PlayerBackend {
        switch target {
        case .music: return music
        case .spotify: return spotify
        case .tidal: return tidal
        case .auto: break
        }

        if music.isRunning, music.isPlaying { return music }
        if spotify.isRunning, spotify.isPlaying { return spotify }
        if tidal.isRunning, tidal.ownership == .mine { return tidal }
        if music.isRunning { return music }
        if spotify.isRunning { return spotify }
        switch activeName {
        case "Spotify": return spotify
        case "Tidal": return tidal
        default: return music
        }
    }

    // MARK: - Extras

    public func scrollPlaylist(by rows: Int) {
        guard !state.playlistRows.isEmpty else { return }
        let maximum = max(0, state.playlistRows.count - 1)
        state.playlistOffset = min(max(0, state.playlistOffset + rows), maximum)
        onChange?(state)
    }

    public func openFile(_ url: URL) {
        _ = PlaylistLoader.openFile(url, application: "Music")
        refreshNow()
    }

    private func runAppleScript(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        script.compileAndReturnError(&error)
        _ = script.executeAndReturnError(&error)
        if let error { NSLog("WMZPlayer: AppleScript failed: \(error)") }
    }

    private func runSpotify(_ body: String) -> Bool {
        let script = """
        tell application "Spotify"
            \(body)
        end tell
        """
        guard let compiled = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        _ = compiled.executeAndReturnError(&error)
        return error == nil
    }

    // MARK: - Queue

    private func attachPlaylist(to state: inout PlayerState, backend: PlayerBackend) {
        let key = "\(backend.name)|\(state.title)|\(state.artist)"
        let stale = Date().timeIntervalSince(lastPlaylistFetch) > 20
        if key == lastPlaylistKey, !stale {
            state.playlistName = self.state.playlistName
            state.playlistRows = self.state.playlistRows
            state.playlistTotal = self.state.playlistTotal
            state.playlistCurrent = self.state.playlistCurrent
            state.playlistStart = self.state.playlistStart
            state.playlistOffset = self.state.playlistOffset
            return
        }
        lastPlaylistKey = key
        lastPlaylistFetch = Date()

        if backend.name == "Music",
           let snapshot = PlaylistLoader.load(application: "Music", radius: 12) {
            state.playlistName = snapshot.name
            state.playlistRows = snapshot.rows
            state.playlistTotal = snapshot.total
            state.playlistCurrent = snapshot.currentIndex
            state.playlistStart = snapshot.startIndex
        } else if state.hasTrack {
            state.playlistRows = [PlaylistRow(index: 1, title: state.title, artist: state.artist,
                                              album: state.album, duration: state.duration)]
            state.playlistTotal = 1
            state.playlistCurrent = 1
            state.playlistStart = 1
        }
        state.playlistOffset = min(max(0, self.state.playlistOffset),
                                   max(0, state.playlistRows.count - 1))
    }

    // MARK: - Coalesced writes

    private func flushVolume() {
        let wait = 0.25 - Date().timeIntervalSince(lastVolumeWrite)
        if wait > 0 {
            guard !volumeScheduled else { return }
            volumeScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.volumeScheduled = false
                self?.flushVolume()
            }
            return
        }
        guard let value = pendingVolume else { return }
        pendingVolume = nil
        lastVolumeWrite = Date()
        activeBackend().setVolume(value)
    }

    private func flushSeek() {
        let wait = 0.25 - Date().timeIntervalSince(lastSeekWrite)
        if wait > 0 {
            guard !seekScheduled else { return }
            seekScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.seekScheduled = false
                self?.flushSeek()
            }
            return
        }
        guard let value = pendingSeek else { return }
        pendingSeek = nil
        lastSeekWrite = Date()
        activeBackend().seek(to: value)
    }

    // MARK: - Commands

    public func perform(_ action: MediaAction) {
        switch action {
        case .ignore:
            return

        case .seek(let seconds):
            pendingSeek = max(0, seconds)
            flushSeek()
            return

        case .seekFraction(let fraction):
            // Without a duration (a player whose metadata the OS hides) a
            // fraction has no meaning; don't jump to the start.
            guard state.duration > 0 else { return }
            pendingSeek = max(0, fraction * state.duration)
            flushSeek()
            return

        case .volume(let fraction):
            lastVolume = max(0, min(100, fraction * 100))
            pendingVolume = lastVolume
            flushVolume()
            return

        case .play:
            activeBackend().play()
        case .pause:
            activeBackend().pause()
        case .playPause:
            activeBackend().playPause()
        case .stop:
            activeBackend().stop()
        case .next:
            activeBackend().next()
        case .previous:
            activeBackend().previous()

        case .toggleMute:
            let backend = activeBackend()
            let volume = backend.snapshot().volume
            if volume > 0 {
                lastVolume = volume
                backend.setVolume(0)
            } else {
                backend.setVolume(lastVolume > 0 ? lastVolume : 60)
            }

        case .playTrack(let index):
            guard activeBackend().name == "Music" else { return }
            _ = PlaylistLoader.play(index: index, application: "Music")

        case .setRating(let value):
            guard activeBackend().name == "Music" else { return }
            runAppleScript("tell application \"Music\" to set rating of current track to \(max(0, min(100, value)))")

        case .shuffle:
            switch activeBackend().name {
            case "Music": _ = PlaylistLoader.toggleShuffle(application: "Music")
            case "Spotify": _ = runSpotify("set shuffling to not shuffling")
            default: MediaRemoteBridge.shared.send(.toggleShuffle)
            }

        case .repeatMode:
            switch activeBackend().name {
            case "Music": _ = PlaylistLoader.cycleRepeat(application: "Music")
            case "Spotify": _ = runSpotify("set repeating to not repeating")
            default: MediaRemoteBridge.shared.send(.toggleRepeat)
            }

        case .openView, .openPanel, .closePanel, .returnToMain, .openMedia, .openURL,
             .closeWindow, .minimizeWindow, .ignore:
            return
        }

        refreshNow()
    }
}

// MARK: - One application

final class AppleScriptPlayer: PlayerBackend {
    let application: String
    let bundleIdentifier: String
    let durationUnit: Double
    let name: String

    private var cache: [String: NSAppleScript] = [:]
    private var lastVolume: Double = 60

    init(application: String, bundleIdentifier: String, durationUnit: Double) {
        self.application = application
        self.bundleIdentifier = bundleIdentifier
        self.durationUnit = durationUnit
        self.name = application
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    var isPlaying: Bool {
        snapshot().isPlaying
    }

    func snapshot() -> PlayerState {
        var state = PlayerState()
        guard isRunning else { return state }
        state.isRunning = true

        // Return a list, not a delimited string: stringifying numbers uses the
        // user's decimal separator (189,0 in nl_NL).
        let script = """
        tell application "\(application)"
            set s to (player state as string)
            set n to ""
            set a to ""
            set al to ""
            set d to 0
            set p to 0
            if s is not "stopped" then
                try
                    set t to current track
                    set n to name of t
                    set a to artist of t
                    set al to album of t
                    set d to ((duration of t) / \(durationUnit)) as integer
                    set p to (player position) as integer
                    try
                        set r to (rating of t) as integer
                    end try
                end try
            end if
            set v to (sound volume) as integer
            return {s, n, a, al, d, p, v, r}
        end tell
        """

        guard let result = run(script, key: "snapshot"), result.numberOfItems >= 8 else { return state }
        func field(_ index: Int) -> String {
            guard index <= result.numberOfItems else { return "" }
            return result.atIndex(index)?.stringValue ?? ""
        }

        state.isPlaying = field(1).lowercased() == "playing"
        state.title = field(2)
        state.artist = field(3)
        state.album = field(4)
        state.duration = Double(field(5)) ?? 0
        state.position = Double(field(6)) ?? 0
        state.volume = Double(field(7)) ?? 0
        // Only Music exposes ratings; Spotify and Tidal leave this nil.
        state.rating = application == "Music" ? (Int(field(8)) ?? 0) : nil
        state.hasTrack = !state.title.isEmpty
        lastVolume = state.volume
        return state
    }

    func play() { command("play") }
    func pause() { command("pause") }
    func stop() { command("stop") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func playPause() {
        run("""
        tell application "\(application)"
            if player state is playing then
                pause
            else
                play
            end if
        end tell
        """, key: "playpause")
    }

    func seek(to seconds: Double) {
        run("""
        tell application "\(application)"
            set player position to \(Int(max(0, seconds)))
        end tell
        """, key: nil)
    }

    func setVolume(_ value: Double) {
        run("""
        tell application "\(application)"
            set sound volume to \(Int(max(0, min(100, value))))
        end tell
        """, key: nil)
    }

    func fetchArtwork(key: String) -> String? {
        let script = """
        tell application "\(application)"
            try
                if (count of artwork of current track) > 0 then
                    return data of artwork 1 of current track
                end if
            end try
            return ""
        end tell
        """
        guard let descriptor = run(script, key: "artwork") else { return nil }
        let data = descriptor.data
        guard !data.isEmpty else { return nil }

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WMZPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let extensionName: String
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { extensionName = "png" }
        else if data.starts(with: [0xFF, 0xD8]) { extensionName = "jpg" }
        else if data.starts(with: [0x47, 0x49, 0x46]) { extensionName = "gif" }
        else { extensionName = "img" }

        let url = directory.appendingPathComponent("artwork-\(abs(key.hashValue)).\(extensionName)")
        try? data.write(to: url)
        return url.path
    }

    private func command(_ verb: String) {
        run("""
        tell application "\(application)"
            \(verb)
        end tell
        """, key: verb)
    }

    /// `key` is nil for scripts with interpolated values (seek and volume):
    /// caching those would replay the first value for the rest of the session.
    @discardableResult
    private func run(_ source: String, key: String?) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let key, let cached = cache[key] {
            script = cached
        } else {
            guard let compiled = NSAppleScript(source: source) else { return nil }
            var error: NSDictionary?
            compiled.compileAndReturnError(&error)
            if let key { cache[key] = compiled }
            script = compiled
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("WMZPlayer: AppleScript failed (\(application)/\(key ?? "one-shot")): \(error)")
            return nil
        }
        return result
    }
}
