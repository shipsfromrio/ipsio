// Quality.swift: the video presets (conf VIDEO_QUALITY). Normal is what the
// engine always recorded (12 fps, 4 Mb/s); anything unknown reads as normal.
// The disk rules (the minimum to start, the hours left) were set for normal,
// so they scale with the preset's size per hour.
import Foundation

enum Quality: String, CaseIterable {
    case economy, normal, high

    var fps: Int {
        switch self { case .economy: return 8; case .normal: return 12; case .high: return 24 }
    }
    var videoBitrate: Int {
        switch self { case .economy: return 2_000_000; case .normal: return 4_000_000; case .high: return 8_000_000 }
    }
    /// Each AAC track (Writer's audioBitrate); a meeting has two.
    static let audioBitrate = 128_000

    /// Fail safe: missing, empty or unknown is normal.
    static func parse(_ conf: String?) -> Quality {
        Quality(rawValue: (conf ?? "").trimmingCharacters(in: .whitespaces).lowercased()) ?? .normal
    }

    /// GB (10^9 bytes) per hour: the video plus one audio track (class) or two (meeting).
    func gbPerHour(meeting: Bool) -> Double {
        Double(videoBitrate + Quality.audioBitrate * (meeting ? 2 : 1)) * 3600 / 8 / 1e9
    }
    /// This preset's size against normal's: 1 for normal, exactly.
    func scale(meeting: Bool) -> Double { gbPerHour(meeting: meeting) / Quality.normal.gbPerHour(meeting: meeting) }

    /// MIN_FREE_GB was set for normal: scaled, rounded up (fail closed).
    func minFreeGB(_ base: Int, meeting: Bool) -> Int { Int((Double(base) * scale(meeting: meeting)).rounded(.up)) }
    /// The level's disk_h (free*10/18 for normal), scaled down for a bigger preset.
    func hoursLeft(freeGB: Int, meeting: Bool) -> Int { max(0, Int(Double(freeGB) * 10 / 18 / scale(meeting: meeting))) }
    /// For the menu and the disk text: "1.0", "1.9", "3.7".
    func perHourLabel(meeting: Bool) -> String { String(format: "%.1f", gbPerHour(meeting: meeting)) }
}
