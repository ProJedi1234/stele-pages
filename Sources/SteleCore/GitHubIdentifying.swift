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

    /// Starts a device sign-in, or nil if this deployment cannot start one.
    ///
    /// The client ID belongs to the conformer, not to this call. That is the only placement
    /// that keeps the value where the design put it: the server holds the client ID and the
    /// CLI never sees it, so a parameter here would be an invitation for some future caller
    /// to source it from somewhere else — and it would force every fake to carry a dummy
    /// string it has no use for.
    ///
    /// **nil means this deployment declines to start a sign-in**, which today means no
    /// `STELE_GITHUB_CLIENT_ID` is set, and it is a refusal for exactly the reason the empty
    /// allowlist is one. An unconfigured deployment is not a broken deployment — the route
    /// answers it with the same refusal every other terminal refusal gets, so a prober
    /// cannot tell "not set up here" from "set up and not for you". A thrown error keeps its
    /// usual meaning: GitHub could not be asked.
    func requestDeviceCode() async throws -> GitHubDeviceCode?

    /// Asks GitHub whether a device code has been authorised yet.
    ///
    /// The polled half of the flow, and the one call this server makes on a schedule
    /// somebody else sets. Throwing still means GitHub could not be asked; every answer
    /// GitHub *did* give is one of the three cases, including the ones GitHub reports as an
    /// `error` string inside a `200` — see `GitHubAPI.verdict(forOAuthError:)` for which
    /// string is which case and why two of them are outages rather than refusals.
    ///
    /// A conformer with no client ID answers `.refused` here rather than throwing, for the
    /// same reason `requestDeviceCode()` answers nil: an unconfigured deployment declines,
    /// it does not fail.
    func redeemDeviceCode(_ deviceCode: String) async throws -> GitHubDeviceRedemption

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

    /// Carries a device sign-in as far as it will go this poll: still waiting, an owner's
    /// login, or nil.
    ///
    /// The second policy method, and it earns its place in the extension the same way the
    /// first one does — it is *the* definition of what a device code buys, so the fake and
    /// the live conformer cannot reach different verdicts about who walks away with a
    /// credential. What the route gets is one of three shapes and no reasons attached.
    ///
    /// The nil is the whole of the security argument and it is wide on purpose. A code
    /// GitHub never issued, a code that expired, a code the person declined, a token GitHub
    /// minted for an account that is not an owner here, a deployment with no allowlist, a
    /// deployment with no client ID: six facts, one nil, decided here rather than in a
    /// handler that would then be one edit away from reporting which. The route is
    /// unauthenticated — reporting any of them turns it into an oracle for who owns the
    /// deployment, walkable by a stranger with a GitHub account of their own.
    ///
    /// `.pending` is the one answer that must *not* collapse into that nil. It is the normal
    /// state of this flow for as long as the person takes to type a code into a browser, and
    /// a client told "refused" at second three of a ninety-second sign-in gives up on one
    /// that was going to succeed.
    ///
    /// The presentability guard is here for a weaker reason than it is on the token path and
    /// is worth keeping anyway. A device code travels in a form body rather than in a
    /// header, so nothing downstream *throws* on a byte it dislikes — the `500`-on-demand
    /// this check prevents for tokens is not reachable here. What it still buys is a round
    /// trip not taken on a value GitHub cannot have issued, and one refusal shape rather
    /// than two.
    ///
    /// The logging split mirrors the token path exactly: refusals are debug, because this
    /// route is unauthenticated and an info line per probe is a log a stranger can fill,
    /// while an outage is error and rethrown so that a GitHub that is down leaves a trace
    /// distinguishable from a sign-in that simply has not happened yet.
    public func owner(
        redeeming deviceCode: String,
        allowedBy allowlist: GitHubOwnerAllowlist,
        logger: Logger? = nil
    ) async throws -> GitHubDeviceSignIn? {
        guard isPresentableAsAToken(deviceCode) else {
            logger?.debug("refused a device code that could not be presented to github")
            return nil
        }
        let redemption: GitHubDeviceRedemption
        do {
            redemption = try await redeemDeviceCode(deviceCode)
        } catch {
            logger?.error(
                "could not ask github whether a device code was authorised",
                metadata: ["error": "\(error)"]
            )
            throw error
        }
        switch redemption {
        case .pending(let retryAfterSeconds):
            return .pending(retryAfterSeconds: retryAfterSeconds)
        case .refused:
            logger?.debug("github will not redeem a presented device code")
            return nil
        case .token(let accessToken):
            // Straight into the existing policy, which is the point of the whole
            // arrangement: the allowlist check, the casing of the login and the collapse of
            // a non-owner into nil are the code that was already there and already tested,
            // not a second opinion written for this flow. The access token dies at the end
            // of this expression — it is never returned, never logged and never stored.
            guard let login = try await owner(
                presenting: accessToken, allowedBy: allowlist, logger: logger
            ) else {
                return nil
            }
            return .identified(login: login)
        }
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

/// What GitHub hands back when a device sign-in is started.
///
/// A named struct rather than the tuple it started as, because every field of it is copied
/// into the start route's JSON and a tuple's labels are not checked against anything. The
/// two the person sees are `userCode` and `verificationURI`; the two the CLI obeys are
/// `interval` and `expiresIn`; `deviceCode` is the whole of the server's state, which it
/// keeps by not keeping it — it goes out in this response and comes back in every poll.
///
/// `verificationURI` is a `String` rather than a `URL` on purpose. It is GitHub's to choose,
/// it is printed for a person to read or paste, and nothing here dereferences it — parsing
/// it would only add a failure mode to a value this server never resolves.
public struct GitHubDeviceCode: Sendable, Equatable {
    public let userCode: String
    public let verificationURI: String
    public let deviceCode: String
    /// Seconds the client must wait between polls, as GitHub set it.
    public let interval: Int
    /// Seconds until the device code is dead and the sign-in has to be started again.
    public let expiresIn: Int

    public init(
        userCode: String,
        verificationURI: String,
        deviceCode: String,
        interval: Int,
        expiresIn: Int
    ) {
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.deviceCode = deviceCode
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

/// What GitHub says when a device code is redeemed.
///
/// Three answers rather than an optional, because this is the one place in the seam where
/// "no" has two genuinely different meanings and the caller must act differently on each.
/// `.pending` is *not yet* — the person has not finished at `verificationURI`, and the right
/// response is to wait and ask again. `.refused` is *no, and asking again will not help*.
/// Folding them together in either direction is a real failure: a `.pending` read as a
/// refusal ends a sign-in the person is halfway through, and a `.refused` read as pending
/// leaves a CLI polling a dead code until it times out.
///
/// The third answer, "GitHub could not be asked", is a thrown error and not a case here —
/// the same nil-versus-throw contract `login(forAccessToken:)` documents at length, said
/// once more in an enum's shape.
public enum GitHubDeviceRedemption: Sendable, Equatable {
    /// The person has not finished authorising yet; ask again in this many seconds.
    ///
    /// GitHub spells this two ways — `authorization_pending`, meaning keep to the interval
    /// you were given, and `slow_down`, meaning you polled too fast and the interval has
    /// grown. They are the same instruction with a different number, so this carries the
    /// number and not the distinction: a conformer that made `slow_down` its own case would
    /// hand the route a shape to branch on and nothing useful to do with it.
    case pending(retryAfterSeconds: Int)
    /// GitHub minted an access token for the person who authorised the code.
    case token(String)
    /// The code will never be redeemed: expired, declined, never issued — or this deployment
    /// has no client ID with which to ask.
    case refused
}

/// The outcome of a device sign-in that got far enough to have one.
///
/// Two cases and an optional wrapper rather than three cases, because the nil is the same
/// nil `owner(presenting:allowedBy:)` returns and it has to stay that way. Every terminal
/// refusal in this flow — a dead device code, a declined one, a real GitHub account that is
/// not an owner here, a deployment with no allowlist, a deployment with no client ID —
/// collapses into it inside the extension, so the route never holds the distinction and
/// cannot leak it. A third case named `.refused` would be the same value with a place to
/// hang a reason off, which is how the leak gets built.
public enum GitHubDeviceSignIn: Sendable, Equatable {
    /// Nobody has authorised the code yet; the client should ask again after this many
    /// seconds.
    case pending(retryAfterSeconds: Int)
    /// An owner authorised the code, and this is the login GitHub reports for them — in
    /// GitHub's casing, since that is what the minted credential is named after.
    case identified(login: String)
}
