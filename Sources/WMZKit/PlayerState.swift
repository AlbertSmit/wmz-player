import Foundation

public struct PlayerState {
    public var title: String = ""
    public var artist: String = ""
    public var album: String = ""
    public var hasTrack: Bool = false
    public var isPlaying: Bool = false
    public var position: Double = 0
    public var duration: Double = 0
    public var volume: Double = 60
    public var artworkPath: String?
    public var backendName: String = ""
    public var isRunning: Bool = false
    public var error: String?

    // Current queue, filled only while a playlist panel is open.
    public var playlistName: String = ""
    public var playlistRows: [PlaylistRow] = []
    public var playlistTotal: Int = 0
    public var playlistCurrent: Int = 0
    public var playlistStart: Int = 0
    public var playlistOffset: Int = 0

    public init() {}

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

public enum MediaAction: Equatable {
    case play
    case pause
    case playPause
    case stop
    case next
    case previous
    case toggleMute
    case seek(Double)            // absolute seconds
    case seekFraction(Double)    // 0...1
    case volume(Double)          // 0...1
    case playTrack(Int)          // absolute index in the current playlist
    case shuffle
    case repeatMode
    case openView(String)        // exact view id, from theme.openView
    case openPanel(String)       // preference token, e.g. "pl" from remoteCallPl
    case closePanel(String)      // token or view id
    case returnToMain
    case openMedia
    case openURL(String)
    case closeWindow
    case minimizeWindow
    case ignore
}

public enum SliderTarget: Equatable {
    case seek
    case volume
    case balance
    case unknown
}
