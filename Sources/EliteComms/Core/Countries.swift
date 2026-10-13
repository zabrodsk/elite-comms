import Foundation

enum Countries {
    /// Canonical name -> spoken aliases (lowercase).
    static let aliases: [String: [String]] = {
        var m: [String: [String]] = [:]
        for name in names { m[name] = [name.lowercased()] }
        let extra: [String: [String]] = [
            "United States": ["united states of america", "usa", "u.s.a.", "the us", "the u.s.", "america", "united states"],
            "United Kingdom": ["uk", "u.k.", "great britain", "britain", "united kingdom of great britain and northern ireland"],
            "Russian Federation": ["russia", "russian federation"],
            "China": ["people's republic of china", "prc", "china"],
            "DPRK": ["north korea", "dprk", "democratic people's republic of korea"],
            "Republic of Korea": ["south korea", "republic of korea", "rok", "korea"],
            "Iran": ["islamic republic of iran", "iran"],
            "Venezuela": ["bolivarian republic of venezuela", "venezuela"],
            "Syria": ["syrian arab republic", "syria"],
            "Bolivia": ["plurinational state of bolivia", "bolivia"],
            "Türkiye": ["turkey", "türkiye", "turkiye"],
            "Côte d'Ivoire": ["ivory coast", "cote d'ivoire", "côte d'ivoire"],
            "Netherlands": ["the netherlands", "netherlands", "holland"],
            "Czechia": ["czech republic", "czechia"],
            "UAE": ["united arab emirates", "uae", "emirates"],
            "Saudi Arabia": ["saudi arabia", "kingdom of saudi arabia"],
            "Vietnam": ["viet nam", "vietnam"],
            "Laos": ["lao people's democratic republic", "laos"],
            "Holy See": ["holy see", "vatican"],
            "State of Palestine": ["palestine", "state of palestine"],
            "European Union": ["european union", "the eu"],
            "Papua New Guinea": ["papua new guinea", "png"],
        ]
        for (k, v) in extra { m[k, default: []].append(contentsOf: v) }
        return m
    }()

    static let names: [String] = [
        "Afghanistan", "Albania", "Algeria", "Andorra", "Angola", "Antigua and Barbuda", "Argentina", "Armenia",
        "Australia", "Austria", "Azerbaijan", "Bahamas", "Bahrain", "Bangladesh", "Barbados", "Belarus", "Belgium",
        "Belize", "Benin", "Bhutan", "Bolivia", "Bosnia and Herzegovina", "Botswana", "Brazil", "Brunei", "Bulgaria",
        "Burkina Faso", "Burundi", "Cabo Verde", "Cambodia", "Cameroon", "Canada", "Central African Republic", "Chad",
        "Chile", "China", "Colombia", "Comoros", "Congo", "Democratic Republic of the Congo", "Costa Rica", "Côte d'Ivoire",
        "Croatia", "Cuba", "Cyprus", "Czechia", "Denmark", "Djibouti", "Dominica", "Dominican Republic", "Ecuador",
        "Egypt", "El Salvador", "Equatorial Guinea", "Eritrea", "Estonia", "Eswatini", "Ethiopia", "Fiji", "Finland",
        "France", "Gabon", "Gambia", "Georgia", "Germany", "Ghana", "Greece", "Grenada", "Guatemala", "Guinea",
        "Guinea-Bissau", "Guyana", "Haiti", "Honduras", "Hungary", "Iceland", "India", "Indonesia", "Iran", "Iraq",
        "Ireland", "Israel", "Italy", "Jamaica", "Japan", "Jordan", "Kazakhstan", "Kenya", "Kiribati", "Kuwait",
        "Kyrgyzstan", "Laos", "Latvia", "Lebanon", "Lesotho", "Liberia", "Libya", "Liechtenstein", "Lithuania",
        "Luxembourg", "Madagascar", "Malawi", "Malaysia", "Maldives", "Mali", "Malta", "Marshall Islands", "Mauritania",
        "Mauritius", "Mexico", "Micronesia", "Moldova", "Monaco", "Mongolia", "Montenegro", "Morocco", "Mozambique",
        "Myanmar", "Namibia", "Nauru", "Nepal", "Netherlands", "New Zealand", "Nicaragua", "Niger", "Nigeria",
        "North Macedonia", "Norway", "Oman", "Pakistan", "Palau", "Panama", "Papua New Guinea", "Paraguay", "Peru",
        "Philippines", "Poland", "Portugal", "Qatar", "Romania", "Russian Federation", "Rwanda", "Saint Kitts and Nevis",
        "Saint Lucia", "Saint Vincent and the Grenadines", "Samoa", "San Marino", "Sao Tome and Principe", "Saudi Arabia",
        "Senegal", "Serbia", "Seychelles", "Sierra Leone", "Singapore", "Slovakia", "Slovenia", "Solomon Islands",
        "Somalia", "South Africa", "South Sudan", "Spain", "Sri Lanka", "Sudan", "Suriname", "Sweden", "Switzerland",
        "Syria", "Tajikistan", "Tanzania", "Thailand", "Timor-Leste", "Togo", "Tonga", "Trinidad and Tobago", "Tunisia",
        "Türkiye", "Turkmenistan", "Tuvalu", "Uganda", "Ukraine", "UAE", "United Kingdom", "United States", "Uruguay",
        "Uzbekistan", "Vanuatu", "Venezuela", "Vietnam", "Yemen", "Zambia", "Zimbabwe", "DPRK", "Republic of Korea",
        "Holy See", "State of Palestine", "European Union",
    ]

