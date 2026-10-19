// Unsticks a Claude Code session that is busy but has gone silent.
//
// Most network trouble never reaches this: Claude Code's stream watchdog turns
// a dead stream into an API error within minutes, and the StopFailure hook
// wakes the session once the network is back. This covers what's left: a turn
// stuck waiting on the API for a long time with no transcript writes.
//
// The nudge goes through Claude Code's own per-session inbox socket
// (/tmp/cc-socks/<pid>.sock, the channel Claude sessions use to message each
// other). Priority "now" aborts the stuck request like Esc and delivers the
// text as the next turn. Works for desktop and CLI sessions, screen locked or not.

import Foundation
import CryptoKit

let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
let claudeDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? homeDir + "/.claude"

/// What the tail of a session transcript says.
struct TranscriptState {
    var lastActivity = Date.distantPast
    var apiCallInFlight = false    // last message is a prompt or tool result: waiting on the API
    var toolRunning = false        // a tool call has no result yet (e.g. one of several parallel calls)
    var permissionMode = "default"
}

private var transcriptDirs: [String: String] = [:]   // session id -> project dir

/// Claude Code's project folder name: the cwd with every non-alphanumeric character as "-".
private func projectDir(cwd: String, sessionId: String) -> String? {
    let fm = FileManager.default
    let projects = claudeDir + "/projects"
    if let d = transcriptDirs[sessionId] { return d }
    let guess = projects + "/" + String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    var found: String?
    if fm.fileExists(atPath: "\(guess)/\(sessionId).jsonl") {
        found = guess
    } else {
        for d in (try? fm.contentsOfDirectory(atPath: projects)) ?? []
            where fm.fileExists(atPath: "\(projects)/\(d)/\(sessionId).jsonl") { found = "\(projects)/\(d)"; break }
    }
    transcriptDirs[sessionId] = found
    return found
}

