/// Why a slug was rejected. Each case carries enough detail to tell the caller
/// exactly what to change, rather than a bare "invalid".
public enum SlugError: Error, Equatable, CustomStringConvertible {
    case tooShort(min: Int)
    case tooLong(max: Int)
    case invalidCharacter(Character)
    case leadingOrTrailingHyphen
    case consecutiveHyphens
    case reserved(String)

    public var description: String {
        switch self {
        case .tooShort(let min):
            "must be at least \(min) characters"
        case .tooLong(let max):
            "must be at most \(max) characters"
        case .invalidCharacter(let character):
            "contains '\(character)'; only lowercase letters, digits and hyphens are allowed"
        case .leadingOrTrailingHyphen:
            "must not start or end with a hyphen"
        case .consecutiveHyphens:
            "must not contain two hyphens in a row"
        case .reserved(let value):
            "'\(value)' is reserved by the server"
        }
    }
}

/// A validated page identifier.
///
/// Every slug in the system passes through `Slug.init(custom:)`, whether it was
/// generated here or supplied by a caller, so the database never sees a string that
/// hasn't been checked. The type exists to make that guarantee visible: if you're
/// holding a `Slug`, it's already safe to put in a URL path.
public struct Slug: Hashable, Sendable, CustomStringConvertible {
    public static let minLength = 3
    public static let maxLength = 64

    /// Paths the server serves itself, plus a few kept back for routes we may add.
    /// A custom slug matching one of these would be permanently unreachable, so it's
    /// rejected at write time instead of silently 404ing later.
    public static let reserved: Set<String> = [
        "pages", "page", "healthz", "health", "skill", "status", "metrics",
        "api", "admin", "static", "assets", "robots", "favicon",
        "index", "about", "login", "logout", "new", "edit", "delete",
    ]

    public let value: String

    public var description: String { value }

    /// Validates a caller-supplied slug.
    ///
    /// Deliberately stricter than "what a URL permits": no uppercase, no underscores,
    /// no percent-encoding. A slug that survives this is unambiguous when typed by
    /// hand, read aloud, or pasted into a chat client that likes to linkify things.
    public init(custom value: String) throws(SlugError) {
        guard value.count >= Self.minLength else { throw .tooShort(min: Self.minLength) }
        guard value.count <= Self.maxLength else { throw .tooLong(max: Self.maxLength) }

        for character in value {
            let isAllowed = character.isASCII
                && (character.isLowercase || character.isNumber || character == "-")
            guard isAllowed else { throw .invalidCharacter(character) }
        }

        guard value.first != "-", value.last != "-" else { throw .leadingOrTrailingHyphen }
        guard !value.contains("--") else { throw .consecutiveHyphens }
        guard !Self.reserved.contains(value) else { throw .reserved(value) }

        self.value = value
    }

    /// Trusted construction for strings already read back out of the database.
    /// Skips validation because the value passed it on the way in.
    init(unchecked value: String) {
        self.value = value
    }
}

/// Builds readable slugs by drawing one word from each pool in `Wordlists`.
public struct SlugGenerator: Sendable {
    /// Words per slug. Three reads best (`quiet-cedar-otter`); four buys ~250x the
    /// keyspace at the cost of a longer URL by adding a second adjective.
    public let wordCount: Int

    /// - Parameter wordCount: clamped to 3...4; other values aren't meaningfully
    ///   different and would only complicate the phrase structure.
    public init(wordCount: Int = 3) {
        self.wordCount = min(max(wordCount, 3), 4)
    }

    /// Total distinct slugs this generator can produce.
    public var keyspace: Int {
        let base = Wordlists.adjectives.count * Wordlists.natureNouns.count
            * Wordlists.creatureNouns.count
        return wordCount == 4 ? base * Wordlists.adjectives.count : base
    }

    /// Draws a slug. Callers must still handle collisions — see `PageStore.create`.
    public func generate() -> Slug {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    /// Seedable variant, so tests can assert on exact output.
    public func generate<G: RandomNumberGenerator>(using generator: inout G) -> Slug {
        var pools: [[String]] = [Wordlists.adjectives]
        if wordCount == 4 { pools.append(Wordlists.adjectives) }
        pools.append(Wordlists.natureNouns)
        pools.append(Wordlists.creatureNouns)

        var words: [String] = []
        words.reserveCapacity(pools.count)
        for pool in pools {
            // A handful of words sit in two pools ("amber" is both an adjective and a
            // mineral), so a naive draw can yield "amber-amber-otter". Redraw until the
            // word differs from its neighbour; pools are large enough that this
            // terminates immediately in practice.
            var word = pool.randomElement(using: &generator)!
            while word == words.last {
                word = pool.randomElement(using: &generator)!
            }
            words.append(word)
        }

        return Slug(unchecked: words.joined(separator: "-"))
    }
}
