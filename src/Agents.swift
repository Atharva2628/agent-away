// Knows which agents are running and what each Claude Code session is doing.
// Sources (all push-based): Claude Code's own ~/.claude/sessions/<pid>.json
// files (FSEvents), NSWorkspace launch/quit for Claude.app, and process-exit
// kqueue sources for every agent pid.

import AppKit
import CoreServices

struct Session: Equatable {
    let pid: pid_t
    let id: String
    let cwd: String
    let name: String
    let entrypoint: String      // "cli", "claude-desktop", ...
    let status: String          // busy | idle | waiting (on the user) | shell (background job running)
    let updatedAt: Date
    let socketPath: String?
    let provider: String        // "claude" | "grok"

    var label: String {
        let n = name.isEmpty ? (cwd as NSString).lastPathComponent : name
        return n.isEmpty ? "pid \(pid)" : n
    }
    var busy: Bool { status == "busy" }
    var isDesktop: Bool { entrypoint == "claude-desktop" }
}

final class AgentWatcher {
    static let desktopBundle = "com.anthropic.claudefordesktop"
    let sessionsDir = claudeDir + "/sessions"

    private(set) var sessions: [pid_t: Session] = [:]
    private(set) var desktopRunning = false
    private(set) var grokPids: Set<pid_t> = []
    var onChange: (() -> Void)?

    private var stream: FSEventStreamRef?
    private var exitSources: [pid_t: DispatchSourceProcess] = [:]

    var anyRunning: Bool { desktopRunning || !sessions.isEmpty || !grokPids.isEmpty }
    var anyBusy: Bool { sessions.values.contains(where: \.busy) }

    init() {
        let ws = NSWorkspace.shared
        desktopRunning = ws.runningApplications.contains { $0.bundleIdentifier == Self.desktopBundle }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let self,
                      let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.desktopBundle else { return }
                self.desktopRunning = name == NSWorkspace.didLaunchApplicationNotification
                self.refresh()
            }
        }
        startStream()
        refresh()
    }

    /// Re-reads session files and scans for grok CLIs. Cheap: a handful of small files.
    func refresh() {
        var next: [pid_t: Session] = [:]
        let table = processTable()
        guard !table.isEmpty else { return }   // sysctl hiccup: keep what we know
        let files = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir)) ?? []
        for f in files where f.hasSuffix(".json") {
            // A file left by a crashed session can name a pid that now belongs to something else.
            guard let pid = pid_t(f.dropLast(5)), table[pid]?.comm == "claude",
                  let data = FileManager.default.contents(atPath: sessionsDir + "/" + f),
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            next[pid] = Session(
                pid: pid,
                id: j["sessionId"] as? String ?? "",
                cwd: j["cwd"] as? String ?? "",
                name: j["name"] as? String ?? "",
                entrypoint: j["entrypoint"] as? String ?? "cli",
                status: j["status"] as? String ?? "",
                updatedAt: Date(timeIntervalSince1970: (j["updatedAt"] as? Double ?? 0) / 1000),
                socketPath: j["messagingSocketPath"] as? String,
                provider: "claude")
        }
        // grok runs as its versioned binary (e.g. "grok-1.0.60-maco"), not "grok".
        let grok = Set(table.values.filter { $0.comm.hasPrefix("grok") && $0.uid == getuid() }.map(\.pid))
        guard next != sessions || grok != grokPids else { return }
        sessions = next
        grokPids = grok
        for pid in Set(sessions.keys).union(grokPids) where exitSources[pid] == nil { watchExit(pid) }
        onChange?()
    }

    private func watchExit(_ pid: pid_t) {
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            src.cancel()
            self?.exitSources[pid] = nil
            self?.refresh()
        }
        exitSources[pid] = src
        src.resume()
    }

    private func startStream() {
        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        // Only <pid>.json changes matter (not .key files or the fleet-view heartbeat).
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let list = unsafeBitCast(paths, to: NSArray.self)
            let relevant = (0..<count).contains { i in
                guard let p = list[i] as? String else { return false }
                let name = (p as NSString).lastPathComponent
                return name.hasSuffix(".json") && name.dropLast(5).allSatisfy(\.isNumber)
            }
            if relevant { Unmanaged<AgentWatcher>.fromOpaque(info).takeUnretainedValue().refresh() }
        }
        let flags = kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [sessionsDir] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }
}
