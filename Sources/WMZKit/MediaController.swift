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
    /// Name of the backend currently being polled ("Music", "Spotify", "Tidal").
    public var currentBackendName: String { activeName }
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
    private var playlistLoading = false
    private var playlistCenter: Int?
    /// The last windows the queue fetch returned, freshest first. Scrolling back
    /// into one of them is served from here instead of another `osascript`
    /// round-trip. Three windows is roughly 120 rows, enough to cover a wheel
    /// spin in either direction.
    private var recentWindows: [PlaylistWindow] = []

    /// A page of the queue as `PlaylistLoader` returned it, kept so a later
    /// request can be answered without going back to Music.
    private struct PlaylistWindow {
        let name: String
        let total: Int
        let currentIndex: Int
        /// Absolute, 1-based index of `rows.first`.
        let startIndex: Int
        let rows: [PlaylistRow]

        var lastIndex: Int { startIndex + rows.count - 1 }
    }

    /// `<playlist>` footer templates from the open skin, e.g.
    /// `"Total Time: %duration%"`. The renderer reads them off the element; this
    /// lets the app hand them over early, and the substituted strings then ride
    /// along in `PlayerState`.
    public var playlistStatusTemplates: (left: String, right: String) = ("", "")

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
            next.playlistStatusLeftTemplate = playlistStatusTemplates.left
            next.playlistStatusRightTemplate = playlistStatusTemplates.right
            next.playlistLeftStatus = Self.playlistStatus(next.playlistStatusLeftTemplate, state: next)
            next.playlistRightStatus = Self.playlistStatus(next.playlistStatusRightTemplate, state: next)
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
        let offset = min(max(0, state.playlistOffset + rows), maximum)
        state.playlistOffset = offset
        if ProcessInfo.processInfo.environment["WMZ_DEBUG_PLAYLIST"] != nil {
            NSLog("playlist scroll rows=%d offset=%d max=%d", rows, offset, maximum)
        }
        onChange?(state)

        // Page in more rows before the user reaches the end of the window.
        let nearTop = offset <= 2
        let nearBottom = offset >= maximum - 2
        if nearTop || nearBottom {
            pagePlaylist(around: state.playlistStart + offset + 6)
        }
    }

    private func pagePlaylist(around index: Int) {
        if ProcessInfo.processInfo.environment["WMZ_DEBUG_PLAYLIST"] != nil {
            NSLog("pagePlaylist around=%d loading=%d needs=%d cached=%d",
                  index, playlistLoading ? 1 : 0, needsPlaylist ? 1 : 0, recentWindows.count)
        }
        guard needsPlaylist else { return }

        if let snapshot = cachedPage(around: index) {
            if ProcessInfo.processInfo.environment["WMZ_DEBUG_PLAYLIST"] != nil {
                NSLog("playlist paged around %d from cache: rows %d…%d",
                      index, snapshot.startIndex, snapshot.startIndex + snapshot.rows.count - 1)
            }
            applyPage(snapshot, center: index, keepingTopRow: true)
            return
        }

        guard !playlistLoading else { return }
        playlistLoading = true
        playlistCenter = index
        PlaylistLoader.loadAsync(application: "Music", radius: Self.pageRadius, center: index) { [weak self] snapshot in
            guard let self else { return }
            self.playlistLoading = false
            guard let snapshot else {
                if ProcessInfo.processInfo.environment["WMZ_DEBUG_PLAYLIST"] != nil {
                    NSLog("pagePlaylist: no snapshot")
                }
                return
            }
            self.remember(snapshot)
            self.applyPage(snapshot, center: index, keepingTopRow: false)
            if ProcessInfo.processInfo.environment["WMZ_DEBUG_PLAYLIST"] != nil {
                NSLog("playlist paged around %d: rows %d…%d offset %d",
                      index, snapshot.startIndex, snapshot.startIndex + snapshot.rows.count - 1,
                      self.state.playlistOffset)
            }
        }
    }

    /// Drops a fetched window into `state` and updates the highlight: the
    /// snapshot's `currentIndex` is the playing track, not the page's centre.
    private func applyPage(_ snapshot: PlaylistSnapshot, center: Int?, keepingTopRow: Bool) {
        // Preserve the absolute row at the top of the list when a cached page
        // covers it, so a cache hit does not jump the viewport.
        let top = state.playlistStart + state.playlistOffset
        state.playlistName = snapshot.name
        state.playlistRows = snapshot.rows
        state.playlistTotal = snapshot.total
        state.playlistCurrent = snapshot.currentIndex
        state.playlistStart = snapshot.startIndex
        if keepingTopRow, top > snapshot.startIndex,
           top <= snapshot.startIndex + snapshot.rows.count - 1 {
            state.playlistOffset = top - snapshot.startIndex
        } else if let center {
            // Keep roughly the same absolute row under the cursor.
            state.playlistOffset = min(max(0, center - snapshot.startIndex - 6),
                                       max(0, snapshot.rows.count - 1))
        } else {
            state.playlistOffset = min(state.playlistOffset, max(0, snapshot.rows.count - 1))
        }
        state.playlistLeftStatus = Self.playlistStatus(state.playlistStatusLeftTemplate, state: state)
        state.playlistRightStatus = Self.playlistStatus(state.playlistStatusRightTemplate, state: state)
        onChange?(state)
    }

    // MARK: - Paging cache

    /// Rows either side of the centre that `pagePlaylist` asks for.
    private static let pageRadius = 20

    private func remember(_ snapshot: PlaylistSnapshot) {
        // A queue that changed shape invalidates everything we kept: row numbers
        // and the playing index would no longer line up.
        if let newest = recentWindows.first,
           newest.total != snapshot.total || newest.name != snapshot.name {
            recentWindows.removeAll()
        }
        // Re-fetching the same window refreshes it rather than adding a copy.
        recentWindows.removeAll { $0.startIndex == snapshot.startIndex && $0.rows.count == snapshot.rows.count }
        recentWindows.insert(PlaylistWindow(name: snapshot.name, total: snapshot.total,
                                            currentIndex: snapshot.currentIndex,
                                            startIndex: snapshot.startIndex,
                                            rows: snapshot.rows), at: 0)
        if recentWindows.count > 3 { recentWindows.removeLast(recentWindows.count - 3) }
    }

    /// The page covering `index` when the kept windows already do, or nil when
    /// the player has to be asked. A hit has to be as good as a fetch: the
    /// windows are stitched together, and only a span they cover end to end is
    /// served, or the user would scroll into a hole with no rows above it.
    private func cachedPage(around index: Int) -> PlaylistSnapshot? {
        guard let newest = recentWindows.first else { return nil }
        // A window from another queue — or from before the track changed — would
        // put row numbers or the highlight out of step.
        let windows = recentWindows
            .filter { $0.total == newest.total && $0.name == newest.name
                      && $0.currentIndex == newest.currentIndex }
            .sorted { $0.startIndex < $1.startIndex }
        guard let oldest = windows.first else { return nil }

        var rows = oldest.rows
        var mergedEnd = oldest.lastIndex
        for window in windows.dropFirst() where window.startIndex <= mergedEnd + 1 {
            let overlap = max(0, mergedEnd - window.startIndex + 1)
            rows.append(contentsOf: window.rows.dropFirst(overlap))
            mergedEnd = window.lastIndex
        }

        let first = max(1, index - Self.pageRadius)
        let last = min(newest.total, index + Self.pageRadius)
        guard first <= last, first >= oldest.startIndex, last <= mergedEnd else { return nil }
        let slice = Array(rows[(first - oldest.startIndex)...(last - oldest.startIndex)])
        return PlaylistSnapshot(name: newest.name, total: newest.total,
                                currentIndex: newest.currentIndex,
                                startIndex: first, rows: slice)
    }

    /// Expands a `<playlist>` status template. Windows Media Player writes
    /// these into the skin (`"Total Time: %duration%"`); only the tokens are
    /// ours, and the surrounding words are the author's.
    public static func playlistStatus(_ template: String, state: PlayerState) -> String {
        guard !template.isEmpty else { return "" }
        let total = state.playlistRows.reduce(0.0) { $0 + max(0, $1.duration) }
        let selected = state.playlistRows.first { $0.index == state.playlistCurrent }
        let substitutions = [
            ("DurationString", durationText(total)),
            ("SelectedDuration", durationText(selected?.duration ?? state.duration)),
            ("SelectedCount", state.playlistRows.isEmpty ? "0" : "1"),
            ("duration", durationText(total)),
            ("count", String(state.playlistRows.count))
        ]
        var text = template
        for (token, value) in substitutions {
            text = text.replacingOccurrences(of: "%\(token)%", with: value, options: .caseInsensitive)
        }
        return text
    }

    /// `5:03` for a queue under an hour, `1:05:03` for anything longer.
    static func durationText(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
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
        // Start from what we already have; the fetch below is asynchronous.
        state.playlistName = self.state.playlistName
        state.playlistRows = self.state.playlistRows
        state.playlistTotal = self.state.playlistTotal
        state.playlistCurrent = self.state.playlistCurrent
        state.playlistStart = self.state.playlistStart
        state.playlistOffset = min(max(0, self.state.playlistOffset),
                                   max(0, state.playlistRows.count - 1))

        guard backend.name == "Music" else {
            if state.hasTrack {
                state.playlistRows = [PlaylistRow(index: 1, title: state.title, artist: state.artist,
                                                  album: state.album, duration: state.duration)]
                state.playlistTotal = 1
                state.playlistCurrent = 1
                state.playlistStart = 1
                state.playlistOffset = 0
            }
            return
        }

        let key = "\(state.title)|\(state.artist)"
        let trackChanged = key != lastPlaylistKey
        let stale = Date().timeIntervalSince(lastPlaylistFetch) > 20
        guard !playlistLoading, trackChanged || stale else { return }
        lastPlaylistKey = key
        lastPlaylistFetch = Date()
        if trackChanged {
            playlistCenter = nil
            // The cached windows carry the old track as `currentIndex`, so the
            // highlight would be wrong until they were refetched anyway.
            recentWindows.removeAll()
        }
        playlistLoading = true

        PlaylistLoader.loadAsync(application: "Music", radius: 12, center: playlistCenter) { [weak self] snapshot in
            guard let self else { return }
            self.playlistLoading = false
            guard let snapshot else {
                self.state.playlistRows = []
                self.state.playlistTotal = 0
                self.state.playlistCurrent = 0
                self.state.playlistStart = 0
                self.state.playlistOffset = 0
                self.recentWindows.removeAll()
                self.onChange?(self.state)
                return
            }
            self.remember(snapshot)
            self.applyPage(snapshot, center: nil, keepingTopRow: true)
        }
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
             .closeWindow, .minimizeWindow:
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
        guard isRunning else { return false }
        let state = run("""
        tell application "\(application)" to return (player state as string)
        """, key: "state")
        return state?.stringValue?.lowercased() == "playing"
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
