import Foundation
@testable import VaultClassifierCore   // upsertVideoClassification: replay what a live correction stores
import VaultClassifierLLM

// `VaultClassifierEval summarize` — does a model turn user corrections into GOOD
// rules? The LLM correction-summarizer was removed (5ca3ff7) after a small model
// fabricated rules ("tag Samsung videos as Sports") that poisoned classification.
// This re-measures that on SYNTHETIC corrections whose intended rule is known,
// including deliberate traps, in two parts:
//
//   1. WHAT IT WRITES  — the rules each prompt variant produces, with cheap
//      automatic checks (rule captured? trap taken? invented a rule from nothing?).
//   2. WHAT IT DOES    — the rules injected as house rules, then held-out titles
//      classified: did the intended videos get fixed, and were unrelated videos
//      left alone? Compared with no rules, the production mechanism (per-video
//      retrieved exemplars) and a hand-written oracle rule.

struct SyntheticCorrection {
    let title: String
    let modelSaid: [String]     // what the classifier predicted ([] = declined)
    let userWants: [String]     // the correction ([] = "apply no tag")
    var note: String? = nil
}

struct HeldOutTitle {
    let title: String
    let expect: [String]
    /// true  = a video the rule SHOULD now fix.
    /// false = a look-alike the rule must NOT touch (the poisoning probe).
    let shouldChange: Bool
}

struct RuleCheck {
    /// Pass when some single rule line mentions one of `anyOf` AND every tag in `tags`.
    let anyOf: [String]
    let tags: [String]
}

struct SummaryScenario {
    let id: String
    let intent: String                 // the rule a careful human would write
    let corrections: [SyntheticCorrection]
    var mustCapture: [RuleCheck] = []
    /// A fabricated rule: a line that pairs `word` with `tag` while mentioning
    /// none of `unless` (the words that would make the pairing legitimate).
    var traps: [(word: String, tag: String, unless: [String])] = []
    /// The evidence supports NO general rule (too sparse / contradictory / not in the titles).
    var expectNoRule = false
    let oracleRule: String             // "" when the honest answer is no rule
    let heldOut: [HeldOutTitle]
}

