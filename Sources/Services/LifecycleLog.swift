import AppKit

/// Records launches and exits in ~/Library/Caches/<bundle id>/lifecycle_log.txt,
/// so a stretch where the app wasn't running can be explained after the
/// unified log (which keeps about a day) has rotated.
///
/// Force Quit, `kill -9`, crashes and power loss can't log anything as they
/// happen, so the next launch notes a run that never logged an exit.
enum LifecycleLog {

    nonisolated static let file = LogFile(named: "lifecycle_log.txt")

    /// Call once at launch: logs the launch — and any previous run that ended
    /// without logging an exit — and starts logging termination signals.
    static func start() {
        let me = getpid()
        if let pid = runWithoutExit(in: file.lines(), isRunning: { $0 != me && kill($0, 0) == 0 }) {
            file.append("previous run pid=\(pid) ended without logging an exit (force quit, crash, kill -9 or power loss)")
        }
        file.append("launch pid=\(me) path=\(Bundle.main.bundlePath)")
        signalSources = [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT"), (SIGHUP, "SIGHUP")]
            .map { logSignal($0, named: $1) }
    }

    nonisolated static func recordExit(_ reason: String) {
        file.append("exit pid=\(getpid()) \(reason)")
    }

    /// Why the app is quitting right now; call from applicationShouldTerminate.
    static func currentQuitReason() -> String {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let sender = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        return quitReason(for: event, senderPID: sender, appName: { processName($0) })
    }

    // MARK: - Signals

    /// Kept alive for the life of the app.
    private static var signalSources: [DispatchSourceSignal] = []

    /// Logs `signo`, then lets it end the app just as it would have. Handled
    /// off the main thread, so a busy main thread can't stop `kill` working.
    nonisolated private static func logSignal(_ signo: Int32, named name: String) -> DispatchSourceSignal {
        signal(signo, SIG_IGN)   // the dispatch source takes delivery instead
        let source = DispatchSource.makeSignalSource(signal: signo, queue: .global())
        source.setEventHandler {
            recordExit(name)
            signal(signo, SIG_DFL)
            raise(signo)
        }
        source.resume()
        return source
    }

    private static func processName(_ pid: pid_t) -> String? {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Decisions (unit-tested)

    /// The pid of the last launch in `lines` that never logged an exit and
    /// isn't running any more, if there is one.
    static func runWithoutExit(in lines: [String], isRunning: (pid_t) -> Bool) -> pid_t? {
        guard let lastLaunch = lines.lastIndex(where: { $0.contains(" launch pid=") }),
              let pid = pid(in: lines[lastLaunch]) else { return nil }
        let exited = lines[lastLaunch...].contains { $0.contains(" exit pid=\(pid) ") }
        return exited || isRunning(pid) ? nil : pid
    }

    /// Why the app is quitting. `event` is the Apple Event being handled — nil
    /// when the quit came from inside the app (Quit button or ⌘Q) — and
    /// `senderPID` the process that sent it.
    static func quitReason(for event: NSAppleEventDescriptor?, senderPID: pid_t?,
                           appName: (pid_t) -> String?) -> String {
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else {
            return "quit from the app"
        }
        switch event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue {
        case kAELogOut?, kAEReallyLogOut?:           return "logout"
        case kAERestart?, kAEShowRestartDialog?:     return "restart"
        case kAEShutDown?, kAEShowShutdownDialog?:   return "shutdown"
        default:                                     break
        }
        if let senderPID, senderPID > 0 {
            return "quit requested by \(appName(senderPID) ?? "an unknown process") (pid \(senderPID))"
        }
        return "quit requested by another process"
    }

    private static func pid(in line: String) -> pid_t? {
        guard let start = line.range(of: "pid=")?.upperBound else { return nil }
        return pid_t(line[start...].prefix(while: \.isNumber))
    }
}
