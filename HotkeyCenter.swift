// The AppKit/Carbon half of the jail toggle hotkey (spec "The dropdown"):
// global registration via RegisterEventHotKey, and the mechanism-2 capture
// view for the recorder. Mechanism 1 (the local keyDown monitor) lives with
// the recorder row's view state in CataclysmApp.swift; both feed the same
// capture closure and the first to fire wins.

import AppKit
import Carbon.HIToolbox

// Registers the stored chord with the window server and fires a callback on
// press. Registration can fail because another app owns the chord; that state
// is surfaced, never logged, so the panel row can show it.
final class HotkeyCenter {
    var onHotkey: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    // Re-registers atomically: the old chord is always released first, so a
    // failed registration leaves no chord active rather than the stale one.
    // Returns false when RegisterEventHotKey refuses the chord.
    @discardableResult
    func apply(keyCode: Int, modifiers: Int) -> Bool {
        installHandlerIfNeeded()
        unregister()
        // Settings validates stored chords, but the trapping UInt32(_:) must
        // never be the last line of defense: an unrepresentable value is a
        // failed registration, not a crash.
        guard let code = UInt32(exactly: keyCode),
              let mods = UInt32(exactly: modifiers) else { return false }
        var ref: EventHotKeyRef?
        // Four-char "CTCL"; the id is arbitrary but must match nothing else
        // this process registers (it registers only this one).
        let hotKeyID = EventHotKeyID(signature: OSType(0x4354_434C), id: 1)
        let status = RegisterEventHotKey(
            code, mods, hotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    // Called while the recorder is capturing: an active registration swallows
    // its own chord globally, so re-recording the current chord would never
    // reach the monitor or the responder.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // passUnretained is safe: AppRuntime owns this object for the process
        // lifetime, and the handler is never installed before onHotkey exists.
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotkeyCenter>.fromOpaque(userData)
                .takeUnretainedValue().onHotkey?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }
}

// Mechanism 2: a first-responder NSView that captures chords the responder
// chain would otherwise route to a menu. keyDown catches plain keys,
// performKeyEquivalent catches command chords. The closure returns true when
// it consumed the event.
final class KeyCaptureNSView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKey?(event) ?? false
    }
}
