import Logging

/// Asking GitHub who an access token belongs to.
///
/// Behind a seam for exactly the reason `PageStoring` and `ClientStoring` are: the HTTP
/// suite has to run the real routing, the real refusals and the real minting with no
/// network anywhere. An exchange route that could only be exercised against
/// `api.github.com` would be a route whose 401 discipline was tested by nobody, and that
/// discipline is the whole of its security argument.
///
/// One requirement, and it is a primitive. Everything that decides anything —  what
/// "may mint" means, which facts collapse into one refusal — lives in the extension below
/// and is therefore shared by every conformer, so the fake cannot reach a different verdict
/// from the live one about who gets a credential.
public protocol GitHubIdentifying: Sendable {
    /// The GitHub login this access token authenticates, or nil if GitHub rejects it.
    ///
    /// The split between nil and a thrown error is the load-bearing part, and it mirrors
    /// `ClientStoring.client(forTokenHash:)` exactly. **nil is a definitive rejection**:
    /// GitHub was asked, GitHub looked, and the answer was no. **A thrown error means the
    /// question could not be asked at all** — a connection that never opened, a 500 from
    /// GitHub, a body that did not decode.
    ///
    /// Collapsing the second into the first would be the kind of bug that only shows up on
    /// the worst day: during a GitHub outage every legitimate owner would be told their
    /// sign-in was refused, and the honest reading of that message is "my account is no
    /// longer allowed" — so they would go and re-authenticate, in a loop, against an
    /// endpoint that cannot answer. The bearer routes already make this distinction (a
    /// database that is down is a 500, not a 401) and this one inherits it.
    func login(forAccessToken token: String) async throws -> String?

    // The provenance check would be the second requirement here, and it is deliberately not
    // built. `POST /applications/{client_id}/token` asks GitHub whether an access token was
    // issued to *this* OAuth app rather than to some other one, which would close the gap
    // where an owner is phished into pasting a token they obtained elsewhere. It authenticates
    // with the app's client secret, and this server has no variable to hold one and no path
    // to spend it — so it stays absent rather than half-present. When it lands it is one more
    // method here, called by `owner(presenting:allowedBy:)` and skipped when no secret is
    // configured; adding the surface for it before then would be a requirement every
    // conformer has to answer and nothing consults. See `Configuration.githubClientID`.
}

extension GitHubIdentifying {
    /// Resolves a presented GitHub access token to the login of an owner permitted to mint,
    /// or nil.
    ///
    /// The policy method, and the analogue of `ClientStoring.authenticate(token:at:)`. Three
    /// different facts arrive here — GitHub rejected the token, GitHub knows the token and
    /// its owner is not on the allowlist, and this deployment has no allowlist at all — and
    /// exactly one nil leaves. That collapse happens *here*, inside the shared extension,
    /// rather than in the handler, and the reason is structural: a handler holding the
    /// distinction is a handler one edit away from reporting it, and the endpoint is
    /// unauthenticated, so reporting it would turn this route into an oracle for who owns
    /// the deployment. Anyone could enumerate GitHub logins against it and read the owner
    /// list off the status codes.
    ///
    /// The empty allowlist needs no branch of its own: `permits(_:)` already refuses
    /// everything, so an unconfigured deployment falls out of the same guard as a stranger.
    /// Nor does the empty *token*, or one carrying bytes no `Authorization` header can hold:
    /// `isPresentableAsAToken` refuses those into the same nil before any conformer is asked
    /// — see its own note for why that check has to live on this side of the seam.
    ///
    /// The logger is where the operator's half of this lives, and it is the only half there
    /// is — the response deliberately says nothing at all, so an operator debugging "why
    /// won't my sign-in work" has nowhere else to look. A refusal by the allowlist logs the
    /// login at info, because that one is nearly always a typo in `STELE_GITHUB_OWNERS` and
    /// the log line is what makes it visible. A token GitHub itself rejected is debug: it is
    /// indistinguishable from probe traffic, and an unauthenticated route that writes an
    /// info line per probe is a log an attacker can fill.
    ///
    /// The thrown error is logged at error and rethrown, and that catch clause is not
    /// ceremony. What it produces is Hummingbird's *unrecognised error* response: a `500`
    /// with an empty body, logged by the framework at debug — which this server does not
    /// run at. Without this line a GitHub outage is a page of sign-in failures whose only
    /// trace in the log is a request line identical to the one a success writes, and the
    /// operator's first move would be to restart the process at a louder log level to
    /// reproduce it. It is the same call the landing page makes when its index read fails,
    /// for the same reason: this is a branch where the failure is real and nothing else says
    /// so. The token never goes in that metadata — the error may quote what it was handed.
    public func owner(
        presenting token: String,
        allowedBy allowlist: GitHubOwnerAllowlist,
        logger: Logger? = nil
    ) async throws -> String? {
        guard isPresentableAsAToken(token) else {
            logger?.debug("refused an access token that could not be presented to github")
            return nil
        }
        let identified: String?
        do {
            identified = try await login(forAccessToken: token)
        } catch {
            logger?.error(
                "could not ask github who an access token belongs to",
                metadata: ["error": "\(error)"]
            )
            throw error
        }
        guard let login = identified else {
            logger?.debug("github did not recognise a presented access token")
            return nil
        }
        guard allowlist.permits(login) else {
            // The login is safe to log and the token is not: one is a public username, the
            // other is a live credential for somebody's GitHub account. Note that this line
            // is written for a caller who has already proved they hold a real GitHub
            // account, which is what makes it worth an info rather than a debug.
            logger?.info(
                "refused a github sign-in for a login that is not an owner",
                metadata: ["login": "\(login)"]
            )
            return nil
        }
        return login
    }
}

/// Whether a string could be presented to GitHub as a bearer token at all.
///
/// Non-empty, and every byte a printable ASCII character with no space among them. Real
/// GitHub tokens are `gho_`/`ghp_`/`github_pat_` followed by letters, digits and
/// underscores, so this refuses nothing GitHub could have issued.
///
/// It is here, in the shared policy, rather than in the route or in `GitHubAPI`, and that
/// placement is the whole point. The value arrives from an unauthenticated caller and ends
/// up interpolated into an `Authorization` header; `AsyncHTTPClient` validates header values
/// before it opens a socket and *throws* on a control character, which the seam's contract
/// then reads as "the question could not be asked" — so `{"accessToken": "gho_x\ny"}` would
/// answer `500`, the one status on this route reserved for a GitHub outage, to anyone who
/// cared to ask for it. A token that cannot legally go in a header is definitionally one
/// GitHub never issued, so the honest answer is the same refusal every other unusable token
/// gets. Checking it in the extension means no conformer can be handed a value it cannot
/// carry, and the refusal collapses into the single nil rather than becoming a second shape
/// the handler has to keep byte-identical.
///
/// The empty token folds in here for the same reason and saves a pointless round trip on the
/// way.
private func isPresentableAsAToken(_ token: String) -> Bool {
    !token.isEmpty && token.utf8.allSatisfy { (0x21...0x7E).contains($0) }
}
