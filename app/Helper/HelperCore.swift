// HelperCore.swift: the pure half of the helper mode (Ipsio 1.1). While a
// meeting, a condo assembly or a debate is recorded, Ipsio listens to both
// tracks (Me = the microphone, Others = the computer sound), keeps a map of
// the arguments of each side and, when the other side finishes a turn, asks a
// brain (on this Mac, or the cloud with the user's own key) for one to three
// short tips. No AppKit, no network and no clock here: the caller passes the
// time, so the bench drives every rule.
//
// What lives here: the rolling transcript window and its running summary, the
// mic echo filter, the argument ledger, when to ask (cadence), the tip dedup,
// the prompts (pt, en), the parse of the brain's answer, which brain may run
// (consent, key, off), secret hygiene, and the "<name>.helper.md" summary.
import Foundation

/// One finished line heard live; `t` in seconds from the start of the helper.
struct HeardLine: Equatable {
    var t: Double, speaker: Speaker, text: String
}

/// One argument in the ledger.
struct Claim: Equatable {
    enum Kind: String, CaseIterable { case claim, unsupported, contradiction, concession, weak }
    var t: Double, side: Speaker, text: String, kind: Kind
}

/// One tip shown in the panel.
struct HelperTip: Equatable {
    var t: Double, text: String, why: String, answers: String, source: String?
}

/// What a brain answers, already parsed.
struct BrainReply: Equatable {
    var summary: String = ""
    var claims: [(side: Speaker, text: String, kind: Claim.Kind)] = []
    var tips: [(text: String, why: String, answers: String, source: String?)] = []
    static func == (a: BrainReply, b: BrainReply) -> Bool {
        a.summary == b.summary && a.claims.map { "\($0.side)|\($0.text)|\($0.kind)" } == b.claims.map { "\($0.side)|\($0.text)|\($0.kind)" }
            && a.tips.map { "\($0.text)|\($0.why)|\($0.answers)|\($0.source ?? "")" } == b.tips.map { "\($0.text)|\($0.why)|\($0.answers)|\($0.source ?? "")" }
    }
}

/// What is sent to a brain: the instructions and the state, in the meeting language.
struct HelperRequest: Equatable {
    var system: String, prompt: String, lang: String, research: Bool
}

enum HelperBrainKind: String { case local, cloud }

/// A brain: given the running state (as a request), the tips. Injected, so
/// the bench uses a fake one.
protocol HelperBrain: AnyObject {
    var kind: HelperBrainKind { get }
    func reply(to r: HelperRequest) async throws -> BrainReply
}

// ---- when to ask ----

/// Ask after the other side finishes a turn: Others paused for more than
/// `pause` seconds after at least `minWords` words since the last request;
/// never more often than every `minGap` seconds; one request in flight at most;
/// after an error, wait `minGap * 2^failures` (up to `maxBackoff`).
struct Cadence: Equatable {
    static let pause = 2.0, minWords = 15, minGap = 20.0, maxBackoff = 300.0
    private(set) var inFlight = false
    private(set) var lastAsk: Double?
    private(set) var failures = 0
    private(set) var notBefore = -Double.infinity

    func shouldAsk(now: Double, othersWords: Int, othersLastHeard: Double?) -> Bool {
        guard !inFlight, othersWords >= Cadence.minWords, let heard = othersLastHeard else { return false }
        guard now - heard > Cadence.pause else { return false }
        if let l = lastAsk, now - l < Cadence.minGap { return false }
        return now >= notBefore
    }
    mutating func begin(now: Double) { inFlight = true; lastAsk = now }
    mutating func end(ok: Bool, now: Double) {
        inFlight = false
        if ok { failures = 0; notBefore = -Double.infinity; return }
        failures += 1
        notBefore = now + min(Cadence.maxBackoff, Cadence.minGap * pow(2, Double(failures)))
    }
}

// ---- text helpers ----