let summaryScenarios: [SummaryScenario] = [
    SummaryScenario(
        id: "S1-specific-over-general",
        intent: "Minecraft content is tagged Minecraft, not the generic Gaming.",
        corrections: [
            .init(title: "I survived 100 days in hardcore Minecraft", modelSaid: ["Gaming"], userWants: ["Minecraft"]),
            .init(title: "Hermitcraft 10: Episode 42 - the shopping district", modelSaid: ["Gaming"], userWants: ["Minecraft"]),
            .init(title: "The fastest creeper farm you can build in survival", modelSaid: ["Gaming"], userWants: ["Minecraft"]),
            .init(title: "We broke the nether roof (again)", modelSaid: ["Gaming"], userWants: ["Minecraft"]),
            .init(title: "Redstone computer tutorial for beginners", modelSaid: ["Technology"], userWants: ["Minecraft"]),
        ],
        mustCapture: [.init(anyOf: ["minecraft", "hermitcraft", "redstone", "creeper", "nether"], tags: ["Minecraft"])],
        oracleRule: "Minecraft videos (including Hermitcraft, redstone, creeper farms, the nether) are tagged \"Minecraft\", not \"Gaming\".",
        heldOut: [
            .init(title: "I built an iron golem farm in my survival world", expect: ["Minecraft"], shouldChange: true),
            .init(title: "Hermitcraft 11: Episode 3 - starting the mega base", expect: ["Minecraft"], shouldChange: true),
            .init(title: "Elden Ring: how to beat Malenia without summons", expect: ["Gaming"], shouldChange: false),
            .init(title: "Best budget gaming monitors of the year", expect: ["Hardware Reviews"], shouldChange: false),
        ]
    ),
    SummaryScenario(
        id: "S2-sponsor-brand-trap",
        intent: "Sports highlights are Sports even when a sponsor's brand (Samsung) is in the title. The brand is incidental.",
        corrections: [
            .init(title: "Samsung Player of the Match: Haaland's hat-trick vs Arsenal", modelSaid: ["Technology"], userWants: ["Sports"]),
            .init(title: "Premier League highlights | presented by Samsung", modelSaid: ["Technology"], userWants: ["Sports"]),
            .init(title: "Top 10 goals of the month - Samsung Goal of the Month", modelSaid: ["Technology"], userWants: ["Sports"]),
            .init(title: "Lakers vs Celtics - full game highlights", modelSaid: ["Entertainment"], userWants: ["Sports"]),
        ],
        mustCapture: [.init(anyOf: ["highlight", "match", "goal", "game", "football", "sport", "league"], tags: ["Sports"])],
        traps: [(word: "samsung", tag: "Sports", unless: ["highlight", "match", "goal", "game", "football", "league", "sponsor", "player", "even", "regardless"])],
        oracleRule: "Match, game and goal highlights are tagged \"Sports\" even when a sponsor's brand name appears in the title.",
        heldOut: [
            .init(title: "Samsung Player of the Match: Salah's brace at Anfield", expect: ["Sports"], shouldChange: true),
            .init(title: "Champions League highlights | presented by Heineken", expect: ["Sports"], shouldChange: true),
            .init(title: "Samsung Galaxy S25 Ultra review: six months later", expect: ["Hardware Reviews"], shouldChange: false),
            .init(title: "Samsung's new foldable has a serious hinge problem", expect: ["Technology"], shouldChange: false),
        ]
    ),
    SummaryScenario(
        id: "S3-single-correction",
        intent: "One correction is not a pattern. The honest answer is NO RULE.",
        corrections: [
            .init(title: "my cat knocked over the christmas tree", modelSaid: ["Comedy & Memes"], userWants: ["Lifestyle"]),
        ],
        expectNoRule: true,
        oracleRule: "",
        heldOut: [
            .init(title: "funniest cat fails compilation 2026", expect: ["Comedy & Memes"], shouldChange: false),
            .init(title: "decorating our apartment for the holidays", expect: ["Lifestyle"], shouldChange: false),
        ]
    ),
    SummaryScenario(
        id: "S4-contradictory",
        intent: "Near-identical podcast titles were corrected two different ways. No consistent rule exists.",
        corrections: [
            .init(title: "The Daily Pod #212 - what happened this week", modelSaid: ["Comedy & Memes"], userWants: ["Entertainment"]),
            .init(title: "The Daily Pod #213 - what happened this week", modelSaid: ["Comedy & Memes"], userWants: ["News & Politics"]),
            .init(title: "The Daily Pod #214 - listener questions", modelSaid: ["Comedy & Memes"], userWants: ["Entertainment"]),
            .init(title: "The Daily Pod #215 - listener questions", modelSaid: ["Comedy & Memes"], userWants: ["News & Politics"]),
        ],
        expectNoRule: true,
        oracleRule: "",
        heldOut: [
            .init(title: "stand-up special: the full set", expect: ["Comedy & Memes"], shouldChange: false),
        ]
    ),
    SummaryScenario(
        id: "S5-apply-no-tag",
        intent: "Trailers and ads get NO tag.",
        corrections: [
            .init(title: "Dune: Part Three | Official Trailer", modelSaid: ["Movies & TV"], userWants: []),
            .init(title: "The new Pixel is here | Official Ad", modelSaid: ["Technology"], userWants: []),
            .init(title: "GTA VI - Trailer 3", modelSaid: ["Gaming"], userWants: []),
            .init(title: "Nike: Find Your Greatness (commercial)", modelSaid: ["Sports"], userWants: []),
        ],
        mustCapture: [.init(anyOf: ["trailer", "ad", "commercial", "promo"], tags: [])],
        oracleRule: "Official trailers, teasers, ads and commercials get no tag at all.",
        heldOut: [
            .init(title: "The Batman Part II | Official Teaser Trailer", expect: [], shouldChange: true),
            .init(title: "Introducing the new MacBook | Official Ad", expect: [], shouldChange: true),
            .init(title: "Dune: Part Two - movie review (no spoilers)", expect: ["Movies & TV"], shouldChange: false),
        ]
    ),
    SummaryScenario(
        id: "S6-chinese-finance",
        intent: "Chinese-language economy / property / stock-market videos are Finance & Business, not News & Politics.",
        corrections: [
            .init(title: "恒大暴雷之后，中国房地产还有救吗？", modelSaid: ["News & Politics"], userWants: ["Finance & Business"]),
            .init(title: "A股三千点保卫战：散户为什么总是亏钱", modelSaid: ["News & Politics"], userWants: ["Finance & Business"]),
            .init(title: "人民币汇率破七意味着什么", modelSaid: ["News & Politics"], userWants: ["Finance & Business"]),
            .init(title: "纪录片《开盘》，房地产的血与泪", modelSaid: [], userWants: ["Finance & Business"]),
        ],
        mustCapture: [.init(anyOf: ["econom", "financ", "property", "real estate", "stock", "market", "房地产", "股", "经济", "金融", "currency"], tags: ["Finance & Business"])],
        oracleRule: "Chinese-language videos about the economy, property market, stocks or currency are tagged \"Finance & Business\", not \"News & Politics\".",
        heldOut: [
            .init(title: "A股为什么又跌了？普通人该怎么办", expect: ["Finance & Business"], shouldChange: true),
            .init(title: "中国楼市的拐点到了吗", expect: ["Finance & Business"], shouldChange: true),
            .init(title: "台海局势最新分析：美国会介入吗", expect: ["News & Politics"], shouldChange: false),
        ]
    ),
    SummaryScenario(
        id: "S7-two-tags",
        intent: "Minecraft speedruns carry BOTH Minecraft and Speedruns.",
        corrections: [
            .init(title: "Minecraft 1.16 any% world record - 9:36", modelSaid: ["Speedruns"], userWants: ["Minecraft", "Speedruns"]),
            .init(title: "funniest clips from 1000 hours of minecraft speedrunning", modelSaid: ["Speedruns"], userWants: ["Minecraft", "Speedruns"]),
            .init(title: "I finally beat Dream's minecraft speedrun time", modelSaid: ["Gaming"], userWants: ["Minecraft", "Speedruns"]),
        ],
        mustCapture: [.init(anyOf: ["minecraft"], tags: ["Minecraft", "Speedruns"])],
        oracleRule: "Minecraft speedrun videos get both \"Minecraft\" and \"Speedruns\".",
        heldOut: [
            .init(title: "Minecraft random seed glitchless in 7 minutes (former WR)", expect: ["Minecraft", "Speedruns"], shouldChange: true),
            .init(title: "Super Mario 64 120 star speedrun in 1:37", expect: ["Speedruns"], shouldChange: false),
        ]
    ),
    SummaryScenario(
        id: "S8-mixed-bag",
        intent: "Two real rules (Clash Royale is its own tag; AI tools are AI & Software) buried among unrelated one-offs.",
        corrections: [
            .init(title: "This 2.6 hog cycle deck is broken in Clash Royale", modelSaid: ["Gaming"], userWants: ["Clash Royale"]),
            .init(title: "I pushed to 9000 trophies with only level 11 cards", modelSaid: ["Gaming"], userWants: ["Clash Royale"]),
            .init(title: "New evolution drop: is mega knight finally good?", modelSaid: ["Gaming"], userWants: ["Clash Royale"]),
            .init(title: "Claude just got a huge coding upgrade", modelSaid: ["Technology"], userWants: ["AI & Software"]),
            .init(title: "I replaced my whole workflow with local LLMs", modelSaid: ["Technology"], userWants: ["AI & Software"]),
            .init(title: "GPT vs Gemini: which writes better code?", modelSaid: ["Technology"], userWants: ["AI & Software"]),
            .init(title: "48 hours in Kyoto on a budget", modelSaid: ["Lifestyle"], userWants: ["Travel"]),
            .init(title: "the only carbonara recipe you need", modelSaid: ["Lifestyle"], userWants: ["Food & Cooking"]),
            .init(title: "lofi beats to study to", modelSaid: [], userWants: ["Music"]),
        ],
        mustCapture: [
            .init(anyOf: ["clash royale", "deck", "troph", "mega knight", "evolution"], tags: ["Clash Royale"]),
            .init(anyOf: ["ai", "llm", "gpt", "claude", "gemini", "model"], tags: ["AI & Software"]),
        ],
        oracleRule: "Clash Royale videos (decks, trophies, card evolutions) are tagged \"Clash Royale\", not \"Gaming\". Videos about AI models and LLM tools are tagged \"AI & Software\", not \"Technology\".",
        heldOut: [
            .init(title: "Best log bait deck after the balance changes", expect: ["Clash Royale"], shouldChange: true),
            .init(title: "Running a 70B model on a single Mac Studio", expect: ["AI & Software"], shouldChange: true),
            .init(title: "iPhone 17 Pro camera test in low light", expect: ["Hardware Reviews"], shouldChange: false),
            .init(title: "Brawl Stars new brawler gameplay", expect: ["Gaming"], shouldChange: false),
        ]
    ),
    SummaryScenario(
        id: "S9-nothing-in-the-titles",
        intent: "The titles carry no topical signal (one creator's in-jokes). No title-based rule can be written honestly.",
        corrections: [
            .init(title: "think", modelSaid: [], userWants: ["Comedy & Memes"]),
            .init(title: "this might be my new favorite channel..", modelSaid: ["Entertainment"], userWants: ["Comedy & Memes"]),
            .init(title: "how did we get here", modelSaid: [], userWants: ["Comedy & Memes"]),
            .init(title: "it finally happened.", modelSaid: [], userWants: ["Comedy & Memes"]),
        ],
        traps: [
            (word: "think", tag: "Comedy & Memes", unless: []),
            (word: "favorite", tag: "Comedy & Memes", unless: []),
            (word: "channel", tag: "Comedy & Memes", unless: []),
        ],
        expectNoRule: true,
        oracleRule: "",
        heldOut: [
            .init(title: "I think this is the best programming language", expect: ["AI & Software"], shouldChange: false),
            .init(title: "my favorite channel for learning physics", expect: ["Science & Education"], shouldChange: false),
        ]
    ),
]

