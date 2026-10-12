import Foundation

@main
struct Checks {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw KeeperError("FAIL: " + message) }
            checks += 1
        }
        let now = Date()
        let oldProfile: [String: Any] = ["CreationDate": now.addingTimeInterval(-5 * 86400), "ExpirationDate": now.addingTimeInterval(2 * 86400)]
        try expect(SigningRules.requiresProfileRefresh([oldProfile], forceFresh: true, started: now, now: now), "manual renewal must replace SovaMusic's old two-day profile")
        try expect(!SigningRules.requiresProfileRefresh([oldProfile], forceFresh: false, started: now, now: now), "automatic renewal waits until due")
        let freshProfile: [String: Any] = ["CreationDate": now, "ExpirationDate": now.addingTimeInterval(7 * 86400)]
        try expect(!SigningRules.requiresProfileRefresh([freshProfile], forceFresh: true, started: now, now: now), "newly issued profile doesn't require a second request")
        var entry = Entry(name: "Test", path: "test.xcodeproj", kind: .project)
        try expect(entry.needsRefresh(now: now, device: "phone"), "first installation")
        entry.expires = now.addingTimeInterval(7 * 86400)
        entry.installedDevice = "phone"
        try expect(!entry.needsRefresh(now: now, device: "phone"), "valid profile shouldn't rebuild")
        entry.expires = now.addingTimeInterval(3600)
        try expect(entry.needsRefresh(now: now, device: "phone"), "renew before expiry")
        entry.lastAttempt = now.addingTimeInterval(-1800)
        try expect(!entry.needsRefresh(now: now, device: "phone"), "throttle failed attempts")
        entry.lastAttempt = now.addingTimeInterval(-3601)
        try expect(entry.needsRefresh(now: now, device: "phone"), "retry after an hour")
        entry.enabled = false
        try expect(!entry.needsRefresh(now: now, device: "phone"), "disabled apps")
        entry.enabled = true
        entry.expires = now.addingTimeInterval(7 * 86400)
        try expect(entry.needsRefresh(now: now, device: "other"), "new device must be installed")

        let generated: [String: Any] = ["application-identifier": "NEWTEAM123.com.test.app", "com.apple.developer.team-identifier": "NEWTEAM123", "get-task-allow": true]
        let profile: [String: Any] = ["keychain-access-groups": ["NEWTEAM123.*"], "aps-environment": "development"]
        let original: [String: Any] = ["application-identifier": "OLDTEAM123.com.test.app", "keychain-access-groups": ["OLDTEAM123.com.test.app"], "aps-environment": "development"]
        let signed = try SigningRules.entitlements(original: original, generated: generated, profile: profile, bundleID: "com.test.app")
        try expect(signed["keychain-access-groups"] as? [String] == ["NEWTEAM123.com.test.app"], "keychain prefix mapping")
        try expect(signed["aps-environment"] as? String == "development", "preserve supported capabilities")
        var rejected = false
        do { _ = try SigningRules.entitlements(original: ["com.apple.developer.networking.networkextension": ["packet-tunnel-provider"]], generated: generated, profile: profile, bundleID: "com.test.app") }
        catch { rejected = true }
        try expect(rejected, "do not strip unsupported capabilities")
        try expect(!SigningRules.permits(["NEWTEAM123.*"], requested: ["OTHERTEAM.com.test"]), "reject ungranted keychain groups")
        try expect(!SigningRules.permits(false, requested: true), "reject entitlement escalation")
        rejected = false
        do { try SigningRules.validateBundleID("com.test\";bad") } catch { rejected = true }
        try expect(rejected, "reject invalid project identifier")

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        func uint(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 255) } }
        let header = uint(0xfeedfacf) + uint(0x100000c) + uint(0) + uint(2) + uint(1) + uint(24) + uint(0) + uint(0)
        let command = uint(0x2c) + uint(24) + uint(0) + uint(0)
        let binary = temp.appendingPathComponent("binary")
        try Data(header + command + uint(0) + uint(0)).write(to: binary)
        try expect(!SigningRules.encryptedMachO(binary), "unencrypted Mach-O")
        try Data(header + command + uint(1) + uint(0)).write(to: binary)
        try expect(SigningRules.encryptedMachO(binary), "encrypted Mach-O")
        try Data([0, 1, 2]).write(to: binary)
        rejected = false
        do { _ = try SigningRules.encryptedMachO(binary) } catch { rejected = true }
        try expect(rejected, "malformed executable")
        let engine = Engine(Preferences(), log: { _ in })
        let literal = "literal; $(touch should-not-exist)"
        try expect(engine.run("/usr/bin/printf", ["%s", literal]).out == literal, "arguments bypass shell interpretation")
        let stub = try engine.makeStub(id: "com.test.futureapp", directory: temp.appendingPathComponent("Stub"),
                                       requested: ["com.apple.developer.kernel.increased-memory-limit": true, "application-identifier": "OLDTEAM123.com.test.futureapp"])
        let requestURL = URL(fileURLWithPath: stub.path).deletingLastPathComponent().appendingPathComponent("Requested.plist")
        let request = try PropertyListSerialization.propertyList(from: Data(contentsOf: requestURL), format: nil) as! [String: Any]
        try expect(request["com.apple.developer.kernel.increased-memory-limit"] as? Bool == true, "request original capabilities from Xcode")
        try expect(request["application-identifier"] == nil, "do not request old team identifier")
        try engine.run("/usr/bin/plutil", ["-lint", stub.path + "/project.pbxproj"])
        checks += 1
        print("Passed \(checks) checks")
    }
}