enum HelperText {
    /// Lowercased, accents folded, letters and digits only, single spaces.
    static func norm(_ s: String) -> String {
        let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let mapped = f.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }
    static func words(_ s: String) -> Int { s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count }
    /// One line, trimmed, at most `max` characters.
    static func clip(_ s: String, _ max: Int) -> String {
        let one = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return one.count <= max ? one : String(one.prefix(max - 3)) + "..."
    }
    /// "MM:SS" (or "H:MM:SS") from seconds.
    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s)); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// ---- the microphone hears the speakers ----

enum Echo {
    static let within = 6.0, overlap = 0.6, minWords = 3
    /// A line on Me that repeats what Others said a moment ago is the
    /// loudspeaker in the microphone, not the user: dropped.
    static func isEcho(_ me: HeardLine, recentOthers: [HeardLine]) -> Bool {
        guard me.speaker == .me else { return false }
        let mine = HelperText.norm(me.text).split(separator: " ").map(String.init)
        guard mine.count >= minWords else { return false }
        for o in recentOthers where o.speaker == .others && abs(me.t - o.t) <= within {
            let theirs = Set(HelperText.norm(o.text).split(separator: " ").map(String.init))
            let shared = mine.filter { theirs.contains($0) }.count
            if Double(shared) / Double(mine.count) >= overlap { return true }
        }
        return false
    }
}

// ---- the state ----

struct HelperState {
    static let windowSeconds = 300.0        // the last 5 minutes go to the brain word for word
    static let summaryMax = 2000            // older content, compacted
    static let dedupSeconds = 600.0         // a tip is not repeated within 10 minutes
    static let promptMax = 6000             // characters of recent transcript (the local model has a small window)

    var lang: String
    private(set) var window: [HeardLine] = []
    private(set) var summary = ""
    private(set) var ledger: [Claim] = []
    private(set) var tips: [HelperTip] = []             // newest last
    private(set) var cadence = Cadence()
    private(set) var partial: [Speaker: (text: String, at: Double)] = [:]
    private(set) var othersWords = 0                    // since the last request
    private(set) var othersLastHeard: Double?
    private(set) var asked = 0, failed = 0

    init(lang: String) { self.lang = lang == "en" ? "en" : "pt" }

    /// A recognizer report: a partial (the line so far) or a final line.
    mutating func hear(_ who: Speaker, _ text: String, final: Bool, at now: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if final {
            partial[who] = nil
            guard !clean.isEmpty else { return }
            let line = HeardLine(t: now, speaker: who, text: clean)
            if Echo.isEcho(line, recentOthers: Array(window.suffix(20)) + (partial[.others].map { [HeardLine(t: $0.at, speaker: .others, text: $0.text)] } ?? [])) { return }
            window.append(line)
            if who == .others { othersWords += HelperText.words(clean); othersLastHeard = now }
        } else {
            if partial[who]?.text != clean { partial[who] = (clean, now); if who == .others && !clean.isEmpty { othersLastHeard = now } }
        }
        compact(now: now)
    }

    /// Lines older than the window leave it for the running summary (the
    /// tail kept when it grows past its limit).
    mutating func compact(now: Double) {
        var old: [HeardLine] = []
        while let f = window.first, now - f.t > HelperState.windowSeconds { old.append(window.removeFirst()) }
        guard !old.isEmpty else { return }
        let add = old.map { "\($0.speaker.rawValue): \(HelperText.clip($0.text, 200))" }.joined(separator: " / ")
        summary = summary.isEmpty ? add : summary + " / " + add
        if summary.count > HelperState.summaryMax { summary = String(summary.suffix(HelperState.summaryMax)) }
    }

    /// Words heard on Others since the last request, the line in progress included.
    var othersPending: Int { othersWords + HelperText.words(partial[.others]?.text ?? "") }

