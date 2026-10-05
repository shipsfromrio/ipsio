// create-device.swift: creates in code (CoreAudio, no clicks) the multi-output
// device that plays on the speaker AND sends the same sound to BlackHole.
// Usage: create-device [name] [uid]   (default: "Ipsio", io.github.shipsfromrio.ipsio.output)
//
// Stacked, with drift correction on BlackHole and the speaker as the main
// clock. The speaker is the current default output; if the default output is
// already BlackHole or an aggregate device, the Mac's first built-in output is
// used. Idempotent: if the name already exists, it does nothing.
import CoreAudio
import Foundation

let args = CommandLine.arguments
let name = args.count > 1 ? args[1] : "Ipsio"
let newUid = args.count > 2 ? args[2] : "io.github.shipsfromrio.ipsio.output"

func str(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var s: CFString = "" as CFString; var sz = UInt32(MemoryLayout<CFString>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &s); return s as String
}
func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v); return v
}
func hasOutput(_ id: AudioObjectID) -> Bool {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr && sz > 0
}
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var sz: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
var ids = [AudioDeviceID](repeating: 0, count: Int(sz) / MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)

var bh = ""
for id in ids {
    let n = str(id, kAudioObjectPropertyName)
    print("device:", n, "|", str(id, kAudioDevicePropertyDeviceUID))
    if n == name { print("\(name) ALREADY EXISTS"); exit(0) }
    if n == "BlackHole 2ch" { bh = str(id, kAudioDevicePropertyDeviceUID) }
}
var deflt: AudioDeviceID = 0
var ap = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var szp = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &ap, 0, nil, &szp, &deflt)
var spk = ""
let defaultName = str(deflt, kAudioObjectPropertyName)
if deflt != 0 && !defaultName.hasPrefix("BlackHole") && u32(deflt, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeAggregate {
    spk = str(deflt, kAudioDevicePropertyDeviceUID)
} else if let builtIn = ids.first(where: { u32($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn && hasOutput($0) }) {
    spk = str(builtIn, kAudioDevicePropertyDeviceUID)
}
if spk.isEmpty || bh.isEmpty { print("MISSING: speaker=[\(spk)] blackhole=[\(bh)]"); exit(1) }
let desc: [String: Any] = [
    kAudioAggregateDeviceNameKey: name,
    kAudioAggregateDeviceUIDKey: newUid,
    kAudioAggregateDeviceIsStackedKey: 1,
    kAudioAggregateDeviceMainSubDeviceKey: spk,
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: spk],
        [kAudioSubDeviceUIDKey: bh, kAudioSubDeviceDriftCompensationKey: 1],
    ],
]
var agg: AudioDeviceID = 0
let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
print(st == noErr ? "CREATED \(name) id=\(agg)" : "ERROR OSStatus \(st)")
exit(st == noErr ? 0 : 2)
