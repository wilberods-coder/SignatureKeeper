import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class KeeperStore: ObservableObject {
    @Published var preferences = Preferences() { didSet { save() } }
    @Published var phones: [Phone] = []
    @Published var busy = false
    @Published var checking = false
    @Published var environmentStatus = "Проверка Xcode…"
    @Published var xcodeReady = false
    @Published var logs: [String] = []
    @Published var alert: String?
    @Published var editing: Entry?
    let file: URL
    let isPreview: Bool
    private var timer: Timer?

    init() {
        isPreview = Bundle.main.object(forInfoDictionaryKey: "SignatureKeeperPreview") as? Bool == true
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SignatureKeeper")
        file = base.appendingPathComponent("settings.json")
        if isPreview {
            let calendar = Calendar(identifier: .gregorian)
            let expiration = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
            preferences.entries = [
                Entry(name: "Atlas", path: "/Users/demo/Projects/Atlas/Atlas.xcodeproj", kind: .project, scheme: "Atlas", expires: expiration, status: "Установлено на iPhone"),
                Entry(name: "Melody", path: "/Users/demo/Projects/Melody/Melody.xcworkspace", kind: .project, scheme: "Melody", expires: expiration, status: "Установлено на iPhone"),
                Entry(name: "Reader", path: "/Users/demo/Apps/Reader.ipa", kind: .ipa, expires: expiration, status: "Установлено на iPhone")
            ]
            preferences.teamID = "DEMO123456"
            preferences.deviceID = "demo-phone"
            phones = [Phone(id: "demo-phone", name: "iPhone")]
            environmentStatus = "Xcode 16.2 · Демонстрационный режим"
            xcodeReady = true
            logs = ["12:00:00  Запрошен свежий профиль Apple.", "12:00:12  Установлено. Профиль действует до 19.10.2026, 12:00."]
            return
        }
        if FileManager.default.fileExists(atPath: file.path) {
            do { preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file)) }
            catch {
                let backup = base.appendingPathComponent("settings-damaged-" + UUID().uuidString + ".json")
                do { try FileManager.default.copyItem(at: file, to: backup) }
                catch { alert = "Настройки не читаются. Не удалось сохранить резервную копию: \(error.localizedDescription)" }
                if alert == nil { alert = "Настройки не читаются. Резервная копия сохранена: \(backup.path)" }
            }
        } else if let seed = Bundle.main.url(forResource: "Defaults", withExtension: "json"),
                  let data = try? Data(contentsOf: seed), let defaults = try? JSONDecoder().decode(Preferences.self, from: data) {
            preferences = defaults
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoRefresh() }
        }
        refreshEnvironment()
    }

    func save() {
        guard !isPreview else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(preferences).write(to: file, options: .atomic)
        } catch { alert = "Не удалось сохранить настройки: \(error.localizedDescription)" }
    }

    func append(_ message: String) {
        logs.append(Date().formatted(date: .omitted, time: .standard) + "  " + message)
        if logs.count > 120 { logs.removeFirst(logs.count - 120) }
    }

    func engine() -> Engine {
        Engine(preferences) { [weak self] message in
            Task { @MainActor in self?.append(message) }
        }
    }

    func refreshEnvironment() {
        guard !isPreview, !busy, !checking else { return }
        checking = true
        let worker = engine()
        Task {
            do {
                let version = try await Task.detached { try worker.checkXcode() }.value
                environmentStatus = version.replacingOccurrences(of: "\n", with: " · ")
                xcodeReady = true
                do {
                    phones = try await Task.detached { try worker.phones() }.value
                    if preferences.deviceID.isEmpty, let first = phones.first { preferences.deviceID = first.id }
                } catch {
                    phones = []
                    environmentStatus += " · Не удалось проверить iPhone — см. журнал"
                    append(error.localizedDescription)
                }
            } catch {
                xcodeReady = false
                environmentStatus = "Нужен полный Xcode. Выберите Xcode.app, если он установлен в другой папке."
                append(error.localizedDescription)
            }
            checking = false
        }
    }

    func chooseXcode() {
        guard !isPreview else { return }
        let panel = NSOpenPanel()
        panel.title = "Выберите Xcode.app"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.developerPath = url.path
        refreshEnvironment()
    }

    func addFiles() {
        guard !isPreview else { return }
        let panel = NSOpenPanel()
        panel.title = "Добавить проект Xcode или IPA"
        panel.message = "Выберите .xcodeproj, .xcworkspace или .ipa. Можно добавить несколько файлов."
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard ["xcodeproj", "xcworkspace", "ipa"].contains(url.pathExtension) else {
                alert = "Выберите файл .ipa либо пакет .xcodeproj или .xcworkspace внутри папки проекта."
                continue
            }
            if preferences.entries.contains(where: { $0.path == url.path }) { continue }
            let kind: SourceKind = url.pathExtension == "ipa" ? .ipa : .project
            let entry = Entry(name: url.deletingPathExtension().lastPathComponent, path: url.path, kind: kind,
                              scheme: kind == .project ? url.deletingPathExtension().lastPathComponent : "")
            preferences.entries.append(entry)
            if kind == .project { editing = entry }
        }
    }

    func autoRefresh() {
        guard preferences.automatic, !busy, !checking, !preferences.deviceID.isEmpty else { return }
        let entries = preferences.entries.filter { $0.needsRefresh(now: Date(), device: preferences.deviceID) }
        if !entries.isEmpty { renew(entries, forceFresh: false) }
    }

    func renew(_ entries: [Entry], forceFresh: Bool = true) {
        guard !isPreview, !busy, !checking, !entries.isEmpty else { return }
        guard !preferences.deviceID.isEmpty else { alert = "Подключите iPhone, разблокируйте его и нажмите «Проверить». Затем выберите устройство."; return }
        let worker = engine()
        busy = true
        Task {
            for entry in entries {
                guard let index = preferences.entries.firstIndex(where: { $0.id == entry.id }) else { continue }
                preferences.entries[index].lastAttempt = Date()
                preferences.entries[index].status = "Обновляется…"
                do {
                    let signed = try await Task.detached { try worker.renew(entry, forceFresh: forceFresh) }.value
                    if let i = preferences.entries.firstIndex(where: { $0.id == entry.id }) {
                        preferences.entries[i].expires = signed.expiration
                        preferences.entries[i].installed = Date()
                        preferences.entries[i].installedDevice = worker.settings.deviceID
                        preferences.entries[i].bundleID = signed.bundleID
                        preferences.entries[i].status = signed.expiration > Date().addingTimeInterval(86400) ? "Установлено на iPhone" : "Установлено; профиль скоро истекает"
                    }
                } catch {
                    if let i = preferences.entries.firstIndex(where: { $0.id == entry.id }) { preferences.entries[i].status = "Не обновлено — подробности в журнале" }
                    append("\(entry.name): \(error.localizedDescription)")
                }
            }
            busy = false
        }
    }

    func commit(_ entry: Entry) {
        if let index = preferences.entries.firstIndex(where: { $0.id == entry.id }) { preferences.entries[index] = entry }
        editing = nil
    }

    func clearCache() {
        guard !isPreview, !busy else { return }
        do {
            let cache = engine().cache
            if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
            append("Кэш сборок очищен.")
        } catch { alert = error.localizedDescription }
    }
}

