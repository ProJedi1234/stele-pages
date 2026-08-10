import Testing

@testable import SteleCore

@Suite("Configuration")
struct ConfigurationTests {
    /// The smallest environment that starts the server. Tests override individual keys
    /// so each one states only the thing it's actually about.
    static func environment(_ overrides: [String: String] = [:]) -> [String: String] {
        var base = [
            "STELE_UPLOAD_TOKEN": String(repeating: "a", count: 32),
            "DATABASE_URL": "postgres://stele:secret@localhost:5432/stele",
        ]
        for (key, value) in overrides { base[key] = value }
        return base
    }

    @Test func appliesDefaults() throws {
        let configuration = try Configuration(environment: Self.environment())
        #expect(configuration.host == "127.0.0.1")
        #expect(configuration.port == 8080)
        #expect(configuration.slugWords == 3)
        #expect(configuration.maxPageBytes == 1024 * 1024)
        #expect(configuration.baseURL == "http://127.0.0.1:8080")
        // GitHub sign-in is unconfigured until an operator configures it, and
        // unconfigured means nobody may mint — see `GitHubConfigurationTests`.
        #expect(configuration.githubOwners.isEmpty)
        #expect(configuration.githubClientID == nil)
    }

    @Test func requiresAnUploadToken() {
        var environment = Self.environment()
        environment["STELE_UPLOAD_TOKEN"] = nil
        #expect(throws: ConfigurationError.self) { try Configuration(environment: environment) }
    }

    /// A short token is worse than no token: it looks configured while being guessable.
    @Test func rejectsShortUploadToken() {
        #expect(throws: ConfigurationError.self) {
            try Configuration(environment: Self.environment(["STELE_UPLOAD_TOKEN": "hunter2"]))
        }
    }

    /// Blank must mean "unset", not "a value that happens to be whitespace". Checked on
    /// a variable with a default, where the two behaviours diverge: blank-as-unset falls
    /// back to 8080, while blank-as-value would fail port validation.
    @Test func treatsBlankValuesAsUnset() throws {
        let configuration = try Configuration(environment: Self.environment(["STELE_PORT": "   "]))
        #expect(configuration.port == 8080)
        // For a required variable, blank means missing, and missing throws.
        #expect(throws: ConfigurationError.self) {
            try Configuration(environment: Self.environment(["STELE_UPLOAD_TOKEN": "   "]))
        }
    }

    @Test func requiresDatabaseURL() {
        var environment = Self.environment()
        environment["DATABASE_URL"] = nil
        #expect(throws: ConfigurationError.self) { try Configuration(environment: environment) }
    }

    @Test("rejects malformed ports", arguments: ["0", "70000", "eight", "-1"])
    func rejectsBadPort(_ port: String) {
        #expect(throws: ConfigurationError.self) {
            try Configuration(environment: Self.environment(["STELE_PORT": port]))
        }
    }

    @Test("rejects slug word counts outside 3...4", arguments: ["2", "5", "three"])
    func rejectsBadSlugWords(_ words: String) {
        #expect(throws: ConfigurationError.self) {
            try Configuration(environment: Self.environment(["STELE_SLUG_WORDS": words]))
        }
    }

    @Test func stripsTrailingSlashFromBaseURL() throws {
        let configuration = try Configuration(
            environment: Self.environment(["STELE_BASE_URL": "https://xyz.domain/"])
        )
        #expect(configuration.baseURL == "https://xyz.domain")
    }
}

@Suite("GitHub sign-in configuration")
struct GitHubConfigurationTests {
    /// Every case goes through `Configuration(environment:)` rather than reaching for the
    /// parser directly, because the environment is how this value actually arrives: the
    /// trimming and blank-is-unset handling in `value(_:)` sit between the operator's
    /// `STELE_GITHUB_OWNERS=` and the allowlist, and they are part of what is being pinned.
    static func allowlist(_ raw: String?) throws -> GitHubOwnerAllowlist {
        var environment = ConfigurationTests.environment()
        environment["STELE_GITHUB_OWNERS"] = raw
        return try Configuration(environment: environment).githubOwners
    }