    /// Sorted longest-first so "democratic republic of the congo" wins over "congo".
    private static let lookup: [(String, String)] = aliases
        .flatMap { k, vs in vs.map { ($0, k) } }
        .sorted { $0.0.count > $1.0.count }

    static func canonical(in fragment: String) -> String? {
        let text = normalize(fragment)
        for (alias, name) in lookup {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: normalize(alias)) + #"(?![\p{L}\p{N}])"#
            if text.range(of: pattern, options: .regularExpression) != nil { return name }
        }
        return nil
    }

    static func canonicalLabel(_ label: String) -> String? {
        let normalized = normalize(label).trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "chair" { return "Chair" }
        return lookup.first { normalize($0.0) == normalized }?.1
    }

    static let spokenPattern = "(?:" + lookup.map { NSRegularExpression.escapedPattern(for: normalize($0.0)) }
        .joined(separator: "|") + ")"

    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

/// Combines chair/floor/self-reference evidence with session-local voice fingerprints.
struct SpeakerTracker {
    struct Tag {
        var label: String?
        var voiceID: Int?
        var source: Segment.SpeakerSource?
        var floorCountry: String?
    }
    private(set) var registry = VoiceRegistry()
    private var pendingFloor: String?
    private var pendingAt: Double?
    private var fallbackSpeaker: String?
    private var previousVoice: Int?
    private var previousEnd: Double?

    private static let country = "(" + Countries.spokenPattern + #")(?![\p{L}\p{N}])"#
    private static let floorPatterns = [
        #"\brecogni[sz](?:es|e|ing|ed)\s+(?:the\s+)?(?:honou?rable\s+)?(?:delegate|delegation|representative)s?\s+(?:of|from)\s+(?:the\s+)?"# + country,
        #"(?:^|[.!?]\s*)(?:(?:the\s+)?(?:delegate|delegation)\s+of\s+)?(?:the\s+)?"# + country + #",?\s+you\s+(?:now\s+)?(?:have|may take)\s+the\s+floor"#,
        #"\bfloor\s+(?:is\s+)?(?:now\s+)?(?:yours|given|open|goes)\s+(?:to\s+)?(?:the\s+)?(?:delegate|delegation)\s+of\s+(?:the\s+)?"# + country,
        #"\b(?:next|first)\s+(?:speaker|on the speakers'? list)\s+is\s+(?:the\s+)?(?:delegate\s+of\s+)?(?:the\s+)?"# + country
    ]
    private static let chairPattern = #"^(?:thank you,?\s+(?:the\s+)?(?:honou?rable\s+)?delegates?\b|are there any (?:points of information|points|motions)\b|(?:the\s+)?delegate has\b.{0,30}\bseconds\b|(?:this|the) (?:motion|committee|chair)\b|(?:all|delegates|those) (?:in|against) favou?r\b|(?:all|those) (?:in favour|opposed|abstaining)\b|we (?:are|will) now (?:vote|move|proceed|begin|in a moderated caucus|in an unmoderated caucus)\b|the (?:motion|amendment) (?:passes|fails)\b|order\b|delegates,? please\b|seeing no\b|(?:voting|roll call) (?:procedure|will|is|begins)\b|please (?:raise|lower) your placards\b)"#
    private static let thanksChair = #"^(?:thank you|thanks),?\s+(?:(?:the|my)\s+)?(?:(?:honou?rable|distinguished|esteemed|mister|madam|mr\.?|ms\.?)\s+)?chair\b[,.!]?\s*"#
    private static let selfPatterns = [
        #"^(?:the\s+)?(?:delegate|delegation|representative)\s+(?:of|from)\s+(?:the\s+)?"# + country + #"\s+(?:believes?|proposes?|supports?|opposes?|calls?|urges?|requests?|asks?|wishes?|would|will|is|has|considers?|recognises?|recognizes?|welcomes?|recommends?|rejects?|stands?|maintains?)\b"#,
        #"^(?:speaking\s+)?on behalf of\s+(?:the\s+)?"# + country,
        "^" + country + #"\s+(?:believes?|proposes?|supports?|opposes?|calls?|urges?|requests?|wishes?|would|will|considers?|welcomes?|recommends?|rejects?|maintains?)\b"#
    ]

