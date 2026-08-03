import Foundation
import NIOSSL
import PostgresNIO

public enum ConfigurationError: Error, CustomStringConvertible {
    case missing(String, hint: String)
    case invalid(String, value: String, hint: String)

    public var description: String {
        switch self {
        case .missing(let key, let hint):
            "\(key) is not set. \(hint)"
        case .invalid(let key, let value, let hint):
            "\(key) is set to '\(value)', which is not valid. \(hint)"
        }
    }
}

/// Everything the server reads from the environment, resolved once at startup.
///
/// Nothing here is read again later, so a running server can't half-apply a config
/// change, and a bad value fails the process immediately with a message that names
/// the variable rather than surfacing as a connection error ten minutes in.
public struct Configuration: Sendable {
    public var host: String
    public var port: Int
    /// Origin used to build the URL returned by `POST /pages`. Purely cosmetic — the
    /// server serves whatever host it's reached on regardless.
    public var baseURL: String
    public var uploadToken: String
    public var maxPageBytes: Int
    public var slugWords: Int
    public var database: PostgresClient.Configuration
    /// Kept for logging, since `PostgresClient.Configuration` doesn't expose these back.
    public var databaseDescription: String

    /// - Parameter environment: injectable so tests don't have to mutate the process
    ///   environment, which is global and not safe to change concurrently.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        func value(_ key: String) -> String? {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty
            else { return nil }
            return raw
        }

        self.host = value("STELE_HOST") ?? "127.0.0.1"

        if let rawPort = value("STELE_PORT") {
            guard let parsed = Int(rawPort), (1...65535).contains(parsed) else {
                throw ConfigurationError.invalid(
                    "STELE_PORT", value: rawPort, hint: "Expected a port between 1 and 65535."
                )
            }
            self.port = parsed
        } else {
            self.port = 8080
        }

        // Required with no default on purpose. A default token would be a published
        // credential the moment this repo is cloned, and an absent one would silently
        // leave the upload endpoint open.
        guard let token = value("STELE_UPLOAD_TOKEN") else {
            throw ConfigurationError.missing(
                "STELE_UPLOAD_TOKEN",
                hint: "Generate one with: openssl rand -hex 32"
            )
        }
        guard token.count >= 16 else {
            throw ConfigurationError.invalid(
                "STELE_UPLOAD_TOKEN",
                value: String(repeating: "*", count: token.count),
                hint: "Use at least 16 characters. Generate one with: openssl rand -hex 32"
            )
        }
        self.uploadToken = token

        self.baseURL = (value("STELE_BASE_URL") ?? "http://\(self.host):\(self.port)")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if let rawMax = value("STELE_MAX_PAGE_BYTES") {
            guard let parsed = Int(rawMax), parsed > 0 else {
                throw ConfigurationError.invalid(
                    "STELE_MAX_PAGE_BYTES", value: rawMax, hint: "Expected a positive integer."
                )
            }
            self.maxPageBytes = parsed
        } else {
            self.maxPageBytes = 1024 * 1024
        }

        if let rawWords = value("STELE_SLUG_WORDS") {
            guard let parsed = Int(rawWords), (3...4).contains(parsed) else {
                throw ConfigurationError.invalid(
                    "STELE_SLUG_WORDS", value: rawWords, hint: "Expected 3 or 4."
                )
            }
            self.slugWords = parsed
        } else {
            self.slugWords = 3
        }

        guard let databaseURL = value("DATABASE_URL") else {
            throw ConfigurationError.missing(
                "DATABASE_URL",
                hint: "Expected postgres://user:password@host:5432/database"
            )
        }
        (self.database, self.databaseDescription) = try Self.parseDatabaseURL(databaseURL)
    }

    /// Parses a libpq-style connection URL.
    ///
    /// Supporting the URL form rather than five separate variables is what makes
    /// moving between the local Docker instance and a real database host a one-line change.
    static func parseDatabaseURL(
        _ raw: String
    ) throws -> (PostgresClient.Configuration, String) {
        let hint = "Expected postgres://user:password@host:5432/database"

        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "postgres" || scheme == "postgresql"
        else {
            throw ConfigurationError.invalid("DATABASE_URL", value: redact(raw), hint: hint)
        }
        guard let host = components.host, !host.isEmpty else {
            throw ConfigurationError.invalid(
                "DATABASE_URL", value: redact(raw), hint: "No host found. \(hint)"
            )
        }
        guard let username = components.user, !username.isEmpty else {
            throw ConfigurationError.invalid(
                "DATABASE_URL", value: redact(raw), hint: "No username found. \(hint)"
            )
        }

        let database = String(components.path.dropFirst())
        guard !database.isEmpty else {
            throw ConfigurationError.invalid(
                "DATABASE_URL", value: redact(raw), hint: "No database name found. \(hint)"
            )
        }

        // `sslmode` follows libpq naming *and* libpq semantics so existing connection
        // strings work unchanged: `require` means encrypt without verifying the
        // certificate, and only the verify-* modes check it. NIOSSL's client default is
        // full verification, so each mode sets the verification level explicitly — a
        // self-signed or IP-addressed Postgres must work under `require`, exactly as it
        // does with psql.
        func tlsConfiguration(_ verification: CertificateVerification) -> TLSConfiguration {
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.certificateVerification = verification
            return tls
        }
        let sslmode = components.queryItems?
            .first { $0.name.lowercased() == "sslmode" }?.value?.lowercased() ?? "disable"
        let tls: PostgresClient.Configuration.TLS
        switch sslmode {
        case "disable":
            tls = .disable
        case "prefer", "allow":
            tls = .prefer(tlsConfiguration(.none))
        case "require":
            tls = .require(tlsConfiguration(.none))
        case "verify-ca":
            tls = .require(tlsConfiguration(.noHostnameVerification))
        case "verify-full":
            tls = .require(tlsConfiguration(.fullVerification))
        default:
            throw ConfigurationError.invalid(
                "DATABASE_URL", value: "sslmode=\(sslmode)",
                hint: "Expected one of: disable, prefer, require, verify-ca, verify-full."
            )
        }

        let port = components.port ?? 5432
        var configuration = PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: components.password,
            database: database,
            tls: tls
        )
        // PostgresNIO's default ceiling is 20. Ten is a deliberate reduction: this
        // serves single-row reads off one table, and it shouldn't be able to crowd out
        // other tenants of a shared Postgres host.
        configuration.options.maximumConnections = 10

        return (configuration, "\(username)@\(host):\(port)/\(database) (sslmode=\(sslmode))")
    }

    /// Strips the password so a malformed `DATABASE_URL` can be echoed in an error
    /// without writing the credential to the logs.
    ///
    /// This is only ever called on input that already failed to parse, so it cannot
    /// assume the `://` and `@` markers are present — a dropped slash is exactly the
    /// kind of typo that gets here. When the shape isn't recognised the value is
    /// withheld entirely rather than echoed on the hope that it holds no secret.
    static func redact(_ raw: String) -> String {
        guard let atIndex = raw.lastIndex(of: "@"),
              let schemeRange = raw.range(of: "://"),
              schemeRange.upperBound <= atIndex
        else { return "<unparseable value withheld in case it contains a credential>" }
        return raw[..<schemeRange.upperBound] + "***" + raw[atIndex...]
    }
}
