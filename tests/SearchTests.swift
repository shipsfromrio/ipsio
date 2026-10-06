// SearchTests.swift: the bench for Search (accents, AND, the transcript line,
// file names, order, limit, and that nothing on disk changes). Compiles alone:
//   swiftc -parse-as-library app/Search.swift tests/SearchTests.swift -o /tmp/search-tests && /tmp/search-tests
// Works in a temporary folder it deletes. Exits 1 if any assertion fails.
import Foundation

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}

@main
struct SearchTests {
    static func main() {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "ipsio-search-" + UUID().uuidString
        try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        func put(_ name: String, _ body: String, age: Double) {
            let p = dir + "/" + name
            try! body.write(toFile: p, atomically: true, encoding: .utf8)
            try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 - age)], ofItemAtPath: p)
        }

        // The line format.
        let p = Search.parse("[01:02:03] Me: a ação começa")
        check(p?.seconds == 3723 && p?.speaker == "Me" && p?.text == "a ação começa", "offset and speaker of a line", "\(String(describing: p))")
        check(Search.parse("[00:00:07] Others: ok: two colons")?.text == "ok: two colons", "the text keeps its own colons")
        check(Search.parse("[123:00:00] Others: long")?.seconds == 123 * 3600, "more than 99 hours")
        for bad in ["(no speech found)", "", "[00:00] Me: x", "[aa:00:00] Me: x", "[00:61:00] Me: x", "[00:00:01]Me: x",
                    "[00:00:01] Me x", "[00:00:01] : x", "[00:00:01] Two words: x", "plain text"] {
            check(Search.parse(bad) == nil, "not a transcript line: '\(bad)'")
        }
        check(Search.clock(3723) == "01:02:03" && Search.clock(0) == "00:00:00" && Search.clock(-5) == "00:00:00", "the clock")

        // Folding and AND.
        check(Search.matches("A AÇÃO começa", Search.terms("acao")), "acao finds ação")
        check(Search.matches("a acao comeca", Search.terms("AÇÃO Começa")), "ação finds acao")
        check(Search.matches("orçamento de março", Search.terms("marco orcamento")), "all words, any order")
        check(!Search.matches("orçamento de abril", Search.terms("marco orcamento")), "one word missing: no match (AND)")
        check(!Search.matches("anything", Search.terms("   ")) && Search.terms(" a  b ") == ["a", "b"], "blank query matches nothing")

        // A folder: two recordings with transcripts, one without, notes, a transcript alone.
        put("2026-10-01_10-00 Planning.mov", "x", age: 3000)
        put("2026-10-01_10-00 Planning.mov.sha256", "x", age: 3000)
        put("2026-10-01_10-00 Planning.txt",
            "[00:00:05] Me: bom dia, vamos ver a ação do orçamento\n[00:01:00] Others: a acao fica para março\n[00:02:00] Others: nada a ver\n",
            age: 3000)
        put("2026-10-01_10-00 Planning.srt", "1\n00:00:05,000 --> 00:00:06,000\nMe: ação\n\n", age: 3000)
        put("2026-10-02_09-00 Ação Social.mkv", "x", age: 1000)
        put("2026-10-02_09-00 Ação Social.txt", "[00:10:00] Others: outra ação\n[00:00:30] Me: primeira ação\n", age: 1000)
        put("2026-10-03_08-00 Daily.mov", "x", age: 10)
        put("2026-09-30_08-00 Orphan.txt", "[00:00:09] Me: ação sem vídeo\n", age: 5000)
        put("notes.md", "ação", age: 1)
        try! fm.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        try! "[00:00:01] Me: ação\n".write(toFile: dir + "/sub/Deep.txt", atomically: true, encoding: .utf8)
        func listing() -> [String: Date] {
            var out: [String: Date] = [:]
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                out[n] = (try? fm.attributesOfItem(atPath: dir + "/" + n))?[.modificationDate] as? Date
            }
            return out
        }
        let before = listing()

        let all = Search.find(query: "acao", in: dir)
        let desc = all.map { "\(($0.media as NSString).lastPathComponent)@\($0.seconds)/\($0.speaker)" }
        check(desc == ["2026-10-02_09-00 Ação Social.mkv@0/", "2026-10-02_09-00 Ação Social.mkv@30/Me", "2026-10-02_09-00 Ação Social.mkv@600/Others",
                       "2026-10-01_10-00 Planning.mov@5/Me", "2026-10-01_10-00 Planning.mov@60/Others",
                       "2026-09-30_08-00 Orphan.txt@9/Me"],
              "newest recording first, file name first, then by time; no .srt, .md or subfolder", "\(desc)")
        check(all.first?.transcript == nil && all.first?.snippet == "2026-10-02_09-00 Ação Social.mkv", "a file-name hit has no transcript")
        check(all[1].transcript == dir + "/2026-10-02_09-00 Ação Social.txt" && all[1].snippet == "primeira ação", "a line hit: transcript and snippet")
        check(all[3].media == dir + "/2026-10-01_10-00 Planning.mov", "the hit points at the .mov next to the .txt")
        check(all.last?.media == dir + "/2026-09-30_08-00 Orphan.txt", "a transcript without its recording points at itself")

        let both = Search.find(query: "acao orcamento", in: dir)
        check(both.count == 1 && both[0].seconds == 5, "AND across a line", "\(both)")
        check(Search.find(query: "acao marco", in: dir).map { $0.seconds } == [60], "AND: both words in one line")
        check(Search.find(query: "daily", in: dir).map { ($0.media as NSString).lastPathComponent } == ["2026-10-03_08-00 Daily.mov"],
              "a recording found by its name alone")
        check(Search.find(query: "Others", in: dir).isEmpty, "the speaker label is not searched as text")
        check(Search.find(query: "acao", in: dir, limit: 2).count == 2 && Search.find(query: "acao", in: dir, limit: 2) == Array(all.prefix(2)),
              "the limit keeps the first hits")
        check(Search.find(query: "acao", in: dir, limit: 0).isEmpty, "limit 0: nothing")
        check(Search.find(query: "", in: dir).isEmpty, "empty query: nothing")
        check(Search.find(query: "acao", in: dir + "/missing").isEmpty, "a missing folder: nothing, no crash")

        // An unreadable transcript is skipped; the others still answer.
        put("2026-10-04_08-00 Locked.txt", "[00:00:01] Me: ação trancada\n", age: 0)
        chmod(dir + "/2026-10-04_08-00 Locked.txt", 0)
        let locked = Search.find(query: "acao", in: dir)
        let canRead = fm.isReadableFile(atPath: dir + "/2026-10-04_08-00 Locked.txt")   // root reads anyway
        check(canRead || (locked.count == all.count && !locked.contains { $0.snippet.contains("trancada") }), "an unreadable file is skipped")
        chmod(dir + "/2026-10-04_08-00 Locked.txt", 0o644)
        try? fm.removeItem(atPath: dir + "/2026-10-04_08-00 Locked.txt")
        // Not UTF-8: skipped too.
        try! Data([0x5b, 0xff, 0xfe, 0x0a]).write(to: URL(fileURLWithPath: dir + "/2026-10-04_09-00 Bad.txt"))
        check(Search.find(query: "acao", in: dir) == all, "a transcript that is not UTF-8 is skipped")
        try? fm.removeItem(atPath: dir + "/2026-10-04_09-00 Bad.txt")

        check(listing() == before, "nothing in the folder was written, renamed or deleted")
        check(!(try! fm.contentsOfDirectory(atPath: dir)).contains { $0.hasSuffix(".tmp") }, "no temporary file left")

        print("\(total - fails)/\(total) ok")
        exit(fails == 0 ? 0 : 1)
    }
}
