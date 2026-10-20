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
