import Foundation
import CryptoKit

final class Engine: @unchecked Sendable {
    let settings: Preferences
    let log: @Sendable (String) -> Void
    let fm = FileManager.default
    let cache: URL

    init(_ settings: Preferences, log: @escaping @Sendable (String) -> Void) {
        self.settings = settings
        self.log = log
        cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SignatureKeeper")
    }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        if !settings.developerPath.isEmpty {
            let path = settings.developerPath
            env["DEVELOPER_DIR"] = path.hasSuffix(".app") ? path + "/Contents/Developer" : path
        }
        return env
    }

    struct Output { var out: String; var err: String; var code: Int32 }

    @discardableResult
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120, allowFailure: Bool = false) throws -> Output {
        let temp = fm.temporaryDirectory.appendingPathComponent("keeper-command-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let stdout = temp.appendingPathComponent("out")
        let stderr = temp.appendingPathComponent("err")
        fm.createFile(atPath: stdout.path, contents: nil)
        fm.createFile(atPath: stderr.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(5)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw KeeperError("Команда \(URL(fileURLWithPath: executable).lastPathComponent) превысила время ожидания.")
        }
        process.waitUntilExit()
        func tail(_ url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > 4_194_304 ? size - 4_194_304 : 0)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        }
        let result = try Output(out: tail(stdout), err: tail(stderr), code: process.terminationStatus)
        if result.code != 0 && !allowFailure {
            throw KeeperError("\(URL(fileURLWithPath: executable).lastPathComponent):\n" + String((result.out + "\n" + result.err).suffix(6500)))
        }
        return result
    }

    func checkXcode() throws -> String {
        let version = try run("/usr/bin/xcrun", ["xcodebuild", "-version"]).out
        _ = try run("/usr/bin/xcrun", ["--find", "devicectl"])
        return version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func deviceJSON(_ args: [String]) throws -> [String: Any] {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? fm.removeItem(at: url) }
        try run("/usr/bin/xcrun", ["devicectl"] + args + ["--json-output", url.path], timeout: 90)
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let result = json["result"] as? [String: Any] else { throw KeeperError("Не удалось прочитать ответ devicectl.") }
        return result
    }

    func phones() throws -> [Phone] {
        _ = try checkXcode()
        let result = try deviceJSON(["list", "devices"])
        return (result["devices"] as? [[String: Any]] ?? []).compactMap { device in
            guard let id = device["identifier"] as? String else { return nil }
            let props = device["deviceProperties"] as? [String: Any] ?? [:]
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let type = hardware["deviceType"] as? String ?? ""
            guard type.isEmpty || type.lowercased().contains("iphone") || type.lowercased().contains("ipad") else { return nil }
            return Phone(id: id, name: props["name"] as? String ?? id)
        }
    }

    func udid() throws -> String {
        guard !settings.deviceID.isEmpty else { throw KeeperError("Выберите iPhone в настройках.") }
        let result = try deviceJSON(["device", "info", "details", "--device", settings.deviceID])
        guard let hardware = result["hardwareProperties"] as? [String: Any], let value = hardware["udid"] as? String else {
            throw KeeperError("Не удалось получить UDID iPhone. Разблокируйте его и проверьте доверие к Mac в Xcode.")
        }
        return value
    }

    func schemes(_ path: String) throws -> [String] {
        let output = try run("/usr/bin/xcrun", ["xcodebuild", containerFlag(path), path, "-list", "-json"], timeout: 180)
        guard let json = try JSONSerialization.jsonObject(with: Data(output.out.utf8)) as? [String: Any] else { throw KeeperError("Не удалось прочитать схемы проекта.") }
        let container = (json["project"] ?? json["workspace"]) as? [String: Any]
        return container?["schemes"] as? [String] ?? []
    }

    func containerFlag(_ path: String) -> String { path.hasSuffix(".xcworkspace") ? "-workspace" : "-project" }

    func profile(_ app: URL) throws -> [String: Any] {
        let file = app.appendingPathComponent("embedded.mobileprovision")
        guard fm.fileExists(atPath: file.path) else { throw KeeperError("В \(app.lastPathComponent) отсутствует профиль подписи.") }
        let data = try run("/usr/bin/security", ["cms", "-D", "-i", file.path]).out
        guard let plist = try PropertyListSerialization.propertyList(from: Data(data.utf8), format: nil) as? [String: Any] else {
            throw KeeperError("Профиль подписи не читается.")
        }
        return plist
    }

    func info(_ app: URL) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any] else {
            throw KeeperError("Info.plist не читается.")
        }
        return plist
    }

    func bundles(_ app: URL) -> [URL] {
        var result = [app]
        if let iterator = fm.enumerator(at: app, includingPropertiesForKeys: nil) {
            for case let file as URL in iterator where file.pathExtension == "appex" || file.pathExtension == "app" { result.append(file) }
        }
        return result.sorted { $0.path.count > $1.path.count }
    }

    func inspect(_ app: URL, udid: String) throws -> SignedApp {
        var dates: [Date] = []
        for bundle in bundles(app) {
            let p = try profile(bundle)
            guard let date = p["ExpirationDate"] as? Date, date > Date() else { throw KeeperError("Профиль подписи уже истёк.") }
            guard let devices = p["ProvisionedDevices"] as? [String], devices.contains(udid) else { throw KeeperError("Профиль не включает выбранный iPhone.") }
            guard (p["TeamIdentifier"] as? [String])?.contains(settings.teamID) == true else { throw KeeperError("Профиль принадлежит другой команде Apple.") }
            dates.append(date)
        }
        guard let id = try info(app)["CFBundleIdentifier"] as? String, let date = dates.min() else { throw KeeperError("Не удалось определить подпись приложения.") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return SignedApp(url: app, expiration: date, bundleID: id)
    }

    func build(_ entry: Entry, device: String, derived: URL) throws -> URL {
        guard !entry.scheme.isEmpty else { throw KeeperError("Выберите схему для \(entry.name).") }
        let base = ["xcodebuild", containerFlag(entry.path), entry.path, "-scheme", entry.scheme,
                    "-configuration", entry.configuration, "-sdk", "iphoneos", "-destination", "id=" + device,
                    "-derivedDataPath", derived.path, "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
                    "-jobs", "2", "DEVELOPMENT_TEAM=" + settings.teamID, "CODE_SIGN_STYLE=Automatic",
                    "CODE_SIGN_IDENTITY=Apple Development", "PROVISIONING_PROFILE_SPECIFIER=", "PROVISIONING_PROFILE=",
                    "COMPILER_INDEX_STORE_ENABLE=NO"]
        log("Сборка \(entry.name). Одновременно работают не более двух задач компиляции.")
        try run("/usr/bin/xcrun", base + ["build"], timeout: 1800)
        let output = try run("/usr/bin/xcrun", base + ["-showBuildSettings", "-json"], timeout: 180)
        guard let targets = try JSONSerialization.jsonObject(with: Data(output.out.utf8)) as? [[String: Any]] else { throw KeeperError("Не удалось прочитать результат сборки.") }
        let apps = targets.compactMap { target -> URL? in
            guard let b = target["buildSettings"] as? [String: Any], b["WRAPPER_EXTENSION"] as? String == "app",
                  let directory = b["TARGET_BUILD_DIR"] as? String, let name = b["FULL_PRODUCT_NAME"] as? String else { return nil }
            let file = URL(fileURLWithPath: directory).appendingPathComponent(name)
            return fm.fileExists(atPath: file.path) ? file : nil
        }
        guard apps.count == 1, let app = apps.first else { throw KeeperError("Схема должна собирать одно iOS-приложение. Найдено: \(apps.count).") }
        return app
    }

    // Move only the exact profiles used by this app. Preserve them if refresh fails.
    func refreshIfNeeded(_ app: URL, device: String, forceFresh: Bool, started: Date, rebuild: () throws -> URL) throws -> URL {
        let profiles = try bundles(app).map { try profile($0) }
        let needsNew = SigningRules.requiresProfileRefresh(profiles, forceFresh: forceFresh, started: started, now: Date())
        guard needsNew else { return app }
        log(forceFresh ? "Ручное обновление: Xcode использовал старый профиль. Запрашиваю свежий." : "Старый профиль скоро истечёт. Запрашиваю новый у Xcode.")
        let ids = Set(profiles.compactMap { ($0["UUID"] as? String)?.lowercased() })
        let previousExpiration = profiles.compactMap { $0["ExpirationDate"] as? Date }.min() ?? .distantPast
        let home = fm.homeDirectoryForCurrentUser
        let folders = ["Library/MobileDevice/Provisioning Profiles", "Library/Developer/Xcode/UserData/Provisioning Profiles"]
        let backup = fm.temporaryDirectory.appendingPathComponent("keeper-profiles-" + UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var moved: [(URL, URL)] = []
        var completed = false
        defer {
            if !completed { for (source, copy) in moved where !fm.fileExists(atPath: source.path) { try? fm.moveItem(at: copy, to: source) } }
            try? fm.removeItem(at: backup)
        }
        for folder in folders {
            for file in (try? fm.contentsOfDirectory(at: home.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? [] {
                guard ids.contains(file.deletingPathExtension().lastPathComponent.lowercased()) else { continue }
                let copy = backup.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at: file, to: copy)
                moved.append((file, copy))
            }
        }
        let refreshed = try rebuild()
        let signed = try inspect(refreshed, udid: device)
        let refreshedProfiles = try bundles(refreshed).map { try profile($0) }
        guard signed.expiration > Date().addingTimeInterval(86400),
              !forceFresh || (signed.expiration > previousExpiration && !SigningRules.requiresProfileRefresh(refreshedProfiles, forceFresh: true, started: started, now: Date())) else {
            throw KeeperError("Xcode снова использовал старый профиль. Откройте проект в Xcode и обновите Signing & Capabilities; срок ещё не продлён.")
        }
        completed = true
        return refreshed
    }

    func readEntitlements(_ app: URL) throws -> [String: Any] {
        let output = try run("/usr/bin/codesign", ["-d", "--entitlements", ":-", app.path])
        if output.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let result = try PropertyListSerialization.propertyList(from: Data(output.out.utf8), format: nil) as? [String: Any] else { throw KeeperError("Не удалось прочитать entitlements IPA.") }
        return result
    }

    func makeStub(id: String, directory: URL, requested: [String: Any] = [:]) throws -> Entry {
        try SigningRules.validateBundleID(id)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = directory.appendingPathComponent("Provision.xcodeproj")
        let shared = project.appendingPathComponent("xcshareddata/xcschemes")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let source = "#import <UIKit/UIKit.h>\nint main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, nil); } }\n"
        try source.write(to: directory.appendingPathComponent("main.m"), atomically: true, encoding: .utf8)
        let signingKeys: Set<String> = ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups"]
        let capabilities = requested.filter { !signingKeys.contains($0.key) }
        try PropertyListSerialization.data(fromPropertyList: capabilities, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Requested.plist"))
        let pbx = """
        // !$*UTF8*$!
        { archiveVersion=1; classes={}; objectVersion=56; objects={
        000000000000000000000001={isa=PBXProject;buildConfigurationList=000000000000000000000002;compatibilityVersion="Xcode 14.0";developmentRegion=en;hasScannedForEncodings=0;knownRegions=(en,Base);mainGroup=000000000000000000000003;projectDirPath="";projectRoot="";targets=(000000000000000000000004,);};
        000000000000000000000002={isa=XCConfigurationList;buildConfigurations=(000000000000000000000005,);defaultConfigurationIsVisible=0;defaultConfigurationName=Debug;};
        000000000000000000000003={isa=PBXGroup;children=(000000000000000000000006,000000000000000000000007,);sourceTree="<group>";};
        000000000000000000000004={isa=PBXNativeTarget;buildConfigurationList=000000000000000000000008;buildPhases=(000000000000000000000009,);buildRules=();dependencies=();name=Provision;productName=Provision;productReference=000000000000000000000007;productType="com.apple.product-type.application";};
        000000000000000000000005={isa=XCBuildConfiguration;name=Debug;buildSettings={SDKROOT=iphoneos;IPHONEOS_DEPLOYMENT_TARGET=15.0;};};
        000000000000000000000006={isa=PBXFileReference;lastKnownFileType=sourcecode.c.objc;path=main.m;sourceTree="<group>";};
        000000000000000000000007={isa=PBXFileReference;explicitFileType=wrapper.application;path=Provision.app;sourceTree=BUILT_PRODUCTS_DIR;};
        000000000000000000000008={isa=XCConfigurationList;buildConfigurations=(000000000000000000000010,);defaultConfigurationIsVisible=0;defaultConfigurationName=Debug;};
        000000000000000000000009={isa=PBXSourcesBuildPhase;buildActionMask=2147483647;files=(000000000000000000000011,);runOnlyForDeploymentPostprocessing=0;};
        000000000000000000000010={isa=XCBuildConfiguration;name=Debug;buildSettings={PRODUCT_NAME=Provision;PRODUCT_BUNDLE_IDENTIFIER="\(id)";GENERATE_INFOPLIST_FILE=YES;CODE_SIGN_STYLE=Automatic;CODE_SIGN_ENTITLEMENTS=Requested.plist;TARGETED_DEVICE_FAMILY="1,2";CLANG_ENABLE_MODULES=YES;CLANG_ENABLE_OBJC_ARC=YES;OTHER_LDFLAGS="-framework UIKit";};};
        000000000000000000000011={isa=PBXBuildFile;fileRef=000000000000000000000006;};
        };rootObject=000000000000000000000001;}
        """
        try pbx.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="000000000000000000000004" BuildableName="Provision.app" BlueprintName="Provision" ReferencedContainer="container:Provision.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction></Scheme>
        """
        try scheme.write(to: shared.appendingPathComponent("Provision.xcscheme"), atomically: true, encoding: .utf8)
        return Entry(name: id, path: project.path, kind: .project, scheme: "Provision")
    }

    func resignIPA(_ entry: Entry, device: String, work: URL, forceFresh: Bool, started: Date) throws -> URL {
        log("Проверяю и распаковываю IPA: \(entry.name). Исходный файл сохраняется.")
        let listing = try run("/usr/bin/unzip", ["-Z1", entry.path]).out
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "/")
            guard !line.hasPrefix("/"), !parts.contains("..") else { throw KeeperError("IPA содержит недопустимый путь.") }
        }
        let extracted = work.appendingPathComponent("Unpacked")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", entry.path, extracted.path], timeout: 600)
        if let iterator = fm.enumerator(at: extracted, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let file as URL in iterator {
                guard file.resolvingSymlinksInPath().path.hasPrefix(extracted.path + "/") else { throw KeeperError("IPA содержит ссылку за пределы архива.") }
            }
        }
        let payload = extracted.appendingPathComponent("Payload")
        let apps = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw KeeperError("В IPA должно быть одно основное приложение.") }
        guard !fm.fileExists(atPath: app.appendingPathComponent("Watch").path), bundles(app).allSatisfy({ $0 == app || $0.pathExtension == "appex" }) else {
            throw KeeperError("Этот IPA включает вложенное приложение или Watch-компонент. Сейчас поддерживаются обычные iOS-приложения и расширения.")
        }
        var identity: String?
        var signing: [(URL, URL)] = []
        for (index, bundle) in bundles(app).enumerated() {
            let metadata = try info(bundle)
            guard let id = metadata["CFBundleIdentifier"] as? String, let executable = metadata["CFBundleExecutable"] as? String,
                  !executable.contains("/"), executable != ".." else { throw KeeperError("В IPA отсутствует Bundle ID или исполняемый файл.") }
            guard try !SigningRules.encryptedMachO(bundle.appendingPathComponent(executable)) else {
                throw KeeperError("IPA зашифрован (обычно это файл из App Store). Для переподписи нужен незашифрованный IPA от разработчика.")
            }
            let original = try readEntitlements(bundle)
            let stubDir = work.appendingPathComponent("Stub-\(index)")
            let stub = try makeStub(id: id, directory: stubDir, requested: original)
            let derived = stubDir.appendingPathComponent("DerivedData")
            var built = try build(stub, device: device, derived: derived)
            built = try refreshIfNeeded(built, device: device, forceFresh: forceFresh, started: started) { try self.build(stub, device: device, derived: derived) }
            _ = try inspect(built, udid: device)
            let p = try profile(built)
            let generated = try readEntitlements(built)
            let entitlements = try SigningRules.entitlements(original: original, generated: generated, profile: p["Entitlements"] as? [String: Any] ?? [:], bundleID: id)
            if identity == nil {
                let available = try run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]).out
                let certificates = p["DeveloperCertificates"] as? [Data] ?? []
                identity = certificates.map { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() }.first { available.contains($0) }
                guard identity != nil else { throw KeeperError("В Связке ключей нет сертификата для нового профиля.") }
            }
            let profileURL = bundle.appendingPathComponent("embedded.mobileprovision")
            if fm.fileExists(atPath: profileURL.path) { try fm.removeItem(at: profileURL) }
            try fm.copyItem(at: built.appendingPathComponent("embedded.mobileprovision"), to: profileURL)
            let ents = work.appendingPathComponent("entitlements-\(index).plist")
            try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: ents)
            signing.append((bundle, ents))
        }
        guard let identity else { throw KeeperError("Не найден сертификат подписи.") }
        var nested: [URL] = []
        if let iterator = fm.enumerator(at: app, includingPropertiesForKeys: nil) {
            for case let file as URL in iterator where file.pathExtension == "framework" || file.pathExtension == "dylib" { nested.append(file) }
        }
        for file in nested.sorted(by: { $0.path.count > $1.path.count }) {
            try run("/usr/bin/codesign", ["--force", "--sign", identity, "--timestamp=none", file.path])
        }
        for (bundle, entitlements) in signing {
            try run("/usr/bin/codesign", ["--force", "--sign", identity, "--timestamp=none", "--entitlements", entitlements.path, bundle.path])
        }
        return app
    }

    func renew(_ entry: Entry, forceFresh: Bool = true) throws -> SignedApp {
        let started = Date()
        guard settings.teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw KeeperError("Введите Team ID из 10 символов, как в Signing & Capabilities проекта.") }
        _ = try checkXcode()
        let device = try udid()
        let work = cache.appendingPathComponent(entry.id.uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let app: URL
        if entry.kind == .project {
            let derived = work.appendingPathComponent("DerivedData")
            let built = try build(entry, device: device, derived: derived)
            app = try refreshIfNeeded(built, device: device, forceFresh: forceFresh, started: started) { try self.build(entry, device: device, derived: derived) }
        } else {
            let ipaWork = work.appendingPathComponent("IPA-" + UUID().uuidString)
            try fm.createDirectory(at: ipaWork, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: ipaWork) }
            let resigned = try resignIPA(entry, device: device, work: ipaWork, forceFresh: forceFresh, started: started)
            return try install(resigned, device: device, previous: entry.bundleID)
        }
        return try install(app, device: device, previous: entry.bundleID)
    }

    func install(_ app: URL, device: String, previous: String?) throws -> SignedApp {
        let signed = try inspect(app, udid: device)
        if let previous, signed.bundleID != previous { throw KeeperError("Bundle ID изменился с \(previous) на \(signed.bundleID). Добавьте приложение отдельной записью, чтобы не потерять связь с прежней установкой.") }
        log("Устанавливаю \(signed.bundleID) на iPhone…")
        try run("/usr/bin/xcrun", ["devicectl", "device", "install", "app", "--device", settings.deviceID, app.path], timeout: 600)
        log("Установлено. Профиль действует до \(signed.expiration.formatted(date: .numeric, time: .shortened)).")
        return signed
    }
}
