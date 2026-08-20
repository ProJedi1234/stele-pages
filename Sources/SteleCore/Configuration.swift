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

/// The GitHub logins permitted to mint a publishing credential by signing in with GitHub.
///
/// Configuration rather than a secret — the list can be read by anyone who can read the
/// deployment's environment and nothing is lost, which is the whole point of replacing a
/// shared bootstrap token with an identity check. What it must never be is *permissive by
/// omission*. An absent list read as "allow anyone" would leave the minting endpoint open
/// on every deployment that had not got round to setting it, and open silently, which is
/// the failure `STELE_UPLOAD_TOKEN`'s missing default exists to prevent. So the empty
/// allowlist permits nobody, and that rule lives in `permits(_:)` rather than in a `guard`
/// each caller is trusted to remember: a caller that asks this type whether a login may
/// mint gets the fail-closed behaviour whether or not it knew to ask for it.
public struct GitHubOwnerAllowlist: Sendable, Equatable {
    /// Folded at parse. `permits(_:)` folds its argument with the same function, so both
    /// sides of every comparison are in the same shape by construction.
    private let logins: Set<String>

    /// Splits on commas and folds each entry, dropping the ones that are empty once
    /// trimmed — so `nil`, `""`, `"   "`, `","` and `" , "` all arrive at the allowlist
    /// that permits nobody, by five routes and with no crash on any of them.
    ///
    /// Entries are not otherwise validated, deliberately. A typo'd login is a login that
    /// will never match, which shows up as one refused sign-in the operator can read;
    /// throwing a `ConfigurationError` instead would take the whole server down over one
    /// bad name in a list whose other names were fine.
    init(parsing raw: String?) {
        self.logins = Set(
            (raw ?? "")
                .split(separator: ",")
                .map { Self.fold(String($0)) }
                .filter { !$0.isEmpty }
        )
    }

    /// True when no login is permitted, which is where an unset `STELE_GITHUB_OWNERS`
    /// leaves the server — and a legitimate state to boot in. The endpoint fails closed;
    /// the process does not fail at all.
    ///
    /// This is a fact about the server's *configuration* rather than about any request, and
    /// it must never be read on a request path. A refusal that branched on it —
    /// "GitHub sign-in is not configured here" where every other refused sign-in gets one
    /// identical answer — would tell an unauthenticated caller whether this deployment has
    /// adopted GitHub sign-in, which is precisely the distinction `permits(_:)` exists to
    /// collapse. A caller deciding whether someone may mint asks `permits(_:)`, which
    /// already refuses everything here.
    public var isEmpty: Bool { logins.isEmpty }

    /// Whether this login may mint a credential. Case-insensitive, and false for every
    /// login when the allowlist is empty — the fail-closed rule, stated once, here.
    public func permits(_ login: String) -> Bool {
        logins.contains(Self.fold(login))
    }

