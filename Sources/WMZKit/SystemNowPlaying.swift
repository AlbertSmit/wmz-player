import AppKit
import Foundation

/// Everything the media layer needs from a player.
protocol PlayerBackend: AnyObject {
    var name: String { get }
    var isRunning: Bool { get }
    var isPlaying: Bool { get }

    func snapshot() -> PlayerState
    func play()
    func pause()
    func playPause()
    func stop()
    func next()
    func previous()
    func seek(to seconds: Double)
    func setVolume(_ value: Double)
    func fetchArtwork(key: String) -> String?
}

// MARK: - MediaRemote

/// Thin wrapper over the private MediaRemote framework, which is how macOS
/// exposes "now playing" (Control Center, media keys) to other processes.
///
/// Tidal has no AppleScript dictionary, so this is the only practical way to
/// read its track and drive its transport. The framework is loaded with
/// `dlopen` so the app still builds and runs if Apple removes it.
final class MediaRemoteBridge {
    static let shared = MediaRemoteBridge()

    enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    private typealias InfoBlock = @convention(block) (CFDictionary?) -> Void
    private typealias InfoFn = @convention(c) (DispatchQueue, InfoBlock) -> Void
    private typealias BoolBlock = @convention(block) (Bool) -> Void
    private typealias BoolFn = @convention(c) (DispatchQueue, BoolBlock) -> Void
    private typealias PidBlock = @convention(block) (Int32) -> Void
    private typealias PidFn = @convention(c) (DispatchQueue, PidBlock) -> Void
    private typealias SendFn = @convention(c) (Int32, CFDictionary?) -> Bool
    private typealias ElapsedFn = @convention(c) (Double) -> Void

    private let queue = DispatchQueue(label: "io.github.albertsmit.wmzplayer.mediaremote")
    private var infoFn: InfoFn?
    private var playingFn: BoolFn?
    private var pidFn: PidFn?
    private var sendFn: SendFn?
    private var elapsedFn: ElapsedFn?

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else { return }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        infoFn = symbol("MRMediaRemoteGetNowPlayingInfo", as: InfoFn.self)
        playingFn = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: BoolFn.self)
        pidFn = symbol("MRMediaRemoteGetNowPlayingApplicationPID", as: PidFn.self)
        sendFn = symbol("MRMediaRemoteSendCommand", as: SendFn.self)
        elapsedFn = symbol("MRMediaRemoteSetElapsedTime", as: ElapsedFn.self)
    }

    var isAvailable: Bool { infoFn != nil && sendFn != nil }

    func nowPlayingInfo() -> [String: Any]? {
        guard let infoFn else { return nil }
        var result: [String: Any]?
        var done = false
        let block: InfoBlock = { info in
            result = info as? [String: Any]
            done = true
        }
        infoFn(DispatchQueue.main, block)
        pump(until: { done })
        return result
    }

    func nowPlayingPID() -> pid_t? {
        guard let pidFn else { return nil }
        var result: pid_t?
        var done = false
        let block: PidBlock = { pid in
            result = pid
            done = true
        }
        pidFn(DispatchQueue.main, block)
        pump(until: { done })
        return result
    }

    func isPlaying() -> Bool {
        guard let playingFn else { return false }
        var result = false
        var done = false
        let block: BoolBlock = { playing in
            result = playing
            done = true
        }
        playingFn(DispatchQueue.main, block)
        pump(until: { done })
        return result
    }

    /// MediaRemote answers on the main queue, so a blocking semaphore on the
    /// main thread would never see the reply. Pump the run loop instead.
    private func pump(until done: () -> Bool, timeout: TimeInterval = 0.5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func send(_ command: Command) {
        _ = sendFn?(command.rawValue, nil)
    }

    func setElapsed(_ seconds: Double) {
        elapsedFn?(max(0, seconds))
    }
}

// MARK: - Tidal

/// A player without an AppleScript dictionary that publishes to macOS Now
/// Playing. Tidal's desktop app is Electron and works this way: transport goes
/// through MediaRemote, and the volume slider drives the system output volume.
///
/// Reading the now-playing dictionary is restricted to Apple-signed processes on
/// recent macOS; sending commands is not. So transport always works, while
/// title/artist/position appear only where the OS allows the read.
final class SystemPlayer: PlayerBackend {
    let name: String
    private let bundleFragment: String
    private let bridge = MediaRemoteBridge.shared

    private var assumedPlaying = false
    private var metadataDisabled = false
    private var lastMetadataAttempt = Date.distantPast