    func shouldAsk(now: Double) -> Bool {
        cadence.shouldAsk(now: now, othersWords: othersPending, othersLastHeard: othersLastHeard)
    }

    /// Starts a request: marks it in flight and builds what the brain reads.
    mutating func beginAsk(now: Double, research: Bool) -> HelperRequest {
        cadence.begin(now: now); othersWords = 0; asked += 1
        return HelperRequest(system: HelperPrompt.system(lang: lang, research: research),
                             prompt: HelperPrompt.user(self, now: now, lang: lang), lang: lang, research: research)
    }

    /// The brain answered (or failed): the ledger grows, the new tips that are
    /// not repeats are returned (newest first, for the panel).
    @discardableResult
    mutating func finishAsk(_ r: Result<BrainReply, Error>, now: Double) -> [HelperTip] {
        switch r {
        case .failure:
            cadence.end(ok: false, now: now); failed += 1; return []
        case .success(let reply):
            cadence.end(ok: true, now: now)
            if !reply.summary.isEmpty { summary = String(HelperText.clip(reply.summary, HelperState.summaryMax)) }
            for c in reply.claims {
                let n = HelperText.norm(c.text)
                let side = heardSide(of: c.text) ?? c.side
                if n.isEmpty || ledger.contains(where: { $0.side == side && HelperText.norm($0.text) == n }) { continue }
                ledger.append(Claim(t: now, side: side, text: HelperText.clip(c.text, 240), kind: c.kind))
            }
            var fresh: [HelperTip] = []
            for t in reply.tips {
                let tip = HelperTip(t: now, text: t.text, why: t.why, answers: t.answers, source: t.source)
                if accept(tip, now: now) { tips.append(tip); fresh.append(tip) }
            }
            return fresh.reversed()
        }
    }

    /// Who said a claim, from the track: when the claim repeats most of the
    /// words of a heard line, that line's speaker wins over the brain's guess
    /// (a small model mixes the sides up). nil when no line matches.
    func heardSide(of claim: String) -> Speaker? {
        let mine = HelperText.norm(claim).split(separator: " ").map(String.init)
        guard mine.count >= 3 else { return nil }
        var best: (score: Double, who: Speaker)?
        for l in window {
            let theirs = Set(HelperText.norm(l.text).split(separator: " ").map(String.init))
            let score = Double(mine.filter { theirs.contains($0) }.count) / Double(mine.count)
            if score >= 0.7, score > (best?.score ?? 0) { best = (score, l.speaker) }
        }
        return best?.who
    }

    /// Dedup: a tip whose normalized text matches one shown in the last 10 minutes is dropped.
    func accept(_ tip: HelperTip, now: Double) -> Bool {
        let n = HelperText.norm(tip.text)
        guard !n.isEmpty else { return false }
        return !tips.contains { now - $0.t < HelperState.dedupSeconds && HelperText.norm($0.text) == n }
    }

    /// The recent transcript as the brain reads it, newest kept when too long.
    func recentText(limit: Int = HelperState.promptMax) -> String {
        var lines = window.map { "[\(HelperText.clock($0.t))] \($0.speaker.rawValue): \($0.text)" }
        for (who, p) in partial.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !p.text.isEmpty {
            lines.append("[\(HelperText.clock(p.at))] \(who.rawValue): \(p.text)")
        }
        var out: [String] = [], size = 0
        for l in lines.reversed() { if size + l.count > limit { break }; out.append(l); size += l.count + 1 }
        return out.reversed().joined(separator: "\n")
    }
}

// ---- prompts ----