    private static func capturedCountry(_ text: String, patterns: [String]) -> String? {
        let ns = text as NSString
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges > 1 else { continue }
            let raw = ns.substring(with: match.range(at: 1))
            return Countries.canonicalLabel(raw) ?? raw
        }
        return nil
    }

    mutating func ingest(_ text: String, embedding: [Float]? = nil,
                         start: Double? = nil, end: Double? = nil, selectedCountry: String? = nil) -> Tag {
        let extra = selectedCountry?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let customPattern = "(" + NSRegularExpression.escapedPattern(for: Countries.normalize(extra)) + #")(?![\p{L}\p{N}])"#
        let custom = !extra.isEmpty && Countries.canonicalLabel(extra) == nil
        let floorPatterns = Self.floorPatterns + (custom ? Self.floorPatterns.map { $0.replacingOccurrences(of: Self.country, with: customPattern) } : [])
        let selfPatterns = Self.selfPatterns + (custom ? Self.selfPatterns.map { $0.replacingOccurrences(of: Self.country, with: customPattern) } : [])
        let normalized = Countries.normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let floor = Self.capturedCountry(normalized, patterns: floorPatterns).map { $0 == Countries.normalize(extra) ? extra : $0 }
        let delegateGreeting = normalized.range(of: Self.thanksChair, options: .regularExpression) != nil
        let isChair = !delegateGreeting && (floor != nil || normalized.range(of: Self.chairPattern, options: .regularExpression) != nil)
        let ownText = normalized.replacingOccurrences(of: Self.thanksChair, with: "", options: .regularExpression)
        let selfCountry = !isChair ? Self.capturedCountry(ownText, patterns: selfPatterns).map { $0 == Countries.normalize(extra) ? extra : $0 } : nil
        let duration = max(0.3, (end ?? 3) - (start ?? 0))
        let gap = start.flatMap { start in previousEnd.map { start - $0 } }
        let continuation = gap.map { $0 >= 0 && $0 < 0.4 } == true ? previousVoice : nil
        let match = registry.identify(embedding, duration: duration, continuationVoice: continuation,
                                      evidenceLabel: isChair ? "Chair" : selfCountry,
                                      briefAcknowledgement: normalized.range(of: #"^(?:thank you|thanks|yes|no|agreed)[,.!]*$"#, options: .regularExpression) != nil,
                                      delegateGreeting: delegateGreeting)
        let id = match.id
        let oldVoice = id.map { registry.voices[$0] }
        let newTurn = id != previousVoice || delegateGreeting || (start != nil && previousEnd != nil && start! - previousEnd! > 0.8)
        if let start, let pendingAt, start - pendingAt > 45 { pendingFloor = nil }

        var evidence: (String, Double, Segment.SpeakerSource)?
        if isChair { evidence = ("Chair", 0.98, .chairPhrase) }
        else if let selfCountry { evidence = (selfCountry, newTurn ? 0.96 : 0.85, .selfReference) }
        else if let pendingFloor, oldVoice?.label != "Chair", id != nil || delegateGreeting || embedding == nil {
            evidence = (pendingFloor, 0.80, .floor)
        } else if let fallbackSpeaker, oldVoice?.label == nil,
                  gap.map({ $0 >= 0 && $0 < 0.8 }) == true {
            evidence = (fallbackSpeaker, 0.70, .floor)
        }

        if let id, let evidence {
            // A confident existing fingerprint outweighs a weaker, contextual floor rule.
            registry.teach(id, label: evidence.0, confidence: evidence.1, source: evidence.2)
        }
        let voice = id.map { registry.voices[$0] }
        var label = voice?.label ?? evidence?.0
        var source = voice?.manual == true ? Segment.SpeakerSource.manual :
            (evidence?.0 == label ? evidence?.2 : (label != nil ? .voice : nil))

        if id == nil {
            if isChair { label = "Chair"; source = .chairPhrase; fallbackSpeaker = nil }
            else if let selfCountry { label = selfCountry; source = .selfReference; fallbackSpeaker = selfCountry }
            else if delegateGreeting {
                label = pendingFloor; source = label == nil ? nil : .floor; fallbackSpeaker = label
            } else if embedding == nil {
                label = evidence?.0 ?? fallbackSpeaker
                source = evidence?.2 ?? (label == nil ? nil : .floor)
                fallbackSpeaker = label
            }
        }
        if !isChair, label != "Chair", let pendingFloor,
           label == pendingFloor {
            self.pendingFloor = nil
            pendingAt = nil
        }
        if let floor {
            pendingFloor = floor
            pendingAt = end
            fallbackSpeaker = nil
        } else if isChair { fallbackSpeaker = nil }
        previousVoice = id
        previousEnd = end
        return Tag(label: label, voiceID: id, source: source, floorCountry: floor)
    }

    mutating func relabel(voiceID: Int, as label: String) {
        registry.teach(voiceID, label: label, confidence: 1, source: .manual)
    }

    /// Strong but automatic evidence (the delegate read our draft aloud): this voice is our own delegation.
    @discardableResult
    mutating func learnOwnVoice(_ voiceID: Int, as label: String) -> Bool {
        registry.teach(voiceID, label: label, confidence: 0.95, source: .selfReference)
    }

    mutating func reset() { self = SpeakerTracker() }
}

