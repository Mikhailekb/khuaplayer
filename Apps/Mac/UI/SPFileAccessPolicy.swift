import Foundation

struct SPAccessLocation: Hashable, Sendable {
    enum Kind: Sendable {
        case homeFolder // ~/Desktop、~/Documents、~/Downloads
        case cloud
        case appData
        case volume
    }
    let kind: Kind

    let key: String

    let rootPath: String
}

enum SPAccessLocationClassifier {

    static func location(forPath rawPath: String, home rawHome: String) -> SPAccessLocation? {
        let path = normalized(rawPath)
        let home = normalized(rawHome)
        if let rest = remainder(of: path, under: "/Volumes"),
           let name = firstComponent(rest) {
            return SPAccessLocation(kind: .volume, key: "volume:" + name,
                                    rootPath: "/Volumes/" + name)
        }
        if let rest = remainder(of: path, under: "/Network"),
           let name = firstComponent(rest) {
            return SPAccessLocation(kind: .volume, key: "network:" + name,
                                    rootPath: "/Network/" + name)
        }
        guard !home.isEmpty, let inHome = remainder(of: path, under: home),
              let top = firstComponent(inHome) else { return nil }
        switch top {
        case "Desktop", "Documents", "Downloads":
            return SPAccessLocation(kind: .homeFolder, key: "home:" + top,
                                    rootPath: home + "/" + top)
        case "Library":
            let library = home + "/Library"
            if remainder(of: path, under: library + "/Mobile Documents") != nil {
                return SPAccessLocation(kind: .cloud, key: "icloud",
                                        rootPath: library + "/Mobile Documents")
            }
            for (folder, kind, prefix) in [
                ("CloudStorage", SPAccessLocation.Kind.cloud, "cloud:"),
                ("Containers", .appData, "app:"),
                ("Group Containers", .appData, "group:"),
            ] {
                let base = library + "/" + folder
                if let rest = remainder(of: path, under: base),
                   let name = firstComponent(rest) {
                    return SPAccessLocation(kind: kind, key: prefix + name,
                                            rootPath: base + "/" + name)
                }
            }
            return nil
        default:
            return nil
        }
    }

    static func remainder(of path: String, under root: String) -> Substring? {
        guard path.hasPrefix(root) else { return nil }
        let rest = path.dropFirst(root.count)
        guard rest.isEmpty || rest.hasPrefix("/") else { return nil }
        return rest.drop { $0 == "/" }
    }

    private static func firstComponent(_ rest: Substring) -> String? {
        let name = rest.prefix { $0 != "/" }
        return name.isEmpty ? nil : String(name)
    }

    private static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

struct SPAccessGrantLedger: Equatable {
    static let capacity = 64
    private(set) var keys: [String]

    init(keys: [String] = []) {
        self.keys = Array(keys.suffix(Self.capacity))
    }

    func contains(_ key: String) -> Bool { keys.contains(key) }

    mutating func noteGranted(_ key: String) -> Bool {
        if keys.last == key { return false }
        keys.removeAll { $0 == key }
        keys.append(key)
        if keys.count > Self.capacity { keys.removeFirst(keys.count - Self.capacity) }
        return true
    }

    mutating func noteDenied(_ key: String) -> Bool {
        guard keys.contains(key) else { return false }
        keys.removeAll { $0 == key }
        return true
    }
}

enum SPBackgroundAccessPolicy {

    static func mayWarm(_ location: SPAccessLocation?, ledger: SPAccessGrantLedger) -> Bool {
        guard let location else { return true }
        return ledger.contains(location.key)
    }

    static func mayScanAfterOpen(_ location: SPAccessLocation?) -> Bool {
        location?.kind != .appData
    }
}