    /// The single definition of "the same login", applied to both sides of every
    /// comparison.
    ///
    /// GitHub logins are ASCII letters, digits and hyphens and GitHub compares them
    /// case-insensitively, so folding is a lowercase. It is `lowercased()`, the
    /// locale-independent one, and must stay that: `lowercased(with:)` under a Turkish
    /// locale maps `I` to a dotless `ı` and would quietly stop matching an ordinary login
    /// on a server whose locale nobody thought about.
    ///
    /// Folding at parse *and* again at comparison sounds like two places that could
    /// disagree. It is one function called twice, which is the only arrangement where
    /// changing the rule reaches both sides of the comparison at once.
    ///
    /// The trimming set includes newlines deliberately, and narrowing it back to
    /// `.whitespaces` would be a real bug: that set is spaces and tabs, so a value reaching
    /// the server from anything file-shaped — a CRLF `.env`, a YAML block scalar, a secrets
    /// tool that appends a line ending — keeps the ending on its *last* entry and leaves
    /// exactly that one login unmatchable. The earlier entries go on working, the allowlist
    /// still reports itself configured, and the sign-in it refuses is deliberately silent
    /// about why, so a half-working list is the least diagnosable outcome available here.
    /// Widening the set costs nothing in the other direction: no GitHub login contains
    /// whitespace of any kind, so nothing that should be refused becomes permitted.
    private static func fold(_ login: String) -> String {
        login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Everything the server reads from the environment, resolved once at startup.
///
/// Nothing here is read again later, so a running server can't half-apply a config
/// change, and a bad value fails the process immediately with a message that names
/// the variable rather than surfacing as a connection error ten minutes in.
public struct Configuration: Sendable {
    /// The `maxPageBytes` an unset `STELE_MAX_PAGE_BYTES` resolves to. Named so the tests
    /// that render the skill document with "the default" share this value instead of
    /// retyping it, where a bump here would strand their copies.
    public static let defaultMaxPageBytes = 1024 * 1024

    /// The `maxAttachmentBytes` an unset `STELE_MAX_ATTACHMENT_BYTES` resolves to: 32 MiB.
    ///
    /// Its own number rather than a multiple of `defaultMaxPageBytes`, which answers a
    /// different question — that one is how much HTML an operator wants to allow, and this
    /// one is how much of a screen recording. Comfortable for screenshots and short
    /// evidence clips, which is what attachments are for.
    public static let defaultMaxAttachmentBytes = 32 * 1024 * 1024

    /// The largest `STELE_MAX_ATTACHMENT_BYTES` the Postgres backend will start with:
    /// 128 MiB.
    ///
    /// A property of the storage backend, not a policy — the same distinction
    /// `maxExpiresInSeconds` draws. Bytes live in `page_blobs.bytes`, and PostgresNIO
    /// materialises a whole column value on any read that is not ranged, so the ceiling is
    /// about what one request may be asked to hold in the container's memory. Above it the
    /// process refuses to boot and names both the variable and the backend, because the
    /// alternative is accepting the number and discovering it as an OOM during whichever
    /// upload first reaches for it.
    ///
    /// Raising this is what an object-store backend would earn. It is deliberately not
    /// something an operator can raise from the environment: the environment is where the
    /// *policy* lives, and this is a fact about the code underneath it.
    public static let maxSupportedAttachmentBytes = 128 * 1024 * 1024

    public var host: String
    public var port: Int
    /// Origin used to build the URL returned by `POST /pages`. Purely cosmetic — the
    /// server serves whatever host it's reached on regardless.
    public var baseURL: String
    public var uploadToken: String
    public var maxPageBytes: Int
    /// The largest attachment this deployment accepts. See `defaultMaxAttachmentBytes`.
    public var maxAttachmentBytes: Int
    public var slugWords: Int
    public var database: PostgresClient.Configuration
    /// Kept for logging, since `PostgresClient.Configuration` doesn't expose these back.
    public var databaseDescription: String

    /// Who may mint a publishing credential by signing in with GitHub.
    ///
    /// Optional at boot, which is the one place this parts company with
    /// `STELE_UPLOAD_TOKEN`: requiring it would fail the next boot of every deployment
    /// that has not adopted GitHub sign-in, over a value they have no use for. It is the
    /// *endpoint* that fails closed here, not the process — an unset variable is an
    /// allowlist that permits nobody, so a server with no `STELE_GITHUB_OWNERS` mints
    /// nothing through GitHub until an operator says who may.
    public var githubOwners: GitHubOwnerAllowlist

    /// The client ID of the GitHub OAuth app this deployment trusts, or nil when none is
    /// registered.
    ///
    /// Registration lives at GitHub → Settings → Developer settings → OAuth Apps
    /// (`https://github.com/settings/developers`). Which app, under which account, and
    /// whether it has a client secret are facts about one host: they belong in the
    /// gitignored `docs/homelab.local.md`, and this repository stays free of them.
    ///
    /// **The callback URL GitHub's registration form insists on is never used.** Sign-in
    /// is RFC 8628's device authorization grant, which has no redirect in it at all — the
    /// client polls GitHub directly and this server never sees a browser come back from
    /// one. A reader who goes looking for the handler behind that URL will not find one,
    /// and should not write one to "finish" it.
    ///
    /// Read from the environment rather than compiled in as a constant, so a deployment
    /// can point at its own app without a rebuild. The honest consequence: the client runs
    /// the device flow itself and carries its own copy of the ID inside its binary, so
    /// setting this variable does not hand the client anything. What it does is record, on
    /// the server side, which app this deployment trusts — beside the allowlist of the
    /// people that app is allowed to identify. Serving the value from an endpoint so the
    /// client could discover it was considered and rejected: another unauthenticated route
    /// to keep honest, to spare the client a constant it already has.
    ///
    /// Nothing on the server reads it yet. Its consumer is the token-provenance check
    /// (`POST /applications/{client_id}/token`, which asks GitHub whether an access token
    /// was issued to *this* app rather than to some other one), and that call needs the
    /// app's client secret — which this server has no variable to hold and no code path to
    /// spend, so the check is deliberately not built rather than half-built. Whether the
    /// registered app happens to have a secret is a fact about one host and stays with the
    /// others, in `docs/homelab.local.md`.
    public var githubClientID: String?

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
            self.maxPageBytes = Self.defaultMaxPageBytes
        }

        if let rawMaxAttachment = value("STELE_MAX_ATTACHMENT_BYTES") {
            guard let parsed = Int(rawMaxAttachment), parsed > 0 else {
                throw ConfigurationError.invalid(
                    "STELE_MAX_ATTACHMENT_BYTES", value: rawMaxAttachment,
                    hint: "Expected a positive integer."
                )
            }
            // Checked at boot rather than per request, because the failure it prevents is
            // not a rejected upload — it is the one accepted upload that takes the process
            // with it. An operator who set this deliberately finds out while they are still
            // looking at the terminal.
            guard parsed <= Self.maxSupportedAttachmentBytes else {
                throw ConfigurationError.invalid(
                    "STELE_MAX_ATTACHMENT_BYTES", value: rawMaxAttachment,
                    hint: """
                        At most \(Self.maxSupportedAttachmentBytes) bytes while attachments \
                        are stored in Postgres, which materialises a whole value on an \
                        unranged read.
                        """
                )
            }
            self.maxAttachmentBytes = parsed
        } else {
            self.maxAttachmentBytes = Self.defaultMaxAttachmentBytes
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

        // Neither of these is required and neither is a secret. The allowlist's absence is
        // not permissive: parsing nil yields the allowlist that permits nobody, so the
        // refusal is carried by the value itself rather than by a check somewhere
        // downstream that a future call site could be written without.
        self.githubOwners = GitHubOwnerAllowlist(parsing: value("STELE_GITHUB_OWNERS"))
        self.githubClientID = value("STELE_GITHUB_CLIENT_ID")

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