@main
@MainActor
struct KeeperApp: App {
    @StateObject private var store = KeeperStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Подпись", id: "main") {
            MainView(store: store)
                .frame(minWidth: 820, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1000, height: 800)
        MenuBarExtra("Подпись", systemImage: store.busy ? "arrow.triangle.2.circlepath" : "checkmark.seal") {
            TrayView(store: store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct TrayView: View {
    @ObservedObject var store: KeeperStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Открыть «Подпись»") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(store.busy ? "Обновление выполняется…" : "Обновить выбранные приложения") { store.renew(store.preferences.entries.filter(\.enabled)) }
            .disabled(store.busy || store.checking)
        Toggle("Автообновление", isOn: $store.preferences.automatic)
        Divider()
        ForEach(store.preferences.entries) { entry in
            Text(entry.name + " · " + (entry.expires.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "нет подписи"))
        }
        Divider()
        Button("Завершить") { NSApp.terminate(nil) }.disabled(store.busy)
    }
}

struct MainView: View {
    @ObservedObject var store: KeeperStore
    @State private var login = SMAppService.mainApp.status == .enabled
    private let green = Color(red: 0.55, green: 0.92, blue: 0.69)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                xcodePanel
                connectionPanel
                toolbar
                appList
                automationPanel
                journalPanel
                disclaimer
            }.padding(30)
        }
        .background(Color(red: 0.07, green: 0.09, blue: 0.10))
        .sheet(item: $store.editing) { entry in EditorView(store: store, entry: entry) }
        .alert("Подпись", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("Понятно") { store.alert = nil }
        } message: { Text(store.alert ?? "") }
    }

    @ViewBuilder private var header: some View {
    HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 8) {
            Text("ПОДПИСЬ / IPHONE").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(green)
            Text("Приложения всегда под рукой").font(.system(size: 30, weight: .bold))
            Text("Обновляйте проекты Xcode и IPA с вашего Mac.").foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "checkmark.seal.fill").font(.system(size: 42)).foregroundStyle(green)
    }
    }

    @ViewBuilder private var xcodePanel: some View {
    HStack(spacing: 12) {
        Image(systemName: store.xcodeReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(store.xcodeReady ? green : .orange)
        Text(store.environmentStatus).font(.callout)
        Spacer()
        Button("Выбрать Xcode") { store.chooseXcode() }
        Button("Проверить") { store.refreshEnvironment() }.disabled(store.busy || store.checking)
    }.padding(16).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var connectionPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            Text("Подключение").font(.headline)
            Spacer()
            Text("Apple Account используется из Xcode").font(.caption).foregroundStyle(.secondary)
        }
        HStack(spacing: 18) {
            VStack(alignment: .leading) {
                Text("Team ID").font(.caption).foregroundStyle(.secondary)
                TextField("10 символов из Signing & Capabilities", text: $store.preferences.teamID)
                    .textFieldStyle(.roundedBorder).onChange(of: store.preferences.teamID) { value in
                        let trimmed = value.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed != value { store.preferences.teamID = trimmed }
                    }
            }.frame(width: 270)
            VStack(alignment: .leading) {
                Text("iPhone").font(.caption).foregroundStyle(.secondary)
                Picker("iPhone", selection: $store.preferences.deviceID) {
                    Text("Выберите устройство").tag("")
                    if !store.preferences.deviceID.isEmpty && !store.phones.contains(where: { $0.id == store.preferences.deviceID }) {
                        Text("Сохранённый iPhone · сейчас недоступен").tag(store.preferences.deviceID)
                    }
                    ForEach(store.phones) { Text($0.name).tag($0.id) }
                }.labelsHidden()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        Text("Первый запуск: войдите в Apple Account в Xcode, подключите iPhone, подтвердите доверие и включите на iPhone режим разработчика.")
            .font(.caption).foregroundStyle(.secondary)
    }.disabled(store.busy)
    }

    @ViewBuilder private var toolbar: some View {
    HStack {
        Text("Ваши приложения").font(.title2.bold())
        Spacer()
        Button { store.addFiles() } label: { Label("Добавить", systemImage: "plus") }.disabled(store.busy)
        Button(store.busy ? "Обновляется…" : "Обновить все") { store.renew(store.preferences.entries.filter(\.enabled)) }
            .buttonStyle(.borderedProminent).tint(green).foregroundStyle(.black)
            .disabled(store.busy || store.checking || !store.xcodeReady || !store.preferences.entries.contains(where: \.enabled))
    }
    }

    @ViewBuilder private var appList: some View {
    if store.preferences.entries.isEmpty {
        VStack(spacing: 8) {
            Image(systemName: "app.badge").font(.largeTitle).foregroundStyle(green)
            Text("Добавьте первое приложение").font(.headline)
            Text("Проект .xcodeproj / .xcworkspace или файл .ipa").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(30).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
    }
    ForEach(store.preferences.entries) { entry in
        EntryRow(store: store, entry: entry)
    }
    }

    @ViewBuilder private var automationPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            Toggle("Обновлять автоматически", isOn: $store.preferences.automatic)
            Spacer()
            Toggle("Запускать при входе", isOn: $login).onChange(of: login) { enabled in
                guard !store.isPreview else { login = false; return }
                do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { store.alert = "Автозапуск: \(error.localizedDescription)"; login = SMAppService.mainApp.status == .enabled }
            }
        }
        Text("Проверка раз в минуту. Обновление — за сутки до истечения; повтор после ошибки — через час. Mac должен бодрствовать, приложение — работать, а iPhone — быть доступен по USB или настроенной в Xcode сети.")
            .font(.caption).foregroundStyle(.secondary)
    }.padding(16).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var journalPanel: some View {
    HStack {
        Text("Журнал").font(.headline)
        if store.busy { ProgressView().controlSize(.small) }
        Spacer()
        Button("Скопировать") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(store.logs.joined(separator: "\n"), forType: .string)
        }
        Button("Очистить кэш сборок") { store.clearCache() }.disabled(store.busy)
    }
    ScrollView {
        Text(store.logs.isEmpty ? "Здесь появятся результаты проверки, сборки и установки." : store.logs.joined(separator: "\n\n"))
            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }.frame(height: 130).padding(14).background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var disclaimer: some View {
    Text("Бесплатный аккаунт: профиль на 7 дней. IPA с шифрованием или неподдерживаемыми возможностями продлить не получится.")
        .font(.caption).foregroundStyle(.secondary)
    }
}