enum HelperPrompt {
    static func system(lang: String, research: Bool) -> String {
        if lang == "en" {
            var s = """
            You help the user (Me) argue better, live, in a meeting, an assembly or a debate. Others are the other participants.
            Rules: be concise, respectful, persuasive and factual. No insults, no personal attacks, no deceptive or manipulative tactics.
            Never invent facts, numbers, laws or quotes. If something needs checking, say so in the tip.
            Each tip: 1 to 3 short lines the user can say or do now, and a "why" that names the claim it answers.
            Spot weak points, contradictions, unsupported claims and concessions on both sides; suggest the next line of argument.
            A claim from a line marked "Me:" has side "me"; from a line marked "Others:", side "others".
            Answer in English, only with the JSON asked for.
            """
            if research { s += "\nYou may search the web to check the Others' claims. A tip that uses a search result must put its URL in \"source\"." }
            return s
        }
        var s = """
        Você ajuda o usuário (Me) a argumentar melhor, ao vivo, numa reunião, assembleia ou debate. Others são os demais participantes.
        Regras: seja conciso, respeitoso, persuasivo e factual. Sem insultos, sem ataques pessoais, sem táticas enganosas ou manipuladoras.
        Nunca invente fatos, números, leis ou citações. Se algo precisa ser conferido, diga isso na dica.
        Cada dica: 1 a 3 linhas curtas que o usuário pode dizer ou fazer agora, e um "why" que nomeia a afirmação que ela responde.
        Aponte pontos fracos, contradições, afirmações sem prova e concessões dos dois lados; sugira a próxima linha de argumento.
        Uma afirmação de uma linha marcada "Me:" tem side "me"; de uma linha marcada "Others:", side "others".
        Responda em português (text, why, answers e summary), só com o JSON pedido.
        """
        if research { s += "\nVocê pode pesquisar na web para conferir as afirmações dos Others. Uma dica que usa um resultado de pesquisa deve pôr a URL em \"source\"." }
        return s
    }

    static let format = """
    {"summary": "...", "claims": [{"side": "others" or "me", "text": "...", "kind": "claim" | "unsupported" | "contradiction" | "concession" | "weak"}], "tips": [{"text": "...", "why": "...", "answers": "...", "source": ""}]}
    """

    static func user(_ s: HelperState, now: Double, lang: String) -> String {
        let en = lang == "en"
        var out = ""
        if !s.summary.isEmpty { out += (en ? "Earlier in the meeting (summary):\n" : "Antes, na reunião (resumo):\n") + s.summary + "\n\n" }
        if !s.ledger.isEmpty {
            out += en ? "Arguments so far:\n" : "Argumentos até aqui:\n"
            for c in s.ledger.suffix(30) { out += "- \(c.side.rawValue) [\(c.kind.rawValue)]: \(c.text)\n" }
            out += "\n"
        }
        out += (en ? "Recent transcript (Me = the user, Others = the other participants):\n" : "Transcrição recente (Me = o usuário, Others = os demais):\n") + s.recentText() + "\n\n"
        let given = s.tips.filter { now - $0.t < HelperState.dedupSeconds }.suffix(10)
        if !given.isEmpty {
            out += (en ? "Tips already given (do not repeat):\n" : "Dicas já dadas (não repita):\n") + given.map { "- " + $0.text }.joined(separator: "\n") + "\n\n"
        }
        out += (en ? "Answer with this JSON only, at most 3 tips:\n" : "Responda só com este JSON, no máximo 3 dicas:\n") + format
        return out
    }
}

// ---- the brain's answer ----

enum HelperParse {
    static let maxTips = 3, tipMax = 280, whyMax = 400

