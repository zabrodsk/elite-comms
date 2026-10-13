import Foundation
import Testing
@testable import EliteComms

struct DelegationTests {
    @Test func freshInstallRequiresAnAssignment() {
        let suite = "elite-comms-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        #expect(!settings.isConfigured)
        #expect(settings.country.isEmpty)
        #expect(settings.committee.isEmpty)
        #expect(settings.topic.isEmpty)
        #expect(settings.delegateName.isEmpty)
        settings.country = "Japan"
        settings.committee = "WHO"
        settings.topic = "Pandemic preparedness"
        #expect(settings.isConfigured)
        #expect(Settings(defaults: defaults).committee == "WHO")
        let prompt = Prompts.system(settings: settings, brief: "Our health policy")
        #expect(prompt.contains("Japan"))
        #expect(prompt.contains("WHO"))
        #expect(prompt.contains("Pandemic preparedness"))
        #expect(!prompt.contains("SunnyMUN"))
    }

    @Test func exactCountryNamesKeepTheirIdentity() {
        let defaults = UserDefaults(suiteName: "elite-comms-tests-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        for (input, output) in [("Republic of Korea", "Republic of Korea"),
                                ("Democratic Republic of the Congo", "Democratic Republic of the Congo"),
                                ("Commonwealth of Australia", "Australia"), ("UK", "United Kingdom"),
                                ("Atlantis", "Atlantis")] {
            settings.country = input
            #expect(settings.shortCountry == output)
        }
    }

    @Test func everyCountryCanBeAddressed() {
        for country in Countries.names {
            #expect(DelegationDetector.check("Question to the delegation of \(country): what is your position?", country: country) == .directed)
            #expect(DelegationDetector.check("We heard the proposal from \(country).", country: country) == .mention)
            #expect(SelfSpeech.soundsLikeUs("The delegation of \(country) supports this proposal.", country: country))
        }
    }

    @Test func aliasesAndBoundaries() {
        #expect(DelegationDetector.check("Why does the UK oppose this proposal?", country: "United Kingdom") == .directed)
        #expect(DelegationDetector.check("We welcome South Korea's proposal.", country: "Republic of Korea") == .mention)
        #expect(DelegationDetector.check("Question to the delegation of Australia.", country: "Japan") == .none)
        #expect(DelegationDetector.check("We welcome Austria's proposal.", country: "Australia") == .none)
        #expect(DelegationDetector.check("Iranian delegates are speaking.", country: "Iran") == .none)
        #expect(DelegationDetector.check("Anyone may answer.", country: "") == .none)
        #expect(DelegationDetector.check("Question to the delegation of Atlantis.", country: "Atlantis") == .directed)
    }

    @Test @MainActor func ownSpeechDoesNotCreateAResponse() {
        let keys = ["country", "committee", "topic", "autoDraft"]
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let model = AppModel()
        model.settings.country = "Japan"
        model.settings.committee = "WHO"
        model.settings.topic = "Pandemic preparedness"
        model.settings.autoDraft = false
        model.ingest("The delegation of Japan supports open health cooperation.", confidence: nil)
        model.ingest("Japan believes countries should share early warnings.", confidence: nil)
        #expect(model.moments.isEmpty)
        model.ingest("Question to the delegate of Japan: how will you fund early warnings?", confidence: nil)
        #expect(model.moments.count == 1)
        #expect(model.moments.first?.kind == .directed)
        #expect(model.moments.first?.quote.contains("fund early warnings") == true)
    }

    @Test func customDelegationCanTakeTheFloor() {
        var tracker = SpeakerTracker()
        let chair = tracker.ingest("Atlantis, you have the floor.", selectedCountry: "Atlantis")
        #expect(chair.label == "Chair")
        #expect(chair.floorCountry == "Atlantis")
        let delegate = tracker.ingest("Thank you, Chair. We support this proposal.", selectedCountry: "Atlantis")
        #expect(delegate.label == "Atlantis")
    }

    @Test func bulletsPrecedeFullAnswer() {
        let draft = Prompts.draft(kind: .directed, quote: "Why?", speaker: "China", transcript: "", country: "Japan")
        #expect(draft.range(of: "**Points**")!.lowerBound < draft.range(of: "**Full answer**")!.lowerBound)
        #expect(draft.contains("3–7 words, not a sentence"))
    }
}
