// Report.swift: an integrity report for one recording, as a PDF next to it
// ("<name>.integrity.pdf"). It states what the file is (size, start, length,
// tracks), its SHA-256 and how anyone can check it with `shasum`. The seal is
// never invented: the hash in the report is the one computed from the file
// now, and the evidence file (".sha256", written when the recording ended) is
// compared with it; a missing or different evidence file is said in words.
// Pure halves: `seal`, `start`, `fields`, `pdf`. `write` only reads the
// recording and its .sha256, and writes the PDF through a temporary file and a
// rename; it refuses anything that is not a recording, and never writes a
// .mov, .mkv or .sha256.
import AVFoundation
import CoreText
import Foundation

enum Report {
    /// The evidence file against the file as it is now.
    enum Seal: Equatable {
        case match(String)                          // .sha256 present and equal to the file now
        case mismatch(recorded: String, now: String) // .sha256 says another hash
        case missing(now: String?)                  // no .sha256 next to the recording
        case invalid(now: String?)                  // .sha256 not in shasum format, or names another file
        case unread(recorded: String)               // the recording could not be read now
    }

    /// "<64 hex>  <name>", the line Evidence.write puts in "<file>.sha256".
    static func seal(evidence: String?, name: String, now: String?) -> Seal {
        guard let ev = evidence else { return .missing(now: now) }
        let lines = ev.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count == 1 else { return .invalid(now: now) }
        let l = lines[0]
        guard l.count > 66, let sep = l.range(of: "  ") else { return .invalid(now: now) }
        let hex = String(l[..<sep.lowerBound]).lowercased()
        let named = String(l[sep.upperBound...])
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }), named == name else { return .invalid(now: now) }
        guard let n = now?.lowercased() else { return .unread(recorded: hex) }
        return hex == n ? .match(n) : .mismatch(recorded: hex, now: n)
    }

    /// When the recording began, and where that came from.
    enum StartSource: Equatable { case created, name }
    struct Start: Equatable { let date: Date; let from: StartSource }

    /// The file name says the minute it began ("2026-10-05_14-00 ...", Naming);
    /// the creation date says the second, but a copy resets it. The creation
    /// date wins only inside the minute of the name.
    static func start(name: String, created: Date?, tz: TimeZone = .current) -> Start? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd_HH-mm"
        let named = name.count >= 16 ? f.date(from: String(name.prefix(16))) : nil
        switch (named, created) {
        case let (n?, c?): return c >= n && c < n.addingTimeInterval(60) ? Start(date: c, from: .created) : Start(date: n, from: .name)
        case let (n?, nil): return Start(date: n, from: .name)
        case let (nil, c?): return Start(date: c, from: .created)
        default: return nil
        }
    }

    /// "HH:MM:SS", rounded down; an 8 h recording reads "08:00:00".
    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s).rounded(.down))
        return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    /// A shell argument that `zsh` and `bash` take literally.
    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func L(_ lang: String, _ pt: String, _ en: String) -> String { lang == "en" ? en : pt }

    /// The report's lines, in order. `tracks` nil = the file could not be read.
    static func fields(path: String, sizeBytes: Int64, seal: Seal, start: Start?, duration: Double?,
                       tracks: (video: Int, audio: Int)?, appVersion: String, osVersion: String,
                       made: Date, lang: String, tz: TimeZone = .current) -> [(label: String, value: String)] {
        let name = (path as NSString).lastPathComponent
        func stamp(_ d: Date, seconds: Bool) -> String {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
            f.dateFormat = seconds ? "yyyy-MM-dd HH:mm:ss xxx" : "yyyy-MM-dd HH:mm xxx"
            return f.string(from: d)
        }
        let unknown = L(lang, "desconhecido (o arquivo não pôde ser lido)", "unknown (the file could not be read)")
        var out: [(label: String, value: String)] = []
        out.append((L(lang, "Arquivo", "File"), name))
        out.append((L(lang, "Tamanho", "Size"), "\(sizeBytes) bytes (" + String(format: "%.1f MB", Double(sizeBytes) / 1_000_000) + ")"))
        if let s = start {
            let exact = s.from == .created
            out.append((L(lang, "Início", "Start"), stamp(s.date, seconds: exact) + " (" + (exact
                ? L(lang, "data de criação do arquivo", "the file's creation date")
                : L(lang, "pelo nome do arquivo, ao minuto", "from the file name, to the minute")) + ")"))
            if let d = duration { out.append((L(lang, "Fim", "End"), stamp(s.date.addingTimeInterval(d), seconds: exact) + " (" + L(lang, "início + duração", "start + length") + ")")) }
        } else {
            out.append((L(lang, "Início", "Start"), L(lang, "desconhecido (nem o nome nem o arquivo dizem)", "unknown (neither the name nor the file say)")))
        }
        out.append((L(lang, "Duração", "Length"), duration.map { clock($0) } ?? unknown))
        out.append((L(lang, "Faixas", "Tracks"), tracks.map {
            L(lang, "\($0.video) de vídeo, \($0.audio) de áudio", "\($0.video) video, \($0.audio) audio") } ?? unknown))

        let sha = name + ".sha256"
        let shaLabel = L(lang, "SHA-256 (calculado agora)", "SHA-256 (computed now)")
        let evLabel = L(lang, "Arquivo de prova", "Evidence file")
        let howLabel = L(lang, "Como conferir", "How to verify")
        let checkCmd = "shasum -a 256 -c " + quoted(sha)
        let hashCmd = "shasum -a 256 " + quoted(name)
        let inFolder = L(lang, "No Terminal, na pasta da gravação:", "In Terminal, in the recording's folder:")
        switch seal {
        case .match(let h):
            out.append((shaLabel, h))
            out.append((evLabel, sha + ": " + L(lang, "confere com o arquivo", "matches the file")))
            out.append((howLabel, inFolder + "\n" + checkCmd + "\n" + L(lang, "Resposta esperada: ", "Expected answer: ") + name + ": OK"))
        case .mismatch(let r, let n):
            out.append((shaLabel, n))
            out.append((evLabel, L(lang, "NÃO CONFERE. ", "DOES NOT MATCH. ") + sha + L(lang, " registrou ", " recorded ") + r
                + L(lang, ". O arquivo mudou depois de gravado, ou o arquivo de prova não é deste arquivo.",
                    ". The file changed after it was recorded, or the evidence file is not this file's.")))
            out.append((howLabel, inFolder + "\n" + checkCmd + "\n" + L(lang, "Hoje a resposta é FAILED.", "Today the answer is FAILED.")))
        case .missing(let n), .invalid(let n):
            let missing: Bool
            if case .missing = seal { missing = true } else { missing = false }
            out.append((shaLabel, n ?? unknown))
            out.append((evLabel, (missing
                ? L(lang, "NÃO HÁ ARQUIVO DE PROVA: ", "NO EVIDENCE FILE: ") + sha + L(lang, " não está ao lado da gravação.", " is not next to the recording.")
                : L(lang, "ARQUIVO DE PROVA INVÁLIDO: ", "INVALID EVIDENCE FILE: ") + sha + L(lang, " não está no formato do shasum, ou cita outro arquivo.", " is not in shasum format, or names another file."))
                + L(lang, " O SHA-256 acima foi calculado quando este relatório foi feito, não quando a gravação terminou.",
                    " The SHA-256 above was computed when this report was made, not when the recording ended.")))
            out.append((howLabel, inFolder + "\n" + hashCmd + "\n" + L(lang, "e compare com o SHA-256 acima.", "and compare with the SHA-256 above.")))
        case .unread(let r):
            out.append((shaLabel, unknown))
            out.append((evLabel, sha + L(lang, " registrou ", " recorded ") + r + L(lang, ", mas o arquivo não pôde ser lido agora para conferir.", ", but the file could not be read now to check it.")))
            out.append((howLabel, inFolder + "\n" + checkCmd))
        }
        out.append((L(lang, "Feito com", "Made with"), "Ipsio \(appVersion), macOS \(osVersion)"))
        out.append((L(lang, "Relatório feito em", "Report made"), stamp(made, seconds: true)))
        out.append((L(lang, "Observação", "Note"), L(lang,
            "O SHA-256 é a impressão digital do arquivo: mudar um único byte muda o valor. Este relatório registra o arquivo como ele estava quando foi feito; não atesta o conteúdo da gravação.",
            "The SHA-256 is the file's fingerprint: changing a single byte changes it. This report records the file as it was when the report was made; it does not vouch for what the recording shows.")))
        return out
    }

    /// A hash or a command: set in a monospaced font.
    static func isCode(_ v: String) -> Bool {
        v.contains("shasum ") || v.split(whereSeparator: { !$0.isHexDigit }).contains { $0.count == 64 }
    }

    /// A4 for pt, US Letter for en.
    static func page(lang: String) -> CGSize { lang == "en" ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842) }

    /// The PDF: a title, then each label over its value; hashes and commands in Menlo.
    static func pdf(fields: [(label: String, value: String)], title: String, page: CGSize = CGSize(width: 595, height: 842)) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        let info = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Ipsio"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, info) else { return Data() }
        let margin: CGFloat = 56, width = page.width - 2 * margin
        func attr(_ s: String, font: String, size: CGFloat, gray: CGFloat) -> NSAttributedString {
            let f = CTFontCreateWithName(font as CFString, size, nil)
            return NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): f,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1)])
        }
        var y: CGFloat = 0
        func newPage() { ctx.beginPDFPage(nil); y = page.height - margin }
        func draw(_ s: NSAttributedString, after: CGFloat) {
            let fs = CTFramesetterCreateWithAttributedString(s as CFAttributedString)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                                   CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            let h = ceil(fit.height) + 1
            if y - h < margin { ctx.endPDFPage(); newPage() }
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0),
                                                 CGPath(rect: CGRect(x: margin, y: y - h, width: width, height: h), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            y -= h + after
        }
        newPage()
        draw(attr(title, font: "Helvetica-Bold", size: 16, gray: 0), after: 14)
        for f in fields {
            draw(attr(f.label, font: "Helvetica-Bold", size: 9, gray: 0.35), after: 2)
            draw(isCode(f.value) ? attr(f.value, font: "Menlo-Regular", size: 9, gray: 0) : attr(f.value, font: "Helvetica", size: 11, gray: 0), after: 10)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    enum Failure: Error, CustomStringConvertible {
        case refused(String), missing(String), write(String)
        var description: String {
            switch self {
            case .refused(let s): return "refused to write a report for \(s): it is not a recording, or the report would replace the recording or its evidence"
            case .missing(let s): return "\(s) does not exist"
            case .write(let s): return "could not write \(s)"
            }
        }
    }

    static let recordings = ["mov", "mkv"]
    static let evidence = ["mov", "mkv", "sha256"]

    /// "<dir>/<name>.integrity.pdf" for "<dir>/<name>.mov".
    static func output(for media: String) -> String { (media as NSString).deletingPathExtension + ".integrity.pdf" }

    /// Length and tracks through AVFoundation; nil when it cannot read the file (.mkv, damaged).
    static func probe(_ path: String) -> (duration: Double, video: Int, audio: Int)? {
        final class Box: @unchecked Sendable { var r: (Double, Int, Int)? }
        let box = Box(), sem = DispatchSemaphore(value: 0)
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        Task.detached {
            if let d = try? await asset.load(.duration), d.isNumeric,
               let v = try? await asset.loadTracks(withMediaType: .video),
               let a = try? await asset.loadTracks(withMediaType: .audio) {
                box.r = (CMTimeGetSeconds(d), v.count, a.count)
            }
            sem.signal()
        }
        sem.wait()
        return box.r.map { (duration: $0.0, video: $0.1, audio: $0.2) }
    }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Reads `media` and its .sha256, writes "<name>.integrity.pdf" next to
    /// them, answers its path. Off the main thread: it hashes the whole file.
    @discardableResult
    static func write(media path: String, lang: String, now: Date = Date()) throws -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        guard recordings.contains(ext) else { throw Failure.refused(path) }
        let out = output(for: path)
        if out == path || out == path + ".sha256" || evidence.contains((out as NSString).pathExtension.lowercased()) { throw Failure.refused(out) }
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path), (attrs[.type] as? FileAttributeType) == .typeRegular else { throw Failure.missing(path) }
        let name = (path as NSString).lastPathComponent
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        // The evidence file is tiny; anything big is not one.
        let shaPath = path + ".sha256"
        var evidenceText: String? = nil
        if fm.fileExists(atPath: shaPath) {
            let sz = ((try? fm.attributesOfItem(atPath: shaPath))?[.size] as? NSNumber)?.intValue ?? 0
            evidenceText = sz <= 4096 ? ((try? String(contentsOfFile: shaPath, encoding: .utf8)) ?? "") : ""
        }
        let seal = Report.seal(evidence: evidenceText, name: name, now: Evidence.sha256(path))
        let p = probe(path)
        let fields = Report.fields(path: path, sizeBytes: size, seal: seal,
                                   start: start(name: name, created: attrs[.creationDate] as? Date), duration: p?.duration,
                                   tracks: p.map { (video: $0.video, audio: $0.audio) }, appVersion: appVersion, osVersion: osVersion,
                                   made: now, lang: lang)
        let title = L(lang, "Relatório de integridade: ", "Integrity report: ") + name
        let body = pdf(fields: fields, title: title, page: page(lang: lang))
        let tmp = out + ".tmp"
        do { try body.write(to: URL(fileURLWithPath: tmp)) }
        catch { try? fm.removeItem(atPath: tmp); throw Failure.write(out) }
        // rename(2) replaces an old report in one step.
        if rename(tmp, out) != 0 { try? fm.removeItem(atPath: tmp); throw Failure.write(out) }
        return out
    }
}
