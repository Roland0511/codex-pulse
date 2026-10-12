import AppKit
import Combine
import Sparkle

/// Sparkle 是更新设置、调度、下载和安装的唯一来源；不另存一套偏好。
@MainActor protocol UpdateDriver: AnyObject {
    var canCheck: Bool { get }
    var automaticallyChecks: Bool { get set }
    var automaticallyInstalls: Bool { get set }
    var pendingVersion: String? { get }
    var onChange: (() -> Void)? { get set }
    func check()
    func installNow()
}

@MainActor private final class SparkleUpdateDriver: NSObject, UpdateDriver, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var pendingInstallation: (() -> Void)?
    private(set) var pendingVersion: String?
    private var observations: Set<AnyCancellable> = []
    var onChange: (() -> Void)?
    var canCheck: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyInstalls: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }
    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] _ in self?.onChange?() }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] _ in self?.onChange?() }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] _ in self?.onChange?() }.store(in: &observations)
        controller.startUpdater()
    }
    func installNow() { pendingInstallation?() }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock handler: @escaping () -> Void) -> Bool {
        pendingVersion = item.displayVersionString
        pendingInstallation = handler
        onChange?()
        return true
    }
    func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

@MainActor final class AppUpdater: ObservableObject {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyInstalls = false
    @Published private(set) var pendingVersion: String?
    let isAvailable: Bool
    let version: String
    private let driver: UpdateDriver?

    init(enabled: Bool = true, driver supplied: UpdateDriver? = nil, bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let configured = feed.flatMap(URL.init(string:))?.scheme == "https" && Data(base64Encoded: key)?.count == 32
        driver = enabled ? (supplied ?? (configured ? SparkleUpdateDriver() : nil)) : nil
        isAvailable = driver != nil
        driver?.onChange = { [weak self] in self?.synchronize() }
        synchronize()
    }
    private func synchronize() {
        canCheck = driver?.canCheck ?? false
        automaticallyChecks = driver?.automaticallyChecks ?? false
        automaticallyInstalls = driver?.automaticallyInstalls ?? false
        pendingVersion = driver?.pendingVersion
    }
    func check() { guard canCheck else { return }; driver?.check(); synchronize() }
    func installNow() { guard pendingVersion != nil else { return }; driver?.installNow() }
    func setAutomaticChecks(_ enabled: Bool) {
        guard let driver else { return }
        if !enabled { driver.automaticallyInstalls = false }
        driver.automaticallyChecks = enabled
        synchronize()
    }
    func setAutomaticInstalls(_ enabled: Bool) {
        guard let driver else { return }
        if enabled { driver.automaticallyChecks = true }
        driver.automaticallyInstalls = enabled
        synchronize()
    }
}
