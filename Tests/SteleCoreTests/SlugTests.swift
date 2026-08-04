import Testing

@testable import SteleCore

/// Deterministic RNG so generator tests assert on exact output instead of properties
/// that happen to hold. SplitMix64 — small, well-distributed, and reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Slug validation")
struct SlugValidationTests {
    @Test("accepts ordinary slugs", arguments: [
        "quiet-cedar-otter", "abc", "my-page-2", "a1-b2-c3",
        String(repeating: "a", count: 64),
    ])
    func acceptsValid(_ candidate: String) throws {
        #expect(try Slug(custom: candidate).value == candidate)
    }

    @Test func rejectsTooShort() {
        #expect(throws: SlugError.tooShort(min: 3)) { try Slug(custom: "ab") }
    }

    @Test func rejectsTooLong() {
        #expect(throws: SlugError.tooLong(max: 64)) {
            try Slug(custom: String(repeating: "a", count: 65))
        }
    }

    @Test("rejects characters that make a URL ambiguous", arguments: [
        "Quiet-Cedar", "my_page", "my page", "page!", "café-page", "a/b", "a.b", "a%20b",
    ])
    func rejectsBadCharacters(_ candidate: String) {
        #expect(throws: SlugError.self) { try Slug(custom: candidate) }
    }

    @Test("rejects hyphens in the wrong places", arguments: ["-abc", "abc-", "a--b"])
    func rejectsBadHyphens(_ candidate: String) {
        #expect(throws: SlugError.self) { try Slug(custom: candidate) }
    }

    @Test func rejectsReservedNames() {
        #expect(throws: SlugError.reserved("pages")) { try Slug(custom: "pages") }
        #expect(throws: SlugError.reserved("healthz")) { try Slug(custom: "healthz") }
        #expect(throws: SlugError.reserved("assets")) { try Slug(custom: "assets") }
        #expect(throws: SlugError.reserved("skill")) { try Slug(custom: "skill") }
    }

    /// Every route the server defines itself must be unreachable as a custom slug,
    /// otherwise a caller could claim a name that then 404s forever. `buildRouter`
    /// registers its routes from `ServerRoute`, so checking against that set means a
    /// new route can't be added without either updating `Slug.reserved` or failing here.
    @Test func reservedListCoversServerRoutes() {
        #expect(!ServerRoute.names.isEmpty)
        for route in ServerRoute.names {
            #expect(Slug.reserved.contains(route), "route '\(route)' is not in Slug.reserved")
        }
    }
}

@Suite("Slug generation")
struct SlugGenerationTests {
    @Test func generatesThreeWordsByDefault() {
        var rng = SeededGenerator(seed: 42)
        let slug = SlugGenerator().generate(using: &rng)
        #expect(slug.value.split(separator: "-").count == 3)
    }

    @Test func generatesFourWordsWhenAsked() {
        var rng = SeededGenerator(seed: 42)
        let slug = SlugGenerator(wordCount: 4).generate(using: &rng)
        #expect(slug.value.split(separator: "-").count == 4)
    }

    @Test("word count is clamped to a range that reads well", arguments: [
        (0, 3), (1, 3), (2, 3), (3, 3), (4, 4), (5, 4), (99, 4),
    ])
    func clampsWordCount(requested: Int, expected: Int) {
        #expect(SlugGenerator(wordCount: requested).wordCount == expected)
    }

    @Test func isDeterministicForAGivenSeed() {
        var first = SeededGenerator(seed: 7)
        var second = SeededGenerator(seed: 7)
        #expect(SlugGenerator().generate(using: &first).value
            == SlugGenerator().generate(using: &second).value)
    }

    /// The pools overlap slightly ("amber" is both an adjective and a mineral), so this
    /// guards the redraw that stops "amber-amber-otter" from being emitted.
    @Test func neverRepeatsAdjacentWords() {
        for seed in UInt64(0)..<2_000 {
            var rng = SeededGenerator(seed: seed)
            for wordCount in [3, 4] {
                let words = SlugGenerator(wordCount: wordCount)
                    .generate(using: &rng).value.split(separator: "-")
                for (left, right) in zip(words, words.dropFirst()) {
                    #expect(left != right, "adjacent repeat from seed \(seed)")
                }
            }
        }
    }

    /// Generated slugs go into the database without passing through `Slug(custom:)`,
    /// so this is the only thing standing between a bad wordlist entry and a page that
    /// can never be fetched back. Both word counts run: the four-word shape is the one
    /// with the least length headroom, so it's the one a long compound word breaks first.
    @Test func everyGeneratedSlugPassesValidation() throws {
        for seed in UInt64(0)..<2_000 {
            var rng = SeededGenerator(seed: seed)
            for wordCount in [3, 4] {
                let generated = SlugGenerator(wordCount: wordCount).generate(using: &rng)
                let revalidated = try Slug(custom: generated.value)
                #expect(revalidated == generated)
            }
        }
    }

    /// Pins the exact figures the README advertises (pool sizes and keyspace), so a
    /// wordlist edit has to update the documentation in the same change or fail here.
    @Test func keyspaceMatchesAdvertisedFigures() {
        #expect(Wordlists.adjectives.count == 253)
        #expect(Wordlists.natureNouns.count == 208)
        #expect(Wordlists.creatureNouns.count == 224)
        #expect(SlugGenerator(wordCount: 3).keyspace == 11_787_776)
        #expect(SlugGenerator(wordCount: 4).keyspace == 2_982_307_328)
    }
}

@Suite("Wordlists")
struct WordlistTests {
    static let pools: [(String, [String])] = [
        ("adjectives", Wordlists.adjectives),
        ("natureNouns", Wordlists.natureNouns),
        ("creatureNouns", Wordlists.creatureNouns),
    ]

    /// A duplicate silently biases the generator toward that word and shrinks the real
    /// keyspace below the advertised figure.
    @Test("no pool contains a duplicate", arguments: pools)
    func poolsAreUnique(name: String, words: [String]) {
        #expect(Set(words).count == words.count, "\(name) contains duplicates")
    }

    @Test("every word is slug-safe on its own", arguments: pools)
    func wordsAreSlugSafe(name: String, words: [String]) {
        for word in words {
            #expect(
                word.allSatisfy { $0.isASCII && $0.isLowercase },
                "\(name) contains '\(word)', which is not lowercase ASCII"
            )
        }
    }

    /// Guards against a future edit quietly gutting a pool; the keyspace claim in the
    /// README depends on these staying substantial.
    @Test("pools stay large enough to be worth generating from", arguments: pools)
    func poolsAreLargeEnough(name: String, words: [String]) {
        #expect(words.count >= 200, "\(name) has only \(words.count) words")
    }

    @Test func noReservedWordIsAlsoAPoolWord() {
        for (_, words) in Self.pools {
            #expect(Set(words).isDisjoint(with: Slug.reserved))
        }
    }
}
