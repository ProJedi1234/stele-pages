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
