// PointerAccel: holds mouse acceleration off through live HID properties.
// On macOS 14 and later the linear-scaling flag, read back through a passive
// HID client (the public simple client cannot see it), turns the tracking
// speed into a constant multiplier instead of an acceleration curve. Raw
// mode writes -1 to skip scaling entirely on macOS 13, or when the flag
// cannot be read. These properties do not survive HID restarts, so wake and
// a slow timer reassert them. Only mouse services and the mouse
// acceleration key are touched.
//
// Main-thread only, like the rest of the process. deinit does not run for a
// global on process exit, so the owner must call restore() from its own exit
// paths, the same way CataclysmApp.swift re-associates the cursor. Those
// paths must reach it on the main thread: signal handlers via a main-queue
// dispatch source (as CataclysmApp.swift already does), and atexit only from
// a main-thread exit(), or a reassert tick still in flight can re-take the
// property after restore() has released it.

import Cocoa

final class PointerAccel {
    private static let disabled: Int32 = -1
    private static let linearKey = "HIDUseLinearScalingMouseAcceleration" as CFString
    private static let linearStoreKey = "recovery.originalLinearScaling"
    // The multiplier last written, persisted so a relaunch after a kill can
    // tell its predecessor's leftover from a tracking speed the user chose.
    private static let heldStoreKey = "recovery.heldMouseAcceleration"
    // 3.0 in 16.16 fixed point, matching the macOS default tracking speed.
    // Used when no real tracking speed has been observed or persisted and
    // com.apple.mouse.scaling cannot be read either.
    private static let fallback: Int32 = 196_608
    // Distinct prefix so settings-reset code can recognize and spare it; the
    // stored value may be the only copy of the user's real acceleration.
    private static let storeKey = "recovery.originalMouseAcceleration"
    private static let reassertInterval: TimeInterval = 5
    // Consecutive ticks with the property unreadable-because-absent before
    // the condition is surfaced as unhealthy: long enough to ride out the
    // normal post-wake blip, short enough that a dead HID connection does
    // not present as a working feature for long.
    private static let unavailableTicksTolerated = 3

    private enum Mode {
        case linear
        case raw
    }

    private struct MouseService {
        let service: IOHIDServiceClient
        let linearScaling: CFTypeRef?

        var linearValue: Int? { (linearScaling as? NSNumber)?.intValue }
    }

    private enum Reading {
        case unavailable      // copy returned nil: HID subsystem down or coming back
        case unreadable       // present but not a number this code can use
        case value(Int32)
    }

    private let client: IOHIDEventSystemClient
    // The flag's client. Nil when the SPI refuses, which reads as no linear
    // support, so the class falls back to raw mode rather than failing.
    private let flagClient: IOHIDEventSystemClient?
    private var mode = Mode.raw
    private var speed: Int32
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    // The value restored on disable/quit. Never -1: adopting -1 as the
    // original would destroy the real value permanently. nil means the user's
    // own preference already was acceleration off, so restore leaves raw
    // movement in place.
    private var original: Int32?
    // A successful acceleration write claims the property for restoration.
    // Rewriting an orphaned raw or linear value claims it too, so quitting
    // can recover a previous holder's unclean exit.
    private var holding = false
    // A successful write of the flag claims it the same way: an enable whose
    // number write failed has still left the flag up, and restore must take
    // it down or the user's tracking speed runs as a multiplier.
    private var flagHeld = false
    // Seeded from the recovery copy so a value a killed predecessor left
    // behind is recognised as ours on relaunch.
    private var heldSpeed: Int32
    private var unavailableTicks = 0
    var onLinearAvailabilityChange: ((Bool) -> Void)?

    // Called with false on the transition into a failing HID write and true
    // when a later write succeeds again. A false from SetProperty is a broken
    // feature indistinguishable by feel from the curve merely being
    // different, so the caller must show it somewhere, and clear it again.
    var onWriteHealthChange: ((_ healthy: Bool) -> Void)?
    private(set) var writeFailing = false

