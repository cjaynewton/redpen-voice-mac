import AppKit
import Sparkle

/// Updates through Sparkle. Once a day Redpen Voice asks the release page for the latest version number; nothing
/// you say or write is sent. A new version is checked against the Redpen signing key before it installs.
@MainActor
final class Updates: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    /// The version waiting to install, found by the daily check. The menu shows it instead of popping up a window
    /// over whatever you are writing.
    @Published private(set) var waiting: String?

    /// Called once at launch. Only a built app (one with a feed address in its Info.plist) starts the updater,
    /// never `swift run` or the screenshot modes.
    func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    /// Redpen Voice lives in the menu bar and is rarely the front app, so Sparkle's windows ("You're up to date", the
    /// update itself) opened behind everything else and looked like nothing happened. it comes forward first.
    func checkNow() {
        bringForward()
        controller?.checkForUpdates(nil)
    }

    func bringForward() { NSApp.activate(ignoringOtherApps: true) }

    // A menu-bar app is rarely in front, so a daily check that finds an update marks the menu instead.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        // Shown now (a check the writer asked for, or a scheduled one in immediate focus): its window comes forward.
        MainActor.assumeIsolated { if handleShowingUpdate { bringForward() } else { waiting = version } }
    }

    nonisolated func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated { bringForward() }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { waiting = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { waiting = nil }
    }
}
