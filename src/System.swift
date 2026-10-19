// System monitors: power/sleep control, lid, battery, thermal, network.
// Everything here is event-driven (IOKit notifications, NWPathMonitor,
// NotificationCenter) so nothing runs while nothing changes.

import AppKit
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Network

// MARK: - Shell

@discardableResult
func sh(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// MARK: - Power

let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

/// Open lid: an IOPM assertion that blocks idle *system* sleep but still lets the
/// display sleep and the screen lock. Closed lid: `pmset disablesleep`, which
/// needs root, so it goes through a sudoers rule limited to exactly those two
/// commands (scripts/setup-sudo.sh). `sudo -n` never prompts.
final class Power {
    private var assertion: IOPMAssertionID = 0

    func holdAssertion(_ on: Bool) {
        if on, assertion == 0 {
            IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Agent Away: agents are working" as CFString,
                                        &assertion)
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    /// Returns true when the system setting now matches `on`. Turning it off
    /// always runs pmset, even if it already reads off: powerd applies changes
    /// asynchronously, so a stale read must never skip the reset.
    @discardableResult
    func setLidClosedAwake(_ on: Bool) -> Bool {
        if on, Power.sleepDisabled() { return true }
        guard sh("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]).status == 0 else { return false }
        // powerd applies the setting asynchronously; give it up to 2 s to show up.
        for _ in 0..<20 {
            if Power.sleepDisabled() == on { return true }
            usleep(100_000)
        }
        return false
    }

    /// The kernel's SleepDisabled flag on IOPMrootDomain (readable without root).
    static func sleepDisabled() -> Bool {
        let v = IORegistryEntryCreateCFProperty(rootDomain, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)
        return (v?.takeRetainedValue() as? Bool) ?? false
    }

    /// Whether scripts/setup-sudo.sh has been run. A plain file check: no sudo
    /// call (which would log an auth failure on every menu open).
    static func sudoRuleInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/etc/sudoers.d/agent-away")
    }

    /// Puts a closed-lid Mac to sleep after lid-closed awake is switched off,
    /// since closing the lid already happened and won't trigger sleep again.
    /// Skipped when an external display is in use (someone is at a desk).
    static func sleepIfLidClosed(_ lid: LidMonitor) {
        guard lid.isClosed else { return }
        var displays: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displays)
        guard displays == 0 else { return }
        let pm = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard pm != 0 else { return }
        IOPMSleepSystem(pm)
        IOServiceClose(pm)
    }
}

// MARK: - Lid

private let kClamshellStateChange: UInt32 = 0xE003_4100 // kIOPMMessageClamshellStateChange

final class LidMonitor {
    private let root = rootDomain
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var lastClosed = false
    var onChange: ((Bool) -> Void)?

    init() {
        lastClosed = isClosed
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { ref, _, type, arg in
            guard let ref, type == kClamshellStateChange else { return }
            let closed = (Int(bitPattern: arg) & 1) != 0 // kClamshellStateBit
            let me = Unmanaged<LidMonitor>.fromOpaque(ref).takeUnretainedValue()
            // The same message also comes for charger and display changes: act only on a real lid change.
            guard closed != me.lastClosed else { return }
            me.lastClosed = closed
            me.onChange?(closed)
        }, me, &notifier)
    }

    var isClosed: Bool {
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (v?.takeRetainedValue() as? Bool) ?? false
    }
}

// MARK: - Battery

/// Battery level; change notifications only while started (keep-awake on).
final class BatteryMonitor {
    private(set) var percent = 100
    private(set) var onAC = true
    private var source: CFRunLoopSource?
    var onChange: (() -> Void)?

    init() { read() }

    func start() {
        guard source == nil else { return }
        read()
        let me = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ref in
            guard let ref else { return }
            let m = Unmanaged<BatteryMonitor>.fromOpaque(ref).takeUnretainedValue()
            m.read()
            m.onChange?()
        }, me)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    func read() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 100
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            percent = max > 0 ? cur * 100 / max : cur
            onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
    }
}

// MARK: - Network

final class NetMonitor {
    private let monitor = NWPathMonitor()
    private(set) var online = true
    private(set) var lastChange = Date.distantPast
    private var lastSignature = ""
    var onChange: (() -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let sig = "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            guard sig != self.lastSignature else { return }
            let first = self.lastSignature.isEmpty
            self.lastSignature = sig
            self.online = path.status == .satisfied
            if !first { self.lastChange = Date() }
            self.onChange?()
        }
        monitor.start(queue: .main)
    }

    deinit { monitor.cancel() }
}

// MARK: - Thermal

func thermalName(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: return "normal"
    case .fair: return "warm"
    case .serious: return "hot"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}