struct EntryRow: View {
    @ObservedObject var store: KeeperStore
    let entry: Entry
    private let green = Color(red: 0.55, green: 0.92, blue: 0.69)
    var body: some View {
        HStack(spacing: 16) {
            Toggle("Включить \(entry.name)", isOn: Binding(get: { entry.enabled }, set: { enabled in
                if let i = store.preferences.entries.firstIndex(where: { $0.id == entry.id }) { store.preferences.entries[i].enabled = enabled }
            })).labelsHidden().toggleStyle(.checkbox)
            Image(systemName: entry.kind == .project ? "hammer.fill" : "shippingbox.fill")
                .font(.title2).foregroundStyle(green).frame(width: 40, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.name).font(.headline)
                Text(entry.kind == .project ? "Проект Xcode · \(entry.scheme)" : "IPA · переподпись").font(.caption).foregroundStyle(.secondary)
                Text(entry.status).font(.caption).foregroundStyle(entry.status.hasPrefix("Не обновлено") ? Color.orange : Color.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let date = entry.expires {
                    Text(date > Date() ? "До \(date.formatted(date: .abbreviated, time: .shortened))" : "Подпись истекла")
                        .foregroundStyle(date.timeIntervalSinceNow > 86400 ? green : .orange)
                    Text("Срок из профиля Apple").foregroundStyle(.secondary)
                } else { Text("Срок ещё не проверен").foregroundStyle(.secondary) }
            }.font(.caption)
            Button { store.renew([entry]) } label: { Image(systemName: "arrow.clockwise") }
                .help("Обновить подпись и установить").disabled(store.busy || store.checking || !store.xcodeReady)
            Button { store.editing = entry } label: { Image(systemName: "slider.horizontal.3") }.help("Настройки приложения").disabled(store.busy)
        }.padding(18).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16)).disabled(store.busy)
    }
}

