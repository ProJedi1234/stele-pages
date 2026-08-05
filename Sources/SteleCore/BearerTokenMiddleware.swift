import Foundation
import Hummingbird

/// Guards write routes with a bearer token, and resolves it to the credential that
/// presented it.
///
/// Reads are intentionally left open — the whole point is that anyone with the link can
/// see the page. Only writing is gated.
///
/// Two credentials get in. A per-client token is hashed and looked up through
/// `ClientStoring`, which is the future and the thing the CLI holds. The shared
/// `STELE_UPLOAD_TOKEN` still works alongside it, because it is what every agent in the
/// field is configured with today and what mints the first client — see
/// `sharedTokenClient`.
///
/// Generic over the store rather than taking `ClientStore` directly, for the same reason
/// the routes take `some PageStoring`: authentication that could only run against Postgres
/// would take the whole write surface's HTTP tests down with it.
public struct BearerTokenMiddleware<Clients: ClientStoring>: RouterMiddleware {
    /// Concrete rather than generic over `RequestContext`. The middleware's job is now to
    /// *write* `client` into the context, so it needs a context type that has that field —
    /// and there is exactly one such type in this server. A protocol abstracting "a context
    /// carrying a client" would buy a second conformer that does not exist.
    public typealias Context = SteleRequestContext

    private let clients: Clients
    private let sharedToken: String

    public init(clients: Clients, sharedToken: String) {
        self.clients = clients
        self.sharedToken = sharedToken
    }

    /// The one answer every rejected credential gets.
    ///
    /// Unknown, revoked, expired, and the shared token mistyped are four different facts
    /// and the caller learns none of them. The README's licence to return distinguishing
    /// errors applies to callers *behind* the token, and someone probing for a valid
    /// credential is by definition not one of them: "that token existed once" tells an
    /// attacker their guess was structurally right. `ClientStoring.authenticate` collapses
    /// the three credential states before they ever reach here, so there is no shape in
    /// this file that could accidentally branch on them.
    ///
    /// The wording is the pre-existing one, kept so the failure a live agent sees does not
    /// change under it.
    private static var rejected: HTTPError {
        HTTPError(.unauthorized, message: "Invalid upload token.")
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // A *missing* header stays distinguishable from a rejected one, and that is not a
        // leak: a caller who presented nothing has learned nothing about which credentials
        // exist. It is also the single most common way a new integration is misconfigured,
        // and "your token is wrong" would send that debugging in the wrong direction.
        guard let header = request.headers[.authorization] else {
            throw HTTPError(.unauthorized, message: "Missing Authorization header.")
        }
        // RFC 7235 allows any run of spaces between the scheme and the credential
        // (`auth-scheme 1*SP token68`), so trim rather than split on the first space.
        let presented = header.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        guard header.lowercased().hasPrefix("bearer ") else {
            // Scheme names are case-insensitive per RFC 7235, hence the lowercasing. The
            // right credential under the wrong scheme is still no credential, and it gets
            // the same answer as a wrong one.
            throw Self.rejected
        }

        let client: Client
        if let authenticated = try await clients.authenticate(token: presented) {
            client = authenticated
            // Best effort, and deliberately after the decision rather than part of it: the
            // request is already authorised, and losing the operator's "is this credential
            // still in service?" stamp is not worth failing a publish over. Awaited rather
            // than detached so the write is ordered with the response — a fire-and-forget
            // task would outlive the request and could be dropped at shutdown.
            do {
                try await clients.recordUse(clientID: authenticated.id)
            } catch {
                context.logger.warning(
                    "could not record credential use",
                    metadata: ["client": "\(authenticated.name)", "error": "\(error)"]
                )
            }
        } else if constantTimeEquals(presented, sharedToken) {
            // No `recordUse`: this credential has no row to stamp.
            client = .sharedToken
        } else {
            throw Self.rejected
        }

        var context = context
        context.client = client
        return try await next(request, context)
    }

}

extension Client {
    /// The credential `STELE_UPLOAD_TOKEN` resolves to.
    ///
    /// Synthesised, not stored: hashing the configured token into a `clients` row would
    /// put configuration into the database layer, which `PageStore.migrations` deliberately
    /// keeps out of it, and would leave a row behind after the variable was rotated or
    /// removed. It exists so the two credential paths hand the rest of the server the same
    /// shape — one `Client` on the context, one place that asks about scopes — rather than
    /// an optional the scope checks would each have to special-case.
    ///
    /// It is `admin` because that is what the shared token is becoming: the operator's root
    /// credential, the one thing that can mint the first per-client token, and no agent's.
    ///
    /// `id` is 0, which `bigserial` never issues, so it cannot collide with a real row.
    /// Nothing may write it to `pages.client_id` — that column is a foreign key, and this
    /// credential has no referent. A page published with the shared token is one with no
    /// honest owner to record, exactly as every page predating migration 2 is.
    ///
    /// It lives on `Client` rather than on the middleware because a generic type cannot
    /// hold a static stored property, and one copy per store type is one copy too many for
    /// a value the whole server compares identities against.
    static let sharedToken = Client(
        id: 0,
        name: "shared-upload-token",
        scopes: [ClientScope.admin.rawValue],
        createdAt: Date(timeIntervalSince1970: 0)
    )

    /// The value to record in `pages.client_id` for a page this credential wrote, or nil
    /// when there is no honest owner to record.
    ///
    /// The nil is `sharedToken` and only `sharedToken`: it is synthesised rather than stored,
    /// so its `id` refers to no row, and `pages.client_id` is a foreign key — writing the 0
    /// would be a constraint violation on every publish, which is a 500 where a null is the
    /// truth. A page written by the shared token has exactly the provenance every page
    /// predating migration 2 has, and records it the same way.
    ///
    /// A computed property rather than an `if client.id == 0` at each write site, because
    /// there are two write sites today and the rule has to be the same at both — and because
    /// "0 means synthesised" is a fact about `sharedToken`, so it belongs beside it.
    var attributableID: Int64? {
        id == Client.sharedToken.id ? nil : id
    }
}

/// Compares two strings without an early exit on the first differing byte.
///
/// A plain `==` returns as soon as it finds a mismatch, so response latency reveals how
/// many leading bytes were correct — enough to recover a token one byte at a time.
/// Length is still observable, which is fine: the token length isn't the secret.
///
/// Still needed for the shared token, and only for it. A per-client token is never
/// compared byte-by-byte at all: it is hashed and looked up on a unique index, so that
/// path has no timing oracle to close in the first place.
func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    guard lhsBytes.count == rhsBytes.count else { return false }

    var difference: UInt8 = 0
    for index in lhsBytes.indices {
        difference |= lhsBytes[index] ^ rhsBytes[index]
    }
    return difference == 0
}
