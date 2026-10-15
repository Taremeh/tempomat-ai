import Foundation
import Testing
@testable import AITempomat

@Suite @MainActor
struct ProfileStorageTests {
    @Test func profileFilesGaugeChoicesAndCalibrationStaySeparate() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        fixture.defaults.set(999, forKey: SettingsKey.tokensPerPercent(.all))

        let reset = Date().addingTimeInterval(3600)
        let personalSource = StorageSource(rows: storageRows(percent: 64, reset: reset))
        let workSource = StorageSource(rows: storageRows(percent: 11, reset: reset))
        let personal = fixture.store(source: personalSource, id: "personal")
        let work = fixture.store(source: workSource, id: "work")
        #expect(personal.typicalTokensPerPercent == nil)
        #expect(work.typicalTokensPerPercent == nil)
        await personal.refresh()
        await work.refresh()
        personal.showOnGauge(try #require(personal.meters.last))
        personal.recordTokensPerPercent(1111, for: .all)
        personal.recordTokensPerPercent(123, for: .output)
        work.recordTokensPerPercent(2222, for: .all)

        // Only the personal account crosses a window boundary.
        let nextSession = storageRows(percent: 3, reset: reset.addingTimeInterval(5 * 3600))[0]
        let sameWeek = storageRows(percent: 64, reset: reset)[1]
        await personalSource.setRows([nextSession, sameWeek])
        await personal.refresh()
        let personalAgain = fixture.store(source: personalSource, id: "personal")
        let workAgain = fixture.store(source: workSource, id: "work")
        #expect(personalAgain.currentTracks["session"]?.samples.last?.p == 3)
        #expect(workAgain.currentTracks["session"]?.samples.last?.p == 11)
        #expect(personalAgain.archive.windows.count == 1)
        #expect(workAgain.archive.windows.isEmpty)
        #expect(personalAgain.tokensPerPercent(for: .all) == 1111)
        #expect(personalAgain.tokensPerPercent(for: .output) == 123)
        #expect(workAgain.tokensPerPercent(for: .all) == 2222)
        #expect(workAgain.tokensPerPercent(for: .output) == 0)
        #expect(fixture.defaults.double(forKey: SettingsKey.tokensPerPercent(.all)) == 999)
        personalAgain.load(rows: storageRows(percent: 3, reset: reset))
        workAgain.load(rows: storageRows(percent: 11, reset: reset))
        #expect(personalAgain.headline?.id == "weekly_all")
        #expect(workAgain.headline?.id == "session")
        #expect(personal.savedDataFolder == fixture.folder.appending(path: "profiles/personal"))
        #expect(work.savedDataFolder == fixture.folder.appending(path: "profiles/work"))
    }

    @Test func nilStorageIDPreservesLegacyFilesAndSettings() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let rows = storageRows(percent: 41, reset: Date().addingTimeInterval(3600))
        let source = StorageSource(rows: rows)
        let legacy = fixture.store(source: source, id: nil)
        await legacy.refresh()
        legacy.showOnGauge(try #require(legacy.meters.last))
        legacy.recordTokensPerPercent(345, for: .all)
        #expect(legacy.savedDataFolder == fixture.folder)
        #expect(legacy.settingsKey(SettingsKey.gaugeChoice) == SettingsKey.gaugeChoice)
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "history.json").path))
        #expect(fixture.defaults.double(forKey: SettingsKey.tokensPerPercent(.all)) == 345)
        let reloaded = fixture.store(source: source, id: nil)
        reloaded.load(rows: rows)
        #expect(reloaded.headline?.id == "weekly_all")
        #expect(reloaded.typicalTokensPerPercent == 345)
        #expect(reloaded.currentTracks["session"]?.samples.last?.p == 41)
    }

    @Test func unsafeProfileIDsCannotEscapeOrShareStorage() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let source = StorageSource(rows: [])
        let ids = ["../work", ".._work", "", "personal", "Personal", String(repeating: "a", count: 300)]
        let stores = ids.map { fixture.store(source: source, id: $0) }
        let paths = try stores.map { try #require($0.savedDataFolder).standardizedFileURL.path }
        #expect(Set(paths.map { $0.lowercased() }).count == ids.count)
        #expect(Set(stores.map { $0.settingsKey("calibration") }).count == ids.count)
        for path in paths {
            #expect(path.hasPrefix(fixture.folder.appending(path: "profiles").path + "/"))
            #expect(URL(fileURLWithPath: path).lastPathComponent.utf8.count < 255)
        }
        #expect(fixture.store(source: source, id: "../work").savedDataFolder == stores[0].savedDataFolder)
    }

    @Test func previewsNeverOverwriteCalibration() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        fixture.defaults.set(50, forKey: SettingsKey.tokensPerPercent(.all))
        let store = UsageStore(source: StorageSource(rows: []), persist: false,
                               dataFolder: fixture.folder, defaults: fixture.defaults)
        store.recordTokensPerPercent(500, for: .all)
        #expect(store.tokensPerPercent(for: .all) == 50)
        #expect(store.savedDataFolder == nil)
    }

    @Test func stoppedFetchCannotOverwriteNewerRefresh() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let source = SuspendedStorageSource()
        let store = fixture.store(source: source, id: "work")
        let first = Task { await store.refresh() }
        await source.waitForFetchCount(1)
        #expect(store.isRefreshing)
        store.stop()
        #expect(!store.isRefreshing)
        let second = Task { await store.refresh() }
        await source.waitForFetchCount(2)
        await source.complete(2, percent: 22)
        await second.value
        await source.complete(1, percent: 99)
        await first.value
        #expect(store.headline?.percent == 22)
        #expect(store.currentTracks["session"]?.samples.count == 1)
        #expect(store.problem == nil)
        #expect(!store.isRefreshing)
    }
}

@MainActor
private struct StorageFixture {
    let folder: URL
    let defaults: UserDefaults
    private let suite: String

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "AITempomatStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "AITempomatStorageTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func store(source: any UsageSource, id: String?) -> UsageStore {
        UsageStore(source: source, persist: true, storageID: id, dataFolder: folder, defaults: defaults)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
}

private func storageRows(percent: Double, reset: Date) -> [LimitRow] {
    let iso = ISO8601DateFormatter()
    return [
        LimitRow(kind: "session", group: "session", percent: percent,
                 resetsAt: iso.string(from: reset), scope: nil, severity: "normal", isActive: true),
        LimitRow(kind: "weekly_all", group: "weekly", percent: 10,
                 resetsAt: iso.string(from: reset.addingTimeInterval(7 * 86400)), scope: nil,
                 severity: "normal", isActive: false)
    ]
}

private actor StorageSource: UsageSource {
    private var rows: [LimitRow]
    init(rows: [LimitRow]) { self.rows = rows }
    func setRows(_ rows: [LimitRow]) { self.rows = rows }
    func fetch() async throws -> [LimitRow] { rows }
}

/// Deliberately ignores cancellation so tests exercise late-result protection too.
private actor SuspendedStorageSource: UsageSource {
    private var count = 0
    private var pending: [Int: CheckedContinuation<[LimitRow], Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func fetch() async throws -> [LimitRow] {
        count += 1
        let id = count
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            for (_, waiter) in waiters.filter({ $0.0 <= count }) { waiter.resume() }
            waiters.removeAll { $0.0 <= count }
        }
    }

    func waitForFetchCount(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    func complete(_ id: Int, percent: Double) {
        pending.removeValue(forKey: id)?.resume(returning: storageRows(percent: percent, reset: Date().addingTimeInterval(3600)))
    }
}
