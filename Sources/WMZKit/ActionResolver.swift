import Foundation

/// Turns WMP's command soup into the handful of things a media proxy can do.
enum ActionResolver {

    static func action(for element: Element) -> MediaAction? {
        switch element.name {
        case "playelement": return .play
        case "pauseelement": return .pause
        case "stopelement": return .stop
        case "prevelement": return .previous
        case "nextelement": return .next
        default: break
        }

        if let script = element["onclick"]?.lowercased(), let action = scan(script) {
            return action
        }

        let words = [element["id"], element["image"]]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return keywordAction(words)
    }

    private static func scan(_ script: String) -> MediaAction? {
        if script.contains("playpause") { return .playPause }
        if script.contains("controls.play") { return .play }
        if script.contains("controls.pause") { return .pause }
        if script.contains("controls.stop") { return .stop }
        if script.contains("controls.next") { return .next }
        if script.contains("controls.previous") { return .previous }
        if script.contains("settings.mute") { return .toggleMute }
        if script.contains("exitview") || script.contains("theme.close") { return .closeWindow }
        if script.contains("minimizeview") { return .minimizeWindow }
        if script.contains("returntomediacenter") { return .ignore }
        return nil
    }

    private static func keywordAction(_ words: String) -> MediaAction? {
        func has(_ needle: String) -> Bool { words.contains(needle) }

        // `preview` must not be read as `prev`.
        if has("previous") || has("prev_") || has("_prev") || has("prev.") || words.hasSuffix("prev") { return .previous }
        if has("next") { return .next }
        if has("playpause") { return .playPause }
        if has("pause") { return .pause }
        if has("play") { return .play }
        if has("stop") { return .stop }
        if has("mute") { return .toggleMute }
        if has("close") { return .closeWindow }
        if has("minimize") || has("min_no") { return .minimizeWindow }
        return nil
    }

    static func sliderTarget(for element: Element) -> SliderTarget {
        let haystack = [
            element["value"],
            element.id,
            element["tooltip"],
            element["uptooltip"],
            element["image"]
        ].compactMap { $0?.lowercased() }.joined(separator: " ")

        if haystack.contains("currentposition") || haystack.contains("seek") { return .seek }
        if haystack.contains("volume") || haystack.contains("speaker") { return .volume }
        if haystack.contains("balance") { return .balance }
        return .unknown
    }

    static func isVisible(_ element: Element, state: PlayerState) -> Bool {
        guard let raw = element["visible"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return true }
        if raw == "false" { return false }
        if raw == "true" { return true }
        if raw.hasPrefix("wmpenabled:") {
            return isEnabled(String(raw.dropFirst("wmpenabled:".count)), state: state)
        }
        if raw.hasPrefix("wmpprop:") { return true }
        if let value = Expression.number(raw, lookup: { _ in 0 }) { return value != 0 }
        return true
    }

    static func isEnabled(_ command: String, state: PlayerState) -> Bool {
        switch command {
        case "player.controls.pause": return state.isPlaying
        case "player.controls.play": return !state.isPlaying
        case "player.controls.next": return state.hasTrack
        case "player.controls.previous": return state.hasTrack
        case "player.controls.stop": return state.hasTrack
        case "player.controls.currentposition": return state.hasTrack
        default: return true
        }
    }

    static func isInteractive(_ element: Element) -> Bool {
        if let raw = element["enabled"]?.lowercased(), raw == "false" { return false }
        if let raw = element["visible"]?.lowercased(), raw == "false" { return false }
        return true
    }

    /// The text WMP would put in a `<text>` control, derived from the player
    /// state rather than from the skin's script.
    static func text(for element: Element, state: PlayerState) -> String? {
        let value = element["value"] ?? ""
        let lowered = value.lowercased()

        if !value.isEmpty {
            if lowered.hasPrefix("wmpprop:") || lowered.hasPrefix("jscript:") || lowered.hasPrefix("javascript:") {
                return derivedText(lowered, state: state)
            }
            return value
        }
        return idText(element.id.lowercased(), state: state)
    }

    private static func derivedText(_ binding: String, state: PlayerState) -> String? {
        guard state.hasTrack else { return "" }
        if binding.contains("currentpositionstring") { return timeString(state.position) }
        if binding.contains("durationstring") { return timeString(state.duration) }
        if binding.contains("artist") { return state.artist }
        if binding.contains("album") { return state.album }
        if binding.contains("name") || binding.contains("title") { return state.title }
        if binding.contains("status") { return state.isPlaying ? "Playing" : "Paused" }
        return nil
    }

    private static func idText(_ id: String, state: PlayerState) -> String? {
        if id.contains("artist") { return state.artist }
        if id.contains("album") { return state.album }
        if id.contains("time") || id.contains("position") { return "" }
        if id.contains("status") { return state.isPlaying ? "Playing" : (state.hasTrack ? "Paused" : "") }
        guard state.hasTrack else { return id.isEmpty ? nil : "" }

        if id.contains("metadata") || id.contains("nowplaying") {
            // These boxes are usually small and partly covered by artwork; a
            // second line is more often clipped than useful.
            return state.title
        }
        if id.contains("trackname") || id.contains("tracktitle") || id.contains("songname")
            || id.contains("songtitle") || id == "title" || id.contains("currenttrack") {
            return state.title
        }
        return nil
    }

    static func timeString(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

extension Element {
    public var id: String { self["id"] ?? "" }

    /// WMP skins key artwork to a colour so a rectangular bitmap can have an
    /// irregular, click-through outline. Magenta is the format's default key.
    /// Candidate key colours, most specific first. WMP7's `clippingColor` and
    /// WMP9's `transparencyColor` often disagree on the same element, and some
    /// authors left one stale — so the renderer picks whichever actually occurs
    /// in the artwork.
    public var keyColours: [RGB] {
        var colours: [RGB] = []
        for raw in [self["clippingcolor"], self["transparencycolor"], self["tranparencycolor"]] {
            guard let raw = raw?.lowercased(), raw != "none", raw != "transparent" else { continue }
            if let colour = RGB(hex: raw), !colours.contains(colour) { colours.append(colour) }
        }
        if colours.isEmpty { colours.append(RGB(r: 255, g: 0, b: 255)) }
        return colours
    }
}
