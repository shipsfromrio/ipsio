// Files.swift: where a recording goes and the evidence written next to it.
// Same names as ipsio.sh ("2026-10-05_14-00 Title.mov", then " (2)") and the
// same .sha256 format, the one `shasum -a 256 -c` checks.
import CryptoKit
import Foundation

enum Naming {
    /// A title safe for a file name: no line breaks, no "/" or ":", trimmed.
    static func title(_ t: String) -> String {
        let s = t.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return String(s.trimmingCharacters(in: .whitespaces).prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    /// The first free path; `exists` is injected so the bench needs no disk.
    static func output(folder: String, date: Date, title: String, ext: String = "mov",
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm"
        let t = Naming.title(title)
        let base = folder + "/" + f.string(from: date) + (t.isEmpty ? "" : " " + t)
        var out = base + "." + ext, n = 2
        while exists(out) { out = "\(base) (\(n)).\(ext)"; n += 1 }
        return out
    }
}

enum Evidence {
    /// SHA-256 of a file, read 4 MB at a time (an 8 h recording does not fit in memory).
    static func sha256(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            // read(upToCount:) answers nil at the end of the file, and throws on a read error.
            let chunk: Data?
            do { chunk = try h.read(upToCount: 4 << 20) } catch { return nil }
            guard let d = chunk, !d.isEmpty else { break }
            hasher.update(data: d)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Writes "<sum>  <name>\n" to "<file>.sha256" through a temporary file,
    /// so a reader never sees half a line. Returns the sum, nil on failure.
    @discardableResult
    static func write(for path: String) -> String? {
        guard let sum = sha256(path) else { return nil }
        let line = "\(sum)  \((path as NSString).lastPathComponent)\n"
        let tmp = path + ".sha256.tmp", dst = path + ".sha256"
        do {
            try line.write(toFile: tmp, atomically: false, encoding: .utf8)
            if FileManager.default.fileExists(atPath: dst) { try FileManager.default.removeItem(atPath: dst) }
            try FileManager.default.moveItem(atPath: tmp, toPath: dst)
        } catch { try? FileManager.default.removeItem(atPath: tmp); return nil }
        return sum
    }
}
