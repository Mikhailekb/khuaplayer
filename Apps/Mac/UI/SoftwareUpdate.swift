#if !SP_APP_STORE
import AppKit

// ── Software updates (Sparkle 2, configuration-gated and lazy-loaded) ──
//
// Distribution policy: an explicit SPEnableDistributionUpdates opt-in and the
// distributor's SUFeedURL/SUPublicEDKey are required. Inherited update metadata
// cannot enable updates by itself. Until configured, the framework is not loaded,
// no menu item is created, and no update request is made. App Store builds compile
// this implementation out.
//
// The framework is embedded but not linked, so first-frame startup does not
// load its dylib. It is loaded during an idle phase and invoked through the
// Objective-C runtime. Only initialization and manual checking use selectors.
//
// Supply-chain model: Sparkle is built from a checksum-pinned source tag.
// Update authenticity is anchored by the distributor's EdDSA private key and
// Developer ID signature, both of which remain outside the source repository.
@MainActor
enum SPSoftwareUpdater {
    /// Enable only after this distributor opts in with its own feed and key.
    /// This reads Info.plist only, so menu construction can call it safely.
    nonisolated static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        return info?["SPEnableDistributionUpdates"] as? Bool == true
            && (info?["SUFeedURL"] as? String)?.isEmpty == false
            && (info?["SUPublicEDKey"] as? String)?.isEmpty == false
    }

    private static var controller: NSObject?
    private static var loadInFlight = false
    private static let updateDelegate = SPUpdateUsageDelegate {
        usageReportingConfigured
    }

    /// Distribution metadata, not a user setting. Unconfigured, third-party,
    /// and App Store builds do not participate in the official feed statistics.
    nonisolated static var usageReportingConfigured: Bool {
        guard isConfigured,
              Bundle.main.object(forInfoDictionaryKey: "SPUpdateUsageEnabled") as? Bool == true,
              let value = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        else { return false }
        return SPUpdateUsageDelegate.supports(feedURL: URL(string: value))
    }

    private static var frameworkBundle: Bundle? {
        guard let fwDir = Bundle.main.privateFrameworksPath else { return nil }
        return Bundle(path: fwDir + "/Sparkle.framework")
    }

    /// Idle-phase start (+5s after launch): dyld-load the framework on a
    /// utility queue, then create the updater on the main thread only while
    /// nothing is playing. Both steps used to run on the main thread at t≈5s,
    /// exactly when a double-clicked file is in steady playback, and the pacing
    /// gate never sees it because internal builds are unconfigured.
    static func startIfConfigured() {
        guard isConfigured, controller == nil, !loadInFlight,
              let bundle = frameworkBundle else { return }
        loadInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let loaded = bundle.load()
            DispatchQueue.main.async {
                loadInFlight = false
                guard loaded else {
                    NSLog("[Updater] Failed to load Sparkle.framework")
                    return
                }
                startControllerWhenIdle()
            }
        }
    }

    private static func startControllerWhenIdle() {
        guard isConfigured, controller == nil else { return }
        if OpenPanelWarmer.foregroundIOActive {
            // Playing: re-check later rather than initialise the updater in the
            // tick's run loop. Manual "Check for Updates" bypasses this wait.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                startControllerWhenIdle()
            }
            return
        }
        startController()
    }

    /// Synchronous start (framework already loaded, or user-initiated).
    private static func startController() {
        guard isConfigured, controller == nil,
              let cls = NSClassFromString("SPUStandardUpdaterController")
                  as? NSObject.Type else {
            NSLog("[Updater] Failed to load Sparkle.framework")
            return
        }
        let sel = NSSelectorFromString(
            "initWithStartingUpdater:updaterDelegate:userDriverDelegate:")
        // Swift does not expose alloc() here, so initialize through the
        // Objective-C runtime and retain the singleton for the process lifetime.
        guard let allocated = (cls as AnyObject)
                  .perform(NSSelectorFromString("alloc"))?
                  .takeUnretainedValue() as? NSObject,
              allocated.responds(to: sel),
              let imp = allocated.method(for: sel) else {
            NSLog("[Updater] SPUStandardUpdaterController API mismatch")
            return
        }
        typealias InitFn = @convention(c)
            (NSObject, Selector, ObjCBool, AnyObject?, AnyObject?) -> NSObject
        let initFn = unsafeBitCast(imp, to: InitFn.self)
        controller = initFn(allocated, sel, true, updateDelegate, nil)
        if spDebugEnabled {
            NSLog("[Updater] Sparkle update scheduling started")
        }
    }

    /// Handle Check for Updates, starting Sparkle first if idle setup has not run.
    static func checkForUpdates() {
        guard isConfigured else { return }
        if controller == nil, isConfigured, let bundle = frameworkBundle, bundle.load() {
            startController() // user action: synchronous, regardless of playback
        }
        guard let controller else { return }
        controller.perform(NSSelectorFromString("checkForUpdates:"),
                           with: nil)
    }

    // ── Automatic-check toggle (menu item; cadence = Sparkle default 86400s) ──
    // Storage is Sparkle's own user-defaults key. When unset, fall back to the
    // Info.plist SUEnableAutomaticChecks (release builds inject YES so checks
    // are on by default without the second-launch permission prompt), then to
    // on. While the updater is running, write through KVC so it reschedules
    // immediately instead of reading the default at the next launch.
    nonisolated static var automaticChecksEnabled: Bool {
        guard isConfigured else { return false }
        if let v = UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks")
            as? Bool { return v }
        if let v = Bundle.main.infoDictionary?["SUEnableAutomaticChecks"]
            as? Bool { return v }
        return true
    }

    static func setAutomaticChecks(_ on: Bool) {
        guard isConfigured else { return }
        startIfConfigured()
        if let controller,
           let updater = controller.value(forKey: "updater") as? NSObject {
            updater.setValue(on, forKey: "automaticallyChecksForUpdates")
        } else {
            UserDefaults.standard.set(on, forKey: "SUEnableAutomaticChecks")
        }
    }
}
#endif