/// Matches the selected delegation, including its known spoken aliases.
enum DelegationDetector {
    enum Hit { case none, mention, directed }

    static func check(_ text: String, country: String) -> Hit {
        let name = country.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .none }
        let canonical = Countries.canonicalLabel(name) ?? Countries.canonical(in: name) ?? name
        let aliases = Set((Countries.aliases[canonical] ?? []) + [name, canonical])
        let c = "(?:" + aliases.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: Countries.normalize($0)) }.joined(separator: "|") + ")"
        let boundary = #"(?![\p{L}\p{N}])"#
        let target = c + boundary
        let patterns = [
            #"(?:question|point of information|poi|ask|asking|directed|addressed)\b.{0,50}\b(?:delegate|delegation|representative)s?\s+(?:of|from)\s+(?:the\s+)?"# + target,
            #"\b(?:to|for)\s+(?:the\s+)?(?:honou?rable\s+)?(?:delegate|delegation)\s+(?:of|from)\s+(?:the\s+)?"# + target,
            #"\b(?:delegate|delegation)\s+of\s+(?:the\s+)?"# + target + #"[^.?!]{0,140}\?"#,
            #"(?<![\p{L}\p{N}])"# + target + #",?\s+(?:do|does|would|could|can|will|how|why|what|is|are|did|has|have)\s+(?:you|your|the delegation|"# + c + ")",
            #"\b(?:does|would|could|can|will|how|why|what|is|did|has)\s+(?:the\s+)?(?:honou?rable\s+)?(?:delegate|delegation)\s+of\s+(?:the\s+)?"# + target,
            #"\b(?:does|would|could|can|will|how|why|what|is|did|has)\s+(?:the\s+)?"# + target + #"[^.?!]{0,140}\?"#,
        ]
        let normalized = Countries.normalize(text)
        let range = NSRange(normalized.startIndex..., in: normalized)
        func matches(_ pattern: String) -> Bool {
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: normalized, range: range) != nil
        }
        if patterns.contains(where: matches) { return .directed }
        if matches(#"(?<![\p{L}\p{N}])"# + target) { return .mention }
        return .none
    }
}
