import Foundation

public enum SkinError: LocalizedError {
    case notAZip
    case noDefinition
    case noViews

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "Not a WMZ archive (a WMZ is a renamed ZIP file)."
        case .noDefinition: return "The archive does not contain a .wms skin definition."
        case .noViews: return "The skin definition does not declare any views."
        }
    }
}

/// A WMZ that has been unpacked and parsed.
public struct SkinDocument {
    public let sourceURL: URL
    public let rootURL: URL
    public let theme: Element
    public let views: [Element]

    public var title: String {
        theme["title"] ?? sourceURL.deletingPathExtension().lastPathComponent
    }

    public var author: String {
        theme["author"] ?? ""
    }

    /// The view the player would open first: the "main" view when there is one,
    /// otherwise the first sane one (preview/upgrade/error views are skipped).
    public var primaryView: Element? {
        let identifiers = ["mainview", "main", "compactview", "controlview"]
        for id in identifiers {
            if let view = views.first(where: { ($0["id"] ?? "").lowercased() == id }) {
                if view.int("width") != nil || view["backgroundimage"] != nil { return view }
            }
        }
        let rejected = ["preview", "upgrade", "error", "splash", "install"]
        let candidates = views.filter { view in
            let id = (view["id"] ?? "").lowercased()
            return !rejected.contains(where: { id.contains($0) })
        }
        return candidates.first ?? views.first
    }

    public func view(id: String) -> Element? {
        views.first { ($0[ "id"] ?? "").lowercased() == id.lowercased() }
    }
}

public enum SkinLoader {
    /// Unpacks `url` into a scratch directory and parses its WML.
    public static func load(_ url: URL) throws -> SkinDocument {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("wmz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try unpack(url, to: destination)

        guard let definition = findDefinition(in: destination) else { throw SkinError.noDefinition }
        let theme = try WMLParser.parse(url: definition)
        let views = theme.children(named: "view")
        guard !views.isEmpty else { throw SkinError.noViews }

        return SkinDocument(sourceURL: url, rootURL: destination, theme: theme, views: views)
    }

    private static func unpack(_ url: URL, to destination: URL) throws {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-qq", url.path, "-d", destination.path]
        let pipe = Pipe()
        unzip.standardError = pipe
        unzip.standardOutput = Pipe()
        try unzip.run()
        unzip.waitUntilExit()
        if unzip.terminationStatus != 0 {
            // Fall back to ditto, which copes with a few archives unzip rejects.
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", url.path, destination.path]
            ditto.standardError = Pipe()
            ditto.standardOutput = Pipe()
            try? ditto.run()
            ditto.waitUntilExit()
            if ditto.terminationStatus != 0 { throw SkinError.notAZip }
        }
    }

    private static func findDefinition(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (depth: Int, url: URL)?
        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "wms" else { continue }
            let depth = file.pathComponents.count - directory.pathComponents.count
            if best == nil || depth < best!.depth { best = (depth, file) }
        }
        return best?.url
    }
}
