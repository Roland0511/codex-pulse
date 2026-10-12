import Foundation
import Testing
@testable import PulseApp

@MainActor private final class FakeUpdateDriver: UpdateDriver {
    var canCheck = true
    var automaticallyChecks = false
    var automaticallyInstalls = false
    var pendingVersion: String?
    var installs = 0
    func installNow() { installs += 1 }
    var onChange: (() -> Void)?
    var checks = 0
    func check() { checks += 1; canCheck = false; onChange?() }
}

@Suite("更新设置与请求入口", .serialized) @MainActor struct UpdaterTests {
    @Test func disabledAndUnconfiguredBuildsNeverStartUpdates() {
        let fake = FakeUpdateDriver()
        let demo = AppUpdater(enabled: false, driver: fake)
        demo.check(); demo.setAutomaticInstalls(true)
        #expect(!demo.isAvailable && !demo.canCheck && fake.checks == 0)
        #expect(!fake.automaticallyChecks && !fake.automaticallyInstalls)
        let unconfigured = AppUpdater(bundle: Bundle(for: FakeBundleMarker.self))
        #expect(!unconfigured.isAvailable)
    }
    @Test func automaticInstallRequiresChecksAndDisablingChecksStopsFutureDownloads() {
        let fake = FakeUpdateDriver()
        let sut = AppUpdater(driver: fake)
        sut.setAutomaticInstalls(true)
        #expect(sut.automaticallyChecks && sut.automaticallyInstalls)
        sut.setAutomaticChecks(false)
        #expect(!sut.automaticallyChecks && !sut.automaticallyInstalls)
        #expect(sut.isAvailable)
    }
    @Test func installationOnlyRunsForTheVerifiedDownloadedUpdate() {
        let fake = FakeUpdateDriver(), sut = AppUpdater(driver: FakeUpdateDriver())
        let ready = AppUpdater(driver: fake)
        ready.installNow()
        #expect(fake.installs == 0)
        fake.pendingVersion = "0.2.0"; fake.onChange?()
        ready.installNow()
        #expect(ready.pendingVersion == "0.2.0" && fake.installs == 1)
        #expect(sut.pendingVersion == nil)
    }
    @Test func storedSettingsAreNotResetAndBusyChecksAreCoalesced() {
        let fake = FakeUpdateDriver()
        fake.automaticallyChecks = true; fake.automaticallyInstalls = true
        let sut = AppUpdater(driver: fake)
        #expect(sut.automaticallyChecks && sut.automaticallyInstalls)
        sut.check(); sut.check()
        #expect(fake.checks == 1 && !sut.canCheck)
        fake.canCheck = true; fake.automaticallyInstalls = false; fake.onChange?()
        #expect(sut.canCheck && !sut.automaticallyInstalls)
    }
}
private class FakeBundleMarker: NSObject {}
