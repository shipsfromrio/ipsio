// ReportTests.swift: the bench for the integrity report (app/Report.swift):
// the seal never invented, the lines, the PDF (PDFKit reads the hash back) and
// a write that never touches the recording or its evidence. Compiles with the
// evidence code:
//   swiftc -parse-as-library app/Report.swift app/Engine/Files.swift tests/ReportTests.swift -o /tmp/report-tests && /tmp/report-tests
// Exits 1 if any assertion fails. The .mov is a 3 s silent one made here.
import AVFoundation
import Foundation
import PDFKit

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}

/// A .mov with one audio track of `seconds` of 16-bit silence.
func makeMov(_ path: String, seconds: Int) -> Bool {
    guard let w = try? AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mov) else { return false }
    let rate = 16000
    let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    w.add(inp)
    guard w.startWriting() else { return false }
    w.startSession(atSourceTime: .zero)
    var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                           mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                           mBitsPerChannel: 16, mReserved: 0)
    var fmt: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
    for s in 0..<seconds {
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: rate * 2, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: rate * 2,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: rate * 2)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!,
                                                             sampleCount: rate, presentationTimeStamp: CMTime(value: CMTimeValue(s * rate), timescale: CMTimeScale(rate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        while !inp.isReadyForMoreMediaData { usleep(1000) }
        guard inp.append(sb!) else { return false }
    }
    inp.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    w.finishWriting { sem.signal() }
    sem.wait()
    return w.status == .completed
}

func value(_ f: [(label: String, value: String)], _ label: String) -> String { f.first { $0.label == label }?.value ?? "" }
func pdfText(_ d: Data) -> String { PDFDocument(data: d)?.string ?? "" }
func noSpace(_ s: String) -> String { s.components(separatedBy: .whitespacesAndNewlines).joined() }

