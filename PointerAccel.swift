// PointerAccel: turns mouse pointer acceleration off by setting the HID event
// system's HIDMouseAcceleration property to -1, which makes the pointer filter
// skip acceleration entirely (the NoMouseAccel technique). Live property, not a
// stored preference: takes effect immediately, invisible to `defaults read`,
// and does not survive HID subsystem restarts, so it is reasserted on wake and
// on a slow timer. The trackpad has its own key, which is never touched.
//
// Main-thread only, like the rest of the process. deinit does not run for a
// global on process exit, so the owner must call restore() from its own exit
// paths, the same way main.swift re-associates the cursor. Those paths must
// reach it on the main thread: signal handlers via a main-queue dispatch
// source (as main.swift already does), and atexit only from a main-thread
// exit(), or a reassert tick still in flight can re-take the property after
// restore() has released it.

import Cocoa

final class PointerAccel {
    private static let disabled: Int32 = -1
    // 3.0 in 16.16 fixed point, matching the macOS default tracking speed.
    // Used only when the first read of the app's life is already -1 (a
    // previous holder was force-quit), nothing was ever persisted, and
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

    private enum Reading {
        case unavailable      // copy returned nil: HID subsystem down or coming back
        case unreadable       // present but not a number this code can use
        case value(Int32)
    }

    private let client: IOHIDEventSystemClient
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    // The value restored on disable/quit. Never -1: adopting -1 as the
    // original would destroy the real value permanently. nil means the user's
    // own preference already was acceleration off, so there is nothing to
    // restore.
    private var original: Int32?
    // True from the first successful write of -1 until a successful restore.
    // restore() without it would write a guessed original over a foreign -1
    // this process never touched. Re-writing a -1 that predates enable() does
    // set it: per the spec's bootstrap rationale, an orphaned -1 (its holder
    // force-quit) is deliberately claimed so quitting restores something.
    private var holding = false
    private var unavailableTicks = 0
    // Called with false on the transition into a failing HID write and true
    // when a later write succeeds again. A false from SetProperty is a broken
    // feature indistinguishable by feel from the curve merely being
    // different, so the caller must show it somewhere, and clear it again.
    var onWriteHealthChange: ((_ healthy: Bool) -> Void)?
    private(set) var writeFailing = false

    init() {
        client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let defaults = UserDefaults.standard
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

    var isActive: Bool { timer != nil }

    // A released instance (disable() or restore() ran) whose write of the
    // original failed, so the property still reads -1 with nobody
    // reasserting it. writeFailing never covers this: exit-path writes are
    // deliberately unreported, so the owner has to read it here or a panel
    // reopen would show the feature as restored.
    var restoreFailed: Bool { holding && timer == nil }

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
        switch read() {
        case .unavailable:
            // Nothing to capture and a write would likely fail too; the
            // timer's first tick performs the initial adopt-and-write.
            break
        case .unreadable:
            writeDisabled()
        case .value(let current):
            adopt(current)
            writeDisabled()
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
    // restore()'s verdict: false means the property still reads -1 with the
    // write of the original failed, and the owner must keep this instance for
    // a later retry rather than drop it.
    func disable() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return teardown()
    }

    // Safe on any exit path: acts only while this instance holds the
    // property, and only when it still reads as ours (-1) or is gone with
    // the HID subsystem down. A readable non-(-1) value, or junk, means
    // another process has written since and clobbering it would be wrong.
    // Exit paths must not report health: the process is going away and a
    // callback here would latch a failure no later write can clear, or run
    // against a half-deallocated owner on the deinit path.
    // Returns whether the claim is released afterwards; false only when the
    // property still reads -1 and the write of the original failed, the one
    // case where the stored original must survive for a later restore.
    @discardableResult
    func restore() -> Bool {
        guard holding else { return true }
        switch read() {
        case .value(Self.disabled), .unavailable:
            if original == nil {
                // The user's own prefs keep acceleration off; leaving -1 is
                // the restore.
                holding = false
            } else if let original, write(original, report: false) {
                holding = false
            }
            // On a failed write the claim is kept: the property is still -1
            // and a later restore() (a retried exit path, or the next
            // enable/disable cycle) is the only thing that can put the
            // original back.
        case .value, .unreadable:
            holding = false
        }
        return !holding
    }

    deinit {
        // Covers an owner that drops the instance without disable(): without
        // this the run loop fires a dead timer forever and the property stays
        // -1 with no restore. No main-queue assertion here; trapping inside
        // deallocation would be worse than the leak it guards against.
        teardown()
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

    private func reassert() {
        // disable() cannot cancel a wake block already enqueued on the main
        // queue, so a tick after teardown must not re-take the property.
        guard timer != nil else { return }
        switch read() {
        case .unavailable:
            // The HID subsystem is still coming back and the next tick
            // retries; but a read that stays gone means nothing is being
            // held at all, which must not present as a working feature.
            unavailableTicks += 1
            if unavailableTicks >= Self.unavailableTicksTolerated { setHealth(ok: false) }
        case .value(Self.disabled):
            // Still ours, nothing to rewrite. It also proves the desired
            // state is in effect, so a failure indicator left over from a
            // write that lost a race can come back down.
            unavailableTicks = 0
            setHealth(ok: true)
        case .unreadable:
            // Foreign junk: nothing to adopt, but the contest for the knob
            // continues, same as enable() overwriting an unreadable value.
            unavailableTicks = 0
            writeDisabled()
        case .value(let current):
            unavailableTicks = 0
            adopt(current)
            writeDisabled()
        }
    }

    // A non-(-1) reading is a deliberate change (System Settings tracking
    // speed) or a competing process. Adopt it as the new original before
    // rewriting, so quitting restores the user's latest choice rather than a
    // stale one, while the rewrite keeps the last-writer-wins contest going.
    private func adopt(_ current: Int32) {
        guard current != Self.disabled else { return }
        original = current
        // Persist even when it matches the bootstrapped guess: a guess
        // derived from com.apple.mouse.scaling is only right until that
        // preference changes, and after an unclean kill the stored copy is
        // all there is.
        if UserDefaults.standard.object(forKey: Self.storeKey) as? Int != Int(current) {
            UserDefaults.standard.set(Int(current), forKey: Self.storeKey)
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

    private func writeDisabled() {
        if write(Self.disabled) { holding = true }
    }

    @discardableResult
    private func write(_ value: Int32, report: Bool = true) -> Bool {
        var v = value
        var ok = false
        if let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) {
            ok = IOHIDEventSystemClientSetProperty(
                client, kIOHIDMouseAccelerationType as CFString, number)
        }
        if report { setHealth(ok: ok) }
        return ok
    }

    // Surface transitions in both directions, once each, not per tick: the
    // caller's indicator has to come back down when a later reassert
    // succeeds.
    private func setHealth(ok: Bool) {
        guard writeFailing == ok else { return }
        writeFailing = !ok
        onWriteHealthChange?(ok)
    }
}