/// Returns nil when the session has written its transcript within `quietFor`
/// seconds (the cheap check), or when the transcript can't be found.
func transcriptState(sessionId: String, cwd: String, quietFor: TimeInterval) -> TranscriptState? {
    let fm = FileManager.default
    guard let dir = projectDir(cwd: cwd, sessionId: sessionId) else { return nil }
    do {
        let file = "\(dir)/\(sessionId).jsonl"
        guard let attrs = try? fm.attributesOfItem(atPath: file) else { transcriptDirs[sessionId] = nil; return nil }
        var st = TranscriptState()
        st.lastActivity = attrs[.modificationDate] as? Date ?? .distantPast
        if Date().timeIntervalSince(st.lastActivity) < quietFor { return nil }
        // Subagents and tool results live next to it; their writes count as progress.
        if let e = fm.enumerator(atPath: "\(dir)/\(sessionId)") {
            while e.nextObject() != nil {
                if let m = e.fileAttributes?[.modificationDate] as? Date, m > st.lastActivity { st.lastActivity = m }
            }
        }
        if Date().timeIntervalSince(st.lastActivity) < quietFor { return nil }
        guard let h = FileHandle(forReadingAtPath: file) else { return st }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        var sawLast = false, sawMode = false, sawCall = false
        var results: Set<String> = []
        for line in tail.split(separator: "\n").reversed() {
            guard let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let type = j["type"] as? String ?? ""
            // Tool calls of the latest assistant message without a matching result are still running.
            let blocks = (j["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            if !sawCall, type == "user" {
                for b in blocks where b["type"] as? String == "tool_result" { if let id = b["tool_use_id"] as? String { results.insert(id) } }
            } else if !sawCall, type == "assistant" {
                let calls = blocks.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
                if !calls.isEmpty {
                    st.toolRunning = calls.contains { !results.contains($0) }
                    sawCall = true
                }
            }
            if !sawMode, let m = j["permissionMode"] as? String {
                st.permissionMode = m
                sawMode = true
            }
            // Only real messages decide it: attachments (e.g. prompt_snapshot) trail the reply.
            // Last message from the user (prompt or tool result) = waiting on the API;
            // from the assistant = a tool is running or the turn is wrapping up.
            if !sawLast, type == "user" || type == "assistant" {
                st.apiCallInFlight = type == "user"
                sawLast = true
            }
            if sawLast && sawMode && sawCall { break }
        }
        return st
    }
}

final class Nudger {
    private let note: (String) -> Void
    private var sent: [String: [Date]] = [:]   // session id -> recent nudge times

    init(note: @escaping (String) -> Void) { self.note = note }

    /// Called every minute while keep-awake is on.
    func checkStalls(_ sessions: [Session], quietMinutes: Int) {
        let now = Date()
        for s in sessions where s.status == "busy" {
            guard let t = transcriptState(sessionId: s.id, cwd: s.cwd, quietFor: Double(quietMinutes * 60)),
                  t.apiCallInFlight, !t.toolRunning, t.permissionMode != "plan" else { continue }
            let recent = (sent[s.id] ?? []).filter { now.timeIntervalSince($0) < 3600 }
            guard recent.count < 3, recent.allSatisfy({ now.timeIntervalSince($0) >= Double(quietMinutes * 60) }),
                  !checking.contains(s.pid) else { continue }
            // Quiet isn't enough: a very long reply also writes nothing until it ends.
            // Only nudge when the session has received no network data for 20 s.
            checking.insert(s.pid)
            DispatchQueue.global(qos: .utility).async {
                let dead = Nudger.receivedNothing(pid: s.pid, seconds: 20)
                DispatchQueue.main.async {
                    self.checking.remove(s.pid)
                    guard dead else { return }
                    self.nudge(s, t, quietMinutes: quietMinutes)
                }
            }
        }
    }

    private var checking: Set<pid_t> = []

    /// Bytes received by the process over `seconds`, via nettop (no root needed).
    static func receivedNothing(pid: pid_t, seconds: Int) -> Bool {
        let out = sh("/usr/bin/nettop", ["-P", "-L", "2", "-s", "\(seconds)", "-p", "\(pid)", "-J", "bytes_in", "-x"]).out
        let values = out.split(separator: "\n").compactMap { line -> UInt64? in
            let f = line.split(separator: ",")
            return f.count >= 2 && !f[0].isEmpty ? UInt64(f[1]) : nil
        }
        guard values.count >= 2 else { return false }   // can't tell: don't interrupt
        return values[values.count - 1] == values[values.count - 2]
    }

    private func nudge(_ s: Session, _ t: TranscriptState, quietMinutes: Int) {
        let now = Date()
        let recent = (sent[s.id] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        let body = "Automated nudge from Agent Away, the watchdog the user installed on this Mac (not another agent). "
            + "Your last request has been waiting with no response for \(quietMinutes)+ minutes, probably a dropped "
            + "connection while the user is away. Please continue the task from where you left off."
        if send(s, body, priority: "now", bypass: t.permissionMode == "bypassPermissions") {
            sent[s.id] = recent + [now]
            note("Nudged stuck session \"\(s.label)\"")
        }
    }

    /// One message to the session's inbox socket. Returns false if it couldn't be delivered.
    @discardableResult
    func send(_ s: Session, _ body: String, priority: String, bypass: Bool) -> Bool {
        guard let path = s.socketPath, path.utf8.count < 104 else { return false }
        let content = "<cross-session-message from=\"did:agent-away\" from-name=\"Agent Away\" from-mode=\"\(bypass ? "bypass" : "prompting")\">\n"
            + body + "\n</cross-session-message>"
        var lines: [[String: Any]] = []
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        if let data = FileManager.default.contents(atPath: "\(claudeDir)/sessions/\(s.pid).\(hash).key"),
           let key = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let token = key["peerToken"] as? String {
            lines.append(["type": "auth", "token": token])
        }
        lines.append(["type": "user", "msgV": 1, "msg_id": UUID().uuidString.lowercased(), "session_id": s.id,
                      "priority": priority, "message": ["role": "user", "content": content]])
        var payload = Data()
        for l in lines {
            guard let d = try? JSONSerialization.data(withJSONObject: l) else { return false }
            payload += d + Data("\n".utf8)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in path.utf8.enumerated() { buf[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { return false }
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)
        return written == payload.count
    }
}
