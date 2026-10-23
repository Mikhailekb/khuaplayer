import AppKit

SPBrandMigration.runIfNeeded()

#if !SP_APP_STORE

if let logPath = ProcessInfo.processInfo.environment["SP_LOGFILE"] {
    freopen(logPath, "w", stderr)
}

func spProcessExecTime() -> Double {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
    let tv = info.kp_proc.p_starttime
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
}
let spExecTime = spProcessExecTime()
func spLaunchMark(_ label: String) {
    guard spDebugEnabled, spExecTime > 0 else { return }
    NSLog("[Launch] %@ %.0fms (自 exec)", label,
          (Date().timeIntervalSince1970 - spExecTime) * 1000)
}
spLaunchMark("main 入口")
#else
@inline(__always) func spLaunchMark(_ label: String) {}
#endif

SPPrewarmMetalDevice()

let spCLIFilePath: String? = {
#if SP_APP_STORE

    return nil
#else
    guard let arg = CommandLine.arguments.dropFirst().first,
          FileManager.default.fileExists(atPath: arg) else { return nil }
    return arg
#endif
}()

if spCLIFilePath == nil,
   !(UserDefaults.standard.object(forKey: WelcomeView.bareLaunchHintKey) as? Bool ?? true) {
    SPPrewarmVideoDecoders()
}

if spCLIFilePath == nil,
   UserDefaults.standard.object(forKey: WelcomeView.bareLaunchHintKey) as? Bool ?? true {
    WelcomeView.prewarmTexture(scale: NSScreen.main?.backingScaleFactor ?? 2.0)

    RecentPlaysWarmer.wakeRecentVolumesAtLaunch()
}

let app = NSApplication.shared

app.appearance = NSAppearance(named: .darkAqua)
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
spLaunchMark("NSApplication 就绪")
app.run()
