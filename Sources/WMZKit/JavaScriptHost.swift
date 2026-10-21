import Foundation
import JavaScriptCore

@_silgen_name("JSContextGetGroup")
private func WMZContextGroup(_ context: JSGlobalContextRef!) -> JSContextGroupRef!

@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func WMZSetExecutionTimeLimit(
    _ group: JSContextGroupRef!,
    _ limit: Double,
    _ callback: (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?,
    _ context: UnsafeMutableRawPointer?
)


/// What the skin's script is allowed to ask the app to do.
public protocol JavaScriptHostDelegate: AnyObject {
    func jsPerform(_ action: MediaAction)
    func jsOpenView(_ id: String)
    func jsCloseView(_ id: String)
    func jsReturnToMediaCenter()
    func jsOpenDialog()
    func jsPlaySound(_ name: String)
    func jsNeedsDisplay()
}

/// Runs a view's own JScript against our scene graph.
///
/// Skins are written against WMP's object model: every element id is a global,
/// and `player`, `theme`, `view`, `eq` and `mediacenter` behave like the real
/// thing. This host implements just enough of it for layout, visibility,
/// animation, navigation and transport to work.
public final class JavaScriptHost: NSObject {
    public private(set) var isActive = false
    /// Called when the skin's visualizer buttons cycle styles.
    public var onEffectChanged: ((Int) -> Void)?

    fileprivate let scene: Scene
    private let registry: [String: SceneNode]
    fileprivate weak var delegate: JavaScriptHostDelegate?
    private let context = JSContext()!
    private let preferencePrefix: String

    private var state = PlayerState()
    private var timer: Timer?
    private var tweenTimer: Timer?
    private var tweens: [Tween] = []
    fileprivate var timerInterval: Double = 0
    fileprivate var onTimerScript: String?
    private var reportedErrors = Set<String>()
    private var didActDuringCall = false
    private var effectIndex = 0
    private let effectTitles = ["Bars", "Wave", "Spikes", "Dots"]

    private var lastPlayState = ""
    private var lastTitle = ""
    private var lastSecond = -1

    public init(scene: Scene, delegate: JavaScriptHostDelegate?,
                registry: [String: SceneNode] = [:]) {
        self.scene = scene
        self.registry = registry
        self.delegate = delegate
        let name = scene.document.sourceURL.deletingPathExtension().lastPathComponent
        self.preferencePrefix = "skin.\(name)."
        super.init()
        // A broken skin must not wedge the app: cap any single evaluation.
        WMZSetExecutionTimeLimit(WMZContextGroup(context.jsGlobalContextRef), 2.0, nil, nil)
        context.exceptionHandler = { [weak self] _, exception in
            self?.report(exception)
        }
    }

    deinit {
        timer?.invalidate()
        tweenTimer?.invalidate()
    }

    // MARK: - Lifecycle

    public func start() {
        guard scene.view["scriptfile"] != nil else { return }
        installBridge()

        let scripts = scriptSources()
        guard !scripts.isEmpty else { return }
        for source in scripts {
            context.evaluateScript(source)
            if let exception = context.exception {
                report(exception)
                context.exception = nil
            }
        }
        isActive = true
        if ProcessInfo.processInfo.environment["WMZ_DEBUG_JS"] != nil {
            NSLog("JS %@ active scripts=%d onTimer=%@ interval=%@", scene.view.id, scripts.count,
                  scene.view["ontimer"] ?? "-", scene.view["timerinterval"] ?? "-")
        }

        onTimerScript = scene.view["ontimer"]
        timerInterval = Double(scene.view.int("timerinterval") ?? 0)
        restartTimer()

        if let load = scene.view["onload"] {
            _ = call(load)
        }
    }

    private func scriptSources() -> [String] {
        guard let list = scene.view["scriptfile"] else { return [] }
        var sources: [String] = []
        for entry in list.split(separator: ";") {
            let name = entry.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.lowercased().hasPrefix("res://") else { continue }
            guard let url = scene.assets.url(for: name), let data = try? Data(contentsOf: url) else { continue }
            sources.append(WMLParser.decodeText(data))
        }
        return sources
    }

    // MARK: - Calls

    @discardableResult
    public func call(_ script: String) -> Bool {
        guard isActive else { return false }
        if ProcessInfo.processInfo.environment["WMZ_DEBUG_JS"] != nil {
            NSLog("JS %@ call: %@", scene.view.id, script)
        }
        didActDuringCall = false
        var source = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return false }
        if source.lowercased().hasPrefix("jscript:") { source = String(source.dropFirst(8)) }
        context.exception = nil
        context.evaluateScript(source)
        if let exception = context.exception {
            report(exception)
            context.exception = nil
            // The script may have done its work before hitting an unknown helper;
            // in that case don't also run the parsed fallback action.
            return didActDuringCall
        }
        delegate?.jsNeedsDisplay()
        return true
    }

    public func setEventKey(_ keyCode: Int) {
        context.setObject(["keyCode": keyCode], forKeyedSubscript: "event" as NSString)
    }

    public func update(_ state: PlayerState) {
        self.state = state
        guard isActive else { return }
        let player = scene.view.firstChild(named: "player")
        let controls = player?.firstChild(named: "controls")

        let playState = state.isPlaying ? 3 : (state.hasTrack ? 2 : 1)
        if "\(playState)" != lastPlayState {
            lastPlayState = "\(playState)"
            context.setObject(playState, forKeyedSubscript: "NewState" as NSString)
            fire(player, "playstate_onchange")
            fire(player, "openstate_onchange")
        }
        if state.title != lastTitle {
            lastTitle = state.title
            context.setObject(state.title, forKeyedSubscript: "status" as NSString)
            fire(player, "status_onchange")
            fire(player, "currentplaylist_onchange")
        }
        let second = Int(state.position)
        if second != lastSecond {
            lastSecond = second
            fire(controls, "currentposition_onchange")
        }
    }

    private func fire(_ element: Element?, _ attribute: String) {
        guard let script = element?[attribute] else { return }
        _ = call(script)
    }

    // MARK: - Timer

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard isActive, timerInterval > 0, let script = onTimerScript, !script.isEmpty else { return }
        let interval = max(0.05, timerInterval / 1000)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.call(script)
            self?.delegate?.jsNeedsDisplay()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if ProcessInfo.processInfo.environment["WMZ_DEBUG_JS"] != nil {
            NSLog("JS timer %@ every %.3fs script=%@", scene.view.id, interval, script)
        }
    }

    // MARK: - Tweens

    private struct Tween {
        let started: Date
        let duration: TimeInterval
        let step: (_ progress: Double) -> Void
    }

    private func addTween(_ duration: TimeInterval, _ step: @escaping (Double) -> Void) {
        tweens.append(Tween(started: Date(), duration: max(0, duration), step: step))
        if tweenTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.advanceTweens()
            }
            RunLoop.main.add(timer, forMode: .common)
            tweenTimer = timer
        }
    }

    private func advanceTweens() {
        guard !tweens.isEmpty else {
            tweenTimer?.invalidate()
            tweenTimer = nil
            return
        }
        let now = Date()
        tweens.removeAll { tween in
            let elapsed = now.timeIntervalSince(tween.started)
            let progress = tween.duration <= 0 ? 1 : min(1, elapsed / tween.duration)
            tween.step(progress)
            return progress >= 1
        }
        delegate?.jsNeedsDisplay()
    }

    // MARK: - Bridge

    private func installBridge() {
        let bridge = Bridge(host: self)
        context.setObject(bridge, forKeyedSubscript: "__bridge" as NSString)
        // JavaScript is case sensitive: expose the ids exactly as the skin
        // spells them, not the lowercased lookup keys. Every open view's
        // elements are visible to every script, like WMP's single global scope.
        var seen = Set<String>()
        var ids: [String] = []
        for node in Array(scene.nodes.values) + Array(registry.values) {
            let id = node.element.id
            guard !id.isEmpty, seen.insert(id.lowercased()).inserted else { continue }
            ids.append(id)
        }
        context.setObject(ids.sorted(), forKeyedSubscript: "WMZ_ELEMENT_IDS" as NSString)
        context.evaluateScript(Self.prelude)
    }

    fileprivate func node(_ id: String) -> SceneNode? {
        let key = id.lowercased()
        return scene.nodes[key] ?? registry[key]
    }

    fileprivate func get(_ id: String, _ property: String) -> Any? {
        guard let node = node(id) else { return nil }
        switch property.lowercased() {
        case "left": return node.frame.minX
        case "top": return node.frame.minY
        case "width": return node.frame.width
        case "height": return node.frame.height
        case "visible":
            return node.visibleOverride ?? (node.element["visible"]?.lowercased() != "false")
        case "alphablend": return Int((node.alpha * 255).rounded())
        case "value":
            // Sliders read their live value, not the wmpprop binding in the XML.
            if let slider = node.slider {
                switch slider.target {
                case .seek: return state.position
                case .volume: return state.volume
                case .balance: return 0
                case .unknown: return 0
                }
            }
            return node.textOverride ?? node.element["value"] ?? ""
        case "backgroundimage": return node.backgroundOverride ?? node.element["backgroundimage"] ?? ""
        case "image": return node.imageOverride ?? node.element["image"] ?? ""
        case "enabled": return node.enabledOverride ?? (node.element["enabled"]?.lowercased() != "false")
        case "tooltip", "uptooltip":
            return node.element["tooltip"] ?? node.element["uptooltip"] ?? ""
        case "currenteffecttitle":
            return node.kind == .effects ? effectTitles[effectIndex] : ""
        case "currentpresettitle":
            return node.kind == .effects ? "Default" : ""
        case "currenteffecttype", "currentpreset":
            return ""
        default: return nil
        }
    }

    fileprivate func set(_ id: String, _ property: String, _ raw: Any?) {
        guard let node = node(id) else { return }
        let string = (raw as? String) ?? ""
        switch property.lowercased() {
        case "left":
            if let value = number(raw) { node.move(by: CGSize(width: value - node.frame.minX, height: 0)) }
        case "top":
            if let value = number(raw) { node.move(by: CGSize(width: 0, height: value - node.frame.minY)) }
        case "width":
            if let value = number(raw) { node.setSize(CGSize(width: value, height: node.frame.height)) }
        case "height":
            if let value = number(raw) { node.setSize(CGSize(width: node.frame.width, height: value)) }
        case "visible":
            node.visibleOverride = bool(raw)
        case "alphablend":
            if let value = number(raw) { node.alpha = CGFloat(max(0, min(255, value))) / 255 }
        case "value":
            // As in WMP, assigning a slider's value only moves the thumb. Skins
            // mirror `currentPosition` into it every second; seeking on that
            // made playback skip back to the whole second.
            if node.slider == nil { node.textOverride = string }
        case "backgroundimage":
            node.backgroundOverride = string
        case "image":
            node.imageOverride = string
        case "enabled":
            node.enabledOverride = bool(raw)
        default:
            break
        }
    }

    fileprivate func alphaTo(_ id: String, _ value: Double, _ milliseconds: Double) {
        guard let node = node(id), value.isFinite, milliseconds.isFinite else { return }
        let target = CGFloat(max(0, min(255, value))) / 255
        let duration = max(0, milliseconds) / 1000
        let start = node.alpha
        guard duration > 0 else { node.alpha = target; return }
        addTween(duration) { progress in
            node.alpha = start + (target - start) * CGFloat(progress)
        }
    }

    fileprivate func moveTo(_ id: String, _ x: Double, _ y: Double, _ milliseconds: Double) {
        guard let node = node(id), x.isFinite, y.isFinite, milliseconds.isFinite else { return }
        let from = node.frame.origin
        let to = CGPoint(x: x, y: y)
        let duration = max(0, milliseconds) / 1000
        guard duration > 0 else {
            node.move(by: CGSize(width: to.x - from.x, height: to.y - from.y))
            return
        }
        var last = from
        addTween(duration) { progress in
            let point = CGPoint(x: from.x + (to.x - from.x) * CGFloat(progress),
                                y: from.y + (to.y - from.y) * CGFloat(progress))
            node.move(by: CGSize(width: point.x - last.x, height: point.y - last.y))
            last = point
        }
    }

    fileprivate func noteAction() {
        didActDuringCall = true
    }

    /// The effects element's next/previous buttons cycle our visualizer styles.
    fileprivate func effectStep(_ id: String, _ delta: Int) {
        if ProcessInfo.processInfo.environment["WMZ_DEBUG_JS"] != nil {
            NSLog("effectStep id=%@ delta=%d kind=%@ delegate=%@", id, delta,
                  String(describing: node(id)?.kind), delegate == nil ? "nil" : "ok")
        }
        guard node(id)?.kind == .effects else { return }
        effectIndex = (effectIndex + delta + effectTitles.count) % effectTitles.count
        onEffectChanged?(effectIndex)
    }

    fileprivate func setTimerInterval(_ milliseconds: Double) {
        timerInterval = milliseconds
        restartTimer()
    }

    fileprivate func setOnTimer(_ script: String) {
        onTimerScript = script
        restartTimer()
    }

    fileprivate func preference(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: preferencePrefix + key)
    }

    fileprivate func savePreference(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: preferencePrefix + key)
    }

    fileprivate var player: PlayerState { state }

    fileprivate func report(_ exception: JSValue?) {
        let message = exception?.toString() ?? "unknown error"
        guard !reportedErrors.contains(message) else { return }
        reportedErrors.insert(message)
        NSLog("WMZPlayer: script error in %@: %@", scene.view.id, message)
    }

    private func number(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber { result = number.doubleValue }
        else if let string = value as? String { result = Double(string) }
        else { result = nil }
        guard let result, result.isFinite else { return nil }
        return result
    }

    private func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            let lowered = string.lowercased()
            if lowered == "true" { return true }
            if lowered == "false" { return false }
        }
        return nil
    }

    // MARK: - JS prelude

    private static let prelude = #"""
    var __elements = {};
    function __mk(id) {
        var o = {};
        ['left','top','width','height','visible','alphaBlend','value','backgroundImage',
         'image','enabled','toolTip','upToolTip','tooltip','currentPreset'].forEach(function(p) {
            Object.defineProperty(o, p, {
                get: function() { return __bridge.get(id, p); },
                set: function(v) { __bridge.set(id, p, v); },
                enumerable: true,
                configurable: true
            });
        });
        o.alphaBlendTo = function(v, ms) { __bridge.alphaTo(id, v, ms || 0); };
        o.alphabendto = o.alphaBlendTo;
        o.moveTo = function(x, y, ms) { __bridge.moveTo(id, x, y, ms || 0); };
        o.moveto = o.moveTo;
        o.size = function() {};
        o.next = function() { __bridge.effectStep(id, 1); };
        o.previous = function() { __bridge.effectStep(id, -1); };
        // Elements expose APIs we do not model (playlist column resizing,
        // effect stepping, …). Stubbing them keeps a skin's script alive.
        ['setColumnResizeMode','setColumns','setColumnWidth','setSortColumn','sort',
         'next','previous','add','remove','clear','refresh','setFocus','show','hide']
            .forEach(function(m) { if (!o[m]) o[m] = function() {}; });
        return o;
    }
    (WMZ_ELEMENT_IDS || []).forEach(function(id) {
        if (id && !(id in globalThis)) { globalThis[id] = __mk(id); }
    });

    // WMP's object model is case-insensitive and skins mix spellings freely
    // (`player.Settings`, `theme.CurrentViewId`). This resolves an unknown
    // spelling to the property we do define; the explicit aliases further down
    // still cover the hot paths without a lookup.
    function __caseInsensitive(target) {
        var names = {};
        Object.keys(target).forEach(function(k) { names[k.toLowerCase()] = k; });
        return new Proxy(target, {
            get: function(object, key) {
                var name = String(key);
                if (name in object) { return object[name]; }
                var alias = names[name.toLowerCase()];
                return alias === undefined ? undefined : object[alias];
            },
            set: function(object, key, value) {
                var name = String(key);
                object[(name in object) ? name : (names[name.toLowerCase()] || name)] = value;
                return true;
            }
        });
    }

    // Playlist and library objects. We have no media library, so they are
    // empty, but skins walk them (`getAll().count`, `item(i).getItemInfo(…)`)
    // and must not trip over a missing method.
    function __mediaItem() {
        return {
            name: '', artist: '', album: '', duration: 0, durationString: '0:00',
            getItemInfo: function() { return ''; },
            getItemInfoByAtom: function() { return ''; },
            getAttributeName: function() { return ''; },
            setItemInfo: function() { }
        };
    }
    function __emptyList(name) {
        return {
            name: name || '',
            count: 0,
            item: function() { return null; },
            getItemInfo: function() { return ''; }
        };
    }

    var __currentPlaylist = {
        get count() { return __bridge.playlistCount(); },
        get name() { return __bridge.state('playlistName'); },
        set name(v) { },
        item: function(i) {
            i = Number(i);
            return i >= 0 && i < __bridge.playlistCount() ? __mediaItem() : null;
        },
        getItemInfo: function(i, key) { return ''; },
        getItemInfoByAtom: function(i, atom) { return ''; }
    };

    var __mediaCollection = {
        get count() { return 0; },
        item: function() { return null; },
        getItemInfo: function() { return ''; },
        getAll: function() { return __emptyList(); },
        getByAttribute: function() { return __emptyList(); },
        getByAttributeStringCollection: function() { return __emptyList(); },
        getByAlbum: function() { return __emptyList(); },
        getByAuthor: function() { return __emptyList(); },
        getMediaAtom: function() { return 0; },
        add: function(media) { return media || __mediaItem(); },
        remove: function() { }
    };

    var __playlistCollection = {
        get count() { return 0; },
        item: function() { return null; },
        getAll: function() { return __emptyList(); },
        getByName: function(name) { return __emptyList(name); },
        newPlaylist: function(name) { return __emptyList(name); },
        remove: function() { return false; }
    };

    var __cdromCollection = {
        get count() { return 0; },
        item: function() { return { eject: function() { }, driveSpecifier: '' }; },
        get driveSpecifier() { return ''; }
    };

    var __fullScreen = false;
    var __url = '';

    var player = {
        controls: {
            play: function() { __bridge.media('play'); },
            pause: function() { __bridge.media('pause'); },
            stop: function() { __bridge.media('stop'); },
            next: function() { __bridge.media('next'); },
            previous: function() { __bridge.media('previous'); },
            playpause: function() { __bridge.media('playpause'); },
            isAvailable: function() { return true; },
            get currentPosition() { return __bridge.state('position'); },
            set currentPosition(v) { __bridge.media('seek:' + v); },
            get currentPositionString() { return __bridge.state('positionString'); }
        },
        settings: {
            get volume() { return __bridge.state('volume'); },
            set volume(v) { __bridge.media('volume:' + v); },
            get mute() { return __bridge.state('mute'); },
            set mute(v) { __bridge.media('mute:' + (v ? 'on' : 'off')); },
            get balance() { return 0; },
            set balance(v) { },
            getMode: function(mode) { return __bridge.mode(mode); },
            setMode: function(mode, value) { __bridge.setMode(mode, value); }
        },
        currentMedia: {
            get name() { return __bridge.mediaInfo('name'); },
            get artist() { return __bridge.mediaInfo('artist'); },
            get album() { return __bridge.mediaInfo('album'); },
            get duration() { return __bridge.state('duration'); },
            get durationString() { return __bridge.mediaInfo('durationString'); },
            get imageSourceWidth() { return 0; },
            get imageSourceHeight() { return 0; },
            // Skins branch on this to tell CD/DVD from file playback.
            get sourceURL() { return ''; },
            getItemInfo: function(key) { return __bridge.itemInfo(key); },
            getItemInfoByAtom: function(atom) { return ''; },
            getAttributeName: function() { return ''; },
            setItemInfo: function(key, value) { }
        },
        get currentPlaylist() { return __currentPlaylist; },
        mediaCollection: __mediaCollection,
        playlistCollection: __playlistCollection,
        cdromCollection: __cdromCollection,
        dvd: { isAvailable: function() { return false; }, title: 0, chapter: 0 },
        versionInfo: '11.0.0.0',
        get fullScreen() { return __fullScreen; },
        set fullScreen(v) { __fullScreen = !!v; },
        get URL() { return __url; },
        set URL(v) { __url = String(v); },
        launchURL: function(url) { __bridge.media('openurl:' + url); },
        newPlaylist: function(name) { return __emptyList(name); },
        network: { bufferingProgress: 100, receptionQuality: 100, downloadProgress: 100 },
        get playState() { return __bridge.state('playState'); },
        get openState() { return __bridge.state('openState'); },
        get status() { return __bridge.mediaInfo('name'); }
    };

    var theme = {
        savePreference: function(key, value) { __bridge.savePref(key, String(value)); },
        loadPreference: function(key) {
            var v = __bridge.loadPref(key);
            return (v === null || v === undefined) ? '--' : v;
        },
        openView: function(id) { __bridge.openView(id); },
        closeView: function(id) { __bridge.closeView(id); },
        playSound: function(name) { __bridge.playSound(name); },
        openDialog: function(kind) { __bridge.openDialog(); },
        openViewRelative: function(id) { __bridge.openView(id); },
        logString: function(message) { },
        loadString: function(key) { return ''; },
        get currentViewID() { return __bridge.currentView(); },
        set currentViewID(v) { }
    };

    var view = {
        get width() { return __bridge.viewSize('width'); },
        get height() { return __bridge.viewSize('height'); },
        get minWidth() { return __bridge.viewSize('width'); },
        get minHeight() { return __bridge.viewSize('height'); },
        get timerInterval() { return __bridge.timerInterval(); },
        set timerInterval(v) { __bridge.setTimerInterval(v); },
        get onTimer() { return __bridge.onTimer(); },
        set onTimer(v) { __bridge.setOnTimer(v); },
        returnToMediaCenter: function() { __bridge.returnToMain(); },
        close: function() { __bridge.media('close'); },
        minimize: function() { __bridge.media('minimize'); },
        focusObjectID: '',
        size: function() {}
    };

    var eq = {
        currentPreset: 0,
        enhancedAudio: true,
        gainLevel: 0,
        speakerSize: 0,
        crossFade: true,
        crossFadeWindow: 7000,
        reset: function() {}
    };

    var mediacenter = {
        effectType: '',
        effectPreset: '',
        videoZoom: 100
    };

    // WMP's object model is case-insensitive; skins are inconsistent about it.
    theme.savepreference = theme.savePreference;
    theme.loadpreference = theme.loadPreference;
    theme.openview = theme.openView;
    theme.closeview = theme.closeView;
    theme.playsound = theme.playSound;
    theme.opendialog = theme.openDialog;
    theme.loadstring = theme.loadString;

    Object.defineProperty(view, 'timerinterval', {
        get: function() { return __bridge.timerInterval(); },
        set: function(v) { __bridge.setTimerInterval(v); }
    });
    Object.defineProperty(view, 'ontimer', {
        get: function() { return __bridge.onTimer(); },
        set: function(v) { __bridge.setOnTimer(v); }
    });
    view.returntomediacenter = view.returnToMediaCenter;

    Object.defineProperty(player.controls, 'currentposition', {
        get: function() { return __bridge.state('position'); },
        set: function(v) { __bridge.media('seek:' + v); }
    });
    player.controls.isavailable = player.controls.isAvailable;
    player.settings.getmode = player.settings.getMode;
    player.settings.setmode = player.settings.setMode;
    player.currentMedia.getiteminfo = player.currentMedia.getItemInfo;
    player.currentMedia.setiteminfo = player.currentMedia.setItemInfo;
    Object.defineProperty(player.currentMedia, 'durationstring', {
        get: function() { return __bridge.mediaInfo('durationString'); }
    });
    Object.defineProperty(player, 'currentmedia', {
        get: function() { return player.currentMedia; }
    });
    Object.defineProperty(player, 'currentplaylist', {
        get: function() { return { count: __bridge.playlistCount() }; }
    });
    Object.defineProperty(player, 'playstate', {
        get: function() { return __bridge.state('playState'); }
    });
    Object.defineProperty(player, 'openstate', {
        get: function() { return __bridge.state('openState'); }
    });

    // WMP defines a few globals skins expect; keep them defined so a missing
    // value does not abort a whole handler.
    var strSourceURL = '';
    var strMediaURL = '';

    var event = { keyCode: 0, shiftKey: false, ctrlKey: false, altKey: false };

    // Sub-objects are wrapped too: `player.currentPlaylist.Name` and
    // `player.Controls.currentPosition` reach through the root alias.
    player.controls = __caseInsensitive(player.controls);
    player.settings = __caseInsensitive(player.settings);
    player.currentMedia = __caseInsensitive(player.currentMedia);
    player.network = __caseInsensitive(player.network);
    player.dvd = __caseInsensitive(player.dvd);
    __currentPlaylist = __caseInsensitive(__currentPlaylist);

    player = __caseInsensitive(player);
    theme = __caseInsensitive(theme);
    view = __caseInsensitive(view);
    mediacenter = __caseInsensitive(mediacenter);
    eq = __caseInsensitive(eq);
    """#
}

// MARK: - JSExport surface

@objc protocol JavaScriptBridgeExports: JSExport {
    func get(_ id: String, _ property: String) -> Any?
    func set(_ id: String, _ property: String, _ value: Any?)
    func alphaTo(_ id: String, _ value: Double, _ milliseconds: Double)
    func moveTo(_ id: String, _ x: Double, _ y: Double, _ milliseconds: Double)
    func media(_ command: String)
    func mediaInfo(_ key: String) -> String
    func itemInfo(_ key: String) -> Any?
    func state(_ key: String) -> Any?
    func mode(_ key: String) -> Bool
    func setMode(_ key: String, _ value: Bool)
    func playlistCount() -> Int
    func openView(_ id: String)
    func closeView(_ id: String)
    func returnToMain()
    func openDialog()
    func playSound(_ name: String)
    func effectStep(_ id: String, _ delta: Int)
    func savePref(_ key: String, _ value: String)
    func loadPref(_ key: String) -> String?
    func currentView() -> String
    func viewSize(_ key: String) -> Double
    func timerInterval() -> Double
    func setTimerInterval(_ milliseconds: Double)
    func onTimer() -> String
    func setOnTimer(_ script: String)
}

final class Bridge: NSObject, JavaScriptBridgeExports {
    weak var host: JavaScriptHost?

    init(host: JavaScriptHost) {
        self.host = host
    }

    func get(_ id: String, _ property: String) -> Any? { host?.get(id, property) }
    func set(_ id: String, _ property: String, _ value: Any?) { host?.set(id, property, value) }
    func alphaTo(_ id: String, _ value: Double, _ milliseconds: Double) { host?.alphaTo(id, value, milliseconds) }
    func moveTo(_ id: String, _ x: Double, _ y: Double, _ milliseconds: Double) { host?.moveTo(id, x, y, milliseconds) }

    func media(_ command: String) {
        guard let host else { return }
        host.noteAction()
        let parts = command.split(separator: ":", maxSplits: 1)
        let verb = String(parts[0])
        let argument = parts.count > 1 ? Double(parts[1]) : nil
        switch verb {
        case "play": host.delegate?.jsPerform(.play)
        case "pause": host.delegate?.jsPerform(.pause)
        case "playpause": host.delegate?.jsPerform(.playPause)
        case "stop": host.delegate?.jsPerform(.stop)
        case "next": host.delegate?.jsPerform(.next)
        case "previous": host.delegate?.jsPerform(.previous)
        case "mute":
            let wantMuted = parts.count > 1 && parts[1] == "on"
            let isMuted = host.player.volume <= 0
            if wantMuted != isMuted { host.delegate?.jsPerform(.toggleMute) }
        case "seek":
            if let argument { host.delegate?.jsPerform(.seek(argument)) }
        case "volume":
            if let argument { host.delegate?.jsPerform(.volume(argument / 100)) }
        case "close": host.delegate?.jsPerform(.closeWindow)
        case "minimize": host.delegate?.jsPerform(.minimizeWindow)
        case "openurl":
            if parts.count > 1, let url = URL(string: String(parts[1])) {
                host.delegate?.jsPerform(.openURL(url.absoluteString))
            }
        default: break
        }
    }

    func mediaInfo(_ key: String) -> String {
        guard let host else { return "" }
        switch key {
        case "name": return host.player.title
        case "artist": return host.player.artist
        case "album": return host.player.album
        case "durationString": return timecode(host.player.duration)
        default: return ""
        }
    }

    func itemInfo(_ key: String) -> Any? {
        guard let host else { return nil }
        switch key.lowercased() {
        case "title", "wm/title": return host.player.title
        case "artist", "wm/albumartist": return host.player.artist
        case "album", "wm/albumtitle": return host.player.album
        case "duration": return host.player.duration
        case "userrating", "usereffectiverating": return host.player.rating ?? 0
        default: return ""
        }
    }

    func state(_ key: String) -> Any? {
        guard let host else { return 0 }
        let state = host.player
        switch key {
        case "position": return state.position
        case "positionString": return timecode(state.position)
        case "playlistName": return state.playlistName
        case "duration": return state.duration
        case "volume": return state.volume
        case "mute": return state.volume <= 0
        case "playState": return state.isPlaying ? 3 : (state.hasTrack ? 2 : 1)
        case "openState": return state.hasTrack ? 13 : 0
        default: return 0
        }
    }

    func mode(_ key: String) -> Bool { false }
    func setMode(_ key: String, _ value: Bool) {
        host?.noteAction()
        switch key.lowercased() {
        case "shuffle": host?.delegate?.jsPerform(.shuffle)
        case "repeat": host?.delegate?.jsPerform(.repeatMode)
        default: break
        }
    }

    func playlistCount() -> Int { host?.player.playlistTotal ?? 0 }
    func openView(_ id: String) { host?.noteAction(); host?.delegate?.jsOpenView(id) }
    func closeView(_ id: String) { host?.noteAction(); host?.delegate?.jsCloseView(id) }
    func returnToMain() { host?.delegate?.jsReturnToMediaCenter() }
    func openDialog() { host?.noteAction(); host?.delegate?.jsOpenDialog() }
    func effectStep(_ id: String, _ delta: Int) { host?.effectStep(id, delta) }
    func playSound(_ name: String) { host?.noteAction(); host?.delegate?.jsPlaySound(name) }
    func savePref(_ key: String, _ value: String) { host?.savePreference(key, value) }
    func loadPref(_ key: String) -> String? { host?.preference(key) }
    func currentView() -> String { host?.scene.view.id ?? "" }
    func viewSize(_ key: String) -> Double {
        guard let size = host?.scene.size else { return 0 }
        return key == "height" ? Double(size.height) : Double(size.width)
    }
    func timerInterval() -> Double { host?.timerIntervalValue ?? 0 }
    func setTimerInterval(_ milliseconds: Double) { host?.setTimerInterval(milliseconds) }
    func onTimer() -> String { host?.onTimerValue ?? "" }
    func setOnTimer(_ script: String) { host?.setOnTimer(script) }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension JavaScriptHost {
    fileprivate var timerIntervalValue: Double { timerInterval }
    fileprivate var onTimerValue: String { onTimerScript ?? "" }
}
