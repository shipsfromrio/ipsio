// HelperLocal.swift: the default brain, Apple's on-device model (Foundation
// Models, macOS 26 with Apple Intelligence). Nothing leaves the Mac. Guided
// generation through a runtime schema (DynamicGenerationSchema): the
// @Generable macro needs Xcode's macro plugin, and Ipsio builds with swiftc
// from the Command Line Tools. The schema is the same JSON the cloud answers,
// so one parser (HelperParse) reads both.
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum LocalModel {
    /// nil when the on-device model can answer now; else the HelperTexts key that says why not.
    static func unavailableReason() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let r):
                switch r {
                case .deviceNotEligible: return "fm_device"
                case .appleIntelligenceNotEnabled: return "fm_off"
                case .modelNotReady: return "fm_not_ready"
                @unknown default: return "fm_other"
                }
            @unknown default: return "fm_other"
            }
        }
        return "fm_os"
        #else
        return "fm_missing"
        #endif
    }
}

final class LocalBrain: HelperBrain {
    let kind = HelperBrainKind.local
    enum Failure: Error, CustomStringConvertible {
        case unavailable(String), badAnswer
        var description: String {
            switch self { case .unavailable(let k): return k; case .badAnswer: return "the on-device model answered out of format" }
        }
    }

    func reply(to r: HelperRequest) async throws -> BrainReply {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if let why = LocalModel.unavailableReason() { throw Failure.unavailable(why) }
            let json = try await LocalBrain.generate(system: r.system, prompt: r.prompt, lang: r.lang)
            guard let reply = HelperParse.reply(json, citations: nil) else { throw Failure.badAnswer }
            return reply
        }
        #endif
        throw Failure.unavailable(LocalModel.unavailableReason() ?? "fm_other")
    }

    #if canImport(FoundationModels)
    /// A fresh session per request: the model's context is small, and the
    /// state travels in the prompt (summary, ledger, recent lines).
    @available(macOS 26, *)
    static func generate(system: String, prompt: String, lang: String) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        let schema = try schema(lang: lang)
        let r = try await session.respond(to: prompt, schema: schema, includeSchemaInPrompt: true,
                                          options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 700))
        return r.content.jsonString
    }

    @available(macOS 26, *)
    static func schema(lang: String) throws -> GenerationSchema {
        // The descriptions in the meeting language: the model answers in the language it reads.
        let en = lang == "en"
        func d(_ e: String, _ p: String) -> String { en ? e : p }
        let str = DynamicGenerationSchema(type: String.self)
        let claim = DynamicGenerationSchema(name: "Claim", properties: [
            .init(name: "side", description: d("who said it: me (lines marked Me:) or others (lines marked Others:)", "quem disse: me (linhas Me:) ou others (linhas Others:)"), schema: DynamicGenerationSchema(name: "Side", anyOf: ["me", "others"])),
            .init(name: "text", description: d("the argument, in one short sentence", "o argumento, numa frase curta"), schema: str),
            .init(name: "kind", schema: DynamicGenerationSchema(name: "Kind", anyOf: Claim.Kind.allCases.map { $0.rawValue })),
        ])
        let tip = DynamicGenerationSchema(name: "Tip", properties: [
            .init(name: "text", description: d("1 to 3 short lines the user can say now", "1 a 3 linhas curtas que o usuário pode dizer agora"), schema: str),
            .init(name: "why", description: d("why it helps, naming the claim it answers", "por que ajuda, citando a afirmação que responde"), schema: str),
            .init(name: "answers", description: d("the Others' line this tip answers, quoted", "a fala dos Others que esta dica responde, citada"), schema: str),
        ])
        let root = DynamicGenerationSchema(name: "HelperReply", properties: [
            .init(name: "summary", description: d("a compact running summary of the meeting so far", "um resumo curto da reunião até aqui"), schema: str),
            .init(name: "claims", schema: DynamicGenerationSchema(arrayOf: claim, maximumElements: 6)),
            .init(name: "tips", schema: DynamicGenerationSchema(arrayOf: tip, minimumElements: 0, maximumElements: 3)),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }
    #endif
}
