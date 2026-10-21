//
//  PlaylistLoader.swift
//  WMZKit
//
//  The playlist window only works against Apple Music: it is the one player on
//  this Mac that exposes its queue over AppleScript. Spotify and Tidal publish
//  the current track (see SystemNowPlaying) but keep the surrounding queue
//  private, so there is nothing here to read from them.
//

import Foundation

public struct PlaylistRow: Equatable {
    /// 1-based position in the playlist.
    public let index: Int
    public let title: String
    public let artist: String
    public let album: String
    /// Seconds.
    public let duration: Double

    public init(index: Int, title: String, artist: String, album: String, duration: Double) {
        self.index = index
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

public struct PlaylistSnapshot {
    public let name: String
    public let total: Int
    /// 1-based, 0 when unknown.
    public let currentIndex: Int
    /// Absolute index of `rows.first`.
    public let startIndex: Int
    public let rows: [PlaylistRow]

    public var isEmpty: Bool { rows.isEmpty }

    public init(name: String, total: Int, currentIndex: Int, startIndex: Int, rows: [PlaylistRow]) {
        self.name = name
        self.total = total
        self.currentIndex = currentIndex
        self.startIndex = startIndex
        self.rows = rows
    }
}

/// Reads the Music queue and exposes the transport bits the skin needs.
///
/// Windows are centred on the playing track by default; `center` pages the same
/// query to any absolute index, which is how the list streams in as the user
/// scrolls away from the current row.
///
/// Every entry point must be called on the main thread: `NSAppleScript` pumps
/// the calling thread's run loop while it waits for Music, and scripts that
/// resolve object references (`current playlist`, `current track`) deadlock
/// when run from a plain dispatch queue. `loadAsync` is the exception: it hands
/// the query to `osascript`, which has a main thread of its own.
public enum PlaylistLoader {

    /// A window of `radius` rows either side of `center`.
    ///
    /// `center` is an absolute, 1-based playlist index. Passing nil anchors the
    /// window on the playing track, which is what the initial load wants; paging
    /// passes the index the user scrolled to, so the same query can fetch any
    /// slice of the queue. The centre is clamped to `1...total` inside the
    /// script; `rows` and `startIndex` stay absolute playlist positions either
    /// way, and `PlaylistSnapshot.currentIndex` still reports the *playing*
    /// track so the renderer can keep highlighting it.
    ///
    /// Returns nil when nothing is playing or the app has no accessible playlist
    /// (Spotify/Tidal are not supported).
    public static func load(application: String, radius: Int, center: Int? = nil) -> PlaylistSnapshot? {
        let radius = max(0, radius)
        let anchorSource = anchorExpression(center)
        // A list, never a delimited string: a U+001F separator was seen hanging
        // the Apple event round-trip on macOS 26.
        let script = """
        tell application \(quoted(application))
            try
                set p to current playlist
            on error
                return {}
            end try
            set n to (count of tracks of p)
            set idx to 0
            try
                set idx to (index of current track)
            end try
            if n is 0 or idx < 1 then return {}
            set anchor to \(anchorSource)
            if anchor < 1 then set anchor to 1
            if anchor > n then set anchor to n
            set firstIndex to anchor - \(radius)
            if firstIndex < 1 then set firstIndex to 1
            set lastIndex to anchor + \(radius)
            if lastIndex > n then set lastIndex to n
            set out to {n, idx, (name of p)}
            repeat with i from firstIndex to lastIndex
                try
                    set t to track i of p
                    set end of out to (name of t)
                    set end of out to (artist of t)
                    set end of out to (album of t)
                    set end of out to ((duration of t) as integer)
                on error
                    set end of out to ""
                    set end of out to ""
                    set end of out to ""
                    set end of out to 0
                end try
            end repeat
            return out
        end tell
        """

        guard let result = execute(script), result.numberOfItems >= 3 else { return nil }

        let total = integer(result.atIndex(1))
        let current = integer(result.atIndex(2))
        guard total > 0, current >= 1 else { return nil }

        // The script clamps the centre to the playlist; mirror it here so the
        // row numbers line up with the rows it collected.
        let anchor = min(max(center ?? current, 1), total)
        let startIndex = max(1, anchor - radius)
        let rowCount = (result.numberOfItems - 3) / 4
        guard rowCount > 0 else { return nil }

        var rows: [PlaylistRow] = []
        rows.reserveCapacity(rowCount)
        for row in 0..<rowCount {
            let base = 4 + row * 4
            rows.append(PlaylistRow(
                index: startIndex + row,
                title: text(result.atIndex(base)),
                artist: text(result.atIndex(base + 1)),
                album: text(result.atIndex(base + 2)),
                duration: Double(integer(result.atIndex(base + 3)))
            ))
        }

        return PlaylistSnapshot(
            name: text(result.atIndex(3)),
            total: total,
            currentIndex: current,
            startIndex: startIndex,
            rows: rows
        )
    }

    /// Same query as `load`, but runs `osascript` on a background queue and
    /// calls back on the main queue. Never blocks the caller. `center` works as
    /// it does in `load`, so a page far from the playing track costs the same
    /// as the initial window.
    ///
    /// Multi-step scripts cannot run off the main thread here, so a subprocess
    /// is the only way to keep a 35k-track library from stalling the UI.
    public static func loadAsync(application: String, radius: Int, center: Int? = nil,
                                 completion: @escaping (PlaylistSnapshot?) -> Void) {
        let radius = max(0, radius)
        let script = textScript(application: application, radius: radius, center: center)
        DispatchQueue.global(qos: .utility).async {
            let output = runOSAScript(script)
            let snapshot = output.flatMap { parseText($0, radius: radius, center: center) }
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    /// Plays an absolute, 1-based index in the current playlist.
    public static func play(index: Int, application: String) -> Bool {
        guard index > 0 else { return false }
        let script = """
        tell application \(quoted(application))
            play track \(index) of current playlist
            return true
        end tell
        """
        guard let result = execute(script) else { return false }
        return boolean(result) ?? false
    }

    /// Toggles shuffle and returns the new state, or nil on failure.
    public static func toggleShuffle(application: String) -> Bool? {
        let script = """
        tell application \(quoted(application))
            set s to shuffle enabled
            set shuffle enabled to not s
            return shuffle enabled
        end tell
        """
        guard let result = execute(script) else { return nil }
        return boolean(result)
    }

    /// Cycles off -> all -> one -> off, returning the new state.
    public static func cycleRepeat(application: String) -> String? {
        let script = """
        tell application \(quoted(application))
            set r to (song repeat as string)
            if r is "off" then
                set song repeat to all
                return "all"
            else if r is "all" then
                set song repeat to one
                return "one"
            else
                set song repeat to off
                return "off"
            end if
        end tell
        """
        guard let result = execute(script) else { return nil }
        let value = text(result)
        return ["off", "all", "one"].contains(value) ? value : nil
    }

    /// Hands a local file to the player; Music imports it and starts playing.
    public static func openFile(_ url: URL, application: String) -> Bool {
        let script = """
        tell application \(quoted(application))
            open POSIX file \(quoted(url.path))
            play
        end tell
        """
        return execute(script) != nil
    }

    // MARK: - Plumbing

    /// What the script should centre the window on: the given absolute index,
    /// or `idx` (the playing track) when the caller did not ask for a page.
    private static func anchorExpression(_ center: Int?) -> String {
        center.map(String.init) ?? "idx"
    }

    /// The same query as `load`, but returning one tab-separated line per row:
    /// `osascript` prints a returned string verbatim, while a list would come
    /// back as a human-readable dump. `tab` and `linefeed` are AppleScript
    /// constants, so the source stays free of control characters.
    ///
    /// The `is running` test does not launch the app, and a `tell` block would,
    /// so a background poll must not skip it.
    private static func textScript(application: String, radius: Int, center: Int?) -> String {
        let anchorSource = anchorExpression(center)
        return """
        if application \(quoted(application)) is not running then return ""
        tell application \(quoted(application))
            try
                set p to current playlist
            on error
                return ""
            end try
            set n to (count of tracks of p)
            set idx to 0
            try
                set idx to (index of current track)
            end try
            if n is 0 or idx < 1 then return ""
            set anchor to \(anchorSource)
            if anchor < 1 then set anchor to 1
            if anchor > n then set anchor to n
            set firstIndex to anchor - \(radius)
            if firstIndex < 1 then set firstIndex to 1
            set lastIndex to anchor + \(radius)
            if lastIndex > n then set lastIndex to n
            set out to ((n as string) & tab & (idx as string) & tab & (name of p) & linefeed)
            repeat with i from firstIndex to lastIndex
                try
                    set t to track i of p
                    set out to out & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (((duration of t) as integer) as string) & linefeed
                on error
                    set out to out & tab & tab & tab & "0" & linefeed
                end try
            end repeat
            return out
        end tell
        """
    }

    /// Runs the script in a child `osascript` and returns what it printed, or
    /// nil when it failed, stayed silent, or outlived the watchdog.
    private static func runOSAScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            NSLog("WMZPlayer: osascript failed to start: \(error)")
            return nil
        }

        // Both pipes are drained on their own queues: a child that fills one
        // buffer would otherwise block before it could exit.
        let drained = DispatchGroup()
        var out = Data()
        var diagnostics = Data()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            out = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            diagnostics = stderr.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }

        guard exited.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            // Give the termination handler a moment to reap it; without the
            // wait the killed child would linger as a zombie.
            _ = exited.wait(timeout: .now() + 2)
            NSLog("WMZPlayer: playlist script timed out")
            return nil
        }
        // The child has exited, so both read ends see EOF right away; the wait
        // is only there so a stuck drain cannot leak the caller's queue.
        guard drained.wait(timeout: .now() + 1) == .success else { return nil }
        guard process.terminationStatus == 0 else {
            let message = String(data: diagnostics, encoding: .utf8) ?? ""
            NSLog("WMZPlayer: osascript failed: \(message)")
            return nil
        }
        return String(data: out, encoding: .utf8)
    }