struct EditorView: View {
    @ObservedObject var store: KeeperStore
    @State var entry: Entry
    @State private var schemes: [String] = []
    @State private var loading = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Настройки приложения").font(.title2.bold())
            TextField("Название", text: $entry.name).textFieldStyle(.roundedBorder)
            Text(entry.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Выбрать другой файл") {
                let panel = NSOpenPanel()
                panel.title = "Выберите новый источник приложения"
                panel.canChooseDirectories = true
                panel.directoryURL = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
                guard panel.runModal() == .OK, let url = panel.url else { return }
                guard ["xcodeproj", "xcworkspace", "ipa"].contains(url.pathExtension) else {
                    error = "Выберите .xcodeproj, .xcworkspace или .ipa."; return
                }
                entry.path = url.path
                entry.kind = url.pathExtension == "ipa" ? .ipa : .project
                entry.scheme = entry.kind == .project ? url.deletingPathExtension().lastPathComponent : ""
                entry.lastAttempt = nil
                entry.expires = nil
                entry.status = "Источник изменён — обновите приложение"
                schemes = []
                error = ""
            }
            if entry.kind == .project {
                HStack {
                    TextField("Схема Xcode", text: $entry.scheme).textFieldStyle(.roundedBorder)
                    Button(loading ? "Загрузка…" : "Получить схемы") {
                        loading = true
                        let worker = store.engine()
                        let path = entry.path
                        Task {
                            do { schemes = try await Task.detached { try worker.schemes(path) }.value; error = "" }
                            catch { self.error = error.localizedDescription }
                            loading = false
                        }
                    }.disabled(loading)
                }
                if !schemes.isEmpty {
                    Picker("Схема", selection: $entry.scheme) {
                        if !schemes.contains(entry.scheme) { Text(entry.scheme).tag(entry.scheme) }
                        ForEach(schemes, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Конфигурация (обычно Debug или Release)", text: $entry.configuration).textFieldStyle(.roundedBorder)
            }
            if !error.isEmpty { Text(String(error.suffix(800))).font(.caption).foregroundStyle(.orange) }
            Text("Bundle ID сохраняется. При смене команды Apple доступ к прежним данным Keychain может измениться.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Удалить из списка", role: .destructive) {
                    store.preferences.entries.removeAll { $0.id == entry.id }; store.editing = nil
                }
                Spacer()
                Button("Отмена") { store.editing = nil }
                Button("Сохранить") { store.commit(entry) }.buttonStyle(.borderedProminent)
                    .disabled(entry.name.isEmpty || (entry.kind == .project && entry.scheme.isEmpty))
            }
        }.padding(26).frame(width: 580)
    }
}
