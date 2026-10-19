// Process-table helpers, agent job discovery, and the heat guard.

import Foundation
import Darwin
import IOKit
import Security

struct ProcInfo {
    let pid: pid_t
    let ppid: pid_t
    let pgid: pid_t
    let uid: uid_t
    let start: Int      // start time (s since epoch): with pid, identifies a process
    let comm: String
}

/// A specific process, not just a pid (pids get reused).
struct ProcKey: Hashable { let pid: pid_t; let start: Int }

/// One sysctl call for the whole process table.
func processTable() -> [pid_t: ProcInfo] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    let stride = MemoryLayout<kinfo_proc>.stride
    var procs: [kinfo_proc] = []
    var size = 0
    for attempt in 0..<3 {   // the table can grow between the size query and the fetch
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [:] }
        procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64 << attempt)
        size = procs.count * stride
        if sysctl(&mib, 4, &procs, &size, nil, 0) == 0 { break }
        if errno != ENOMEM || attempt == 2 { return [:] }
    }
    var table: [pid_t: ProcInfo] = [:]
    for p in procs.prefix(size / stride) {
        let comm = withUnsafeBytes(of: p.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        table[p.kp_proc.p_pid] = ProcInfo(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid, pgid: p.kp_eproc.e_pgid,
                                          uid: p.kp_eproc.e_ucred.cr_uid,
                                          start: Int(p.kp_proc.p_starttime.tv_sec), comm: comm)
    }
    return table
}

/// Children lists built once per table.
func childMap(_ table: [pid_t: ProcInfo]) -> [pid_t: [pid_t]] {
    var m: [pid_t: [pid_t]] = [:]
    for p in table.values { m[p.ppid, default: []].append(p.pid) }
    return m
}

private let timebase: (numer: UInt64, denom: UInt64) = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return (UInt64(tb.numer), UInt64(max(tb.denom, 1)))
}()

/// CPU time in nanoseconds: the process's own, plus (with `children`) that of
/// descendants it already reaped, so short-lived workers (compilers under
/// make -j, test runners) still count. rusage times are mach ticks on Apple Silicon.
func cpuNanos(_ pid: pid_t, children: Bool = false) -> UInt64? {
    var ru = rusage_info_v2()
    let rc = withUnsafeMutablePointer(to: &ru) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
        }
    }
    guard rc == 0 else { return nil }
    var t = ru.ri_user_time + ru.ri_system_time
    if children { t += ru.ri_child_user_time + ru.ri_child_system_time }
    return t * timebase.numer / timebase.denom
}