/// Unrelated titles classified under EVERY scenario's rules: a good rule set
/// leaves all of these exactly as they were.
let globalControls: [HeldOutTitle] = [
    .init(title: "How black holes actually evaporate", expect: ["Science & Education"], shouldChange: false),
    .init(title: "Fed holds rates: what it means for your mortgage", expect: ["Finance & Business"], shouldChange: false),
    .init(title: "Taylor Swift - new single (official music video)", expect: ["Music"], shouldChange: false),
    .init(title: "Senate passes the budget bill after all-night session", expect: ["News & Politics"], shouldChange: false),
]

enum SummaryPromptVariant: String, CaseIterable {
    /// EXACTLY what shipped and was removed in 5ca3ff7: the original prompt as a
    /// raw completion, 200 tokens, stopping only on a triple newline — and the
    /// whole output injected verbatim.
    case asShipped = "as-shipped"
    /// The same prompt asked properly: inside the model's chat template. Isolates
    /// the framing bug from the prompt's design.
    case originalChat = "original+chat"
    /// Generate-then-VERIFY. A strict `IF <subject> THEN tag "X" (not "Y") [#n, #m]`
    /// format with one worked example, so every rule cites its evidence — and then
    /// `verifiedRules` rejects, in code, any rule the citations do not support.
    /// (A first, abstract "grounded" prompt without the format/example failed on the
    /// 7B: it wrote `- Sports [#1, #2]`, descriptions instead of instructions —
    /// which made the classifier decline unrelated videos — and ignored the
    /// two-correction minimum.)
    case structured = "structured+verify"

