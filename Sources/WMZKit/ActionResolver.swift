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

        let original = element["onclick"] ?? ""
        let script = original.lowercased()
        if let action = panelAction(script, original: original) { return action }
        if let action = scan(script) { return action }

        let words = [element["id"], element["image"]]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return keywordAction(words)
    }

    /// Navigation and shell actions, which are written as script fragments but
    /// map cleanly onto the app: open/close a panel view, open a file or URL,
    /// shuffle/repeat, return to the main window.
    private static func panelAction(_ script: String, original: String) -> MediaAction? {
        if script.contains("exitview") || script.contains("theme.close") { return .closeWindow }
        if script.contains("minimizeview") { return .minimizeWindow }
        if script.contains("returntomediacenter") { return .returnToMain }

        if let id = quoted(after: "openview(", in: original) {
            return .openView(id)
        }
        if let id = quoted(after: "onviewclose(", in: original) ?? quoted(after: "closeview(", in: original) {
            return .closePanel(id)
        }
        let preference = quotedStrings(after: "savepreference(", in: original)
        if preference.count >= 2, preference[1].lowercased() == "true",
           let token = viewToken(from: preference[0]) {
            return .openPanel(token)
        }
        if let value = quoted(after: "ratesong(", in: original), let rating = Int(value) {
            return .setRating(rating)
        }
        if script.contains("opendialog") || script.contains("openmediafile") { return .openMedia }
        if let url = quoted(after: "launchurl(", in: original) { return .openURL(url) }
        if script.contains("setmode") || script.contains("settings.getmode") {
            if script.contains("shuffle") { return .shuffle }
            if script.contains("repeat") { return .repeatMode }
        }
        return nil
    }

    /// The sound a control plays when clicked, e.g. `checkSoundPref('button.wav')`.
    static func sound(for element: Element) -> String? {
        guard let script = element["onclick"] else { return nil }
        return quoted(after: "playsound(", in: script) ?? quoted(after: "checksoundpref(", in: script)
    }

    /// "remoteCallPl" -> "pl", "plViewer" -> "pl", "vidViewer" -> "video".
    private static func viewToken(from key: String) -> String? {
        let lowered = key.lowercased()
        let looksLikeView = lowered.contains("remotecall")
            || lowered.hasSuffix("viewer")
            || lowered.hasSuffix("view")
        guard looksLikeView else { return nil }

        var token = lowered
            .replacingOccurrences(of: "remotecall", with: "")
            .replacingOccurrences(of: "viewer", with: "")
            .replacingOccurrences(of: "view", with: "")
        token = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard !token.isEmpty else { return nil }
        switch token {
        case "vid": return "video"
        case "exit", "minimize", "main", "control": return nil
        default: return token
        }
    }

    /// Single-quoted arguments of a call, preserving case.
    private static func quotedStrings(after marker: String, in text: String) -> [String] {
        guard let range = text.range(of: marker, options: .caseInsensitive) else { return [] }
        let rest = text[range.upperBound...]
        var values: [String] = []
        var index = rest.startIndex
        while index < rest.endIndex, values.count < 3 {
            let character = rest[index]
            if character == ")" { break }
            if character == "'" || character == "\"" {
                let quote = character
                let start = rest.index(after: index)
                guard let close = rest[start...].firstIndex(of: quote) else { break }
                let value = String(rest[start..<close]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { values.append(value) }
                index = rest.index(after: close)
                continue
            }
            index = rest.index(after: index)
        }
        return values
    }

    private static func quoted(after marker: String, in text: String) -> String? {
        quotedStrings(after: marker, in: text).first
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
        if has("shuffle") || has("shuff") { return .shuffle }
        if has("repeat") { return .repeatMode }
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
        if let rating = state.rating, let override = ratingVisibility(element, rating: rating) {
            return override
        }
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

    /// WMP's rating widget is a stack of `rate1…5` (filled), `blankRate1…5`
    /// (empty) and `autoRate1…5` buttons. The skin's script normally toggles
    /// them; we drive them from the player's rating instead.
    private static func ratingVisibility(_ element: Element, rating: Int) -> Bool? {
        let id = element.id.lowercased()
        let stars = Int((Double(max(0, min(100, rating))) / 20).rounded())
        if id == "emptyrate" { return false }
        if let slot = trailingNumber(id, prefix: "autorate") { _ = slot; return false }
        if let slot = trailingNumber(id, prefix: "blankrate") { return slot > stars }
        if let slot = trailingNumber(id, prefix: "rate") { return slot <= stars }
        return nil
    }

    private static func trailingNumber(_ text: String, prefix: String) -> Int? {
        guard text.hasPrefix(prefix) else { return nil }
        let suffix = text.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(suffix)
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

        let identifier = element.id.lowercased()
        // `locSomething` elements are strings the skin's script reads for
        // tooltips and messages; WMP does not paint them.
        if identifier.hasPrefix("loc") { return nil }
        if identifier.contains("ratetext"), let rating = state.rating {
            return rating == 0 ? "Rate Song" : "Rating"
        }
        // "test" is the placeholder several skins leave in their effect name.
        if ["test", "placeholder", "lorem ipsum"].contains(lowered) { return "" }

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
