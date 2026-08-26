import AsyncHTTPClient
import Foundation
import NIOCore

/// The one type in this repository that talks to GitHub.
///
/// Deliberately thin. Everything with a decision in it — which refusals collapse into one
/// answer, what a login buys, what happens on a repeat sign-in — lives in
/// `GitHubIdentifying`'s extension and in the exchange route, both of which run against
/// `InMemoryGitHub` in the hermetic suite. What is left here is one request, and what
/// *arrives* here is a status code whose meaning is `verdict(forStatus:)` — a decision, so
/// it is a function that takes a number rather than a `case` buried in the transport, and
/// `GitHubAPITests` pins it. The transport around it is exercised only by production, which
/// is the same bargain `PageStore`'s SQL strikes with the in-memory fake, and it is only a
/// safe bargain while the file stays this small: a branch that grows here without a name is
/// a branch nothing is watching.
///
/// The device flow added two more requests and a second decision, and it is the decision
/// that matters: GitHub answers a device-code poll with `200` and an `error` string in the
/// body, so `verdict(forOAuthError:)` sits beside `verdict(forStatus:)` as a pure function
/// over that string, pinned the same way and for the same reason.
public struct GitHubAPI: GitHubIdentifying {
    /// Ten seconds, bounding the wait for GitHub's response *head* — which is where a
    /// connection that never opens, or opens and never answers, hangs. The caller is a CLI
    /// polling a device flow with a person watching it, so an outage has to arrive as a
    /// `500` rather than as a request that sits there.
    ///
    /// It genuinely is only the head: `HTTPClient` cancels the deadline as soon as that
    /// arrives, so collecting the body afterwards is bounded by size and not by time, and a
    /// peer that answers `200` and then stalls mid-stream would leave one sign-in waiting
    /// indefinitely. That needs a wedged intermediary — it is not a state a caller can ask
    /// for — and closing it means racing the read against a timer, which is a second
    /// concurrency construct in the one file here no test exercises. The note is preferred
    /// to the machinery; it is recorded rather than tidied away so the next reader does not
    /// take the ten seconds for a guarantee it is not.
    private static let timeout = TimeAmount.seconds(10)

    /// The most of GitHub's answer worth reading. `GET /user`'s body is a few kilobytes of
    /// profile JSON and only one field of it is wanted; the device-flow bodies are smaller
    /// still. The cap is here so a wrong endpoint or a proxy's error page cannot stream
    /// unboundedly into a login attempt.
    private static let maxResponseBytes = 64 * 1024

    /// The interval to obey when GitHub tells this server to wait and does not say how long.
    ///
    /// Five seconds is the value GitHub documents as the device flow's default, and it is
    /// only ever reached when a `slow_down` or an `authorization_pending` arrives with no
    /// `interval` field. Guessing shorter would be this server instructing a client to poll
    /// faster than GitHub's own floor, which is how a sign-in earns a `slow_down` it did not
    /// have to.
    private static let defaultPollSeconds = 5

    /// The OAuth app this deployment signs people in through, or nil if it was never
    /// configured.
    ///
    /// Held by the conformer rather than passed per call, so there is exactly one place the
    /// value enters the process and no signature anywhere invites a caller to supply their
    /// own. `String?` rather than a required `String` because `STELE_GITHUB_CLIENT_ID` is
    /// optional at boot — the same shape `STELE_GITHUB_OWNERS` has, and for the same reason:
    /// demanding it would fail the next boot of every deployment that does not use GitHub
    /// sign-in, over a feature they never turn on. It is the sign-in that refuses, not the
    /// process, and the two methods below are where that refusal happens.
    private let clientID: String?

    /// Not defaulted to nil. A conformer that silently has no client ID is one whose
    /// sign-ins refuse everybody with nothing in the code to say why, and the one call site
    /// that builds this type has the configuration in hand.
    public init(clientID: String?) {
        self.clientID = clientID
    }