    @Test func parsesACommaSeparatedAllowlist() throws {
        let owners = try Self.allowlist(" ProJedi1234 , other-user ,,")
        #expect(!owners.isEmpty)
        #expect(owners.permits("ProJedi1234"))
        #expect(owners.permits("other-user"))
        #expect(!owners.permits("someone-else"))
        // The empty entries between those commas are dropped rather than stored, so a
        // caller presenting an empty login cannot match one of them.
        #expect(!owners.permits(""))
        // An entry is a whole login, not a pattern. A stranger being refused does not pin
        // that on its own: both of these are registerable GitHub accounts, and a rewrite to
        // prefix or substring matching — the shape somebody reaches for when adding
        // organisation-wide or wildcard entries — would leave the line above passing while
        // handing a publishing credential to an account nobody listed.
        #expect(!owners.permits("proj"))
        #expect(!owners.permits("projedi12345"))
    }

    /// A value that arrived from anything file-shaped — a CRLF `.env`, a YAML block scalar,
    /// a secrets tool that appends a line ending — carries that ending on its last entry,
    /// and `value(_:)`'s own trim does not take it off. Left there it would strand exactly
    /// one login in an otherwise working list, which is the misconfiguration nothing
    /// downstream can report: the list is non-empty, so it looks configured, and the
    /// sign-in it refuses is deliberately silent about why.
    @Test func lineEndingsInTheListDoNotStrandTheLastLogin() throws {
        let unixEnding = try Self.allowlist("alice,projedi1234\n")
        #expect(unixEnding.permits("projedi1234"))

        let windowsEnding = try Self.allowlist("alice,projedi1234\r\n")
        #expect(windowsEnding.permits("projedi1234"))

        let acrossLines = try Self.allowlist("alice,\nprojedi1234\n")
        #expect(acrossLines.permits("alice"))
        #expect(acrossLines.permits("projedi1234"))
    }

    /// The fail-closed guarantee, asserted as the guarantee rather than as the parse.
    /// `isEmpty` is the mechanism; what it is *for* is that a deployment which has not
    /// configured GitHub sign-in has no login at all — not the operator's own, not any
    /// spelling of it, not an empty one — that can be traded for a credential. Anything
    /// that gates minting on `permits(_:)` therefore refuses everything here without
    /// having to know that it should.
    @Test func withNoOwnersConfiguredNoLoginCanMintACredential() throws {
        let owners = try Self.allowlist(nil)
        #expect(owners.isEmpty)
        for login in ["projedi1234", "ProJedi1234", "octocat", "admin", "root", ""] {
            #expect(!owners.permits(login), "an unconfigured allowlist admitted \(login)")
        }
    }

    /// Blank and separator-only spellings reach the allowlist by different routes — `"   "`
    /// is mapped to nil by `value(_:)` before it gets there, while `","` is a perfectly
    /// good non-blank string that arrives intact — and both have to land in the same place:
    /// no login permitted, and no crash on the way.
    @Test(
        "a blank or separator-only owner list still mints nothing",
        arguments: ["", "   ", ",", " , ", ",,,"]
    )
    func aBlankOwnerListStillMintsNothing(_ raw: String) throws {
        let owners = try Self.allowlist(raw)
        #expect(owners.isEmpty)
        #expect(!owners.permits("projedi1234"))
        #expect(!owners.permits("ProJedi1234"))
    }

    /// GitHub logins are case-insensitive, so an operator who typed the casing GitHub
    /// shows must not have locked out the same account spelled any other way. Both
    /// directions are here because the fold is on both sides of the comparison: it must
    /// not matter which side carries GitHub's canonical casing.
    @Test func ownerMatchingIsCaseInsensitive() throws {
        let configuredInMixedCase = try Self.allowlist("ProJedi1234")
        #expect(configuredInMixedCase.permits("ProJedi1234"))
        #expect(configuredInMixedCase.permits("projedi1234"))
        #expect(configuredInMixedCase.permits("PROJEDI1234"))

        let configuredInLowercase = try Self.allowlist("projedi1234")
        #expect(configuredInLowercase.permits("ProJedi1234"))
    }