    var usesChat: Bool { self != .asShipped }
    var tokenBudget: Int { self == .asShipped ? 200 : 220 }

    /// What a production implementation would inject for this variant's output.
    func injectable(from output: String) -> String {
        switch self {
        case .asShipped:
            return output   // verbatim, as it was
        case .originalChat:
            // Every line it wrote is a rule (it answers in plain sentences).
            return output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.prefix(5).joined(separator: "\n")
        case .structured:
            return ""   // decided by verifiedRules(…), which needs the corrections
        }
    }

    func prompt(for corrections: [SyntheticCorrection], allowed: [String]) -> String {
        let allowedList = allowed.prefix(40).joined(separator: ", ")
        switch self {
        case .asShipped, .originalChat:
            let lines = corrections.prefix(24).map { item -> String in
                let tags = item.userWants.isEmpty ? "no tag" : item.userWants.joined(separator: ", ")
                let note = (item.note?.isEmpty == false) ? " — note: \(item.note!)" : ""
                return "- \"\(item.title)\" -> \(tags)\(note)"
            }.joined(separator: "\n")
            return """
            You refine a video-tagging assistant's guidance from a user's past corrections. From the corrections below, write 2 to 5 short imperative rules that capture how this user wants videos tagged so future videos match. Be concise and specific, use only the allowed tags, and do not restate every example.

            Allowed tags: \(allowedList)

            Corrections:
            \(lines)

            Rules:
            """
        case .structured:
            let lines = corrections.prefix(24).enumerated().map { index, item -> String in
                let said = item.modelSaid.isEmpty ? "no tag" : item.modelSaid.joined(separator: ", ")
                let wants = item.userWants.isEmpty ? "no tag" : item.userWants.joined(separator: ", ")
                return "#\(index + 1) \"\(item.title)\" | assistant said: \(said) | user corrected to: \(wants)"
            }.joined(separator: "\n")
            return """
            A video-tagging assistant made mistakes and the user corrected them. Turn the corrections into tagging rules.

            Write one rule per line, in English, in EXACTLY this form and nothing else:
            - IF the video is about <the shared subject, a few words> THEN tag "<tag>" (not "<the tag the assistant wrongly used>") [#<numbers of the corrections that prove it>]

            Requirements:
            - Cite at least 2 corrections per rule; a correction that stands alone gets no rule.
            - The subject must be what the videos are ABOUT. Never a sponsor, brand or filler word that merely appears in the titles.
            - Keep the subject as narrow as the evidence: do not widen "Minecraft speedruns" to "speedruns".
            - Use only the allowed tags, spelled exactly. For two tags write: tag "A" and "B". When the user removed every tag write: THEN tag "no tag".
            - If corrections on the same subject disagree, or the titles share no subject, write exactly: NO RULE

            Example (different tags, shown only for the format):
            #1 "Sourdough starter, day 5" | assistant said: Lifestyle | user corrected to: Baking
            #2 "Why my baguettes keep failing" | assistant said: Lifestyle | user corrected to: Baking
            #3 "My morning routine" | assistant said: Vlogs | user corrected to: Lifestyle
            Rules:
            - IF the video is about baking bread THEN tag "Baking" (not "Lifestyle") [#1, #2]

            Allowed tags: \(allowedList)

            Corrections:
            \(lines)

            Rules:
            """
        }
    }
}

