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
/// Every entry point must be called on the main thread: `NSAppleScript` pumps
/// the calling thread's run loop while it waits for Music, and scripts that
/// resolve object references (`current playlist`, `current track`) deadlock
/// when run from a plain dispatch queue.
public enum PlaylistLoader {

    /// Rows around the current track. Returns nil when nothing is playing or
    /// the app has no accessible playlist (Spotify/Tidal are not supported).
    public static func load(application: String, radius: Int) -> PlaylistSnapshot? {
        let radius = max(0, radius)
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
            set firstIndex to idx - \(radius)
            if firstIndex < 1 then set firstIndex to 1
            set lastIndex to idx + \(radius)
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

        let startIndex = max(1, current - radius)
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