    /// The JSON object in `text` (the first "{" to the last "}"), parsed.
    /// `citations`: the URLs a cloud search returned; a tip's source outside
    /// them is dropped (an invented link never reaches the panel). nil = no
    /// search ran, so no source is kept at all.
    static func reply(_ text: String, citations: Set<String>?) -> BrainReply? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any] else { return nil }
        var r = BrainReply()
        r.summary = (obj["summary"] as? String) ?? ""
        for c in (obj["claims"] as? [[String: Any]]) ?? [] {
            guard let txt = c["text"] as? String, let side = side(c["side"] as? String) else { continue }
            let kind = Claim.Kind(rawValue: ((c["kind"] as? String) ?? "claim").lowercased()) ?? .claim
            if !txt.trimmingCharacters(in: .whitespaces).isEmpty { r.claims.append((side, txt, kind)) }
        }
        for t in (obj["tips"] as? [[String: Any]]) ?? [] {
            guard let raw = t["text"] as? String else { continue }
            let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(3)
            let txt = lines.map { HelperText.clip($0, tipMax) }.joined(separator: "\n")
            if txt.isEmpty { continue }
            var src = (t["source"] as? String)?.trimmingCharacters(in: .whitespaces)
            if let s = src, !(s.hasPrefix("https://") || s.hasPrefix("http://")) || !(citations?.contains(s) ?? false) { src = nil }
            r.tips.append((txt, HelperText.clip((t["why"] as? String) ?? "", whyMax), HelperText.clip((t["answers"] as? String) ?? "", tipMax), src))
            if r.tips.count == maxTips { break }
        }
        return r
    }

    /// "me" / "Me" / "eu" is the user; "others" / "Others" / "outros" the rest; anything else unknown.
    static func side(_ s: String?) -> Speaker? {
        switch (s ?? "").lowercased().trimmingCharacters(in: .whitespaces) {
        case "me", "eu", "user", "usuário", "usuario": return .me
        case "others", "outros", "other", "them": return .others
        default: return nil
        }
    }
}

// ---- which brain may run ----

enum HelperConf {
    static let mode = "HELPER_MODE", brain = "HELPER_BRAIN", model = "HELPER_MODEL", consent = "HELPER_CLOUD_CONSENT"
    static func on(_ c: [String: String]) -> Bool { c[mode] == "1" }
    static func wantsCloud(_ c: [String: String]) -> Bool { c[brain] == "cloud" }
    static func cloudModel(_ c: [String: String]) -> String {
        let m = (c[model] ?? "").trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? "claude-sonnet-5-5" : m
    }
}

enum BrainChoice: Equatable {
    case off, local, cloud
    case unavailable(String)     // the local model's reason (a HelperTexts key)
    case needsKey, needsConsent
}

enum HelperPolicy {
    /// Off unless HELPER_MODE='1'. The cloud runs only when chosen AND the
    /// user gave a key AND consented; it is never a fallback for the local
    /// brain (the menu offers it, the user picks it).
    static func choose(conf c: [String: String], localUnavailable: String?, hasKey: Bool) -> BrainChoice {
        guard HelperConf.on(c) else { return .off }
        if HelperConf.wantsCloud(c) {
            guard hasKey else { return .needsKey }
            guard c[HelperConf.consent] == "1" else { return .needsConsent }
            return .cloud
        }
        if let why = localUnavailable { return .unavailable(why) }
        return .local
    }
}

// ---- secrets ----

enum HelperSecrets {
    /// Any Anthropic key ("sk-ant-...") and the given key itself, hidden.
    static func redact(_ s: String, key: String? = nil) -> String {
        var out = s
        if let k = key, k.count >= 8 { out = out.replacingOccurrences(of: k, with: "(key hidden)") }
        while let r = out.range(of: "sk-ant-[A-Za-z0-9_\\-]+", options: .regularExpression) { out.replaceSubrange(r, with: "(key hidden)") }
        return out
    }
    /// The conf without any helper value that holds a key: the key lives in
    /// the Keychain only. Other keys of the conf are not the helper's to judge.
    static func scrub(_ c: [String: String], key: String? = nil) -> [String: String] {
        c.filter { k, v in !k.hasPrefix("HELPER_") || redact(v, key: key) == v }
    }
}

// ---- the summary next to the recording ----

enum HelperSummary {
    static func path(for media: String) -> String { (media as NSString).deletingPathExtension + ".helper.md" }