/// Generate-then-verify: keep a model-written rule only if the evidence it cites
/// really supports it. Everything here is checkable in code, which is the point —
/// a fabricated rule has nothing valid to cite.
func verifiedRules(_ output: String, corrections: [SyntheticCorrection], allowed: [String]) -> (kept: [String], rejected: [(line: String, why: String)]) {
    let allowedByLower = Dictionary(allowed.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 && Int($0) == nil })
    }
    func similar(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.5
    }
    var kept: [String] = [], rejected: [(String, String)] = []
    for raw in output.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.uppercased().contains("NO RULE") else { continue }
        guard line.hasPrefix("-"), let ifRange = line.range(of: "IF ", options: .caseInsensitive),
              let thenRange = line.range(of: " THEN ", options: .caseInsensitive), ifRange.upperBound <= thenRange.lowerBound else {
            rejected.append((line, "not in IF … THEN … form")); continue
        }
        let subject = String(line[ifRange.upperBound..<thenRange.lowerBound])
        var action = String(line[thenRange.upperBound...])
        // Evidence.
        var cited: [Int] = []
        if let open = action.lastIndex(of: "["), let close = action.lastIndex(of: "]"), open < close {
            cited = action[action.index(after: open)..<close].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            action = String(action[..<open])
        }
        let valid = Array(Set(cited.filter { $0 >= 1 && $0 <= corrections.count })).sorted()
        guard valid.count >= 2 else { rejected.append((line, "cites fewer than 2 real corrections")); continue }
        // Tags: the quoted names before the "(not …)" clause.
        let head = action.range(of: "(not", options: .caseInsensitive).map { String(action[..<$0.lowerBound]) } ?? action
        var quoted: [String] = []
        var rest = Substring(head)
        while let open = rest.firstIndex(of: "\"") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "\"") else { break }
            quoted.append(String(after[..<close])); rest = after[after.index(after: close)...]
        }
        let wantsNoTag = quoted.contains { $0.lowercased() == "no tag" }
        let tags = quoted.filter { $0.lowercased() != "no tag" }
        guard wantsNoTag || !tags.isEmpty else { rejected.append((line, "names no tag")); continue }
        if let bad = tags.first(where: { allowedByLower[$0.lowercased()] == nil }) { rejected.append((line, "\"\(bad)\" is not an allowed tag")); continue }
        let ruleTags = Set(tags.map { allowedByLower[$0.lowercased()]! })
        // Every cited correction must actually have been corrected to these tags.
        if let bad = valid.first(where: { Set(corrections[$0 - 1].userWants) != ruleTags }) {
            rejected.append((line, "#\(bad) was corrected to \(corrections[bad - 1].userWants.isEmpty ? "no tag" : corrections[bad - 1].userWants.joined(separator: "+")), not this")); continue
        }
        // A near-identical title that the user corrected DIFFERENTLY contradicts the rule.
        let contradiction = corrections.enumerated().first { index, other in
            !valid.contains(index + 1) && Set(other.userWants) != ruleTags
                && valid.contains { similar(corrections[$0 - 1].title, other.title) }
        }
        if let contradiction { rejected.append((line, "contradicted by #\(contradiction.offset + 1), a near-identical title corrected differently")); continue }
        // The subject must not be just an incidental title word: it has to say something
        // beyond words that appear in EVERY cited title only by coincidence of branding.
        let subjectWords = words(subject).subtracting(["video", "videos", "about", "the", "content", "related"])
        guard !subjectWords.isEmpty else { rejected.append((line, "has no subject")); continue }
        // Vacuous: the "subject" merely restates the tag AND the rule names no wrong
        // tag to steer away from ("about Comedy & Memes → Comedy & Memes (not no tag)").
        // It carries no information, yet would cost prompt tokens on every video.
        let restatesTag = !ruleTags.isEmpty && subjectWords.isSubset(of: words(ruleTags.joined(separator: " ")))
        let namesWrongTag = action.range(of: "(not", options: .caseInsensitive).map { clause -> Bool in
            allowed.contains { action[clause.lowerBound...].localizedCaseInsensitiveContains("\"\($0)\"") }
        } ?? false
        if restatesTag && !namesWrongTag { rejected.append((line, "vacuous: the subject just restates the tag and no wrong tag is named")); continue }
        let tagText = wantsNoTag ? "no tag at all" : ruleTags.sorted().map { "\"\($0)\"" }.joined(separator: " and ")
        let notClause = action.range(of: "(not", options: .caseInsensitive).map { " " + String(action[$0.lowerBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
        kept.append("- If the video is about \(subject.replacingOccurrences(of: "the video is about ", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)), give it \(tagText)\(wantsNoTag ? "" : notClause).")
    }
    return (kept, rejected)
}

struct RuleAssessment {
    let lines: [String]
    let saidNoRule: Bool
    let captured: Int
    let toCapture: Int
    let trapsTaken: [String]
    let offTaxonomyQuotes: [String]
    var inventedFromNothing: Bool
}

func assessRules(_ output: String, rawOutput: String, scenario: SummaryScenario, allowed: [String]) -> RuleAssessment {
    let rawLines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let saidNoRule = rawOutput.uppercased().contains("NO RULE")
    let lines = rawLines.filter { !$0.uppercased().contains("NO RULE") }
    let lower = lines.map { $0.lowercased() }
    func mentions(_ line: String, tag: String) -> Bool { line.contains(tag.lowercased()) }
    var captured = 0
    for check in scenario.mustCapture {
        let hit = lower.contains { line in
            check.anyOf.contains { line.contains($0.lowercased()) }
                && (check.tags.isEmpty ? (line.contains("no tag") || line.contains("none") || line.contains("not tag") || line.contains("untagged"))
                                       : check.tags.allSatisfy { mentions(line, tag: $0) })
        }
        if hit { captured += 1 }
    }
    var traps: [String] = []
    for trap in scenario.traps {
        for (index, line) in lower.enumerated()
        where line.contains(trap.word.lowercased()) && mentions(line, tag: trap.tag)
            && !trap.unless.contains(where: { line.contains($0.lowercased()) }) {
            traps.append(lines[index])
        }
    }
    // A quoted phrase that is neither an allowed tag nor lifted from a correction title.
    let allowedLower = Set(allowed.map { $0.lowercased() })
    let titleText = scenario.corrections.map { $0.title.lowercased() }.joined(separator: " \u{1F}")
    var offTaxonomy: [String] = []
    for line in lines {
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "\"") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "\"") else { break }
            let quoted = String(after[..<close])
            let key = quoted.lowercased()
            if quoted.count >= 3, !allowedLower.contains(key), !titleText.contains(key), key != "no tag" { offTaxonomy.append(quoted) }
            rest = after[after.index(after: close)...]
        }
    }
    return RuleAssessment(
        lines: lines, saidNoRule: saidNoRule, captured: captured, toCapture: scenario.mustCapture.count,
        trapsTaken: Array(Set(traps)), offTaxonomyQuotes: Array(Set(offTaxonomy)),
        inventedFromNothing: scenario.expectNoRule && !lines.isEmpty
    )
}

