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
    /// profile JSON and only one field of it is wanted; the cap is here so a wrong endpoint
    /// or a proxy's error page cannot stream unboundedly into a login attempt.
    private static let maxResponseBytes = 64 * 1024

    public init() {}

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

/// Why the question could not be asked. Never a reason a *caller* is shown — every one of
/// these becomes the same 500 the exchange route answers a down dependency with — so the
/// detail here exists for the log line and for nothing else.
enum GitHubAPIError: Error, CustomStringConvertible {
    case unexpectedStatus(code: UInt)
    case unreadableUser(underlying: String)

    var description: String {
        switch self {
        case .unexpectedStatus(let code):
            "GitHub answered \(code)"
        case .unreadableUser(let underlying):
            "GitHub's user response could not be decoded: \(underlying)"
        }
    }
}