    init(name: String, bundleFragment: String) {
        self.name = name
        self.bundleFragment = bundleFragment.lowercased()
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier ?? "").lowercased().contains(bundleFragment)
        }
    }

    enum Ownership {
        case mine
        case other
        case unknown
    }

    /// Which app owns the Now Playing slot. `unknown` means this macOS does not
    /// let us identify it; explicit commands are still sent, but automatic
    /// selection stays conservative.
    var ownership: Ownership {
        guard let pid = bridge.nowPlayingPID(), pid > 0,
              let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
            return .unknown
        }
        return bundle.lowercased().contains(bundleFragment) ? .mine : .other
    }

    private var isNowPlaying: Bool { ownership != .other }

    var isPlaying: Bool {
        if metadataDisabled { return assumedPlaying }
        return bridge.isPlaying()
    }

    private func metadata() -> [String: Any]? {
        guard !metadataDisabled else { return nil }
        guard Date().timeIntervalSince(lastMetadataAttempt) > 2 else { return cachedMetadata }
        lastMetadataAttempt = Date()
        guard let info = bridge.nowPlayingInfo() else {
            // This macOS build does not hand now-playing data to third-party
            // apps; stop paying the timeout on every poll.
            metadataDisabled = true
            cachedMetadata = nil
            return nil
        }
        cachedMetadata = info
        return info
    }

    private var cachedMetadata: [String: Any]?

    func snapshot() -> PlayerState {
        var state = PlayerState()
        guard isRunning else { return state }
        state.isRunning = true
        state.volume = SystemVolume.current() ?? state.volume

        guard let info = metadata(), isNowPlaying else {
            state.isPlaying = assumedPlaying
            return state
        }

        state.title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        state.artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        state.album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        state.duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0

        let playing = bridge.isPlaying()
        assumedPlaying = playing
        state.isPlaying = playing

        let elapsed = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
        if let timestamp = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date, playing {
            state.position = min(state.duration, elapsed + Date().timeIntervalSince(timestamp))
        } else {
            state.position = elapsed
        }

        state.hasTrack = !state.title.isEmpty
        return state
    }

    func play() {
        guard isRunning else { return }
        assumedPlaying = true
        bridge.send(.play)
    }

    func pause() {
        guard isRunning else { return }
        assumedPlaying = false
        bridge.send(.pause)
    }

    func playPause() {
        guard isRunning else { return }
        assumedPlaying.toggle()
        bridge.send(.togglePlayPause)
    }

    func stop() {
        guard isRunning, isNowPlaying else { return }
        assumedPlaying = false
        bridge.send(.stop)
    }

    func next() {
        guard isRunning, isNowPlaying else { return }
        bridge.send(.nextTrack)
    }

    func previous() {
        guard isRunning, isNowPlaying else { return }
        bridge.send(.previousTrack)
    }

    func seek(to seconds: Double) {
        guard isRunning, isNowPlaying else { return }
        bridge.setElapsed(seconds)
    }

    func setVolume(_ value: Double) {
        SystemVolume.set(value)
    }

    func fetchArtwork(key: String) -> String? {
        guard isRunning, isNowPlaying, let info = metadata(),
              let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
              !data.isEmpty else { return nil }

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WMZPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let mime = (info["kMRMediaRemoteNowPlayingInfoArtworkMIMEType"] as? String ?? "").lowercased()
        let extensionName: String
        if mime.contains("png") || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { extensionName = "png" }
        else if mime.contains("jpeg") || data.starts(with: [0xFF, 0xD8]) { extensionName = "jpg" }
        else { extensionName = "img" }

        let url = directory.appendingPathComponent("\(bundleFragment)-\(abs(key.hashValue)).\(extensionName)")
        try? data.write(to: url)
        return url.path
    }
}

/// Debug helper behind `wmz media --bundle <fragment>`: read any app through the
/// Now Playing channel (useful when the target app is not installed).
public enum NowPlayingProbe {
    public static func diagnostics() -> String {
        let bridge = MediaRemoteBridge.shared
        let pid = bridge.nowPlayingPID() ?? -1
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "nil"
        return "available=\(bridge.isAvailable) pid=\(pid) bundle=\(bundle) infoKeys=\(bridge.nowPlayingInfo()?.keys.count ?? -1) playing=\(bridge.isPlaying())"
    }

    public static func run(bundleFragment: String, seconds: Double) {
        let player = SystemPlayer(name: bundleFragment, bundleFragment: bundleFragment)
        if ProcessInfo.processInfo.environment["WMZ_DEBUG_NP"] != nil {
            FileHandle.standardError.write(Data("NP \(diagnostics())\n".utf8))
        }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let state = player.snapshot()
            let playing = state.isPlaying ? "playing" : "paused"
            let art = player.fetchArtwork(key: state.title) == nil ? "no" : "yes"
            print("\(playing)  \(state.title) — \(state.artist)  \(Int(state.position))/\(Int(state.duration))s  art:\(art)")
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
    }
}

// MARK: - System volume

/// Tidal keeps its own volume inside the app, but macOS's now-playing volume is
/// the output volume. The skin's volume control adjusts that, via Standard
/// Additions (no extra permission prompt).
enum SystemVolume {
    private static let queue = DispatchQueue(label: "io.github.albertsmit.wmzplayer.volume")
    private static var cached: Double = 60

    static func current() -> Double? {
        queue.sync {
            guard let script = NSAppleScript(source: "output volume of (get volume settings)") else {
                return cached
            }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if let value = Double(result.stringValue ?? "") {
                cached = value
            }
            return cached
        }
    }

    static func set(_ value: Double) {
        let clamped = Int(max(0, min(100, value)))
        queue.async {
            cached = Double(clamped)
            guard let script = NSAppleScript(source: "set volume output volume \(clamped)") else { return }
            var error: NSDictionary?
            _ = script.executeAndReturnError(&error)
        }
    }
}