    public func login(forAccessToken token: String) async throws -> String? {
        var request = HTTPClientRequest(url: "https://api.github.com/user")
        request.method = .GET
        request.headers.add(name: "Authorization", value: "Bearer \(token)")
        request.headers.add(name: "Accept", value: "application/vnd.github+json")
        // Pinned rather than left to whatever GitHub currently defaults to: the one field
        // read below is stable across every version of this endpoint, and naming a version
        // is what keeps a future default from changing the shape underneath us silently.
        request.headers.add(name: "X-GitHub-Api-Version", value: "2022-11-28")
        // GitHub answers a request with no User-Agent with a 403 and an HTML body, which
        // would arrive here as "that token buys nothing" — a refused sign-in with a
        // perfectly good token behind it, and no way to tell from the response.
        request.headers.add(name: "User-Agent", value: "stele-pages")

        // `HTTPClient.shared` rather than a private client: a private one owns an event
        // loop group and needs a shutdown hook, which means a service registered in
        // `buildApplication` and a lifetime to keep straight, all to make one request per
        // sign-in. The shared instance is process-wide and shuts down with the process.
        let response = try await HTTPClient.shared.execute(request, timeout: Self.timeout)

        switch Self.verdict(forStatus: response.status.code) {
        case .identity:
            let body = try await response.body.collect(upTo: Self.maxResponseBytes)
            do {
                // `Data(buffer.readableBytesView)` rather than `Data(buffer:)`, which lives
                // in NIOFoundationCompat — a module this target gets only transitively and
                // does not declare.
                return try JSONDecoder()
                    .decode(GitHubUserResponse.self, from: Data(body.readableBytesView))
                    .login
            } catch {
                // A 200 whose body is not the shape this endpoint documents is GitHub
                // behaving unexpectedly, not a caller presenting a bad token. Throwing sends
                // it down the outage path, where a 500 tells the operator to go and look;
                // returning nil would blame the user for it.
                throw GitHubAPIError.unreadableUser(underlying: "\(error)")
            }
        case .rejected:
            // GitHub looked at the token and said no. Not a fact this server passes on:
            // `owner(presenting:allowedBy:)` collapses this nil with the allowlist's.
            return nil
        case .unavailable:
            throw GitHubAPIError.unexpectedStatus(code: response.status.code)
        }
    }

    public func requestDeviceCode() async throws -> GitHubDeviceCode? {
        // No client ID is a refusal and not a failure, decided before a socket is opened.
        // See the protocol's note: an unconfigured deployment declines, indistinguishably
        // from one that is configured and not for you.
        guard let clientID else { return nil }

        // `github.com`, not `api.github.com`. The device endpoints live on the web host
        // beside the authorisation pages, which is easy to get wrong and answers a 404 that
        // would arrive here as an outage.
        let response = try await post(
            "https://github.com/login/device/code",
            // An empty scope, spelled out rather than omitted. This flow asks GitHub who
            // somebody is and nothing else — no repositories, no organisations, no write of
            // any kind — and sending the field empty is what makes that a visible decision
            // on the wire rather than a field somebody forgot.
            form: [("client_id", clientID), ("scope", "")]
        )
        guard response.status.code == 200 else {
            throw GitHubAPIError.unexpectedStatus(code: response.status.code)
        }
        let body = try await response.body.collect(upTo: Self.maxResponseBytes)
        let decoded: GitHubDeviceCodeResponse
        do {
            decoded = try JSONDecoder()
                .decode(GitHubDeviceCodeResponse.self, from: Data(body.readableBytesView))
        } catch {
            throw GitHubAPIError.unreadableDeviceResponse(underlying: "\(error)")
        }
        // Every error this endpoint can report is a deployment fault, so all of them throw
        // and none of them refuse. The caller sent an empty body — there is nothing they
        // could have got wrong — so an `error` here means the client ID is wrong, or the
        // OAuth app does not have device flow enabled, and the operator is the only person
        // who can act on it. `verdict(forOAuthError:)` is not consulted: its refusal cases
        // are all about a *device code*, and no device code has been issued yet.
        if let error = decoded.error {
            throw GitHubAPIError.unexpectedOAuthError(error)
        }
        guard
            let deviceCode = decoded.deviceCode,
            let userCode = decoded.userCode,
            let verificationURI = decoded.verificationUri,
            let expiresIn = decoded.expiresIn
        else {
            throw GitHubAPIError.unreadableDeviceResponse(
                underlying: "a device-code response was missing a field the flow needs"
            )
        }
        return GitHubDeviceCode(
            userCode: userCode,
            verificationURI: verificationURI,
            deviceCode: deviceCode,
            // The only optional field with a sensible stand-in: GitHub documents five
            // seconds as the floor, and a missing interval is a client with no instruction
            // rather than a flow that cannot proceed.
            interval: decoded.interval ?? Self.defaultPollSeconds,
            expiresIn: expiresIn
        )
    }

