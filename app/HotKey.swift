import Carbon.HIToolbox

/// Global shortcuts through Carbon's RegisterEventHotKey: they work in the
/// sandbox and need no Accessibility permission (a key monitor would).
final class HotKeys {
    enum Action: UInt32, CaseIterable { case record = 1, test = 2 }
    struct Combo: Equatable { let key: UInt32; let modifiers: UInt32; let letter: String }

    /// ⌃⌥⌘: three modifiers, so no app or system shortcut is taken over.
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let combos: [Action: Combo] = [
        .record: Combo(key: UInt32(kVK_ANSI_R), modifiers: modifiers, letter: "r"),
        .test: Combo(key: UInt32(kVK_ANSI_T), modifiers: modifiers, letter: "t"),
    ]
    /// On unless HOTKEYS='0'.
    static func enabled(_ conf: String?) -> Bool { conf != "0" }
    static let signature: OSType = 0x4950_534F // "IPSO"

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let fire: (Action) -> Void
    init(_ fire: @escaping (Action) -> Void) { self.fire = fire }

    /// Registers every combo; returns the actions macOS refused (taken by another app).
    @discardableResult func start() -> [Action] {
        stop()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, me in
            var id = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard st == noErr, id.signature == HotKeys.signature, let me, let a = Action(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let keys = Unmanaged<HotKeys>.fromOpaque(me).takeUnretainedValue()
            DispatchQueue.main.async { keys.fire(a) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        var refused: [Action] = []
        for a in Action.allCases {
            guard let c = HotKeys.combos[a] else { continue }
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(c.key, c.modifiers, EventHotKeyID(signature: HotKeys.signature, id: a.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { refused.append(a) }
        }
        return refused
    }
    func stop() {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []
        if let h = handler { RemoveEventHandler(h); handler = nil }
    }
    deinit { stop() }
}
