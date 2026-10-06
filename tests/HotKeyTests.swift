import Carbon.HIToolbox
import Foundation

// swiftc -parse-as-library app/HotKey.swift tests/HotKeyTests.swift -o hk && ./hk
@main struct HotKeyTests {
    static var ok = 0, failed = 0
    static func check(_ name: String, _ cond: Bool) {
        if cond { ok += 1 } else { failed += 1; print("FAIL: \(name)") }
    }
    static func main() {
        let r = HotKeys.combos[.record], t = HotKeys.combos[.test]
        check("record is ⌃⌥⌘R", r?.key == UInt32(kVK_ANSI_R) && r?.letter == "r")
        check("test is ⌃⌥⌘T", t?.key == UInt32(kVK_ANSI_T) && t?.letter == "t")
        check("every action has a combo", HotKeys.Action.allCases.allSatisfy { HotKeys.combos[$0] != nil })
        check("the combos differ", r != t)
        for a in HotKeys.Action.allCases {
            let m = HotKeys.combos[a]?.modifiers ?? 0
            check("\(a) needs control, option and command",
                  m & UInt32(controlKey) != 0 && m & UInt32(optionKey) != 0 && m & UInt32(cmdKey) != 0)
            check("\(a) does not use shift", m & UInt32(shiftKey) == 0)
        }
        check("on by default", HotKeys.enabled(nil))
        check("on when '1'", HotKeys.enabled("1"))
        check("off when '0'", !HotKeys.enabled("0"))
        check("action ids are unique", Set(HotKeys.Action.allCases.map(\.rawValue)).count == HotKeys.Action.allCases.count)
        print("\(ok)/\(ok + failed) ok")
        exit(failed == 0 ? 0 : 1)
    }
}
