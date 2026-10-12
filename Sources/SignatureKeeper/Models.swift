import Foundation

enum SourceKind: String, Codable, CaseIterable { case project, ipa }

struct Entry: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var kind: SourceKind
    var scheme = ""
    var configuration = "Debug"
    var enabled = true
    var expires: Date?
    var installed: Date?
    var status = "Ещё не обновлялось"
    var lastAttempt: Date?
    var bundleID: String?
    var installedDevice: String?

    func needsRefresh(now: Date, device: String) -> Bool {
        guard enabled else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 3600 { return false }
        return installedDevice != device || expires == nil || expires! <= now.addingTimeInterval(86400)
    }
}

struct Preferences: Codable {
    var entries: [Entry] = []
    var developerPath = ""
    var teamID = ""
    var deviceID = ""
    var automatic = false
}

struct Phone: Identifiable {
    var id: String
    var name: String
}

struct SignedApp {
    var url: URL
    var expiration: Date
    var bundleID: String
}

struct KeeperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum SigningRules {
    static func requiresProfileRefresh(_ profiles: [[String: Any]], forceFresh: Bool, started: Date, now: Date) -> Bool {
        profiles.contains { profile in
            let expiration = profile["ExpirationDate"] as? Date ?? .distantPast
            let creation = profile["CreationDate"] as? Date ?? .distantPast
            return expiration <= now.addingTimeInterval(86400) || (forceFresh && creation < started.addingTimeInterval(-60))
        }
    }

    static func validateBundleID(_ value: String) throws {
        guard value.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else {
            throw KeeperError("Некорректный Bundle ID: \(value)")
        }
    }

    // Keep capability requests intact. Never silently remove an app's entitlements.
    static func entitlements(original: [String: Any], generated: [String: Any], profile: [String: Any], bundleID: String) throws -> [String: Any] {
        var result = generated
        let signingKeys: Set<String> = ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups"]
        for (key, value) in original where !signingKeys.contains(key) {
            guard let allowed = profile[key], permits(allowed, requested: value) else {
                throw KeeperError("IPA требует \(key). Новый профиль этого не разрешает. Переподпись остановлена: для этой возможности может понадобиться другой аккаунт или исходный проект.")
            }
            result[key] = value
        }
        if let groups = original["keychain-access-groups"] as? [String], !groups.isEmpty,
           let newAppID = generated["application-identifier"] as? String,
           let dot = newAppID.firstIndex(of: ".") {
            let prefix = String(newAppID[..<dot])
            let oldID = original["application-identifier"] as? String ?? ""
            let oldPrefix = oldID.split(separator: ".").first.map(String.init) ?? ""
            let updated = groups.map { group -> String in
                if !oldPrefix.isEmpty && group.hasPrefix(oldPrefix + ".") {
                    return prefix + String(group.dropFirst(oldPrefix.count))
                }
                return group
            }
            guard let allowed = profile["keychain-access-groups"], permits(allowed, requested: updated) else {
                throw KeeperError("Новый профиль не разрешает группы Keychain этого IPA.")
            }
            result["keychain-access-groups"] = updated
        }
        return result
    }

    static func permits(_ allowed: Any, requested: Any) -> Bool {
        if let requested = requested as? [Any], let allowed = allowed as? [Any] {
            return requested.allSatisfy { value in allowed.contains { permits($0, requested: value) } }
        }
        if let a = allowed as? String, let b = requested as? String {
            if a.hasSuffix("*") { return b.hasPrefix(String(a.dropLast())) }
            return a == b
        }
        return (allowed as? NSObject)?.isEqual(requested) == true
    }

    // Streaming callers read only Mach-O headers, never an entire large executable.
    static func encryptedMachO(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        func bytes(_ offset: UInt64, _ size: Int) throws -> [UInt8] {
            try file.seek(toOffset: offset)
            return Array(try file.read(upToCount: size) ?? Data())
        }
        func uint(_ data: [UInt8], _ offset: Int, big: Bool) -> UInt32 {
            guard offset + 4 <= data.count else { return 0 }
            let b = Array(data[offset..<offset + 4])
            return big ? b.reduce(0) { ($0 << 8) | UInt32($1) } : b.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let head = try bytes(0, 8)
        guard head.count == 8 else { throw KeeperError("Повреждён исполняемый файл IPA.") }
        let magic = uint(head, 0, big: true)
        var slices: [UInt64] = [0]
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let count = Int(uint(head, 4, big: true))
            guard count > 0 && count <= 64 else { throw KeeperError("Некорректный FAT Mach-O.") }
            let is64 = magic == 0xcafebabf
            let size = is64 ? 32 : 20
            let arches = try bytes(8, count * size)
            guard arches.count == count * size else { throw KeeperError("Обрезанный FAT Mach-O.") }
            slices = (0..<count).map { index in
                let pos = index * size + 8
                return is64 ? UInt64(uint(arches, pos, big: true)) << 32 | UInt64(uint(arches, pos + 4, big: true)) : UInt64(uint(arches, pos, big: true))
            }
        }
        for slice in slices {
            let h = try bytes(slice, 32)
            let m = uint(h, 0, big: true)
            guard [UInt32(0xfeedface), 0xfeedfacf, 0xcefaedfe, 0xcffaedfe].contains(m) else {
                throw KeeperError("IPA содержит неподдерживаемый исполняемый файл.")
            }
            let big = m == 0xfeedface || m == 0xfeedfacf
            let is64 = m == 0xfeedfacf || m == 0xcffaedfe
            let commands = Int(uint(h, 16, big: big))
            let total = Int(uint(h, 20, big: big))
            guard commands <= 100000 && total <= 16 * 1024 * 1024 else { throw KeeperError("Повреждён заголовок Mach-O.") }
            var pos = slice + UInt64(is64 ? 32 : 28)
            let end = pos + UInt64(total)
            for _ in 0..<commands {
                let command = try bytes(pos, 20)
                let kind = uint(command, 0, big: big)
                let size = uint(command, 4, big: big)
                guard command.count >= 8 && size >= 8 && pos + UInt64(size) <= end else { throw KeeperError("Повреждены команды Mach-O.") }
                if kind == 0x21 || kind == 0x2c {
                    guard size >= 20 && command.count >= 20 else { throw KeeperError("Повреждена команда шифрования Mach-O.") }
                    if uint(command, 16, big: big) != 0 { return true }
                }
                pos += UInt64(size)
            }
        }
        return false
    }
}