    init(speedThousandths: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        speed = Self.fixedSpeed(thousandths: speedThousandths)
        client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        flagClient = IOHIDEventSystemClientCreateWithType(
            kCFAllocatorDefault, .passive, nil)
        let defaults = UserDefaults.standard
        // Recovery copies with no restore since mean a predecessor was
        // killed holding: claim what it held, so even a raw-mode instance
        // (no mouse attached now) whose own write fails still puts the
        // number and the flag back on quit.
        if let stored = (defaults.object(forKey: Self.heldStoreKey) as? Int)
            .flatMap(Int32.init(exactly:)) {
            heldSpeed = stored
            holding = true
        } else {
            heldSpeed = Self.disabled
        }
        flagHeld = defaults.object(forKey: Self.linearStoreKey) != nil
        if let stored = defaults.object(forKey: Self.storeKey) as? Int,
           let value = Int32(exactly: stored), value != Self.disabled {
            original = value
        } else {
            if defaults.object(forKey: Self.storeKey) != nil {
                // A stored -1 can only have come from a buggy build; leaving
                // it would keep feeding the one value the guard blocks.
                defaults.removeObject(forKey: Self.storeKey)
            }
            original = Self.bootstrapOriginal()
        }
        confirmLinearSupport(mouseServices())
    }

    var linearAvailable: Bool { mode == .linear }

    // A tracking speed the window server wrote since the last tick is
    // adopted before the rewrite, as a tick would, or the user's latest
    // choice would be lost under the new multiplier.
    func setSpeed(thousandths: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        speed = Self.fixedSpeed(thousandths: thousandths)
        guard holding, mode == .linear else { return }
        let mice = mouseServices()
        if case .value(let current) = read() { adopt(current, mice: mice) }
        writeHeld(mice)
    }

    // A released instance (disable() or restore() ran) whose write of the
    // original failed, so the properties stay held with nobody
    // reasserting it. writeFailing never covers this: exit-path writes are
    // deliberately unreported, so the owner has to read it here or a panel
    // reopen would show the feature as restored.
    var restoreFailed: Bool { (holding || flagHeld) && timer == nil }

    // IOHIDEventSystemClientCreateSimpleClient can return null in degraded
    // contexts despite its nonnull annotation, and a null client fails every
    // call silently. The only reliable probe is whether a property read
    // round-trips at all; callers gate their "acceleration control is on"
    // report on this rather than on enable() having been called.
    var clientResponsive: Bool {
        if case .unavailable = read() { return false }
        return true
    }

    // Overwrite the property and hold it there until disable(). Idempotent.
    func enable() {
        dispatchPrecondition(condition: .onQueue(.main))
        let mice = mouseServices()
        confirmLinearSupport(mice)
        switch read() {
        case .unavailable:
            // Nothing to capture and a write would likely fail too; the
            // timer's first tick performs the initial adopt-and-write.
            break
        case .unreadable:
            writeHeld(mice)
        case .value(let current):
            adopt(current, mice: mice)
            writeHeld(mice)
        }
        if timer == nil {
            // On RunLoop.main in common modes, so reassertion keeps running
            // while a menu or window has the run loop in event tracking.
            let t = Timer(timeInterval: Self.reassertInterval, repeats: true) {
                [weak self] _ in self?.reassert()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.reassert() }
        }
    }