/// GPU time per process in nanoseconds, from the Apple GPU driver's per-client
/// accounting in the IORegistry (readable without root; what Activity Monitor shows).
func gpuNanosByPid() -> [pid_t: UInt64] {
    var out: [pid_t: UInt64] = [:]
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXDeviceUserClient"), &iter) == KERN_SUCCESS else { return out }
    defer { IOObjectRelease(iter) }
    while case let e = IOIteratorNext(iter), e != 0 {
        defer { IOObjectRelease(e) }
        // "pid 412, WindowServer"
        guard let creator = IORegistryEntryCreateCFProperty(e, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
              let pid = pid_t(creator.dropFirst(4).prefix(while: { $0 != "," })),
              let usage = IORegistryEntryCreateCFProperty(e, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]] else { continue }
        for u in usage { out[pid, default: 0] += (u["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0 }
    }
    return out
}

func processPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

// MARK: - The only things this app ever does to another process
//
// It never terminates anything (no SIGTERM/SIGKILL anywhere). It only:
//   - sets or clears Darwin background priority (efficiency cores), and
//   - pauses/resumes (SIGSTOP/SIGCONT) Bash jobs a Claude Code agent started.
// Each action first re-checks that the pid is still the same process (start
// time) owned by this user, so a recycled pid can never redirect it.

/// Start time and owner of one pid, straight from the kernel.
private func identity(_ pid: pid_t) -> (start: Int, uid: uid_t)? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
    return (Int(info.kp_proc.p_starttime.tv_sec), info.kp_eproc.e_ucred.cr_uid)
}

private func sameProcess(_ pid: pid_t, start: Int) -> Bool {
    guard pid > 1, pid != getpid(), let id = identity(pid) else { return false }
    return id.start == start && id.uid == getuid()
}

/// Darwin "background" policy: E-cores only, throttled disk and network I/O.
func setBackground(_ pid: pid_t, start: Int, _ on: Bool) {
    guard sameProcess(pid, start: start) else { return }
    setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0)
}

func pauseProcess(_ pid: pid_t, start: Int) {
    guard sameProcess(pid, start: start) else { return }
    kill(pid, SIGSTOP)
}

func resumeProcess(_ pid: pid_t, start: Int) {
    guard sameProcess(pid, start: start) else { return }
    kill(pid, SIGCONT)
}

private let appleRequirement: SecRequirement? = {
    var r: SecRequirement?
    SecRequirementCreateWithString("anchor apple" as CFString, [], &r)
    return r
}()

/// Signed by Apple (macOS itself, Apple apps, system tools). When the signature
/// can't be checked, answers true so the process is left alone.
func isAppleSigned(_ pid: pid_t) -> Bool {
    var code: SecCode?
    guard let req = appleRequirement,
          SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
          let code else { return true }
    return SecCodeCheckValidity(code, [], req) == errSecSuccess
}

/// Where a non-agent process must live to be throttled at all.
private let userAppRoots = ["/Applications/", homeDir + "/", "/opt/homebrew/", "/usr/local/"]

// MARK: - Agent jobs

/// What a Claude Code session launched. Each direct child of a session process
/// is one job: a Bash tool command or a long-lived server (MCP, language
/// server). Claude Code starts every Bash command as the leader of its own
/// process group, while servers stay in Claude's group; that tells them apart
/// even after the shell replaces itself with the command (`zsh -c ffmpeg` →
/// `ffmpeg`). A job's members are its descendants plus its process group, which
/// keeps `nohup cmd &` and `cmd & disown` orphans in the job after they're
/// reparented to launchd.
struct AgentJob {
    let key: ProcKey
    let pids: [pid_t]          // live members, parents first where known
    let isCommand: Bool        // a Bash tool command (pausable), not a server
}

final class JobTracker {
    /// Job roots seen before; kept while their process group has live members.
    private var known: [ProcKey: Bool] = [:]   // key -> isCommand

    func jobs(roots: Set<pid_t>, table: [pid_t: ProcInfo]) -> [AgentJob] {
        let kids = childMap(table)
        var byGroup: [pid_t: [pid_t]] = [:]
        for p in table.values { byGroup[p.pgid, default: []].append(p.pid) }

        for root in roots {
            for child in kids[root] ?? [] where !roots.contains(child) {
                guard let info = table[child] else { continue }
                let key = ProcKey(pid: child, start: info.start)
                if known[key] == nil { known[key] = info.pgid == child }
            }
        }
        var out: [AgentJob] = []
        for (key, isCommand) in known {
            var members: [pid_t] = [], seen: Set<pid_t> = []
            var stack: [pid_t] = []
            if table[key.pid]?.start == key.start { stack.append(key.pid) }
            // The group outlives its leader; a pgid can't be reused while members exist.
            stack += (byGroup[key.pid] ?? []).filter { (table[$0]?.start ?? 0) >= key.start }.reversed()
            while let p = stack.popLast() {
                guard !seen.contains(p), !roots.contains(p), let info = table[p], info.uid == getuid() else { continue }
                seen.insert(p)
                members.append(p)
                stack += (kids[p] ?? []).reversed()
            }
            if members.isEmpty { known[key] = nil; continue }
            out.append(AgentJob(key: key, pids: members, isCommand: isCommand))
        }
        return out
    }
}

// MARK: - Heat guard

/// Runs every 10 s while away mode is on and the lid is closed.
///
/// Agent jobs are measured for CPU (including finished child processes) and
/// GPU. Over the limit for long enough: moved to background priority
/// (efficiency cores). Bash jobs are paused (SIGSTOP) when that isn't enough:
/// GPU still over the limit (background priority doesn't slow the GPU), or the
/// Mac stays hot. Paused jobs resume (still throttled) once it has cooled down.
/// Limits tighten as the Mac heats up. Servers (MCP, LSP) and other heavy apps
/// the user owns are throttled at most, never paused. The agents themselves and
/// anything signed by Apple are never touched.
final class HeatGuard {
    struct Load { var cpu = 0.0, gpu = 0.0 }    // % of one core, % of the GPU

    var cpuLimit = 150.0
    var gpuLimit = 40.0
    private let stateFile = supportDir + "/touched-pids"
    private let tracker = JobTracker()

    private var lastJobCPU: [ProcKey: UInt64] = [:]
    private var lastCPU: [pid_t: UInt64] = [:], lastGPU: [pid_t: UInt64] = [:]
    private var lastSample = Date.distantPast
    private var overSince: [ProcKey: Date] = [:]
    private var throttledAt: [ProcKey: Date] = [:]
    private var pausedAt: [ProcKey: Date] = [:]
    private var pauseCount: [ProcKey: Int] = [:]
    private var names: [ProcKey: String] = [:]
    private var warmSince: Date?, hotSince: Date?, coolSince: Date?
    private var outsiderOK: [ProcKey: Bool] = [:]       // cached eligibility of non-agent processes
    private var touched: [pid_t: Int] = [:]              // pid -> start time
    private var savedTouched: [pid_t: Int] = [:]

    private(set) var throttled: Set<ProcKey> = []
    private(set) var paused: Set<ProcKey> = []

    var summary: String? {
        var parts: [String] = []
        if !paused.isEmpty { parts.append("paused " + paused.compactMap { names[$0] }.sorted().joined(separator: ", ")) }
        if !throttled.isEmpty { parts.append("throttled " + throttled.compactMap { names[$0] }.sorted().joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// (cpu %, gpu %, seconds over the limit before acting) for the current heat.
    private func limits(_ t: ProcessInfo.ThermalState) -> (cpu: Double, gpu: Double, sustain: Double) {
        switch t {
        case .nominal: return (cpuLimit, gpuLimit, 60)
        case .fair: return (cpuLimit / 2, gpuLimit / 2, 30)
        default: return (25, 10, 0)
        }
    }

    /// Returns descriptions of what changed this round.
    func sample(agentRoots: Set<pid_t>, thermal: ProcessInfo.ThermalState)
        -> (throttled: [String], paused: [String], resumed: [String]) {
        let table = processTable()
        guard !table.isEmpty else { return ([], [], []) }   // sysctl hiccup: try again next tick
        let now = Date()
        let dt = now.timeIntervalSince(lastSample)
        let valid = dt > 0 && dt < 120
        lastSample = now
        let gpuNow = gpuNanosByPid()
        var cpuNow: [pid_t: UInt64] = [:], jobCPUNow: [ProcKey: UInt64] = [:]

        func gpuLoad(_ pids: [pid_t]) -> Double {
            var g = 0.0
            for p in pids {
                if let n = gpuNow[p], let prev = lastGPU[p], n >= prev, valid { g += Double(n - prev) / 1e9 / dt * 100 }
            }
            return g
        }
        func busiest(_ pids: [pid_t]) -> String {
            func used(_ p: pid_t) -> UInt64 {
                guard let c = cpuNow[p], let prev = lastCPU[p], c >= prev else { return 0 }
                return c - prev
            }
            return pids.max { used($0) < used($1) }.flatMap { table[$0]?.comm } ?? "?"
        }
        func describe(_ name: String, _ pid: pid_t, _ l: Load) -> String {
            "\(name) (\(pid), \(Int(l.cpu))% CPU\(l.gpu >= 5 ? ", \(Int(l.gpu))% GPU" : ""))"
        }

        struct Item { let key: ProcKey; let pids: [pid_t]; let pausable: Bool; let load: Load }
        var items: [Item] = []

        // Agent jobs: cumulative CPU over live members, including reaped children.
        let jobs = tracker.jobs(roots: agentRoots, table: table)
        var agentPids = agentRoots
        for job in jobs {
            agentPids.formUnion(job.pids)
            var cum: UInt64 = 0
            for p in job.pids {
                cpuNow[p] = cpuNanos(p)
                cum += cpuNanos(p, children: true) ?? 0
            }
            jobCPUNow[job.key] = cum
            var l = Load(gpu: gpuLoad(job.pids))
            if let prev = lastJobCPU[job.key], cum >= prev, valid { l.cpu = Double(cum - prev) / 1e9 / dt * 100 }
            names[job.key] = describe(busiest(job.pids), job.key.pid, l)
            items.append(Item(key: job.key, pids: job.pids, pausable: job.isCommand, load: l))
        }

        // Other heavy processes the user owns (outside macOS, Apple apps and Claude).
        let me = getuid(), mine = getpid()
        for p in table.values where p.uid == me && p.pid != mine && !agentPids.contains(p.pid) {
            let c = cpuNanos(p.pid)
            cpuNow[p.pid] = c
            var l = Load(gpu: gpuLoad([p.pid]))
            if let c, let prev = lastCPU[p.pid], c >= prev, valid { l.cpu = Double(c - prev) / 1e9 / dt * 100 }
            let key = ProcKey(pid: p.pid, start: p.start)
            guard l.cpu >= 25 || l.gpu >= 10 || throttled.contains(key) else { continue }
            if outsiderOK[key] == nil {
                let path = processPath(p.pid)
                outsiderOK[key] = userAppRoots.contains(where: { path.hasPrefix($0) })
                    && !path.contains("/Claude.app/") && !path.contains("/Application Support/Claude/")
                    && !path.hasPrefix(homeDir + "/Library/") && !isAppleSigned(p.pid)
            }
            guard outsiderOK[key] == true else { continue }
            names[key] = describe(p.comm, p.pid, l)
            items.append(Item(key: key, pids: [p.pid], pausable: false, load: l))
        }
        lastCPU = cpuNow
        lastGPU = gpuNow
        lastJobCPU = jobCPUNow

        // Forget what no longer exists (a job is gone once it has no live members).
        let present = Set(items.map(\.key))
        let liveKeys = present.union(jobs.map(\.key))
        throttled = throttled.filter { liveKeys.contains($0) || table[$0.pid]?.start == $0.start }
        paused = paused.filter { liveKeys.contains($0) }
        for k in Array(overSince.keys) where !present.contains(k) { overSince[k] = nil }
        outsiderOK = outsiderOK.filter { table[$0.key.pid]?.start == $0.key.start }
        touched = touched.filter { table[$0.key]?.start == $0.value }

        let lim = limits(thermal)
        let warm = thermal.rawValue >= ProcessInfo.ThermalState.fair.rawValue
        let hot = thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        warmSince = warm ? (warmSince ?? now) : nil
        hotSince = hot ? (hotSince ?? now) : nil
        coolSince = warm ? nil : (coolSince ?? now)

        var newlyThrottled: [String] = [], newlyPaused: [String] = [], resumed: [String] = []
        for item in items {
            let name = names[item.key] ?? "?"
            if paused.contains(item.key) {
                // Cooled down long enough (longer after each re-pause): resume, still throttled.
                let wait = 180.0 * Double(1 << (min(pauseCount[item.key] ?? 1, 4) - 1))
                if let cs = coolSince, now.timeIntervalSince(cs) >= wait,
                   let pa = pausedAt[item.key], now.timeIntervalSince(pa) >= wait {
                    for p in item.pids.reversed() { if let s = table[p]?.start { resumeProcess(p, start: s) } }
                    paused.remove(item.key)
                    throttled.insert(item.key)
                    throttledAt[item.key] = now
                    resumed.append(name)
                }
                continue
            }
            let over = item.load.cpu >= lim.cpu || item.load.gpu >= lim.gpu
            overSince[item.key] = over ? (overSince[item.key] ?? now) : nil

            if throttled.contains(item.key) {
                // Members started since the last round get the same treatment.
                for p in item.pids where touched[p] == nil { throttle(p, table) }
            } else if let since = overSince[item.key], now.timeIntervalSince(since) >= lim.sustain {
                for p in item.pids { throttle(p, table) }
                throttled.insert(item.key)
                throttledAt[item.key] = now
                newlyThrottled.append(name)
                continue
            }

            // Escalate Bash jobs only: pause until it cools down or the lid opens.
            guard item.pausable, let at = throttledAt[item.key] else { continue }
            let gpuStill = item.load.gpu >= lim.gpu && now.timeIntervalSince(at) >= 60
            let warmLong = warmSince.map { now.timeIntervalSince($0) >= 300 } ?? false
            let hotLong = hotSince.map { now.timeIntervalSince($0) >= 120 } ?? false
            let busy = item.load.cpu >= 25 || item.load.gpu >= 10
            if gpuStill || (busy && (hotLong || (warmLong && item.load.cpu >= lim.cpu))) {
                for p in item.pids { pause(p, table) }   // parents first
                paused.insert(item.key)
                throttled.remove(item.key)
                pausedAt[item.key] = now
                pauseCount[item.key, default: 0] += 1
                newlyPaused.append(name)
            }
        }
        saveState()
        return (newlyThrottled, newlyPaused, resumed)
    }

    private func throttle(_ p: pid_t, _ table: [pid_t: ProcInfo]) {
        guard let s = table[p]?.start else { return }
        touched[p] = s
        setBackground(p, start: s, true)
    }

    private func pause(_ p: pid_t, _ table: [pid_t: ProcInfo]) {
        guard let s = table[p]?.start else { return }
        touched[p] = s
        pauseProcess(p, start: s)
    }

    private func saveState() {
        guard touched != savedTouched else { return }
        savedTouched = touched
        if touched.isEmpty {
            try? FileManager.default.removeItem(atPath: stateFile)
        } else {
            try? touched.map { "\($0.key) \($0.value)" }.joined(separator: "\n")
                .write(toFile: stateFile, atomically: true, encoding: .utf8)
        }
    }

    /// Undo everything (lid opened, or quitting). Also clears background
    /// priority that members inherited from a throttled parent since the last tick.
    func release(agentRoots: Set<pid_t>) {
        let table = processTable()
        var all = touched
        for job in tracker.jobs(roots: agentRoots, table: table)
            where throttled.contains(job.key) || paused.contains(job.key) {
            for p in job.pids { if let s = table[p]?.start { all[p] = s } }
        }
        HeatGuard.resume(all)
        touched.removeAll()
        throttled.removeAll()
        paused.removeAll()
        overSince.removeAll()
        throttledAt.removeAll()
        pausedAt.removeAll()
        pauseCount.removeAll()
        lastJobCPU.removeAll()
        lastCPU.removeAll()
        lastGPU.removeAll()
        warmSince = nil
        hotSince = nil
        coolSince = nil
        lastSample = .distantPast
        saveState()
    }

    /// Whether anything is currently throttled or paused.
    var holding: Bool { !touched.isEmpty || !paused.isEmpty || !throttled.isEmpty }

    /// After a crash: resume whatever a previous run paused or throttled.
    static func recover() {
        let file = supportDir + "/touched-pids"
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
        var pids: [pid_t: Int] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.count == 2, let p = pid_t(f[0]), let s = Int(f[1]) { pids[p] = s }
        }
        resume(pids)
        try? FileManager.default.removeItem(atPath: file)
    }

    /// Only processes whose pid AND start time still match: never a reused pid.
    private static func resume(_ pids: [pid_t: Int]) {
        for (p, start) in pids {
            resumeProcess(p, start: start)
            setBackground(p, start: start, false)
        }
    }
}

/// Whether anything the agents started (Bash jobs, not long-lived servers) or a
/// grok agent itself used real CPU since the last call. For idle auto-off.
final class ActivityMeter {
    private let tracker = JobTracker()
    private var last: [ProcKey: UInt64] = [:]

    func active(claudeRoots: Set<pid_t>, grokRoots: Set<pid_t>, minNanos: UInt64) -> Bool {
        let table = processTable()
        guard !table.isEmpty else { return true }
        var now: [ProcKey: UInt64] = [:], used: UInt64 = 0
        for job in tracker.jobs(roots: claudeRoots.union(grokRoots), table: table) where job.isCommand {
            now[job.key] = job.pids.reduce(0) { $0 + (cpuNanos($1, children: true) ?? 0) }
        }
        // grok has no status file: its own CPU is the only sign it's thinking or editing.
        for g in grokRoots { if let i = table[g] { now[ProcKey(pid: g, start: i.start)] = cpuNanos(g) ?? 0 } }
        for (k, v) in now { if let prev = last[k], v > prev { used += v - prev } }
        let first = last.isEmpty && !now.isEmpty
        last = now
        return first || used > minNanos
    }
}