    @Test func readsTheGitHubClientID() throws {
        var environment = ConfigurationTests.environment([
            "STELE_GITHUB_CLIENT_ID": "  Ov23liEXAMPLE0000  "
        ])
        #expect(try Configuration(environment: environment).githubClientID == "Ov23liEXAMPLE0000")

        // Blank means unset here as it does everywhere else, so an operator who left the
        // line in `.env` with nothing after the `=` has no app configured rather than one
        // whose ID is a space.
        environment["STELE_GITHUB_CLIENT_ID"] = "   "
        #expect(try Configuration(environment: environment).githubClientID == nil)
    }
}

@Suite("DATABASE_URL parsing")
struct DatabaseURLTests {
    @Test func parsesAFullURL() throws {
        let (config, description) = try Configuration.parseDatabaseURL(
            "postgres://stele:s3cret@198.51.100.10:5433/stele"
        )
        #expect(config.host == "198.51.100.10")
        #expect(config.port == 5433)
        #expect(config.username == "stele")
        #expect(config.password == "s3cret")
        #expect(config.database == "stele")
        #expect(!description.contains("s3cret"))
    }

    @Test func defaultsToThePostgresPort() throws {
        let (config, _) = try Configuration.parseDatabaseURL("postgres://stele@db.example.com/stele")
        #expect(config.port == 5432)
    }

    @Test func acceptsThePostgresqlScheme() throws {
        let (config, _) = try Configuration.parseDatabaseURL("postgresql://stele@db.example.com/stele")
        #expect(config.host == "db.example.com")
    }

    /// Passwords generated with `openssl rand -base64` routinely contain `/` and `+`,
    /// which must be percent-encoded in a URL and decoded back out here.
    @Test func decodesPercentEncodedPasswords() throws {
        let (config, _) = try Configuration.parseDatabaseURL(
            "postgres://stele:p%40ss%2Fword@db.example.com/stele"
        )
        #expect(config.password == "p@ss/word")
    }

    @Test("rejects URLs missing a required part", arguments: [
        "mysql://stele:x@db.example.com/stele",
        "postgres://db.example.com/stele",
        "postgres://stele@db.example.com",
        "postgres://stele@db.example.com/",
        "not a url at all",
    ])
    func rejectsIncompleteURLs(_ raw: String) {
        #expect(throws: ConfigurationError.self) { try Configuration.parseDatabaseURL(raw) }
    }

    @Test func rejectsUnknownSSLMode() {
        #expect(throws: ConfigurationError.self) {
            try Configuration.parseDatabaseURL("postgres://stele:x@db.example.com/stele?sslmode=maybe")
        }
    }

    @Test("accepts libpq sslmode values", arguments: [
        "disable", "prefer", "allow", "require", "verify-ca", "verify-full",
    ])
    func acceptsKnownSSLModes(_ mode: String) throws {
        let (_, description) = try Configuration.parseDatabaseURL(
            "postgres://stele:x@db.example.com/stele?sslmode=\(mode)"
        )
        #expect(description.contains("sslmode=\(mode)"))
    }

    /// A bad `DATABASE_URL` gets echoed back in the startup error, so the password must
    /// not survive that round trip into the logs.
    @Test func redactionRemovesThePassword() {
        let redacted = Configuration.redact("postgres://stele:s3cret@db.example.com:5432/stele")
        #expect(!redacted.contains("s3cret"))
        #expect(redacted.contains("db.example.com"))
    }

    /// The only values `redact` ever sees are ones that already failed to parse, so it
    /// must not leak the password when the `://` or `@` markers are mangled or missing.
    @Test("redaction survives malformed URLs", arguments: [
        "stele:s3cret@db.example.com:5432/stele",
        "postgres:/stele:s3cret@db.example.com:5432/stele",
        "postgres//stele:s3cret@db.example.com/stele",
        "s3cret@://",
    ])
    func redactionSurvivesMalformedURLs(_ raw: String) {
        #expect(!Configuration.redact(raw).contains("s3cret"))
    }
}
