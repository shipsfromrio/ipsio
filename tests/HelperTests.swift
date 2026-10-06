// HelperTests.swift: the bench for the helper mode's pure core (cadence,
// dedup, sides, echo, window, prompts, parse, which brain may run, secrets,
// the summary) and the cloud brain against a fake HTTP server (no network).
// Compiles with:
//   swiftc -parse-as-library app/Transcribe/Transcript.swift app/Helper/HelperCore.swift app/Helper/HelperTexts.swift \
//     app/Helper/HelperCloud.swift tests/HelperTests.swift -o /tmp/helper-tests && /tmp/helper-tests
// Exits 1 if any assertion fails.
import Foundation

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}
func words(_ n: Int, _ w: String = "argumento") -> String { Array(repeating: w, count: n).joined(separator: " ") }

/// A brain that answers what the test says and records what it was asked.
final class FakeBrain: HelperBrain {
    let kind: HelperBrainKind
    var answer: Result<BrainReply, Error>
    var asked: [HelperRequest] = []
    init(_ kind: HelperBrainKind = .local, _ a: Result<BrainReply, Error>) { self.kind = kind; answer = a }
    func reply(to r: HelperRequest) async throws -> BrainReply { asked.append(r); return try answer.get() }
}
struct Boom: Error {}

/// The fake server: every request the cloud brain makes lands here.
final class FakeHTTP: URLProtocol {
    static var requests: [URLRequest] = []
    static var answer: (Int, Data) = (200, Data())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        FakeHTTP.requests.append(request)
        let r = HTTPURLResponse(url: request.url!, statusCode: FakeHTTP.answer.0, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: FakeHTTP.answer.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func fakeSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [FakeHTTP.self]
    return URLSession(configuration: c)
}
func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

let replyJSON = """
Aqui está: {"summary": "Debate sobre a reforma da fachada.", "claims": [
  {"side": "others", "text": "A obra custa 200 mil", "kind": "unsupported"},
  {"side": "me", "text": "Temos três orçamentos", "kind": "claim"},
  {"side": "Outros", "text": "Ninguém reclamou antes", "kind": "weak"},
  {"side": "juiz", "text": "lado desconhecido", "kind": "claim"}],
 "tips": [{"text": "Peça a planilha do orçamento de 200 mil.", "why": "O valor foi dito sem prova.", "answers": "A obra custa 200 mil", "source": "https://exemplo.org/preco"},
          {"text": "Linha 1\\nLinha 2\\nLinha 3\\nLinha 4", "why": "", "answers": ""},
          {"text": "Terceira dica", "why": "w", "answers": "a"},
          {"text": "Quarta dica", "why": "w", "answers": "a"}]}
Fim.
"""

@main
struct HelperTests {
    static func main() async {
        // ---- cadence ----
        do {
            var s = HelperState(lang: "pt")
            s.hear(.others, words(10), final: true, at: 10)
            check(!s.shouldAsk(now: 20), "fewer than 15 words from the others: no request")
            s.hear(.me, words(30, "proposta"), final: true, at: 11)
            check(!s.shouldAsk(now: 20), "the user's own words do not count toward the others' turn")
            check(s.window.count == 2, "the user's line is heard (not an echo)")
            s.hear(.others, words(6), final: true, at: 30)
            check(!s.shouldAsk(now: 31.5), "the others still speaking (pause of 1.5 s): no request")
            s.hear(.others, "e mais uma coisa", final: false, at: 31.8)
            check(!s.shouldAsk(now: 33.5), "a partial line in progress resets the pause")
            check(s.shouldAsk(now: 34.0), "the others paused over 2 s after 15+ words: ask")
            let r = s.beginAsk(now: 34, research: false)
            s.hear(.others, words(20), final: true, at: 40)
            check(!s.shouldAsk(now: 60), "one request in flight at most")
            s.finishAsk(.success(BrainReply()), now: 45)
            check(!s.shouldAsk(now: 50), "never more often than every 20 s")
            check(s.shouldAsk(now: 54.5), "20 s after the last request it may ask again")
            check(r.prompt.contains("Others: argumento") && !r.research, "the request carries the transcript; local does not research")
            var s2 = HelperState(lang: "pt")
            s2.hear(.others, words(16), final: true, at: 1)
            _ = s2.beginAsk(now: 4, research: false); s2.finishAsk(.success(BrainReply()), now: 5)
            check(!s2.shouldAsk(now: 100) && s2.othersPending == 0, "after a request the others' count starts over")
        }
        do {
            var c = Cadence()
            check(c.shouldAsk(now: 100, othersWords: 15, othersLastHeard: 97), "exactly 15 words and 3 s of pause: ask")
            c.begin(now: 100)
            check(!c.shouldAsk(now: 200, othersWords: 50, othersLastHeard: 150), "in flight blocks every later ask")
            c.end(ok: false, now: 110)
            check(!c.shouldAsk(now: 140, othersWords: 50, othersLastHeard: 130), "after an error: back off 40 s")
            check(c.shouldAsk(now: 151, othersWords: 50, othersLastHeard: 130), "the backoff ends")
            c.begin(now: 151); c.end(ok: false, now: 152)
            check(!c.shouldAsk(now: 220, othersWords: 50, othersLastHeard: 200) && c.shouldAsk(now: 233, othersWords: 50, othersLastHeard: 200),
                  "a second error doubles the backoff (80 s)")
            c.begin(now: 233); c.end(ok: true, now: 234)
            check(c.shouldAsk(now: 254, othersWords: 50, othersLastHeard: 250), "a success clears the backoff")
            for _ in 0..<10 { c.begin(now: 0); c.end(ok: false, now: 1000) }
            check(c.shouldAsk(now: 1301, othersWords: 50, othersLastHeard: 1290), "the backoff stops at 5 minutes")
            check(!Cadence().shouldAsk(now: 10, othersWords: 50, othersLastHeard: nil), "nothing heard: no request")
            var v = HelperState(lang: "pt")
            v.hear(.others, words(20), final: true, at: 5)
            v.sound(.others, dB: -20, at: 9)
            check(!v.shouldAsk(now: 10) && v.shouldAsk(now: 11.5), "the others' sound holds the request until their pause, even with no new words")
            v.sound(.others, dB: -70, at: 12)
            check(v.shouldAsk(now: 12), "background noise is not the others talking")
            v.sound(.me, dB: -10, at: 12)
            check(v.shouldAsk(now: 12), "the user's voice does not hold the tips")
            v.hear(.others, "a linha final que chegou atrasada", final: true, at: 12.5)
            v.hear(.others, "um pedaço revisado", final: false, at: 12.6)
            check(v.shouldAsk(now: 12.7), "with the sound measured, a late line does not hold the request")
            var w = HelperState(lang: "pt")
            w.hear(.others, words(20), final: true, at: 5)
            w.hear(.others, "linha tardia", final: true, at: 7)
            check(!w.shouldAsk(now: 8) && w.shouldAsk(now: 9.5), "without the sound, the text says when the others pause")
        }

        // ---- the brain loop, with a fake brain ----
        do {
            var s = HelperState(lang: "pt")
            let reply = HelperParse.reply(replyJSON, citations: ["https://exemplo.org/preco"])!
            let brain = FakeBrain(.cloud, .success(reply))
            s.hear(.others, "A obra da fachada custa duzentos mil reais e todo mundo concorda que precisa ser feita agora mesmo", final: true, at: 5)
            check(s.shouldAsk(now: 8), "a long turn of the others triggers a request")
            let req = s.beginAsk(now: 8, research: brain.kind == .cloud)
            let got: Result<BrainReply, Error>
            do { got = .success(try await brain.reply(to: req)) } catch { got = .failure(error) }
            let fresh = s.finishAsk(got, now: 9)
            check(brain.asked.count == 1 && brain.asked[0].research, "the cloud brain is asked once, with research")
            check(fresh.count == 3 && fresh[0].text == "Terceira dica" && fresh[2].text.hasPrefix("Peça a planilha"), "new tips come newest first, at most 3",
                  fresh.map { $0.text }.joined(separator: " | "))
            check(s.ledger.count == 3, "the ledger takes the claims with a known side", "\(s.ledger.count)")
            check(s.ledger.first { $0.text.hasPrefix("A obra") }?.side == .others && s.ledger.first { $0.text.hasPrefix("Temos") }?.side == .me
                  && s.ledger.first { $0.text.hasPrefix("Ninguém") }?.side == .others, "each claim keeps its side")
            check(s.summary == "Debate sobre a reforma da fachada.", "the brain's summary replaces the running one")
            s.hear(.others, words(20), final: true, at: 30)
            let again = s.finishAsk(.success(reply), now: 40)
            check(again.isEmpty && s.tips.count == 3, "the same tips are not shown twice")
            check(s.ledger.count == 3, "the same claims are not added twice")
            let failed = s.finishAsk(.failure(Boom()), now: 41)
            check(failed.isEmpty && s.failed == 1 && s.cadence.failures == 1, "a failed request shows nothing and backs off")
        }

        // ---- dedup ----
        do {
            var s = HelperState(lang: "pt")
            var r = BrainReply(); r.tips = [("Pergunte pelo orçamento!", "", "", nil)]
            s.finishAsk(.success(r), now: 100)
            var r2 = BrainReply(); r2.tips = [("pergunte   pelo ORÇAMENTO", "", "", nil)]
            check(s.finishAsk(.success(r2), now: 400).isEmpty, "a tip that matches one from 5 min ago (case, accents, punctuation) is dropped")
            check(s.finishAsk(.success(r2), now: 701).count == 1, "after 10 minutes it may come back")
            check(!s.accept(HelperTip(t: 0, text: "  ", why: "", answers: "", source: nil), now: 0), "an empty tip is never shown")
            // Seen live: the on-device model rewrote the end of a tip it had given.
            var t = HelperState(lang: "pt")
            var r3 = BrainReply(); r3.tips = [("Pergunte ao empreiteiro sobre a planilha que ele mencionou.", "", "", nil)]
            t.finishAsk(.success(r3), now: 10)
            var r4 = BrainReply(); r4.tips = [("Pergunte ao empreiteiro sobre a planilha que está faltando.", "", "", nil),
                                              ("Pergunte ao responsável pelo orçamento se há uma planilha disponível.", "", "", nil)]
            let got = t.finishAsk(.success(r4), now: 40)
            check(got.count == 1 && got[0].text.hasPrefix("Pergunte ao responsável"), "a reworded repeat is dropped, a different tip on the same subject is kept",
                  got.map { $0.text }.joined(separator: " | "))
        }

        // ---- echo and sides ----
        do {
            var s = HelperState(lang: "pt")
            s.hear(.others, "o condomínio não tem dinheiro para pintar", final: true, at: 10)
            s.hear(.me, "condomínio não tem dinheiro para pintar", final: true, at: 12)
            check(s.window.count == 1 && s.window[0].speaker == .others, "the loudspeaker heard by the microphone is dropped (echo)")
            s.hear(.me, "condomínio não tem dinheiro para pintar", final: true, at: 40)
            check(s.window.count == 2 && s.window[1].speaker == .me, "the same words long after are the user's")
            var r = HelperState(lang: "pt")
            r.hear(.me, "a taxa extra vai ser de oitocentos reais", final: true, at: 70)
            r.hear(.others, "porque a taxa extra vai ser de oitocentos reais por mês", final: true, at: 71)
            check(r.window.count == 1 && r.window[0].speaker == .others, "an echo that came out before the others' line is dropped when that line arrives")
            r.hear(.me, "eu não concordo com essa taxa", final: true, at: 72)
            r.hear(.others, "a taxa é pequena", final: true, at: 73)
            check(r.window.count == 3 && r.window[1].speaker == .me, "the user's own line stays when the others speak next")
            s.hear(.me, "eu discordo totalmente desse valor", final: true, at: 41)
            check(s.window.count == 3, "a different line of the user is kept")
            check(!Echo.isEcho(HeardLine(t: 1, speaker: .me, text: "sim"), recentOthers: [HeardLine(t: 1, speaker: .others, text: "sim")]),
                  "a short 'yes' is not judged an echo")
            check(HelperParse.side("me") == .me && HelperParse.side("Eu") == .me && HelperParse.side("Others") == .others
                  && HelperParse.side("outros") == .others && HelperParse.side("juiz") == nil && HelperParse.side(nil) == nil, "sides from the brain's words")
            var mixed = BrainReply(); mixed.claims = [(.others, "Eu discordo totalmente desse valor.", .claim), (.me, "uma ideia que ninguém disse aqui", .weak)]
            s.finishAsk(.success(mixed), now: 42)
            check(s.ledger.first { $0.text.hasPrefix("Eu discordo") }?.side == .me, "a claim that repeats a heard line takes that line's side (the track wins)")
            check(s.ledger.first { $0.text.hasPrefix("uma ideia") }?.side == .me, "a claim no line matches keeps the brain's side")
            check(s.recentText().contains("Others: o condomínio") && s.recentText().contains("Me: eu discordo"), "the prompt labels each line with its track's speaker")
            var e = HelperState(lang: "pt")
            e.hear(.others, "a obra custa trezentos mil reais", final: false, at: 50)
            e.hear(.me, "obra custa trezentos mil", final: false, at: 51)
            check(!e.recentText().contains("Me:") && e.recentText().contains("Others: a obra custa"), "the microphone's echo in progress stays out of the prompt")
            e.hear(.me, "quero ver os três orçamentos", final: false, at: 52)
            check(e.recentText().contains("Me: quero ver os três orçamentos"), "the user's own line in progress goes to the prompt")
        }

        // ---- window and summary ----
        do {
            var s = HelperState(lang: "pt")
            s.hear(.others, "primeira fala antiga", final: true, at: 0)
            s.hear(.others, "fala recente", final: true, at: 301)
            check(s.window.count == 1 && s.window[0].text == "fala recente" && s.summary.contains("primeira fala antiga"),
                  "a line older than 5 minutes leaves the window for the summary")
            for i in 0..<200 { s.hear(.others, words(30, "x\(i)"), final: true, at: 400 + Double(i) * 400) }
            check(s.summary.count <= HelperState.summaryMax, "the summary stays bounded", "\(s.summary.count)")
            var t = HelperState(lang: "en")
            for i in 0..<300 { t.hear(.others, "line \(i) " + words(10, "word"), final: true, at: Double(i)) }
            let txt = t.recentText(limit: 500)
            check(txt.count <= 500 && txt.contains("line 299"), "the recent transcript keeps the newest lines within the limit")
        }

        // ---- prompts ----
        do {
            let pt = HelperPrompt.system(lang: "pt", research: false), en = HelperPrompt.system(lang: "en", research: true)
            check(pt.contains("Nunca invente") && pt.contains("Sem insultos") && pt.contains("enganosas") && pt.contains("português"), "the pt rules")
            check(pt.contains("Nada de conselho genérico") && en.contains("No generic advice") && pt.contains("ponha em \"answers\"") && en.contains("put it in \"answers\""),
                  "a tip answers something the others said, never generic advice")
            check(en.contains("Never invent") && en.contains("No insults") && en.contains("deceptive") && en.contains("\"source\""), "the en rules, research cites its source")
            check(!pt.contains("pesquisar") && HelperPrompt.system(lang: "pt", research: true).contains("URL"), "research only when asked")
            var s = HelperState(lang: "pt")
            s.hear(.others, words(20), final: true, at: 1)
            var r = BrainReply(); r.tips = [("Dica antiga", "", "", nil)]; r.claims = [(.others, "afirmação X", .unsupported)]
            s.finishAsk(.success(r), now: 2)
            let req = s.beginAsk(now: 30, research: false)
            check(req.prompt.contains("Dica antiga") && req.prompt.contains("não repita"), "the prompt lists the tips already given")
            var small = s
            let local = small.beginAsk(now: 30, research: false, small: true)
            check(!local.prompt.contains("Dica antiga") && !local.prompt.contains("não repita"), "the on-device model is not handed the tips it would copy back")
            check(req.prompt.contains("Others [unsupported]: afirmação X"), "the prompt carries the ledger with sides")
            s.finishAsk(.success(BrainReply()), now: 31)
            s.hear(.others, "a lei proíbe usar o fundo de reserva", final: true, at: 40)
            s.hear(.others, "e a taxa extra é pequena", final: false, at: 41)
            let req2 = s.beginAsk(now: 60, research: false)
            let turn = req2.prompt.components(separatedBy: "A última fala dos Others (responda primeiro a ela):\n").last?.components(separatedBy: "\n\n").first ?? ""
            check(turn == "a lei proíbe usar o fundo de reserva\ne a taxa extra é pequena", "the prompt names the others' turn since the last request, in progress included", turn)
            check(req.lang == "pt" && req.prompt.contains("\"tips\""), "the prompt asks for the JSON")
            let all = [pt, en, HelperPrompt.format, req.prompt] + Array(HelperTexts.pt.values) + Array(HelperTexts.en.values)
            check(!all.contains { $0.contains("\u{2014}") || $0.contains("\u{2013}") }, "no em-dash or en-dash anywhere")
            check(Set(HelperTexts.pt.keys) == Set(HelperTexts.en.keys), "pt and en have the same strings")
            check(HelperTexts.t("consent_body", lang: "pt").contains("não o áudio") && HelperTexts.t("consent_body", lang: "pt").contains("outros participantes")
                  && HelperTexts.t("consent_body", lang: "en").contains("api.anthropic.com"), "the consent says what leaves, to whom, and that others are included")
        }

        // ---- parse ----
        do {
            let r = HelperParse.reply(replyJSON, citations: ["https://exemplo.org/preco"])!
            check(r.tips.count == 3, "at most 3 tips")
            check(r.tips[1].text.components(separatedBy: "\n").count == 3, "a tip has at most 3 lines")
            check(r.tips[0].source == "https://exemplo.org/preco", "a source the search returned is kept")
            let invented = HelperParse.reply(replyJSON, citations: ["https://outro.org"])!
            check(invented.tips[0].source == nil, "a source the search did not return is dropped")
            check(HelperParse.reply(replyJSON, citations: nil)!.tips[0].source == nil, "no search, no source")
            check(HelperParse.reply("sem json aqui", citations: nil) == nil && HelperParse.reply("{quebrado", citations: nil) == nil, "garbage is no reply")
            check(r.claims.first?.kind == .unsupported, "the kind of a claim")
        }

        // ---- which brain may run ----
        do {
            let full = ["HELPER_MODE": "1", "HELPER_BRAIN": "cloud", "HELPER_CLOUD_CONSENT": "1"]
            check(HelperPolicy.choose(conf: [:], localUnavailable: nil, hasKey: true) == .off, "off by default")
            var off = full; off["HELPER_MODE"] = "0"
            check(HelperPolicy.choose(conf: off, localUnavailable: nil, hasKey: true) == .off, "helper off: nothing runs, not even a ready cloud")
            check(HelperPolicy.choose(conf: full, localUnavailable: nil, hasKey: true) == .cloud, "cloud chosen, key and consent: cloud")
            var noConsent = full; noConsent["HELPER_CLOUD_CONSENT"] = nil
            check(HelperPolicy.choose(conf: noConsent, localUnavailable: nil, hasKey: true) == .needsConsent, "no consent: no cloud")
            check(HelperPolicy.choose(conf: full, localUnavailable: nil, hasKey: false) == .needsKey, "no key: no cloud")
            var local = full; local["HELPER_BRAIN"] = "local"
            check(HelperPolicy.choose(conf: local, localUnavailable: "fm_off", hasKey: true) == .unavailable("fm_off"),
                  "local unavailable: says why, never falls back to the cloud")
            check(HelperPolicy.choose(conf: local, localUnavailable: nil, hasKey: true) == .local, "local is the brain unless the cloud is chosen")
            check(HelperPolicy.choose(conf: ["HELPER_MODE": "1"], localUnavailable: nil, hasKey: true) == .local, "no brain chosen: local")
            check(HelperConf.cloudModel([:]) == "claude-sonnet-5-5" && HelperConf.cloudModel(["HELPER_MODEL": " x "]) == "x", "the cloud model, configurable")
        }

        // ---- secrets ----
        let key = "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV_wxyz-0123"
        do {
            check(!HelperSecrets.redact("erro: \(key) invalid", key: nil).contains("sk-ant-api03"), "a key pattern is hidden in any text")
            check(!HelperSecrets.redact("x \(key) y", key: key).contains(key), "the key itself is hidden")
            let c = HelperSecrets.scrub(["HELPER_MODEL": key, "HELPER_BRAIN": "cloud", "TITLE": "aula"])
            check(c["HELPER_MODEL"] == nil && c["HELPER_BRAIN"] == "cloud" && c["TITLE"] == "aula", "the key never stays in the conf")
        }

        // ---- the cloud brain, against the fake server ----
        do {
            let req = HelperRequest(system: "SYS", prompt: "PROMPT", lang: "pt", research: true)
            let q = CloudBrain.request(req, key: key, model: "claude-sonnet-5-5")
            let body = String(decoding: q.httpBody ?? Data(), as: UTF8.self)
            check(q.url?.absoluteString == "https://api.anthropic.com/v1/messages" && q.httpMethod == "POST", "the Messages endpoint")
            check(q.value(forHTTPHeaderField: "x-api-key") == key && q.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "the headers")
            check(!body.contains(key), "the key is not in the body")
            check(body.contains("\"web_search_20250305\"") && body.contains("\"max_uses\":3") && body.contains("claude-sonnet-5-5") && body.contains("PROMPT"),
                  "the body: model, prompt and the web search tool", body)
            var r2 = req; r2.research = false
            check(!String(decoding: CloudBrain.request(r2, key: key, model: "m").httpBody ?? Data(), as: UTF8.self).contains("web_search"), "no research, no tool")

            let answer: [String: Any] = ["content": [
                ["type": "text", "text": "Vou pesquisar."],
                ["type": "server_tool_use", "id": "srv1", "name": "web_search", "input": ["query": "preço"]],
                ["type": "web_search_tool_result", "tool_use_id": "srv1", "content": [["type": "web_search_result", "url": "https://exemplo.org/preco", "title": "t"]]],
                ["type": "text", "text": replyJSON, "citations": [["type": "web_search_result_location", "url": "https://exemplo.org/cit"]]],
            ], "stop_reason": "end_turn"]
            FakeHTTP.requests = []; FakeHTTP.answer = (200, json(answer))
            var consent = true
            let brain = CloudBrain(model: "claude-sonnet-5-5", key: { key }, consent: { consent }, session: fakeSession())
            do {
                let r = try await brain.reply(to: req)
                check(r.tips.count == 3 && r.tips[0].source == "https://exemplo.org/preco" && r.claims.count == 3,
                      "the answer: tips with the searched source, claims")
            } catch { check(false, "the cloud brain answers", "\(error)") }
            check(FakeHTTP.requests.count == 1, "one HTTP request")

            consent = false; FakeHTTP.requests = []
            do { _ = try await brain.reply(to: req); check(false, "no consent: refused") }
            catch { check((error as? CloudError) == .noConsent && FakeHTTP.requests.isEmpty, "no consent: nothing leaves the Mac") }

            consent = true
            let nokey = CloudBrain(model: "m", key: { nil }, consent: { true }, session: fakeSession())
            do { _ = try await nokey.reply(to: req); check(false, "no key: refused") }
            catch { check((error as? CloudError) == .noKey && FakeHTTP.requests.isEmpty, "no key: no request") }

            FakeHTTP.answer = (401, json(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key \(key)"]]))
            do { _ = try await brain.reply(to: req); check(false, "401 is an error") }
            catch {
                let text = "\(error)"
                check(text.contains("401") && !text.contains(key) && !text.contains("sk-ant-api03"), "an error never carries the key", text)
            }
            FakeHTTP.answer = (200, json(["content": [["type": "text", "text": "sem json"]]]))
            do { _ = try await brain.reply(to: req); check(false, "an answer out of format is an error") }
            catch { check((error as? CloudError) == .badAnswer, "an answer out of format is an error") }
        }

        // ---- the summary next to the recording ----
        do {
            var s = HelperState(lang: "pt")
            var r = BrainReply()
            r.claims = [(.others, "A obra custa 200 mil", .unsupported), (.me, "Temos três orçamentos", .claim)]
            r.tips = [("Peça a planilha.", "O valor foi dito sem prova.", "A obra custa 200 mil", "https://exemplo.org/p")]
            s.finishAsk(.success(r), now: 65)
            let md = HelperSummary.md(title: "2026-10-06_10-00 Assembleia", lang: "pt", brain: "no Mac", state: s)
            check(md.hasPrefix("# 2026-10-06_10-00 Assembleia") && md.contains("## Argumentos") && md.contains("### Others\n\n- [01:05] A obra custa 200 mil (sem prova)")
                  && md.contains("### Me\n\n- [01:05] Temos três orçamentos"), "the summary maps the arguments by side", md)
            check(md.contains("## Dicas dadas") && md.contains("Peça a planilha.") && md.contains("por quê: O valor") && md.contains("fonte: https://exemplo.org/p"),
                  "the summary lists the tips with why and source")
            check(HelperSummary.md(title: "x", lang: "en", brain: "cloud", state: HelperState(lang: "en")).contains("## Tips given\n\n_(none)_"), "the en summary, empty")

            let dir = NSTemporaryDirectory() + "helper-bench-\(getpid())"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let mov = dir + "/2026-10-06_10-00 Assembleia.mov"
            try? Data("video".utf8).write(to: URL(fileURLWithPath: mov))
            try? Data("sum  x.mov\n".utf8).write(to: URL(fileURLWithPath: mov + ".sha256"))
            let p = try? HelperSummary.write(md, media: mov)
            check(p == dir + "/2026-10-06_10-00 Assembleia.helper.md" && (try? String(contentsOfFile: p ?? "", encoding: .utf8)) == md, "written as <name>.helper.md")
            check((try? Data(contentsOf: URL(fileURLWithPath: mov))) == Data("video".utf8)
                  && (try? Data(contentsOf: URL(fileURLWithPath: mov + ".sha256"))) == Data("sum  x.mov\n".utf8), "the recording and its evidence are untouched")
            check(!FileManager.default.fileExists(atPath: (p ?? "") + ".tmp"), "no temporary file is left")
            check((try? HelperSummary.write(md, media: mov + ".sha256")) == nil && (try? HelperSummary.write(md, media: dir + "/a.md")) == nil
                  && (try? HelperSummary.write(md, media: dir + "/a.txt")) == nil, "refused next to anything that is not a recording")
            check(HelperSummary.path(for: "/x/a.mov") == "/x/a.helper.md" && HelperSummary.path(for: "/x/a.mkv") == "/x/a.helper.md", "the name")
        }

        // ---- live recognition: when a line is cut ----
        do {
            check(LiveCut.mayOpen(closingSince: nil, now: 0), "nothing closing: a request opens")
            check(!LiveCut.mayOpen(closingSince: 10, now: 11), "a request still writing its line is not ended by the next one")
            check(LiveCut.mayOpen(closingSince: 10, now: 13.1), "a closing request that never answers does not block forever")
            check(LiveLanes.listens(.me, analyzer: true) && LiveLanes.listens(.others, analyzer: true), "the analyzer transcribes both tracks")
            check(LiveLanes.listens(.others, analyzer: false) && !LiveLanes.listens(.me, analyzer: false),
                  "SFSpeechRecognizer (one task per process) transcribes the others only")
            check(!LiveCut.shouldCut(requestStarted: 0, lastChange: 10, hasText: true, now: 11), "speech still changing: no cut")
            check(LiveCut.shouldCut(requestStarted: 0, lastChange: 10, hasText: true, now: 11.6), "1.5 s without change: the line ends")
            check(!LiveCut.shouldCut(requestStarted: 0, lastChange: nil, hasText: false, now: 30), "silence alone: no cut")
            check(LiveCut.shouldCut(requestStarted: 0, lastChange: nil, hasText: false, now: 50), "a request ends before the recognizer's minute")
        }

        print("\(total - fails)/\(total) ok")
        if fails > 0 { exit(1) }
    }
}