struct DownstreamTally {
    var fixed = 0, toFix = 0          // shouldChange titles now exactly right
    var intact = 0, toKeep = 0        // look-alikes + global controls still exactly right
    var misses: [String] = []
}

func runSummarizeExperiment(
    engine: VaultLocalLLMEngine,
    modelName: String,
    type: ClassifierTypeAsset,
    tree: TagTreeAsset,
    baseCatalog: WorkspaceCatalog,
    baseHouseRules: String?,
    maximumTags: Int,
    allowedNames: [String],
    onlyScenario: String?,
    skipDownstream: Bool
) async throws {
    let nameByID = Dictionary(tree.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let idByName = Dictionary(tree.nodes.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
    var usedTagNames: [String] = globalControls.flatMap(\.expect)
    for scenario in summaryScenarios {
        for correction in scenario.corrections { usedTagNames += correction.modelSaid + correction.userWants }
        for item in scenario.heldOut { usedTagNames += item.expect }
    }
    let missing: [String] = Set(usedTagNames).filter { idByName[$0.lowercased()] == nil }
    if !missing.isEmpty { print("! scenario tags missing from this tree (those checks will be unreliable): \(missing.sorted())") }

    var emptyCatalog = baseCatalog
    emptyCatalog.correctionExamples = []
    let pipeline = VideoClassificationPipeline(llm: engine, maximumTags: maximumTags)

    func classify(_ titles: [HeldOutTitle], scenario: SummaryScenario, houseRules: String?, catalog: WorkspaceCatalog, creatorID: String? = nil) async throws -> [[String]] {
        let inputs = titles.enumerated().map { index, item in
            VideoClassificationPipeline.Input(
                title: item.title, entryID: "youtube:video:synthetic-\(scenario.id)-\(index)",
                creatorID: creatorID ?? "youtube:channel:synthetic-heldout-\(scenario.id)")
        }
        let results = try await pipeline.classifyBatch(
            inputs, platformID: "youtube", classifierType: type, tree: tree, catalog: catalog,
            houseRules: houseRules, maxKnowledgePerVideo: 0)
        return results.map { $0.tags.compactMap { nameByID[$0.tagID] }.sorted() }
    }
    func withLearned(_ rules: String, count: Int) -> String? {
        CorrectionDistiller.combinedHouseRules(manualHouseRules: baseHouseRules, learnedRules: rules, correctionCount: count)
    }

    let scenarios = summaryScenarios.filter { onlyScenario == nil || $0.id.lowercased().contains(onlyScenario!.lowercased()) }
    var totals: [String: DownstreamTally] = [:]
    var writeStats: [SummaryPromptVariant: (captured: Int, toCapture: Int, traps: Int, invented: Int, noRuleRight: Int, noRuleCases: Int, offTax: Int)] = [:]
    for variant in SummaryPromptVariant.allCases { writeStats[variant] = (0, 0, 0, 0, 0, 0, 0) }
    var runOn: [SummaryPromptVariant: Int] = [:]   // outputs that kept going past the rules

    print("══ model: \(modelName)  •  \(scenarios.count) synthetic scenarios ══")
    for scenario in scenarios {
        print("\n────────────────────────────────────────────────────────────────")
        print("▌\(scenario.id)")
        print("  intent: \(scenario.intent)")
        for (index, c) in scenario.corrections.enumerated() {
            let said = c.modelSaid.isEmpty ? "—" : c.modelSaid.joined(separator: "+")
            let wants = c.userWants.isEmpty ? "(no tag)" : c.userWants.joined(separator: "+")
            print("    #\(index + 1) \(c.title)   [\(said) → \(wants)]")
        }

        var rulesByVariant: [SummaryPromptVariant: String] = [:]
        for variant in SummaryPromptVariant.allCases {
            let started = Date()
            let output = try await engine.generateTextForEvaluation(
                prompt: variant.prompt(for: scenario.corrections, allowed: allowedNames),
                maximumTokens: variant.tokenBudget, chat: variant.usesChat)
            let seconds = Date().timeIntervalSince(started)
            var injected = variant.injectable(from: output)
            var rejections: [(line: String, why: String)] = []
            if variant == .structured {
                let verified = verifiedRules(output, corrections: scenario.corrections, allowed: allowedNames)
                injected = verified.kept.joined(separator: "\n"); rejections = verified.rejected
            }
            let a = assessRules(injected, rawOutput: output, scenario: scenario, allowed: allowedNames)
            rulesByVariant[variant] = injected
            print("\n  ◆ \(variant.rawValue)  (\(String(format: "%.1f", seconds))s, \(output.count) chars → injects \(injected.count))")
            for line in output.split(whereSeparator: \.isNewline) { print("      \(line)") }
            for rejection in rejections { print("      ✂ verifier rejected: \(rejection.why)") }
            if variant == .structured { for line in injected.split(whereSeparator: \.isNewline) { print("      ✔ injects: \(line)") } }
            var verdict: [String] = []
            if a.toCapture > 0 { verdict.append("captured \(a.captured)/\(a.toCapture)") }
            if scenario.expectNoRule { verdict.append(a.inventedFromNothing ? "✗ INVENTED \(a.lines.count) rule(s) from nothing" : "✓ correctly wrote no rule") }
            if !a.trapsTaken.isEmpty { verdict.append("✗ TRAP: " + a.trapsTaken.joined(separator: " ¦ ")) }
            if !a.offTaxonomyQuotes.isEmpty { verdict.append("⚠ off-taxonomy quotes: \(a.offTaxonomyQuotes)") }
            print("      ⇒ " + (verdict.isEmpty ? "—" : verdict.joined(separator: "  •  ")))
            if output.contains("Corrections:") || output.contains("Refined") || output.count > 900 { runOn[variant, default: 0] += 1 }
            var s = writeStats[variant]!
            s.captured += a.captured; s.toCapture += a.toCapture; s.traps += a.trapsTaken.count; s.offTax += a.offTaxonomyQuotes.count
            if scenario.expectNoRule { s.noRuleCases += 1; if a.inventedFromNothing { s.invented += 1 } else { s.noRuleRight += 1 } }
            writeStats[variant] = s
        }

        guard !skipDownstream else { continue }
        // The production mechanism today: corrections live in the catalog and the
        // most similar ones are retrieved per video as few-shot exemplars.
        var exemplarCatalog = emptyCatalog
        exemplarCatalog.correctionExamples = scenario.corrections.enumerated().map { index, c in
            CorrectionExample(
                id: "synthetic-\(scenario.id)-\(index)", classifierTypeID: type.id, platformID: "youtube",
                entryID: "youtube:video:synthetic-correction-\(scenario.id)-\(index)",
                creatorID: "youtube:channel:synthetic-corrected-\(scenario.id)", title: c.title,
                correctTagIDs: c.userWants.compactMap { idByName[$0.lowercased()] }, note: c.note,
                createdAtMilliseconds: Int64(1_700_000_000_000 + index))
        }
        // What a LIVE CORRECTION really leaves behind, for that creator's next videos:
        // the exemplar AND the authoritative row (human-corrected, confidence 5) that
        // rebuilds the creator prior — exactly what submitCorrection stores.
        let correctedCreator = "youtube:channel:synthetic-corrected-\(scenario.id)"
        var liveCatalog = exemplarCatalog
        for (index, c) in scenario.corrections.enumerated() {
            liveCatalog.upsertVideoClassification(VideoClassification(
                classifierTypeID: type.id, platformID: "youtube",
                entryID: "youtube:video:synthetic-correction-\(scenario.id)-\(index)", creatorID: correctedCreator,
                treeID: tree.id, treeRevision: tree.revision,
                tags: c.userWants.compactMap { idByName[$0.lowercased()] }.map { ScoredTag(tagID: $0, confidence: ScoredTag.maxConfidence) },
                source: .humanCorrected, modelVersion: "human-correction-v1"))
        }
        let titles = scenario.heldOut + globalControls
        let conditions: [(name: String, rules: String?, catalog: WorkspaceCatalog, creator: String?)] = [
            ("no-rules", baseHouseRules, emptyCatalog, nil),
            ("exemplars(prod)", baseHouseRules, exemplarCatalog, nil),
            ("live:same-creator", baseHouseRules, liveCatalog, correctedCreator),
            ("rules:as-shipped", withLearned(rulesByVariant[.asShipped] ?? "", count: scenario.corrections.count), emptyCatalog, nil),
            ("rules:orig+chat", withLearned(rulesByVariant[.originalChat] ?? "", count: scenario.corrections.count), emptyCatalog, nil),
            ("rules:verified", withLearned(rulesByVariant[.structured] ?? "", count: scenario.corrections.count), emptyCatalog, nil),
            ("rules:oracle", withLearned(scenario.oracleRule.isEmpty ? "" : "- " + scenario.oracleRule, count: scenario.corrections.count), emptyCatalog, nil),
        ]
        print("\n  ▸ downstream: held-out titles classified under each condition")
        // FIX  passes when every wanted tag is present and none of the tags the
        //      classifier used to give wrongly remain.
        // KEEP passes when its own tags are present and none of the tags this
        //      scenario's corrections were pushing (the poison) leaked onto it.
        let pushed = Set(scenario.corrections.flatMap(\.userWants))
        let wasWrong = Set(scenario.corrections.flatMap(\.modelSaid))
        func passes(_ got: [String], _ item: HeldOutTitle) -> Bool {
            let gotSet = Set(got), want = Set(item.expect)
            if item.shouldChange {
                if want.isEmpty { return gotSet.isEmpty }
                return want.isSubset(of: gotSet) && gotSet.isDisjoint(with: wasWrong.subtracting(want))
            }
            return want.isSubset(of: gotSet) && gotSet.isDisjoint(with: pushed.subtracting(want))
        }
        var table: [[[String]]] = []
        for condition in conditions {
            table.append(try await classify(titles, scenario: scenario, houseRules: condition.rules, catalog: condition.catalog, creatorID: condition.creator))
        }
        for (row, item) in titles.enumerated() {
            let want = item.expect.isEmpty ? "(none)" : item.expect.sorted().joined(separator: "+")
            let cells = conditions.indices.map { c -> String in
                let got = table[c][row]
                let ok = passes(got, item)
                return (ok ? "✓" : "✗") + (got.isEmpty ? "(none)" : got.joined(separator: "+"))
            }
            let kind = item.shouldChange ? "FIX " : "KEEP"
            print("    [\(kind)] \(item.title.prefix(52))")
            print("           want \(want)")
            for (c, condition) in conditions.enumerated() { print("           \(condition.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(cells[c])") }
        }
        for (c, condition) in conditions.enumerated() {
            var tally = totals[condition.name] ?? DownstreamTally()
            for (row, item) in titles.enumerated() {
                let ok = passes(table[c][row], item)
                if item.shouldChange { tally.toFix += 1; if ok { tally.fixed += 1 } }
                else { tally.toKeep += 1; if ok { tally.intact += 1 } else { tally.misses.append("\(scenario.id): \(item.title.prefix(40)) → \(table[c][row].joined(separator: "+"))") } }
            }
            totals[condition.name] = tally
        }
    }

    print("\n════════════════════════════ SUMMARY — \(modelName) ════════════════════════════")
    print("WHAT IT WRITES")
    for variant in SummaryPromptVariant.allCases {
        let s = writeStats[variant]!
        let label: String = variant.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
        let captured: String = "rules captured \(s.captured)/\(s.toCapture)"
        let invented: String = "invented-from-nothing \(s.invented)/\(s.noRuleCases)"
        print("  " + label + " " + captured + "   traps taken \(s.traps)   " + invented + "   off-taxonomy quotes \(s.offTax)")
    }
    guard !skipDownstream else { return }
    for variant in SummaryPromptVariant.allCases where (runOn[variant] ?? 0) > 0 {
        print("  \(variant.rawValue): \(runOn[variant]!)/\(scenarios.count) outputs ran on past the rules (hallucinated more corrections / 'refined' sections)")
    }
    print("WHAT IT DOES  (held-out titles; FIX = wanted tags present & old wrong tag gone, KEEP = own tags present & no leaked tag)")
    for name in ["no-rules", "exemplars(prod)", "live:same-creator", "rules:as-shipped", "rules:orig+chat", "rules:verified", "rules:oracle"] {
        guard let t = totals[name] else { continue }
        print("  \(name.padding(toLength: 18, withPad: " ", startingAt: 0)) fixed \(t.fixed)/\(t.toFix)   kept intact \(t.intact)/\(t.toKeep)")
    }
    for name in ["exemplars(prod)", "live:same-creator", "rules:as-shipped", "rules:orig+chat", "rules:verified", "rules:oracle"] {
        guard let t = totals[name], let base = totals["no-rules"] else { continue }
        let baseMisses = Set(base.misses.map { String($0.prefix(while: { $0 != "→" })) })
        let poisoned = t.misses.filter { !baseMisses.contains(String($0.prefix(while: { $0 != "→" }))) }
        if !poisoned.isEmpty {
            print("  POISONED by \(name) (right with no rules, wrong with them):")
            for line in poisoned { print("     - \(line)") }
        }
    }
}