    // Stop holding the property and put the original back. Returns
    // restore()'s verdict: false means an original could not be restored,
    // and the owner must keep this instance for a later retry rather than
    // drop it.
    func disable() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return teardown()
    }

    // Safe on any exit path: the acceleration number is written back only
    // while it still reads as ours (-1 in raw mode, the held multiplier in
    // linear mode) or is gone with the HID subsystem down; a foreign value
    // or junk belongs to another writer. The linear flag is ours whoever
    // owns the number, so it goes back in every case once the claim on the
    // number is released. Exit paths do not report health: a callback could
    // run against a half-deallocated owner or latch a failure no later write
    // can clear. Returns false while either claim stands: the number still
    // reads as ours and the write of the original failed, or the flag could
    // not be taken down. The stored originals survive for a later restore.
    @discardableResult
    func restore() -> Bool {
        guard holding || flagHeld else { return true }
        let mice = mouseServices()
        if holding {
            switch read() {
            case .value(let current) where !accelerationIsOurs(current):
                holding = false
            case .unreadable:
                holding = false
            case .value(Self.disabled) where original == nil:
                // A non-positive tracking preference means the user already
                // wanted raw movement, and -1 is what is there: leaving it
                // is the restore.
                holding = false
            case .unavailable, .value:
                // With no original, a multiplier still standing (linear
                // mode, or a predecessor's leftover) goes back to raw.
                if write(original ?? Self.disabled) { holding = false }
            }
            if !holding { UserDefaults.standard.removeObject(forKey: Self.heldStoreKey) }
        }
        // A failed number write keeps the flag too: the multiplier only
        // means what it does while the flag is up, and the next restore
        // retries both.
        guard !holding else { return false }
        if flagHeld { restoreLinearFlag(mice) }
        return !flagHeld
    }

    // The flag goes back after the number so the gap between the writes
    // runs the user's tracking speed as a plain multiplier, never the
    // multiplier with acceleration back on. A failed write keeps the claim
    // and the recovery copy for a later retry; junk in the copy is dropped
    // rather than written, and a missing copy (never recorded) falls back
    // to 0, the value IOHIDSystem seeds.
    private func restoreLinearFlag(_ mice: [MouseService]) {
        let defaults = UserDefaults.standard
        var flag: Int32 = 0
        if let stored = defaults.object(forKey: Self.linearStoreKey) {
            if let value = (stored as? Int).flatMap(Int32.init(exactly:)),
               value == 0 || value == 1 {
                flag = value
            } else {
                defaults.removeObject(forKey: Self.linearStoreKey)
            }
        }
        if writeLinearScaling(flag, mice: mice).all {
            flagHeld = false
            defaults.removeObject(forKey: Self.linearStoreKey)
        }
    }

    deinit {
        // Covers an owner that drops the instance without disable(): without
        // this the run loop fires a dead timer forever with no restore.
        // No main-queue assertion here: trapping inside deallocation would
        // be worse than the leak it guards against.
        teardown()
    }

    // A non-(-1) reading is a deliberate change (System Settings tracking
    // speed) or a competing process. Adopt it as the new original before
    // rewriting, so quitting restores the user's latest choice rather than a
    // stale one, while the rewrite keeps the last-writer-wins contest going.
    // Never our own multiplier, though: the window server can clear the
    // flag and leave the number, and in linear mode a value equal to the
    // multiplier last written (by this instance or its killed predecessor,
    // through the recovery copy) is ours whatever the flag says. Only the
    // value that landed counts: a requested speed whose write failed never
    // reached the property, so a matching tracking speed is a real choice,
    // and in raw mode the multiplier is never written at all (1.0 is a
    // System Settings stop). And only an
    // accelerated-mode reading is a tracking speed: with the flag at 1 on a
    // mouse, or the flag's recovery copy still on disk with no mouse reading
    // 0 (a killed holder, and no mouse to read back through), the number is
    // a linear multiplier, ours or the user's own System Settings switch,
    // and must never replace the recovery copy of the real tracking speed.
    private func adopt(_ current: Int32, mice: [MouseService]) {
        guard current != Self.disabled else { return }
        if mode == .linear, current == heldSpeed { return }
        let flagOn = mice.contains { $0.linearValue == 1 }
        let flagOff = mice.contains { $0.linearValue == 0 }
        let unrestored = UserDefaults.standard.object(forKey: Self.linearStoreKey) != nil
            && !flagOff
        guard !flagOn, !unrestored else { return }
        original = current
        // Persist even a value matching the bootstrapped guess: after an
        // unclean kill this may be the only copy of the tracking speed.
        if UserDefaults.standard.object(forKey: Self.storeKey) as? Int != Int(current) {
            UserDefaults.standard.set(Int(current), forKey: Self.storeKey)
        }
    }

    // The value to restore when nothing usable was ever observed or stored.
    // The live property mirrors com.apple.mouse.scaling (tracking speed) in
    // 16.16 fixed point, so deriving from it restores the user's actual
    // setting rather than an assumed one. A non-positive scaling is the
    // old-school way of turning acceleration off in the global prefs: honor
    // it by restoring nothing (nil) rather than substituting a speed the
    // user deliberately does not want.
    private static func bootstrapOriginal() -> Int32? {
        guard let ref = CFPreferencesCopyValue(
            "com.apple.mouse.scaling" as CFString, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
            CFGetTypeID(ref) == CFNumberGetTypeID() else { return fallback }
        var scaling = 0.0
        guard CFNumberGetValue((ref as! CFNumber), .float64Type, &scaling),
              scaling.isFinite else { return fallback }
        if scaling <= 0 { return nil }
        return Int32(exactly: (scaling * 65_536).rounded()) ?? fallback
    }

    // Linear mode needs the flag to read back, from the system or from a
    // mouse service. Once confirmed it stays confirmed: a mouse unplugged
    // later must not flip the mode back and write -1 over a multiplier the
    // next plug-in would then inherit.
    private func confirmLinearSupport(_ mice: [MouseService]) {
        guard mode == .raw, #available(macOS 14, *) else { return }
        let systemFlag = flagClient.flatMap {
            IOHIDEventSystemClientCopyProperty($0, Self.linearKey)
        }
        if systemFlag != nil || mice.contains(where: { $0.linearScaling != nil }) {
            mode = .linear
            recordLinearOriginal(mice)
            onLinearAvailabilityChange?(true)
        }
    }

    // The flag as it was before this app first wrote it, saved once and
    // never replaced while present, so a copy left by an unclean exit is not
    // overwritten with the flag that exit left behind. Taken here, while the
    // confirming mouse is attached, and again from writeHeld as a fallback
    // with 0 (the value IOHIDSystem seeds) when no mouse can answer.
    private func recordLinearOriginal(_ mice: [MouseService], fallback: Int? = nil) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.linearStoreKey) == nil else { return }
        let observed = mice.compactMap(\.linearValue).first { $0 == 0 || $0 == 1 }
        if let flag = observed ?? fallback {
            defaults.set(flag, forKey: Self.linearStoreKey)
        }
    }

    private static func fixedSpeed(thousandths: Int) -> Int32 {
        Int32((Double(clampedPointerSpeedThousandths(thousandths)) * 65_536 / 1_000).rounded())
    }

    // The tick's check: the whole desired state reads back, the requested
    // number and, in linear mode, the flag on every mouse. Anything else,
    // including a speed change whose write failed, is written again.
    private func isOurs(_ current: Int32, mice: [MouseService], speed: Int32) -> Bool {
        switch mode {
        case .raw: return current == Self.disabled
        case .linear: return current == speed && mice.allSatisfy { $0.linearValue == 1 }
        }
    }

    // restore()'s check, just the number: what this instance last wrote (or
    // claimed from a killed predecessor's recovery copy), and in raw mode -1
    // as well. The flag is put back regardless.
    private func accelerationIsOurs(_ current: Int32) -> Bool {
        current == heldSpeed || (mode == .raw && current == Self.disabled)
    }

    // Through the flag's client: the simple client's services answer nil
    // for the flag.
    private func mouseServices() -> [MouseService] {
        guard let flagClient else { return [] }
        let services = IOHIDEventSystemClientCopyServices(flagClient)
            as? [IOHIDServiceClient] ?? []
        return services.compactMap { service in
            guard (IOHIDServiceClientCopyProperty(service, "PrimaryUsagePage" as CFString)
                    as? NSNumber)?.intValue == 1,
                  (IOHIDServiceClientCopyProperty(service, "PrimaryUsage" as CFString)
                    as? NSNumber)?.intValue == 2 else { return nil }
            return MouseService(service: service, linearScaling:
                IOHIDServiceClientCopyProperty(service, Self.linearKey))
        }
    }

    private func read() -> Reading {
        guard let ref = IOHIDEventSystemClientCopyProperty(
            client, kIOHIDMouseAccelerationType as CFString) else { return .unavailable }
        guard CFGetTypeID(ref) == CFNumberGetTypeID() else { return .unreadable }
        // Via Int64 so an integer that merely arrives in a wider box still
        // reads; CFNumberGetValue with .sInt32Type would reject it as lossy.
        var wide: Int64 = 0
        guard CFNumberGetValue((ref as! CFNumber), .sInt64Type, &wide),
              let value = Int32(exactly: wide) else { return .unreadable }
        return .value(value)
    }

    private func reassert() {
        dispatchPrecondition(condition: .onQueue(.main))

        // disable() cannot cancel a wake block already enqueued on the main
        // queue, so a tick after teardown must not re-take the property.
        guard timer != nil else { return }
        let mice = mouseServices()
        confirmLinearSupport(mice)
        switch read() {
        case .unavailable:
            // A short post-wake gap is normal; a read that stays gone must
            // not present as a working feature.
            unavailableTicks += 1
            if unavailableTicks >= Self.unavailableTicksTolerated { setHealth(ok: false) }
        case .value(let current) where isOurs(current, mice: mice, speed: speed):
            unavailableTicks = 0
            setHealth(ok: true)
        case .unreadable:
            unavailableTicks = 0
            writeHeld(mice)
        case .value(let current):
            unavailableTicks = 0
            adopt(current, mice: mice)
            writeHeld(mice)
        }
    }

    // Surface transitions in both directions, once each, not per tick: the
    // caller's indicator has to come back down when a later reassert
    // succeeds.
    private func setHealth(ok: Bool) {
        guard writeFailing == ok else { return }
        writeFailing = !ok
        onWriteHealthChange?(ok)
    }

    @discardableResult
    private func teardown() -> Bool {
        timer?.invalidate()
        timer = nil
        if let o = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            wakeObserver = nil
        }
        return restore()
    }

    @discardableResult
    private func write(_ value: Int32) -> Bool {
        var v = value
        var ok = false
        if let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) {
            ok = IOHIDEventSystemClientSetProperty(
                client, kIOHIDMouseAccelerationType as CFString, number)
        }
        return ok
    }

    // Write the whole held state: the flag first in linear mode, so the
    // number that follows is read as a multiplier from the moment it lands.
    // A flag write that fails drops this tick to -1: a positive number
    // under a flag that did not take is acceleration back on, the one
    // outcome this class exists to prevent. The next tick retries the pair.
    private func writeHeld(_ mice: [MouseService]) {
        var flagOK = true
        if mode == .linear {
            recordLinearOriginal(mice, fallback: 0)
            let written = writeLinearScaling(1, mice: mice)
            flagOK = written.all
            // One landed write is a flag up somewhere, so the claim stands
            // on any success, not only a clean sweep.
            if written.any { flagHeld = true }
        }
        let value = mode == .linear && flagOK ? speed : Self.disabled
        // The recovery copy goes down before the write, so a kill between
        // the two cannot leave a landed multiplier unrecorded for the next
        // launch to mistake for a tracking speed; a failed write puts the
        // previous copy back.
        let defaults = UserDefaults.standard
        defaults.set(Int(value), forKey: Self.heldStoreKey)
        let accelerationOK = write(value)
        if accelerationOK {
            holding = true
            // A failed speed change must still restore the speed last
            // written, even though the next tick retries the requested one.
            heldSpeed = value
        } else if holding {
            defaults.set(Int(heldSpeed), forKey: Self.heldStoreKey)
        } else {
            defaults.removeObject(forKey: Self.heldStoreKey)
        }
        setHealth(ok: flagOK && accelerationOK)
    }

    // The flag goes to the system and to every mouse service: the system
    // write propagates to attached mice (measured), the per-service writes
    // cover any that missed it, and the per-service reads are the read-back
    // the tick and the health check see. Reports whether every write landed
    // and whether any did.
    private func writeLinearScaling(_ value: Int32,
                                    mice: [MouseService]) -> (all: Bool, any: Bool) {
        var value = value
        guard let flagClient,
              let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &value) else {
            return (false, false)
        }
        var results = [IOHIDEventSystemClientSetProperty(flagClient, Self.linearKey, number)]
        for mouse in mice {
            results.append(
                IOHIDServiceClientSetProperty(mouse.service, Self.linearKey, number))
        }
        return (results.allSatisfy { $0 }, results.contains(true))
    }
}