    public func redeemDeviceCode(_ deviceCode: String) async throws -> GitHubDeviceRedemption {
        guard let clientID else { return .refused }

        let response = try await post(
            "https://github.com/login/oauth/access_token",
            form: [
                ("client_id", clientID),
                ("device_code", deviceCode),
                // The grant type is RFC 8628's, verbatim. GitHub answers anything else with
                // `unsupported_grant_type`, which this file classifies as an outage — so a
                // typo here would surface as a 500 rather than as a refused sign-in, which
                // is the right way round for a fault only the deployment can fix.
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ]
        )
        guard response.status.code == 200 else {
            throw GitHubAPIError.unexpectedStatus(code: response.status.code)
        }
        let body = try await response.body.collect(upTo: Self.maxResponseBytes)
        let decoded: GitHubDeviceRedemptionResponse
        do {
            decoded = try JSONDecoder()
                .decode(GitHubDeviceRedemptionResponse.self, from: Data(body.readableBytesView))
        } catch {
            throw GitHubAPIError.unreadableDeviceResponse(underlying: "\(error)")
        }
        // The token is read before the error, and an empty one does not count. GitHub sends
        // one field or the other, never both; checking the token first means a body that
        // somehow carried both is read as the grant it plainly is rather than as a refusal
        // of a sign-in that succeeded.
        if let accessToken = decoded.accessToken, !accessToken.isEmpty {
            return .token(accessToken)
        }
        guard let error = decoded.error else {
            // A 200 carrying neither is GitHub behaving unexpectedly, and there is no honest
            // third answer to give the person waiting.
            throw GitHubAPIError.unreadableDeviceResponse(
                underlying: "a device redemption carried neither an access token nor an error"
            )
        }
        switch Self.verdict(forOAuthError: error) {
        case .pending:
            // GitHub sends the new floor with a `slow_down` and sends nothing with an
            // `authorization_pending`, where the interval has not changed — so an absent
            // field means "keep going at the pace you were given", which the client already
            // has from the start response and which this default matches.
            return .pending(retryAfterSeconds: decoded.interval ?? Self.defaultPollSeconds)
        case .refused:
            return .refused
        case .unavailable:
            throw GitHubAPIError.unexpectedOAuthError(error)
        }
    }

    /// One `POST` of a form body to GitHub, shared by the two device-flow calls.
    ///
    /// Both of GitHub's device endpoints take `application/x-www-form-urlencoded` and both
    /// are asked for JSON back — without that `Accept` they answer in form encoding, which
    /// would arrive at the decoder as an unreadable body and at the operator as a 500. The
    /// `User-Agent` is the same one `GET /user` sends and is not optional for the same
    /// reason it is not optional there.
    private func post(_ url: String, form fields: [(String, String)]) async throws
        -> HTTPClientResponse
    {
        var request = HTTPClientRequest(url: url)
        request.method = .POST
        request.headers.add(name: "Accept", value: "application/json")
        request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        request.headers.add(name: "User-Agent", value: "stele-pages")
        request.body = .bytes(ByteBuffer(string: Self.formEncoded(fields)))
        return try await HTTPClient.shared.execute(request, timeout: Self.timeout)
    }

    /// A form body, percent-encoded field by field.
    ///
    /// Everything sent through here is alphanumeric in practice — a client ID, a device
    /// code, a fixed grant-type URN — so the encoding is not what makes the request work; it
    /// is what keeps a value nobody vetted from ending the field early and adding one of its
    /// own. The device code is the value in question: it arrives from an unauthenticated
    /// caller and is copied straight into this body.
    ///
    /// `.alphanumerics` rather than a URL character set, because those permit `&` and `=` —
    /// the two bytes this encoding exists to neutralise. The nil coalescing is unreachable:
    /// `addingPercentEncoding` returns nil only for a string that cannot be represented,
    /// which a `String` always can.
    private static func formEncoded(_ fields: [(String, String)]) -> String {
        fields
            .map { name, value in
                let encode = { (raw: String) in
                    raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                }
                return "\(encode(name))=\(encode(value))"
            }
            .joined(separator: "&")
    }

