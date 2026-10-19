// Agent Away: a menu-bar switch for leaving Claude Code agents working
// while you're away (lid closed, laptop in a bag, flaky Wi-Fi).
//
// Idle cost is ~0: everything is driven by OS notifications. Timers exist
// only while a mode is on (60 s watch) or the lid is closed (10 s heat guard).

import AppKit

let supportDir = homeDir + "/Library/Application Support/AgentAway"
let runDir = supportDir + "/run"
let sleepMarker = supportDir + "/sleep-disabled-by-agent-away"

// MARK: - Flag files shared with hooks/away-hook.sh

enum Flags {
    static let fm = FileManager.default
    static func path(_ n: String) -> String { runDir + "/" + n }
    static func set(_ n: String, _ text: String = "") {
        try? text.write(toFile: path(n), atomically: true, encoding: .utf8)
    }
    static func clear(_ n: String) { try? fm.removeItem(atPath: path(n)) }
    static func clearDir(_ n: String) {
        try? fm.removeItem(atPath: path(n))
        try? fm.createDirectory(atPath: path(n), withIntermediateDirectories: true)
    }
    static func reset() {
        try? fm.removeItem(atPath: runDir)
        for d in ["s", "seen", "wake", "pending"] { clearDir(d) }
        set("pid", "\(getpid())\n")   // hooks ignore flags unless this app is running
    }
    /// Ask phase per session id: "asked" | "waiting" | "answered", and since when.
    static func askPhases() -> [String: (phase: String, since: Date)] {
        var out: [String: (phase: String, since: Date)] = [:]
        for f in (try? fm.contentsOfDirectory(atPath: path("s"))) ?? [] {
            let t = ((try? String(contentsOfFile: path("s/" + f), encoding: .utf8)) ?? "").split(separator: " ")
            let since = Date(timeIntervalSince1970: Double(t.count > 1 ? t[1].trimmingCharacters(in: .whitespacesAndNewlines) : "0") ?? 0)
            out[f] = (t.first.map(String.init) ?? "", since)
        }
        return out
    }
    /// A wake-failure hook is waiting for the network to come back (written by the hook).
    static func pendingWake() -> Bool {
        let dir = path("pending")
        for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            if let m = (try? fm.attributesOfItem(atPath: dir + "/" + f))?[.modificationDate] as? Date,
               Date().timeIntervalSince(m) < 8000 { return true }
        }
        return false
    }
    static var now: String { String(Int(Date().timeIntervalSince1970)) }
}

// MARK: - Preferences

enum Pref: String, CaseIterable {
    case cpuLimit, gpuLimit, idleOffMinutes, batteryFloor, askTimeoutMinutes, stallMinutes

    var title: String {
        switch self {
        case .cpuLimit: return "Heat guard CPU limit"
        case .gpuLimit: return "Heat guard GPU limit"
        case .idleOffMinutes: return "Auto-off when all idle"
        case .batteryFloor: return "Allow sleep below battery"
        case .askTimeoutMinutes: return "Unanswered questions: decide after"
        case .stallMinutes: return "Nudge a session stuck on the API for"
        }
    }
    var choices: [Int] {
        switch self {
        case .cpuLimit: return [100, 150, 200, 300]
        case .gpuLimit: return [20, 40, 60]
        case .idleOffMinutes: return [10, 15, 30, 60, 0]
        case .batteryFloor: return [10, 20, 30]
        case .askTimeoutMinutes: return [5, 10, 20, 30]
        case .stallMinutes: return [15, 20, 30, 60]
        }
    }
    var fallback: Int {
        switch self {
        case .cpuLimit: return 150
        case .gpuLimit: return 40
        case .idleOffMinutes: return 15
        case .batteryFloor: return 20
        case .askTimeoutMinutes: return 10
        case .stallMinutes: return 20
        }
    }
    func label(_ v: Int) -> String {
        switch self {
        case .cpuLimit: return "\(v)% (\(Double(v) / 100) cores)"
        case .gpuLimit: return "\(v)% of the GPU"
        case .batteryFloor: return "\(v)%"
        case .idleOffMinutes: return v == 0 ? "Never" : "\(v) min"
        default: return "\(v) min"
        }
    }
    var value: Int {
        get { UserDefaults.standard.object(forKey: rawValue) as? Int ?? fallback }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: rawValue) }
    }
}