    /// Mirrors the descriptor walk in `load`. A row that does not parse still
    /// consumes an index, so the numbers stay aligned with the playlist.
    private static func parseText(_ output: String, radius: Int, center: Int?) -> PlaylistSnapshot? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard let header = lines.first else { return nil }
        let fields = header.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 3,
              let total = Int(fields[0]),
              let current = Int(fields[1]),
              total > 0, current >= 1
        else { return nil }

        // Same clamp as the script, so the row numbers match what it collected.
        let anchor = min(max(center ?? current, 1), total)
        let startIndex = max(1, anchor - radius)
        var rows: [PlaylistRow] = []
        rows.reserveCapacity(lines.count)
        for (offset, line) in lines.dropFirst().enumerated() {
            let row = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard row.count >= 4, let duration = Int(row[row.count - 1]) else { continue }
            rows.append(PlaylistRow(
                index: startIndex + offset,
                title: String(row[0]),
                artist: String(row[1]),
                // A tab inside a track name pushes the fields right; the
                // surplus lands in the album rather than losing the row.
                album: row[2..<(row.count - 1)].joined(separator: "\t"),
                duration: Double(duration)
            ))
        }
        guard !rows.isEmpty else { return nil }

        return PlaylistSnapshot(
            name: fields[2...].joined(separator: "\t"),
            total: total,
            currentIndex: current,
            startIndex: startIndex,
            rows: rows
        )
    }

    private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("WMZPlayer: playlist script failed: \(error)")
            return nil
        }
        return result
    }

    /// AppleScript string literals need both characters escaped, backslash
    /// first, or `"C:\Music\a.mp3"` would end the literal at the quote.
    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func text(_ descriptor: NSAppleEventDescriptor?) -> String {
        descriptor?.stringValue ?? ""
    }

    /// Durations come back as integers so no decimal separator is involved;
    /// track counts and indices are small enough for the 32-bit event type.
    private static func integer(_ descriptor: NSAppleEventDescriptor?) -> Int {
        guard let descriptor else { return 0 }
        switch descriptor.descriptorType {
        case typeSInt16, typeSInt32, typeSInt64:
            return Int(descriptor.int32Value)
        default:
            return Int(descriptor.stringValue ?? "") ?? 0
        }
    }

    private static func boolean(_ descriptor: NSAppleEventDescriptor) -> Bool? {
        switch descriptor.descriptorType {
        case typeTrue: return true
        case typeFalse: return false
        default: return nil
        }
    }
}