    static func md(title: String, lang: String, brain: String, state s: HelperState) -> String {
        let en = lang == "en"
        var out = "# \(HelperText.clip(title, 200))\n\n"
        out += en ? "Helper mode: arguments and tips (\(brain)). Me = the microphone track, Others = the computer sound.\n\n"
                  : "Modo ajudante: argumentos e dicas (\(brain)). Me = a faixa do microfone, Others = o som do computador.\n\n"
        out += en ? "## Arguments\n\n" : "## Argumentos\n\n"
        for side in [Speaker.others, .me] {
            let mine = s.ledger.filter { $0.side == side }
            out += "### \(side.rawValue)\n\n"
            out += mine.isEmpty ? (en ? "_(none)_\n\n" : "_(nenhum)_\n\n")
                : mine.map { "- [\(HelperText.clock($0.t))] \($0.text) (\(kindLabel($0.kind, en)))" }.joined(separator: "\n") + "\n\n"
        }
        out += en ? "## Tips given\n\n" : "## Dicas dadas\n\n"
        if s.tips.isEmpty { out += en ? "_(none)_\n" : "_(nenhuma)_\n" }
        for t in s.tips {
            out += "- [\(HelperText.clock(t.t))] " + t.text.replacingOccurrences(of: "\n", with: " / ") + "\n"
            if !t.why.isEmpty { out += "  - " + (en ? "why: " : "por quê: ") + t.why + "\n" }
            if !t.answers.isEmpty { out += "  - " + (en ? "answers: " : "responde a: ") + t.answers + "\n" }
            if let src = t.source { out += "  - " + (en ? "source: " : "fonte: ") + src + "\n" }
        }
        if !s.summary.isEmpty { out += (en ? "\n## Summary\n\n" : "\n## Resumo\n\n") + s.summary + "\n" }
        return out
    }

    static func kindLabel(_ k: Claim.Kind, _ en: Bool) -> String {
        switch k {
        case .claim: return en ? "claim" : "afirmação"
        case .unsupported: return en ? "unsupported" : "sem prova"
        case .contradiction: return en ? "contradiction" : "contradição"
        case .concession: return en ? "concession" : "concessão"
        case .weak: return en ? "weak point" : "ponto fraco"
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case refused(String), write(String)
        var description: String {
            switch self {
            case .refused(let s): return "refused to write \(s): it would replace the recording or its evidence"
            case .write(let s): return "could not write \(s)"
            }
        }
    }

    /// Writes "<name>.helper.md" next to `media` through a temporary file and a
    /// rename. The recording (.mov, .mkv) and any .sha256 are never written.
    @discardableResult
    static func write(_ body: String, media: String) throws -> String {
        let ext = (media as NSString).pathExtension.lowercased()
        guard ["mov", "mkv", "mp4", "m4a"].contains(ext) else { throw Failure.refused(media) }
        let p = path(for: media)
        let pe = (p as NSString).pathExtension.lowercased()
        if p == media || p == media + ".sha256" || pe == "mov" || pe == "mkv" || pe == "sha256" { throw Failure.refused(p) }
        let tmp = p + ".tmp"
        do { try body.write(toFile: tmp, atomically: false, encoding: .utf8) }
        catch { try? FileManager.default.removeItem(atPath: tmp); throw Failure.write(p) }
        if rename(tmp, p) != 0 { try? FileManager.default.removeItem(atPath: tmp); throw Failure.write(p) }
        return p
    }
}

// ---- live recognition: when to close an utterance ----

enum LiveCut {
    static let quiet = 1.5, longest = 50.0
    /// The recognizer gives a final line only when its request ends: end it
    /// after `quiet` seconds without a change, or when it nears the minute
    /// SFSpeechRecognizer allows a request.
    static func shouldCut(requestStarted: Double, lastChange: Double?, hasText: Bool, now: Double) -> Bool {
        if now - requestStarted >= longest { return true }
        guard hasText, let l = lastChange else { return false }
        return now - l >= quiet
    }
}