@main
struct ReportTests {
    static func main() {
        typealias R = Report
        let utc = TimeZone(identifier: "UTC")!
        let h1 = String(repeating: "ab", count: 32), h2 = String(repeating: "cd", count: 32)
        let name = "2026-10-05_14-00 Weekly.mov"

        // The seal: never invented.
        check(R.seal(evidence: "\(h1)  \(name)\n", name: name, now: h1) == .match(h1), "same hash: match")
        check(R.seal(evidence: "\(h1.uppercased())  \(name)\n", name: name, now: h1) == .match(h1), "case does not matter")
        check(R.seal(evidence: "\(h1)  \(name)\n", name: name, now: h2) == .mismatch(recorded: h1, now: h2), "another hash: mismatch")
        check(R.seal(evidence: nil, name: name, now: h1) == .missing(now: h1), "no .sha256: missing")
        check(R.seal(evidence: "\(h1)  other.mov\n", name: name, now: h1) == .invalid(now: h1), "a .sha256 naming another file is invalid")
        check(R.seal(evidence: "garbage\n", name: name, now: h1) == .invalid(now: h1), "garbage is invalid")
        check(R.seal(evidence: "", name: name, now: h1) == .invalid(now: h1), "an empty .sha256 is invalid")
        check(R.seal(evidence: "\(h1)  \(name)\n\(h1)  \(name)\n", name: name, now: h1) == .invalid(now: h1), "two lines are invalid")
        check(R.seal(evidence: String(h1.dropLast()) + "g  \(name)\n", name: name, now: h1) == .invalid(now: h1), "a non-hex hash is invalid")
        check(R.seal(evidence: "\(h1)  \(name)\n", name: name, now: nil) == .unread(recorded: h1), "an unreadable file is not a match")

        // The start: the name to the minute, the creation date inside that minute.
        let named = ISO8601DateFormatter().date(from: "2026-10-05T14:00:00Z")!
        check(R.start(name: name, created: named.addingTimeInterval(12), tz: utc) == R.Start(date: named.addingTimeInterval(12), from: .created),
              "creation date inside the name's minute: to the second")
        check(R.start(name: name, created: named.addingTimeInterval(86400), tz: utc) == R.Start(date: named, from: .name),
              "a copy (creation date a day later): the name wins")
        check(R.start(name: name, created: nil, tz: utc) == R.Start(date: named, from: .name), "no creation date: the name")
        check(R.start(name: "notes.mov", created: named, tz: utc) == R.Start(date: named, from: .created), "no date in the name: the creation date")
        check(R.start(name: "notes.mov", created: nil, tz: utc) == nil, "neither: unknown, not now")

        check(R.clock(3) == "00:00:03" && R.clock(3725.9) == "01:02:05" && R.clock(8 * 3600) == "08:00:00" && R.clock(-1) == "00:00:00", "duration format")
        check(R.quoted("it's.mov") == "'it'\\''s.mov'", "a quote in the name is escaped for the shell")

        // The lines.
        let start = R.Start(date: named.addingTimeInterval(12), from: .created)
        func fields(_ seal: R.Seal, _ lang: String = "en", dur: Double? = 3725, tracks: (video: Int, audio: Int)? = (1, 2)) -> [(label: String, value: String)] {
            R.fields(path: "/x/" + name, sizeBytes: 123_456_789, seal: seal, start: start, duration: dur, tracks: tracks,
                     appVersion: "1.2.3", osVersion: "26.6.2", made: named.addingTimeInterval(7200), lang: lang, tz: utc)
        }
        let ok = fields(.match(h1))
        let all = ok.map { $0.label + ": " + $0.value }.joined(separator: "\n")
        check(value(ok, "SHA-256 (computed now)") == h1, "the hash is in the report", all)
        check(value(ok, "How to verify").contains("shasum -a 256 -c '\(name).sha256'"), "the verification command", value(ok, "How to verify"))
        check(value(ok, "How to verify").contains(name + ": OK"), "the expected answer")
        check(value(ok, "Evidence file").contains("matches"), "evidence matches")
        check(value(ok, "Length") == "01:02:05", "length HH:MM:SS")
        check(value(ok, "Start") .hasPrefix("2026-10-05 14:00:12 +00:00"), "start to the second", value(ok, "Start"))
        check(value(ok, "End").hasPrefix("2026-10-05 15:02:17 +00:00"), "end = start + length", value(ok, "End"))
        check(value(ok, "Tracks") == "1 video, 2 audio", "tracks")
        check(value(ok, "Size").hasPrefix("123456789 bytes") && value(ok, "Size").contains("123.5 MB"), "size", value(ok, "Size"))
        check(value(ok, "File") == name && !all.contains("/x/"), "the file name only, not the folder")
        check(value(ok, "Made with") == "Ipsio 1.2.3, macOS 26.6.2", "app and macOS versions")
        check(value(ok, "Report made").hasPrefix("2026-10-05 16:00:00"), "when the report was made")

        let miss = fields(.missing(now: h2))
        check(value(miss, "Evidence file").contains("NO EVIDENCE FILE"), "missing .sha256 says there is no evidence file", value(miss, "Evidence file"))
        check(value(miss, "Evidence file").contains("not when the recording ended"), "and that the hash is from now")
        check(!value(miss, "How to verify").contains("-c "), "no -c check against a file that is not there")
        check(value(miss, "SHA-256 (computed now)") == h2, "missing: the hash computed now, labeled as such")
        let missPt = fields(.missing(now: h2), "pt")
        check(value(missPt, "Arquivo de prova").contains("NÃO HÁ ARQUIVO DE PROVA"), "pt: missing .sha256 said in words")
        let bad = fields(.mismatch(recorded: h1, now: h2))
        check(value(bad, "Evidence file").contains("DOES NOT MATCH") && value(bad, "Evidence file").contains(h1) && value(bad, "SHA-256 (computed now)") == h2,
              "mismatch: both hashes, said in words")
        check(!bad.contains { $0.value.contains("matches the file") }, "mismatch never reads as a match")
        let inv = fields(.invalid(now: h2))
        check(value(inv, "Evidence file").contains("INVALID EVIDENCE FILE"), "invalid evidence said in words")
        let unread = fields(.unread(recorded: h1), dur: nil, tracks: nil)
        check(value(unread, "SHA-256 (computed now)").hasPrefix("unknown") && value(unread, "Length").hasPrefix("unknown")
              && value(unread, "Tracks").hasPrefix("unknown") && value(unread, "End").isEmpty, "unreadable: unknown, nothing made up")
        let noStart = R.fields(path: "a.mov", sizeBytes: 1, seal: .match(h1), start: nil, duration: 3, tracks: (1, 1),
                               appVersion: "1", osVersion: "1", made: named, lang: "en", tz: utc)
        check(value(noStart, "Start").hasPrefix("unknown") && value(noStart, "End").isEmpty, "no start: unknown, no end")
        let namedStart = R.fields(path: "a.mov", sizeBytes: 1, seal: .match(h1), start: R.Start(date: named, from: .name), duration: 3,
                                  tracks: (1, 1), appVersion: "1", osVersion: "1", made: named, lang: "en", tz: utc)
        check(value(namedStart, "Start") == "2026-10-05 14:00 +00:00 (from the file name, to the minute)", "start from the name: to the minute", value(namedStart, "Start"))
        let pt = fields(.match(h1), "pt")
        check(value(pt, "Duração") == "01:02:05" && value(pt, "Faixas") == "1 de vídeo, 2 de áudio" && value(pt, "Como conferir").contains("shasum -a 256 -c"), "pt lines")
        for (l, f) in [("en", ok), ("pt", pt), ("en miss", miss), ("pt miss", missPt), ("bad", bad), ("inv", inv), ("unread", unread)] {
            check(!f.contains { $0.label.contains("\u{2014}") || $0.value.contains("\u{2014}") || $0.value.contains("\u{2013}") }, "no em or en dash: \(l)")
        }
        check(R.isCode(h1) && R.isCode("shasum -a 256 x") && !R.isCode("Weekly meeting"), "hashes and commands are set as code")

        // The PDF.
        let d = R.pdf(fields: ok, title: "Integrity report: " + name, page: R.page(lang: "en"))
        check(d.starts(with: Array("%PDF".utf8)), "the PDF starts with %PDF")
        let doc = PDFDocument(data: d)
        check(doc != nil && doc!.pageCount >= 1, "PDFKit opens it")
        let txt = pdfText(d)
        check(noSpace(txt).contains(h1), "PDFKit reads the hash back", String(txt.prefix(400)))
        check(noSpace(txt).contains(noSpace("shasum -a 256 -c '\(name).sha256'")), "the PDF has the verification command")
        check(txt.contains("Integrity report"), "the PDF has the title")
        if let p = doc?.page(at: 0) { let b = p.bounds(for: .mediaBox); check(b.width == 612 && b.height == 792, "en is US Letter") }
        let a4 = R.pdf(fields: pt, title: "x", page: R.page(lang: "pt"))
        if let p = PDFDocument(data: a4)?.page(at: 0) { let b = p.bounds(for: .mediaBox); check(b.width == 595 && b.height == 842, "pt is A4") }
        let many = (0..<80).map { (label: "L\($0)", value: "line \($0) " + h1) }
        let long = R.pdf(fields: many, title: "long", page: R.page(lang: "pt"))
        check((PDFDocument(data: long)?.pageCount ?? 0) > 1 && noSpace(pdfText(long)).contains("line79" + h1), "a long report flows onto more pages, nothing cut")

        // write: next to the recording, never touching it.
        let dir = NSTemporaryDirectory() + "ipsio-report-test-\(getpid())"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let mov = dir + "/" + name
        check(makeMov(mov, seconds: 3), "the synthetic .mov is made")
        Evidence.write(for: mov)
        let before = Evidence.sha256(mov), shaBefore = try? Data(contentsOf: URL(fileURLWithPath: mov + ".sha256"))
        let mtime = (try? FileManager.default.attributesOfItem(atPath: mov))?[.modificationDate] as? Date
        var out = ""
        do { out = try R.write(media: mov, lang: "en") } catch { check(false, "write succeeds", "\(error)") }
        check(out == dir + "/2026-10-05_14-00 Weekly.integrity.pdf" && FileManager.default.fileExists(atPath: out), "the report is next to the recording", out)
        check(Evidence.sha256(mov) == before && before != nil, "the recording is the same, byte for byte")
        check((try? Data(contentsOf: URL(fileURLWithPath: mov + ".sha256"))) == shaBefore && shaBefore != nil, "the .sha256 is the same")
        check(((try? FileManager.default.attributesOfItem(atPath: mov))?[.modificationDate] as? Date) == mtime, "the recording's date is the same")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        check(left.sorted() == [name, name + ".sha256", "2026-10-05_14-00 Weekly.integrity.pdf"].sorted(), "no temporary file left", "\(left)")
        let written = (try? Data(contentsOf: URL(fileURLWithPath: out))) ?? Data()
        let wt = noSpace(pdfText(written))
        check(wt.contains(before ?? "-") && wt.contains("matchesthefile"), "the written report has the real hash and the match", String(wt.prefix(600)))
        check(wt.contains("00:00:03") && wt.contains("0video,1audio"), "the written report has the length and tracks from AVFoundation")

        // The .sha256 changed: the report says so.
        try? "\(h1)  \(name)\n".write(toFile: mov + ".sha256", atomically: true, encoding: .utf8)
        _ = try? R.write(media: mov, lang: "en")
        let t2 = noSpace(pdfText((try? Data(contentsOf: URL(fileURLWithPath: out))) ?? Data()))
        check(t2.contains("DOESNOTMATCH") && t2.contains(before ?? "-"), "a different .sha256 reads DOES NOT MATCH")
        // No .sha256: the report says so, and still does not create one.
        try? FileManager.default.removeItem(atPath: mov + ".sha256")
        _ = try? R.write(media: mov, lang: "pt")
        let t3 = noSpace(pdfText((try? Data(contentsOf: URL(fileURLWithPath: out))) ?? Data()))
        check(t3.contains("NÃOHÁARQUIVODEPROVA"), "no .sha256 reads NO EVIDENCE FILE", String(t3.prefix(600)))
        check(!FileManager.default.fileExists(atPath: mov + ".sha256"), "the report never writes a .sha256")
        check(Evidence.sha256(mov) == before, "the recording is still the same")

        // Refusals: only a recording gets a report.
        for bad in [mov + ".sha256", dir + "/notes.txt", dir + "/x.integrity.pdf", dir + "/plain"] {
            FileManager.default.createFile(atPath: bad, contents: Data("x".utf8))
            var refused = false
            do { try R.write(media: bad, lang: "en") } catch Report.Failure.refused { refused = true } catch {}
            check(refused, "refused: \((bad as NSString).lastPathComponent)")
            check((try? String(contentsOfFile: bad, encoding: .utf8)) == "x", "and left as it was: \((bad as NSString).lastPathComponent)")
            try? FileManager.default.removeItem(atPath: bad)
        }
        var missing = false
        do { try R.write(media: dir + "/gone.mov", lang: "en") } catch Report.Failure.missing { missing = true } catch {}
        check(missing, "a recording that is not there is an error, not an empty report")
        check(!FileManager.default.fileExists(atPath: dir + "/gone.integrity.pdf"), "and no report is left for it")
        check(R.output(for: "/a/b.mov") == "/a/b.integrity.pdf" && R.output(for: "/a/b.MKV") == "/a/b.integrity.pdf", "the report's name")
        // A .mkv (the script engine): AVFoundation cannot read it; the report says unknown.
        let mkv = dir + "/2026-10-05_15-00 Old.mkv"
        FileManager.default.createFile(atPath: mkv, contents: Data(repeating: 7, count: 1000))
        if let o = try? R.write(media: mkv, lang: "en") {
            let t = pdfText((try? Data(contentsOf: URL(fileURLWithPath: o))) ?? Data())
            check(t.contains("unknown") && t.contains("NO EVIDENCE FILE") && noSpace(t).contains(Evidence.sha256(mkv) ?? "-"), "an unreadable .mkv: unknown length, real hash")
        } else { check(false, "a .mkv gets a report") }

        print("\(total - fails)/\(total) ok")
        exit(fails == 0 ? 0 : 1)
    }
}
