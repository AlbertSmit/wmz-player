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
    /// 0–100 as the player reports it; nil when the player has no rating notion.
    public var rating: Int?
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
    /// The `<playlist>` element's `leftStatus` / `rightStatus` templates, e.g.
    /// `"Total Time: %duration%"`. Empty when the skin does not ask for a line.
    public var playlistStatusLeftTemplate: String = ""
    public var playlistStatusRightTemplate: String = ""
    /// The templates above with their tokens filled in for the cached rows.
    /// The renderer substitutes from the element when these are empty.
    public var playlistLeftStatus: String = ""
    public var playlistRightStatus: String = ""

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
    case setRating(Int)          // 0...100, from the skin's star buttons
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

    /// Actions the app must still handle even when the skin's script ran: some
    /// skins only record a preference that a hidden controller view polls.
    public var isNavigation: Bool {
        switch self {
        case .openView, .openPanel, .closePanel, .returnToMain,
             .openMedia, .openURL, .closeWindow, .minimizeWindow:
            return true
        default:
            return false
        }
    }
}

public enum SliderTarget: Equatable {
    case seek
    case volume
    case balance
    case unknown
}