// MARK: - App

final class AgentAway: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let power = Power()
    let lid = LidMonitor()
    let battery = BatteryMonitor()
    var net: NetMonitor?            // only while keep-awake is on
    let heat = HeatGuard()
    let activity = ActivityMeter()
    var agents: AgentWatcher!
    var nudger: Nudger!
    var item: NSStatusItem?
    var lastSymbol = ""

    var away = false        // keep awake, lid closed OK
    var askFirst = false    // ask first, then don't
    var lidAwake = false    // SleepDisabled is on while away
    var lidPreexisting = false  // it was already on (user's own setting): never undo it
    var idleSince: Date?
    var heatTimer: DispatchSourceTimer?
    var watchTimer: DispatchSourceTimer?
    var restoreTimer: DispatchSourceTimer?
    var hotSince: Date?
    var log: [String] = []
    var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        // One instance only. A second launch hands its flags (--away, --ask-first) to the running one.
        let lock = open(supportDir + "/lock", O_CREAT | O_RDWR, 0o600)
        if lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0 {
            let args = CommandLine.arguments.dropFirst().joined(separator: " ")
            DistributedNotificationCenter.default().postNotificationName(
                .init("local.agentaway.cmd"), object: args, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("local.agentaway.cmd"), object: nil, queue: .main) { [weak self] n in
            let args = (n.object as? String ?? "").split(separator: " ")
            if args.contains("--away") { self?.setAway(true, why: "Keep awake on (command line)") }
            if args.contains("--ask-first") { self?.setAskFirst(true) }
            if args.contains("--off") { self?.revert("Turned off (command line)") }
        }
        Flags.reset()
        // Crash recovery: resume anything the heat guard paused or throttled,
        // and undo lid-closed awake if we left it on.
        HeatGuard.recover()
        restoreLidSleep()

        agents = AgentWatcher()
        nudger = Nudger(note: { [weak self] in self?.note($0) })
        agents.onChange = { [weak self] in self?.agentsChanged() }
        lid.onChange = { [weak self] closed in self?.lidChanged(closed) }
        battery.onChange = { [weak self] in self?.checkBattery() }
        _ = ProcessInfo.processInfo.thermalState // read once so change notifications flow
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.thermalChanged() }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { NSApp.terminate(nil) }
            s.resume()
            signalSources.append(s)
        }
        agentsChanged()
        let args = CommandLine.arguments
        if args.contains("--away") { setAway(true, why: "Keep awake on (launch flag)") }
        if args.contains("--ask-first") { setAskFirst(true) }
    }

    func applicationWillTerminate(_ note: Notification) {
        setAway(false, why: nil)
        setAskFirst(false)
        heat.release(agentRoots: agentRoots())   // never leave anything paused behind
    }

    // MARK: Modes

    func setAway(_ on: Bool, why: String?) {
        if on == away { return }
        away = on
        if on {
            power.holdAssertion(true)
            Flags.set("away")
            battery.start()
            net = NetMonitor()
            net?.onChange = { [weak self] in self?.netChanged() }
            if !Power.sudoRuleInstalled() {
                note("Lid-closed mode needs the one-time setup (see menu)")
            } else if Power.sleepDisabled() {
                lidPreexisting = true   // already on by someone else: use it, never undo it
                lidAwake = true
            } else {
                FileManager.default.createFile(atPath: sleepMarker, contents: nil)
                lidAwake = power.setLidClosedAwake(true)
                if !lidAwake { note("Couldn't turn on lid-closed awake (pmset failed)") }
            }
            if lid.isClosed { lidChanged(true) }
            // Act at once on conditions that already hold.
            checkBattery()
            thermalChanged()
        } else {
            let wasPreexisting = lidPreexisting
            power.holdAssertion(false)
            restoreLidSleep()
            battery.stop()
            net = nil
            heatTimer?.cancel()
            heatTimer = nil
            hotSince = nil
            // With the lid closed, paused jobs stay paused until it opens (see lidChanged):
            // releasing them now would heat a Mac that's about to sleep in a bag.
            if !lid.isClosed { releaseHeat() }
            Flags.clear("away")
            Flags.clear("lid")
            Flags.clear("hot")
            Flags.clearDir("wake")
            if !wasPreexisting { Power.sleepIfLidClosed(lid) }
        }
        if let why { note(why) }
        idleSince = nil
        updateTimers()
        updateIcon()
    }

    /// Turns lid-closed awake back off if we turned it on. Keeps retrying every
    /// minute until pmset succeeds; the marker file survives crashes and reboots.
    func restoreLidSleep() {
        lidAwake = false
        if lidPreexisting { lidPreexisting = false; return }
        guard FileManager.default.fileExists(atPath: sleepMarker) else { return }
        if power.setLidClosedAwake(false) {
            try? FileManager.default.removeItem(atPath: sleepMarker)
            restoreTimer?.cancel()
            restoreTimer = nil
        } else if restoreTimer == nil {
            note("Couldn't restore normal sleep yet: retrying every minute")
            restoreTimer = timer(every: 60, leeway: 10) { [weak self] in
                guard let self, !self.away else { return }
                self.restoreLidSleep()
            }
        }
    }

    func setAskFirst(_ on: Bool) {
        if on == askFirst { return }
        askFirst = on
        if on {
            Flags.set("askfirst", "\(Flags.now) \(Pref.askTimeoutMinutes.value * 60)\n")
            let idle = agents.sessions.values.filter { !$0.busy }.count
            note("Ask first: busy sessions ask now" + (idle > 0 ? "; idle ones on your next message" : ""))
        } else {
            Flags.clear("askfirst")
            Flags.clearDir("s")
        }
        idleSince = nil
        updateTimers()
        updateIcon()
    }

    /// Back to the Mac's normal behaviour.
    func revert(_ why: String) {
        guard away || askFirst else { return }
        setAway(false, why: nil)
        setAskFirst(false)
        note(why)
    }

    // MARK: Events

    func agentsChanged() {
        if !agents.anyRunning { revert("Claude quit: back to normal") }
        updateIcon()
    }

    /// The icon exists only while an agent runs or a mode is on. Adding and
    /// removing it (instead of toggling isVisible) leaves the user's own
    /// menu-bar visibility setting for this app alone.
    func showItem(_ show: Bool) {
        if show, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.delegate = self
            i.menu = menu
            item = i
            lastSymbol = ""
        } else if !show, let i = item {
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    func lidChanged(_ closed: Bool) {
        if !closed {
            // Whatever the mode, opening the lid undoes every throttle and pause.
            releaseHeat()
            heatTimer?.cancel()
            heatTimer = nil
            hotSince = nil
            Flags.clear("lid")
            if away { note("Lid opened") }
            updateIcon()
            return
        }
        guard away else { return }
        Flags.set("lid", Flags.now)
        note(lidAwake ? "Lid closed: staying awake" : "Lid closed (no setup: the Mac will sleep)")
        startHeatGuard()
        checkBattery()
        thermalChanged()
        updateIcon()
    }

    func checkBattery() {
        guard away, !battery.onAC, battery.percent <= Pref.batteryFloor.value else { return }
        setAway(false, why: "Battery at \(battery.percent)%: sleep allowed again")
    }

    func thermalChanged() {
        if away, lid.isClosed, ProcessInfo.processInfo.thermalState == .critical {
            setAway(false, why: "Critical heat with lid closed: letting the Mac sleep")
        }
        updateIcon()
    }

    func netChanged() {
        note(net?.online ?? true ? "Network back" : "Network lost")
        updateIcon()
    }

    // MARK: Timers (only while a mode is on)

    func updateTimers() {
        if (away || askFirst), watchTimer == nil {
            watchTimer = timer(every: 60, leeway: 15) { [weak self] in self?.watch() }
        } else if !(away || askFirst), let t = watchTimer {
            t.cancel()
            watchTimer = nil
        }
    }

    func timer(every s: Double, leeway: Int, _ fn: @escaping () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + s, repeating: s, leeway: .seconds(leeway))
        t.setEventHandler(handler: fn)
        t.resume()
        return t
    }

    func startHeatGuard() {
        guard heatTimer == nil else { return }
        heat.cpuLimit = Double(Pref.cpuLimit.value)
        heat.gpuLimit = Double(Pref.gpuLimit.value)
        _ = heat.sample(agentRoots: agentRoots(), thermal: .nominal) // baseline
        heatTimer = timer(every: 10, leeway: 3) { [weak self] in self?.heatTick() }
    }

    func releaseHeat() {
        heat.release(agentRoots: agentRoots())
        Flags.clear("hot")
    }

    func agentRoots() -> Set<pid_t> { Set(agents.sessions.keys).union(agents.grokPids) }

    func heatTick() {
        let t = ProcessInfo.processInfo.thermalState
        if t == .critical {
            setAway(false, why: "Critical heat with lid closed: letting the Mac sleep")
            return
        }
        let r = heat.sample(agentRoots: agentRoots(), thermal: t)
        var what: [String] = []
        if !r.paused.isEmpty { what.append("paused until it cools down or the lid opens: " + r.paused.joined(separator: ", ")) }
        if !r.throttled.isEmpty { what.append("slowed to efficiency cores: " + r.throttled.joined(separator: ", ")) }
        if !r.resumed.isEmpty { what.append("cooled down, resumed slowly: " + r.resumed.joined(separator: ", ")) }
        if !what.isEmpty {
            let text = what.joined(separator: "; ")
            note("Heat guard " + text)
            Flags.set("hot", "\(Flags.now)\n[Agent Away] Heat guard (lid closed, laptop likely in a bag, Mac is "
                + "\(thermalName(t))): \(text). Do not start more heavy CPU or GPU work until the user is back; "
                + "do the lighter parts of the task and list the heavy steps in your summary.")
        } else if heat.summary == nil {
            Flags.clear("hot")
        }
        // Still hot five minutes on despite throttling/pausing: give up and let it sleep.
        if t.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            hotSince = hotSince ?? Date()
            if Date().timeIntervalSince(hotSince!) > 300 {
                setAway(false, why: "Still hot after 5 min with lid closed: letting the Mac sleep")
                return
            }
        } else {
            hotSince = nil
        }
        updateIcon()
    }

    func watch() {
        // Auto-off once nothing has been working for a while. Not while a session
        // waits for the network to come back or for answers to its questions.
        let limit = Pref.idleOffMinutes.value
        let waitingAnswers = Flags.askPhases().contains {
            $0.value.phase == "waiting" && Date().timeIntervalSince($0.value.since) < Double(Pref.askTimeoutMinutes.value * 60 + 900)
        }
        if limit > 0, !agents.anyBusy, !Flags.pendingWake(), !waitingAnswers,
           !activity.active(claudeRoots: Set(agents.sessions.keys), grokRoots: agents.grokPids, minNanos: 3_000_000_000) {
            idleSince = idleSince ?? Date()
            if Date().timeIntervalSince(idleSince!) >= Double(limit * 60) {
                revert("All agents idle for \(limit) min: back to normal")
                return
            }
        } else {
            idleSince = nil
        }
        if away { nudger.checkStalls(Array(agents.sessions.values), quietMinutes: Pref.stallMinutes.value) }
    }

    // MARK: UI

    func note(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        log.insert("\(f.string(from: Date()))  \(s)", at: 0)
        if log.count > 8 { log.removeLast() }
    }

    func updateIcon() {
        showItem(agents.anyRunning || away || askFirst)
        guard let item else { return }
        let symbol: String
        if heat.summary != nil { symbol = "flame.fill" }
        else if away && !(net?.online ?? true) { symbol = "wifi.exclamationmark" }
        else if away { symbol = "sun.max.fill" }
        else if askFirst { symbol = "questionmark.bubble" }
        else { symbol = "moon.zzz" }
        guard symbol != lastSymbol else { return }
        lastSymbol = symbol
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Agent Away")
        img?.isTemplate = true
        item.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func action(_ s: String, _ sel: Selector, on: Bool? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: s, action: sel, keyEquivalent: "")
            i.target = self
            if let on { i.state = on ? .on : .off }
            menu.addItem(i)
            return i
        }

        let s = agents.sessions.values
        let busy = s.filter(\.busy).count
        var who = "\(s.count) Claude Code session\(s.count == 1 ? "" : "s")"
        if !s.isEmpty { who += ": \(busy) working" }
        if !agents.grokPids.isEmpty { who += ", \(agents.grokPids.count) grok" }
        if agents.desktopRunning, s.isEmpty { who = "Claude app open, no Code sessions" }
        info(away ? (lidAwake ? "Staying awake (lid closed OK)" : "Staying awake (lid open only)") : "Mac sleeps normally")
        info(who)
        battery.read()
        let batt = battery.onAC ? "on power" : "battery \(battery.percent)%"
        let netText = net.map { $0.online ? " · online" : " · offline" } ?? ""
        info("Lid \(lid.isClosed ? "closed" : "open") · \(batt) · \(thermalName(ProcessInfo.processInfo.thermalState))\(netText)")
        menu.addItem(.separator())

        _ = action("Keep awake, even with lid closed", #selector(toggleAway), on: away)
        _ = action("Ask first, then don't", #selector(toggleAskFirst), on: askFirst)
        if askFirst {
            let phases = Flags.askPhases()
            let waiting = phases.values.filter { $0.phase == "waiting" }.count
            let answered = phases.values.filter { $0.phase == "answered" }.count
            info("   \(waiting) waiting for your answers · \(answered) deciding on their own")
        }
        if !Power.sudoRuleInstalled() {
            _ = action("⚠︎ Lid-closed mode needs one-time setup… (copies command)", #selector(copySetup))
        }
        if let h = heat.summary { info("Heat guard: \(h)") }
        menu.addItem(.separator())

        _ = action("Copy \"ask me first\" prompt (for Chat)", #selector(copyPrompt))
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for p in Pref.allCases {
            let head = NSMenuItem(title: p.title, action: nil, keyEquivalent: "")
            let choices = NSMenu()
            for v in p.choices {
                let i = NSMenuItem(title: p.label(v), action: #selector(setPref(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = [p.rawValue, v] as [Any]
                i.state = p.value == v ? .on : .off
                choices.addItem(i)
            }
            head.submenu = choices
            sub.addItem(head)
        }
        settings.submenu = sub
        menu.addItem(settings)
        if !log.isEmpty {
            let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            let r = NSMenu()
            for l in log { let i = NSMenuItem(title: l, action: nil, keyEquivalent: ""); i.isEnabled = false; r.addItem(i) }
            recent.submenu = r
            menu.addItem(recent)
        }
        menu.addItem(.separator())
        _ = action("Quit Agent Away", #selector(quit))
    }

    @objc func toggleAway() { setAway(!away, why: away ? "Keep awake off" : "Keep awake on") }
    @objc func toggleAskFirst() { setAskFirst(!askFirst) }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func setPref(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [Any], let k = a[0] as? String, let v = a[1] as? Int,
              let p = Pref(rawValue: k) else { return }
        p.value = v
        heat.cpuLimit = Double(Pref.cpuLimit.value)
        heat.gpuLimit = Double(Pref.gpuLimit.value)
        if askFirst { Flags.set("askfirst", "\(Flags.now) \(Pref.askTimeoutMinutes.value * 60)\n") }
    }

    @objc func copySetup() {
        let src = (try? String(contentsOfFile: supportDir + "/source-dir", encoding: .utf8)) ?? "agent-away"
        copy("sh \"\(src.trimmingCharacters(in: .whitespacesAndNewlines))/scripts/setup-sudo.sh\"")
        note("Setup command copied: paste it in Terminal")
    }

    @objc func copyPrompt() {
        copy("""
        I'm about to step away from the computer for a while. Before you continue, think ahead through the \
        rest of this task and ask me, in one message, every question or decision you'll need from me \
        (numbered, each with your recommended default). After I answer, don't ask me anything else: \
        when something comes up, choose what you think is best, note the assumption, and keep going.
        """)
        note("Prompt copied")
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

let app = NSApplication.shared
let delegate = AgentAway()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
