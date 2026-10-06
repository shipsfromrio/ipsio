// HelperCloud.swift: the optional cloud brain. Off by default; runs only when
// the user picked it, gave their OWN Anthropic key (kept in the Keychain,
// HelperKeychain.swift) and agreed to the one-time notice. What leaves the
// Mac is the transcribed text in the request (never audio). The server-side
// web search tool lets it check the others' claims; a tip that uses a search
// result carries the link, and a link the search did not return is dropped
// (HelperParse). The key never reaches the conf, a log or an error text.
import Foundation

enum CloudError: Error, CustomStringConvertible, Equatable {
    case noConsent, noKey, http(Int, String), badAnswer, network(String)
    var description: String {
        switch self {
        case .noConsent: return "the cloud was not agreed to"
        case .noKey: return "no Anthropic key"
        case .http(let c, let s): return "HTTP \(c)" + (s.isEmpty ? "" : ": \(s)")
        case .badAnswer: return "the answer had no tips in the expected format"
        case .network(let s): return s
        }
    }
}

final class CloudBrain: HelperBrain {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    // Checked on 2026-10-06 in the web search tool docs (platform.claude.com):
    // "web_search_20250305" is the basic version every model takes, with no
    // code execution behind it (the newer versions add dynamic filtering).
    static let webSearchTool = "web_search_20250305"
    static let maxSearches = 3

    let kind = HelperBrainKind.cloud
    let model: String
    private let key: () -> String?
    private let consent: () -> Bool
    private let session: URLSession

    init(model: String, key: @escaping () -> String?, consent: @escaping () -> Bool, session: URLSession? = nil) {
        self.model = model; self.key = key; self.consent = consent
        if let s = session { self.session = s } else {
            let c = URLSessionConfiguration.ephemeral   // no cache, no cookies on disk
            c.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: c)
        }
    }

    /// The Messages API request. The key goes in the header only.
    static func request(_ r: HelperRequest, key: String, model: String) -> URLRequest {
        var q = URLRequest(url: endpoint)
        q.httpMethod = "POST"
        q.setValue(key, forHTTPHeaderField: "x-api-key")
        q.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        q.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": model, "max_tokens": 1500, "system": r.system,
            "messages": [["role": "user", "content": r.prompt]],
        ]
        if r.research { body["tools"] = [["type": webSearchTool, "name": "web_search", "max_uses": maxSearches]] }
        q.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return q
    }

    /// The text blocks joined, and every URL the search returned or cited.
    static func parse(_ data: Data) -> (text: String, citations: Set<String>)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = obj["content"] as? [[String: Any]] else { return nil }
        var text = "", urls = Set<String>()
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                text += (b["text"] as? String) ?? ""
                for c in (b["citations"] as? [[String: Any]]) ?? [] { if let u = c["url"] as? String { urls.insert(u) } }
            case "web_search_tool_result":
                for c in (b["content"] as? [[String: Any]]) ?? [] { if let u = c["url"] as? String { urls.insert(u) } }
            default: break
            }
        }
        return (text, urls)
    }

    func reply(to r: HelperRequest) async throws -> BrainReply {
        // Checked here too: the controller asks the policy, this is the second lock.
        guard consent() else { throw CloudError.noConsent }
        guard let k = key(), !k.isEmpty else { throw CloudError.noKey }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: CloudBrain.request(r, key: k, model: model)) }
        catch { throw CloudError.network(HelperSecrets.redact("\(error.localizedDescription)", key: k)) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            // The error body may quote the request; never let the key through.
            var msg = ""
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = o["error"] as? [String: Any] { msg = (e["message"] as? String) ?? "" }
            else { msg = String(decoding: data.prefix(300), as: UTF8.self) }
            throw CloudError.http(code, HelperSecrets.redact(HelperText.clip(msg, 200), key: k))
        }
        guard let (text, cites) = CloudBrain.parse(data), let reply = HelperParse.reply(text, citations: r.research ? cites : nil) else {
            throw CloudError.badAnswer
        }
        return reply
    }
}