    /// What GitHub's answer to `GET /user` means, as a decision separate from the request
    /// that produced it — a plain function over a status code, so the one judgement in this
    /// file can be asserted without a socket. It takes the code rather than
    /// `HTTPResponseStatus` to keep `NIOHTTP1` out of this target's imports, which it has
    /// only transitively.
    ///
    /// **`401` is the only status that is a verdict on the token.** GitHub examined the
    /// credential presented and refused it: invalid, revoked, expired. Everything else that
    /// is not a `200` is a statement about *this server* rather than about the caller, and
    /// keeping the two apart is the whole of the seam's nil-versus-throw contract.
    ///
    /// `403` is the one that reads like a refusal and is not, which is why it moved. GitHub
    /// answers its primary rate limit with `403` and a spent `x-ratelimit-remaining`, its
    /// secondary limits with `403` or `429`, and a source address that has offered too many
    /// invalid credentials with `403` on *every* request from it — valid ones included. All
    /// three are per-IP states this server reaches on its own, and since the exchange is
    /// unauthenticated they are states anyone can push it into by posting junk tokens at it.
    /// Calling any of them a rejection tells a legitimate owner holding a perfectly good
    /// token that their sign-in was refused, which is precisely the lie the contract exists
    /// to prevent; `unavailable` says the true thing, that the question could not be asked
    /// right now, and the `500` sends the operator to look rather than the owner to
    /// re-authenticate.
    ///
    /// What that costs is a `403` genuinely about the caller — an app whose access an
    /// organisation withdrew, an account GitHub has suspended — arriving as a `500` instead
    /// of a `401`. Worth paying: GitHub answers a credential it will not accept with
    /// `401 Bad credentials`, so those shapes are rare, and the failure they produce is an
    /// operator investigating something real rather than an owner looping against a
    /// dependency that cannot answer.
    static func verdict(forStatus code: UInt) -> Verdict {
        switch code {
        case 200: .identity
        case 401: .rejected
        default: .unavailable
        }
    }

    /// What GitHub's `error` string means when a device code is redeemed.
    ///
    /// The device endpoints report failure inside a `200`, so the status code says nothing
    /// and this string says everything. It is a pure function for the same reason
    /// `verdict(forStatus:)` is: it is the only decision in this half of the file, and
    /// `GitHubAPITests` can pin every arm of it without a socket.
    ///
    /// **Pending is not a failure at all.** `authorization_pending` is the answer for as
    /// long as the person is still typing a code into a browser, and `slow_down` is the same
    /// answer with a larger interval attached — GitHub's complaint about the polling rate,
    /// not about the sign-in. Reading either as a refusal ends a sign-in that was going to
    /// succeed, seconds after it started.
    ///
    /// **Refused means this device code will never be redeemed.** `expired_token` (the
    /// person took too long), `access_denied` (the person said no) and
    /// `incorrect_device_code` (no such code was ever issued) are three facts the caller
    /// learns none of — they collapse into the single 401 the route answers every terminal
    /// refusal with, because distinguishing them would tell a stranger polling stolen codes
    /// which of them GitHub has heard of.
    ///
    /// **Two of GitHub's errors are this server's fault and must not read as refusals.**
    /// `unsupported_grant_type` means the grant URN sent above is wrong,
    /// `incorrect_client_credentials` means `STELE_GITHUB_CLIENT_ID` is not a client ID
    /// GitHub knows, and `device_flow_disabled` means the OAuth app exists with the device
    /// flow left unticked. All three are deployment faults that no user action can clear, so
    /// they are `unavailable`: a 500 sends the operator to look at the configuration, while
    /// a 401 would tell every owner in turn that their sign-in was refused and leave the
    /// actual fault invisible. It is the same distinction `403` forced on
    /// `verdict(forStatus:)`, arriving through a different field.
    ///
    /// **An unrecognised string is GitHub behaving unexpectedly, never the caller's fault.**
    /// The default is `unavailable` rather than `refused` on purpose, and it is the arm most
    /// likely to be "tidied" the wrong way: a new error string GitHub invents is something
    /// this server has not been taught to read, and guessing "refused" would silently
    /// convert a whole new failure mode into a lie told to legitimate owners.
    static func verdict(forOAuthError error: String) -> OAuthVerdict {
        switch error {
        case "authorization_pending", "slow_down": .pending
        case "expired_token", "access_denied", "incorrect_device_code": .refused
        default: .unavailable
        }
    }

