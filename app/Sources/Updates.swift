import AppKit
import Sparkle

/// Updates, through Sparkle. Once a day it reads appcast.xml from the latest GitHub release
/// (SUFeedURL in Info.plist) and offers a newer build; the download is installed only if its
/// EdDSA signature matches SUPublicEDKey. `make release` signs the disk image and publishes
/// the appcast next to it (tools/release/release.sh).
enum Updates {
    private static let delegate = UpdaterDelegate()
    /// Made for the menu item at launch, started after the first paint.
    private static let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)

    /// Starts the daily check. Never in preview mode (sample chats, no network).
    /// Dev: WA_UPDATE_FEED=<url> reads that appcast instead and checks straight away.
    static func start() {
        guard !Core.shared.isPreview else { return }
        controller.startUpdater()
        if ProcessInfo.processInfo.environment["WA_UPDATE_FEED"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { controller.updater.checkForUpdates() }
        }
    }

    /// App menu › Check for Updates…; disabled until the updater has started and while it checks.
    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…",
                              action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        return item
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["WA_UPDATE_FEED"]
    }
}