    /// The three things a device-code redemption can mean. Deliberately a different type
    /// from `Verdict`: that one classifies a status code on the identity call and this one
    /// classifies an error string on the poll, and the vocabularies only look alike —
    /// `pending` has no counterpart there, and a single shared enum would invite a `switch`
    /// somewhere that handled a case its call site cannot receive.
    enum OAuthVerdict: Equatable {
        /// Nobody has authorised the code yet; ask again.
        case pending
        /// This code is dead. The caller learns nothing beyond that.
        case refused
        /// GitHub did not answer the question that was asked, or answered something this
        /// server does not understand.
        case unavailable
    }

    /// The three things GitHub's answer can mean, named so that the mapping above is a
    /// decision with a name rather than a `return nil` in a `switch`.
    enum Verdict: Equatable {
        /// GitHub will say who the token belongs to; the login is in the body.
        case identity
        /// GitHub examined the token and refused it.
        case rejected
        /// GitHub did not answer the question that was asked.
        case unavailable
    }
}

/// The one field of `GET /user` this server reads.
///
/// A dedicated type with one property rather than a dictionary, so the thing being trusted
/// as an identity is named in the type system and a future reader can see at a glance that
/// nothing else from GitHub's profile is being carried anywhere.
private struct GitHubUserResponse: Decodable {
    let login: String
}

/// GitHub's answer to `POST /login/device/code`.
///
/// Every field optional, including the ones the flow cannot proceed without, because this
/// endpoint reports failure as a `200` carrying `error` instead of the fields — so a shape
/// with them required would fail to decode on the one body that has something to say, and
/// the operator would get "unreadable" where GitHub had written the reason. They are unwrapped
/// at the call site, which is where a missing one can be reported as what it is.
private struct GitHubDeviceCodeResponse: Decodable {
    let deviceCode: String?
    let userCode: String?
    let verificationUri: String?
    let interval: Int?
    let expiresIn: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case interval
        case expiresIn = "expires_in"
        case error
    }
}

/// GitHub's answer to `POST /login/oauth/access_token` for a device code.
///
/// One of `access_token` and `error` arrives, never both, and `interval` rides along with a
/// `slow_down` to say how much slower. Optionality here is the wire's, not a convenience.
private struct GitHubDeviceRedemptionResponse: Decodable {
    let accessToken: String?
    let error: String?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
        case interval
    }
}

/// Why the question could not be asked. Never a reason a *caller* is shown — every one of
/// these becomes the same 500 the exchange route answers a down dependency with — so the
/// detail here exists for the log line and for nothing else.
enum GitHubAPIError: Error, CustomStringConvertible {
    case unexpectedStatus(code: UInt)
    case unreadableUser(underlying: String)
    case unreadableDeviceResponse(underlying: String)
    /// An `error` string from a device endpoint that is not a verdict on the caller — a
    /// deployment fault, or one this server has not been taught to read. The string is kept
    /// because it is the entire diagnosis and it goes nowhere but the log.
    case unexpectedOAuthError(String)

    var description: String {
        switch self {
        case .unexpectedStatus(let code):
            "GitHub answered \(code)"
        case .unreadableUser(let underlying):
            "GitHub's user response could not be decoded: \(underlying)"
        case .unreadableDeviceResponse(let underlying):
            "GitHub's device-flow response could not be read: \(underlying)"
        case .unexpectedOAuthError(let error):
            "GitHub answered a device-flow request with \(error)"
        }
    }
}
