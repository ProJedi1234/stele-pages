import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// HTTP-level tests for the two sign-in routes, `POST /auth/github/device` and
/// `POST /auth/github/exchange` — the only routes in this server that are neither a public
/// read nor behind a credential.
///
/// Three properties carry most of the weight here and none of them is the happy path. The
/// first is that *every* refusal, on either route, is one byte-identical `401`: a pair of
/// routes that could distinguish "not an owner" from "dead device code" from "this
/// deployment is not set up" would let anyone with a GitHub account of their own read this
/// deployment's owner list off the status codes. The second is that a GitHub outage is
/// emphatically **not** a refusal: it is a `500`, because telling a legitimate owner their
/// sign-in was refused when GitHub is down sends them to re-authenticate in a loop against
/// something that cannot answer. The third is new with the device flow and is the reason for
/// it: the GitHub access token never leaves this server, so no response on any route may
/// carry one.
///
/// Waiting is the fourth and it is not a refusal either. A person typing a code into a
/// browser takes as long as they take, and for all of it the poll answers `202` with the
/// interval to wait — the one outcome that must never collapse into the `401`.
///
/// Nothing here reaches the network. `InMemoryGitHub` answers the seam's three primitives
/// from stored values, so what these exercise is the real shared policy in
/// `GitHubIdentifying`'s extension and the real routes around it.
@Suite("GitHub sign-in exchange")
struct GitHubExchangeTests {
    static let path =
        "/\(ServerRoute.auth)/\(ServerRoute.authGitHub)/\(ServerRoute.authExchange)"
    static let startPath =
        "/\(ServerRoute.auth)/\(ServerRoute.authGitHub)/\(ServerRoute.authDevice)"

    /// The access token the fake redeems a code into, and the login it reports for it — in
    /// GitHub's canonical casing, which is *not* the casing the allowlist below is written
    /// in. Every test that mints here therefore crosses the case fold at least once, so a
    /// comparison that quietly became case-sensitive fails the whole suite rather than one
    /// test.
    ///
    /// It is a fixture rather than a value any test sends: no caller can present an access
    /// token any more, which is the whole point of the device flow. It stays here so
    /// `theGitHubAccessTokenNeverLeavesTheServer` has a needle to search bodies for.
    static let ownerToken = "gho_owner"
    static let ownerLogin = "ProJedi1234"
    static let ownerName = "projedi1234"

    /// A GitHub account that exists and is nobody's owner — the case that must be
    /// indistinguishable from a device code GitHub never issued.
    static let strangerToken = "gho_stranger"
    static let strangerLogin = "passing-stranger"

    /// A device code the owner has already authorised: redeeming it yields their access
    /// token, which the route spends and discards inside the same request.
    static let ownerDeviceCode = "dev_owner_authorised"
    /// The same, for the account that is not an owner here.
    static let strangerDeviceCode = "dev_stranger_authorised"
    /// Issued, alive, and nobody has finished authorising it — the state the flow spends
    /// almost all of its wall-clock time in.
    static let pendingDeviceCode = "dev_waiting"
    /// Pending too, but with GitHub asking for a slower poll. A separate code rather than a
    /// second answer for the same one, because the property under test is that a larger
    /// interval is *the same shape* — a fake that changed its answer between polls would be
    /// proving something else.
    static let slowedDeviceCode = "dev_slow_down"
    /// Expired, declined, or never issued: three things GitHub spells differently and this
    /// server does not.
    static let deadDeviceCode = "dev_expired"

    static let pollSeconds = 5
    static let slowedPollSeconds = 27

    /// What the start route hands back, and what `aStartedSignInPassesGitHubsAnswerThrough`
    /// expects to read out of the JSON field for field. The user code is GitHub's documented
    /// example shape, which is worth keeping: it carries a hyphen, so a client that assumed
    /// the code was alphanumeric fails here rather than in somebody's terminal.
    static let issued = GitHubDeviceCode(
        userCode: "WDJB-MJHT",
        verificationURI: "https://github.com/login/device",
        deviceCode: ownerDeviceCode,
        interval: pollSeconds,
        expiresIn: 900
    )

    /// A GitHub that has issued one device code and holds an opinion about five.
    ///
    /// An unscripted code is `.refused`, which is what GitHub says about one it never
    /// issued, so the junk-code leg of the refusal test needs no arrangement at all.
    static var identifiedTokens: InMemoryGitHub {
        InMemoryGitHub(
            [ownerToken: ownerLogin, strangerToken: strangerLogin],
            issuing: issued,
            redeeming: [
                ownerDeviceCode: .token(ownerToken),
                strangerDeviceCode: .token(strangerToken),
                pendingDeviceCode: .pending(retryAfterSeconds: pollSeconds),
                slowedDeviceCode: .pending(retryAfterSeconds: slowedPollSeconds),
                deadDeviceCode: .refused,
            ]
        )
    }

    /// An application whose credential store starts empty, so a listing shows exactly what
    /// the test under it minted, and whose allowlist holds one owner.
    ///
    /// The allowlist arrives as an environment variable rather than as a constructed
    /// `GitHubOwnerAllowlist`, so what these tests exercise is the real parse-then-permit
    /// path an operator's `STELE_GITHUB_OWNERS` takes. `STELE_GITHUB_CLIENT_ID` has no
    /// counterpart here on purpose: the client ID belongs to the conformer, so "this
    /// deployment has no client ID" is arranged by handing over a `GitHubIdentifying` that
    /// issues nothing — which is exactly the shape `GitHubAPI` takes when the variable is
    /// unset.
    static func makeApp(
        clients: InMemoryClientStore = InMemoryClientStore(),
        github: some GitHubIdentifying = identifiedTokens,
        owners: String? = ownerName
    ) throws -> Application<RouterResponder<SteleRequestContext>> {
        var environment: [String: String] = [:]
        if let owners { environment["STELE_GITHUB_OWNERS"] = owners }
        return try TestFixture.makeApp(
            clients: clients, github: github, environment: environment
        )
    }

    /// Polls `code`, returning the status and the decoded body.
    ///
    /// No `Authorization` header anywhere in this file, and its absence is the point: these
    /// routes *are* the authentication, so a test that quietly presented a stele credential
    /// would be proving that some other middleware let it through.
    @discardableResult
    static func exchange(
        _ client: some TestClientProtocol,
        code: String,
        headers: HTTPFields = [.contentType: "application/json"]
    ) async throws -> (status: HTTPResponse.Status, raw: String, json: [String: Any]) {
        try await post(client, body: #"{"deviceCode":"\#(code)"}"#, headers: headers)
    }

    /// The same, for the tests that need to send a body the request type cannot express.
    @discardableResult
    static func post(
        _ client: some TestClientProtocol,
        body: String,
        headers: HTTPFields = [.contentType: "application/json"]
    ) async throws -> (status: HTTPResponse.Status, raw: String, json: [String: Any]) {
        try await client.execute(
            uri: path, method: .post, headers: headers, body: ByteBuffer(string: body)
        ) { decoded($0) }
    }

    /// Starts a sign-in. No body at all, not even an empty JSON object: the route reads none,
    /// and sending one here would hide a handler that had quietly started requiring it.
    @discardableResult
    static func start(
        _ client: some TestClientProtocol,
        headers: HTTPFields = [:]
    ) async throws -> (status: HTTPResponse.Status, raw: String, json: [String: Any]) {
        try await client.execute(uri: startPath, method: .post, headers: headers) { decoded($0) }
    }

    static func decoded(
        _ response: TestResponse
    ) -> (status: HTTPResponse.Status, raw: String, json: [String: Any]) {
        let raw = String(buffer: response.body)
        let json = (try? JSONSerialization.jsonObject(with: Data(buffer: response.body)))
            as? [String: Any] ?? [:]
        return (response.status, raw, json)
    }

    static func publish(
        _ client: some TestClientProtocol,
        with token: String
    ) async throws -> HTTPResponse.Status {
        try await client.execute(
            uri: "/\(ServerRoute.pages)",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "text/html"],
            body: ByteBuffer(string: "<h1>signed in</h1>")
        ) { $0.status }
    }

    // MARK: - Starting

    /// The start route is a pass-through, and this is the assertion that it passes
    /// *everything* through. Five fields, each read by somebody: two a person reads off a
    /// terminal, two the CLI obeys, and the one that comes back in every poll.
    ///
    /// Field by field against the bundle the fake issued rather than "is a string": a
    /// handler that swapped `userCode` and `deviceCode` would print the polling secret to a
    /// terminal and poll with the code the person is meant to type, and every shape check
    /// would pass.
    @Test func aStartedSignInPassesGitHubsAnswerThrough() async throws {
        try await Self.makeApp().test(.router) { client in
            let started = try await Self.start(client)
            #expect(started.status == .ok)
            #expect(started.json["userCode"] as? String == Self.issued.userCode)
            #expect(started.json["verificationURI"] as? String == Self.issued.verificationURI)
            #expect(started.json["deviceCode"] as? String == Self.issued.deviceCode)
            #expect(started.json["interval"] as? Int == Self.issued.interval)
            #expect(started.json["expiresIn"] as? Int == Self.issued.expiresIn)
        }
    }

    /// The code that came out of the start route is the code the exchange accepts, asserted
    /// as one flow rather than as two tests sharing a constant. What it rules out is a start
    /// route that reshaped the device code on the way out — a trim, a case fold, a URL escape
    /// — which no field-by-field check above would catch if the fixture happened to be
    /// invariant under it.
    @Test func theCodeTheStartRouteHandsOutIsTheCodeTheExchangeRedeems() async throws {
        try await Self.makeApp().test(.router) { client in
            let started = try await Self.start(client)
            let code = try #require(started.json["deviceCode"] as? String)
            let created = try await Self.exchange(client, code: code)
            #expect(created.status == .created)
        }
    }

    /// A deployment with no `STELE_GITHUB_CLIENT_ID` cannot start a sign-in, and says so with
    /// the same refusal everything else says nothing with.
    ///
    /// The temptation is a `503`, or a message naming the variable, and both are refused: the
    /// operator has the boot log, which names exactly which half is missing, and the prober
    /// has nothing. A start route that answered distinguishably while the exchange answered
    /// `401` would leak in aggregate what neither leaks alone — which half of the setup is
    /// missing, and therefore that a deployment has the other half.
    @Test func aDeploymentWithNoClientIDCannotStartASignIn() async throws {
        let unconfigured = InMemoryGitHub([Self.ownerToken: Self.ownerLogin])
        try await Self.makeApp(github: unconfigured).test(.router) { client in
            let refused = try await Self.start(client)
            #expect(refused.status == .unauthorized)
            #expect(refused.json["deviceCode"] == nil)
            // Nothing about configuration, in either direction: the message must not name
            // the variable, and it must not name GitHub's app either.
            #expect(!refused.raw.lowercased().contains("client"))
            #expect(!refused.raw.lowercased().contains("configur"))
        }
    }

    // MARK: - Minting

    /// The happy path. An authorised device code belonging to somebody on the allowlist buys
    /// a credential with exactly the shape `POST /admin/clients` hands out — same body, same
    /// `201`, same one-time token — because the CLI decodes both with one type and a second
    /// shape here would be a second decoder to keep in agreement.
    @Test func anAllowlistedIdentityMintsAPublishScopedCredential() async throws {
        try await Self.makeApp().test(.router) { client in
            let created = try await Self.exchange(client, code: Self.ownerDeviceCode)
            #expect(created.status == .created)

            let token = try #require(created.json["token"] as? String)
            #expect(token.hasPrefix(ClientCredential.prefix))
            // The prefix plus base64url of 32 bytes: long enough that a truncated or
            // placeholder value cannot pass.
            #expect(token.count > ClientCredential.prefix.count + 40)

            let credential = try #require(created.json["client"] as? [String: Any])
            // The login, folded into the alphabet a credential name is addressed by — not
            // GitHub's canonical casing, which `DELETE /admin/clients/:name` could not
            // address.
            #expect(credential["name"] as? String == Self.ownerName)
            // `publish` and nothing else. A sign-in mints an agent's credential; the scope
            // that mints credentials is not one an owner can arrive at through this route.
            #expect(credential["scopes"] as? [String] == [ClientScope.publish.rawValue])
            #expect(credential["createdAt"] is String)
            // Rotation is by signing in again, so there is no server-imposed deadline —
            // a second way for a working agent to die, with nothing asking for it.
            #expect(credential["expiresAt"] == nil || credential["expiresAt"] is NSNull)
            #expect(credential["revokedAt"] == nil || credential["revokedAt"] is NSNull)
            // The secret belongs to the response, not to the credential record.
            #expect(credential["token"] == nil)
        }
    }

    /// End to end, and the assertion that the minting actually works rather than merely
    /// returning a plausible string: the token that came out of a sign-in publishes a page
    /// through the ordinary write route, with no operator in the loop at any point.
    @Test func theMintedCredentialCanImmediatelyPublish() async throws {
        try await Self.makeApp().test(.router) { client in
            let created = try await Self.exchange(client, code: Self.ownerDeviceCode)
            let token = try #require(created.json["token"] as? String)
            #expect(try await Self.publish(client, with: token) == .created)
        }
    }

    /// GitHub compares logins case-insensitively and displays a canonical casing, so an
    /// operator will write whichever one they were looking at. Both directions have to
    /// match, and the resulting credential name is lowercase either way — the name is a URL
    /// path segment on `DELETE /admin/clients/:name`, which has no uppercase in its
    /// alphabet at all.
    @Test(arguments: [
        (allowlist: "projedi1234", login: "ProJedi1234"),
        (allowlist: "ProJedi1234", login: "projedi1234"),
        (allowlist: "PROJEDI1234", login: "ProJedi1234"),
    ])
    func allowlistMatchingIsCaseInsensitive(allowlist: String, login: String) async throws {
        let app = try Self.makeApp(
            github: InMemoryGitHub(
                [Self.ownerToken: login],
                redeeming: [Self.ownerDeviceCode: .token(Self.ownerToken)]
            ),
            owners: allowlist
        )
        try await app.test(.router) { client in
            let created = try await Self.exchange(client, code: Self.ownerDeviceCode)
            #expect(created.status == .created, "\(allowlist) vs \(login)")
            let credential = try #require(created.json["client"] as? [String: Any])
            #expect(credential["name"] as? String == Self.ownerName)
        }
    }

    // MARK: - Waiting

    /// The outcome that is neither a credential nor a refusal, and the one this flow spends
    /// nearly all of its time in. A `202` carrying the interval to wait, and — asserted
    /// explicitly — not a `401`, because a client told "refused" while the person is still
    /// typing gives up on a sign-in that was about to succeed.
    ///
    /// No credential comes with it, which is the other half: a handler that answered `202`
    /// *and* minted would hand out a credential for a code nobody had authorised.
    @Test func aPendingSignInIsA202CarryingTheInterval() async throws {
        try await Self.makeApp().test(.router) { client in
            let pending = try await Self.exchange(client, code: Self.pendingDeviceCode)
            #expect(pending.status == .accepted)
            #expect(pending.status != .unauthorized)
            #expect(pending.json["interval"] as? Int == Self.pollSeconds)
            #expect(pending.json["token"] == nil)
            #expect(pending.json["client"] == nil)
        }
    }

    /// `slow_down` is a bigger number and not a new shape, which is the decision the seam's
    /// `.pending(retryAfterSeconds:)` records and this is where the route is held to it.
    /// GitHub spells the two cases differently; a client only ever needs to know how long to
    /// wait, and a distinct status or an extra field here would be a branch every client had
    /// to write and none could do anything useful with.
    ///
    /// Compared as whole responses minus `content-length`, so a `Retry-After` appearing on
    /// one and not the other would fail here — the two differ by a number in the body and by
    /// nothing else.
    @Test func slowDownIsABiggerIntervalRatherThanANewShape() async throws {
        try await Self.makeApp().test(.router) { client in
            let ordinary = try await client.execute(
                uri: Self.path,
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"deviceCode":"\#(Self.pendingDeviceCode)"}"#)
            ) { Rejection($0) }
            let slowed = try await client.execute(
                uri: Self.path,
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"deviceCode":"\#(Self.slowedDeviceCode)"}"#)
            ) { Rejection($0) }

            #expect(ordinary.status == slowed.status)
            #expect(
                ordinary.headers.filter { !$0.hasPrefix("content-length") }
                    == slowed.headers.filter { !$0.hasPrefix("content-length") }
            )

            let decoded = try await Self.exchange(client, code: Self.slowedDeviceCode)
            #expect(decoded.json["interval"] as? Int == Self.slowedPollSeconds)
            #expect(Self.slowedPollSeconds > Self.pollSeconds)
        }
    }

    // MARK: - Refusing

    /// The property the whole pair of routes rests on: seven different reasons to refuse
    /// produce one response, byte for byte, headers included — and one of them comes from the
    /// *other route*, which is what keeps the pair from leaking in aggregate what neither
    /// leaks alone.
    ///
    /// The comparison is whole-response rather than seven `== .unauthorized` checks, because
    /// a shared status was never the part in doubt. What would leak is a `content-length` a
    /// few bytes apart, a header one branch sets and another does not, or a message that
    /// names which check failed — and the one that must never be nameable is "that is a real
    /// GitHub account, just not an owner here", which turns these routes into a directory of
    /// who owns the deployment.
    ///
    /// The last two shapes are the fail-closed configuration seen from outside: a valid
    /// owner's authorised code against an application with no allowlist, and a start against
    /// an application with no client ID. An unconfigured deployment must not be
    /// distinguishable from one that simply does not want you.
    @Test func everyRefusalIsOneByteIdentical401() async throws {
        let refusals = try await Self.makeApp().test(.router) { client -> [Rejection] in
            var collected: [Rejection] = []
            // A code GitHub never issued; one it issued and will not redeem, which is expired
            // and declined both; one belonging to an account on nobody's allowlist; one
            // carrying a byte no header can hold; and an empty one. The last two never reach
            // GitHub at all.
            for code in [
                "dev_junk", Self.deadDeviceCode, Self.strangerDeviceCode, #"dev_x\ny"#, "",
            ] {
                collected.append(try await client.execute(
                    uri: Self.path,
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: #"{"deviceCode":"\#(code)"}"#)
                ) { Rejection($0) })
            }
            return collected
        }

        let unallowlisted = try await Self.makeApp(owners: nil).test(.router) { client in
            try await client.execute(
                uri: Self.path,
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"deviceCode":"\#(Self.ownerDeviceCode)"}"#)
            ) { Rejection($0) }
        }

        let unconfigured = try await Self
            .makeApp(github: InMemoryGitHub([Self.ownerToken: Self.ownerLogin]))
            .test(.router) { client in
                try await client.execute(uri: Self.startPath, method: .post) { Rejection($0) }
            }

        let all = refusals + [unallowlisted, unconfigured]
        for rejection in all {
            #expect(rejection.status == .unauthorized)
        }
        for index in all.indices.dropFirst() {
            #expect(all[index - 1] == all[index], "refusal \(index - 1) vs \(index)")
        }

        let first = try #require(all.first)
        // Not seven copies of some *other* uniform answer: routes that threw the same 500 for
        // all of them would satisfy every comparison above.
        #expect(String(decoding: first.body, as: UTF8.self).contains("GitHub sign-in was refused"))
        // And the header half of the comparison is not vacuous. If these responses ever
        // carried no headers at all, "identical headers" would stay true for free — and go
        // on being true after somebody added a distinguishing one.
        #expect(!first.headers.isEmpty)
    }

    /// The fail-closed acceptance, spelled at the level an operator would feel it. Unset,
    /// blank and nothing-but-commas are the three ways `STELE_GITHUB_OWNERS` ends up
    /// permitting nobody, and a device code the fake *would* redeem into an identified
    /// account is refused under each — so the refusal is the allowlist's and not the fake's.
    @Test(arguments: [nil, "", "   ", " , ,"])
    func anAbsentOrBlankAllowlistRefusesEveryExchange(owners: String?) async throws {
        try await Self.makeApp(owners: owners).test(.router) { client in
            let refused = try await Self.exchange(client, code: Self.ownerDeviceCode)
            #expect(refused.status == .unauthorized, "\(owners ?? "<unset>")")
            #expect(refused.json["token"] == nil)
        }
    }

    /// A missing allowlist stops the *exchange* and deliberately does not stop the *start*.
    ///
    /// It reads like a bug and is the same fail-closed reasoning taken the other way round:
    /// the start route knows nothing about who is asking — nobody has authorised anything
    /// yet, and there is no identity to check against a list. Refusing there on the strength
    /// of the allowlist would tell a prober that `STELE_GITHUB_OWNERS` is unset, which is
    /// precisely the fact `everyRefusalIsOneByteIdentical401` spends seven shapes hiding. The
    /// sign-in still fails; it fails at the poll, indistinguishably from every other way it
    /// can.
    @Test func aStartSucceedsWithNoAllowlistAndThePollStillRefuses() async throws {
        try await Self.makeApp(owners: nil).test(.router) { client in
            let started = try await Self.start(client)
            #expect(started.status == .ok)
            let code = try #require(started.json["deviceCode"] as? String)
            #expect(try await Self.exchange(client, code: code).status == .unauthorized)
        }
    }

    /// The one refusal on this route that is *not* the uniform 401, and it is the same
    /// distinction `BearerTokenMiddleware` draws for a missing `Authorization` header: a
    /// caller who presented no credential at all has learned nothing about which credentials
    /// exist, and telling them the shape of the body is what makes a mistyped field name
    /// fixable rather than indistinguishable.
    @Test func aMalformedBodyIs400AndNamesTheShapeExpected() async throws {
        try await Self.makeApp().test(.router) { client in
            for body in ["", "not json", #"{"code":"dev_x"}"#, #"{"device_code":"dev_x"}"#] {
                let response = try await Self.post(client, body: body)
                #expect(response.status == .badRequest, "\(body)")
                #expect(response.raw.contains("deviceCode"), "\(body)")
                #expect(response.json["token"] == nil, "\(body)")
            }
        }
    }

    /// The body this route used to take was a GitHub access token, and a client still sending
    /// one gets a `400` naming the shape rather than a `401`.
    ///
    /// Pinned separately from the malformed bodies above because it is the only one anybody
    /// will actually send, and because the wrong answer here is expensive in a specific way:
    /// a `401` would tell somebody running an older CLI that their GitHub account was
    /// refused, and send them to check their allowlist, their token and their organisation
    /// membership for a problem that is an upgrade. The old field name is named in the
    /// assertion so that a future request type which quietly re-added `accessToken` — as an
    /// optional, as a fallback, as a kindness — fails here.
    @Test func theOldAccessTokenBodyIsA400NotARefusal() async throws {
        try await Self.makeApp().test(.router) { client in
            let response = try await Self.post(
                client, body: #"{"accessToken":"\#(Self.ownerToken)"}"#
            )
            #expect(response.status == .badRequest)
            #expect(response.status != .unauthorized)
            #expect(response.status != .created)
            #expect(response.raw.contains("deviceCode"))
            #expect(response.json["token"] == nil)
        }
    }

    /// A string that could never be presented to GitHub is refused without asking GitHub, and
    /// `UnreachableGitHub` is what makes that assertion mean something: it throws for every
    /// code it is handed, so a `401` here proves it was never handed this one — and
    /// `gitHubBeingUnreachableIsA500NotA401` below is the positive control, the same
    /// conformer producing its `500` for a code that *is* presentable.
    ///
    /// The shape matters less than it did when this field was an access token bound for an
    /// `Authorization` header, and the check is kept for the reasons the seam records: a
    /// round trip not taken on a value GitHub cannot have issued, and one refusal shape
    /// rather than two.
    ///
    /// The first two are raw strings, so their backslashes reach the wire as JSON escapes
    /// and arrive at the handler as a real newline and a real NUL. The third is a plain
    /// space, which a header would in fact carry — the rule is "printable, and no spaces",
    /// because a device code with a space in it is not a device code either.
    @Test(arguments: [#"dev_x\ny"#, #"dev_x\u0000y"#, "dev_x y", ""])
    func aDeviceCodeThatCouldNotBePresentedIsRefusedWithoutAskingGitHub(
        code: String
    ) async throws {
        try await Self.makeApp(github: UnreachableGitHub()).test(.router) { client in
            let refused = try await Self.exchange(client, code: code)
            #expect(refused.status == .unauthorized, "\(code)")
            #expect(refused.status != .internalServerError, "\(code)")
        }
    }

    /// An outage is not a refusal, on either route. `UnreachableGitHub` throws where the real
    /// conformer would have thrown on a 5xx or a dead connection, and the answer has to be a
    /// `500`: a `401` would tell every legitimate owner that their sign-in was refused, which
    /// reads as "my account is no longer allowed" and sends them round a re-authentication
    /// loop against a dependency that cannot answer. The bearer routes make the same call
    /// about a database that is down.
    ///
    /// Both routes, because the start is where an outage is met first and it is the one whose
    /// refusal — an unconfigured deployment — is a nil rather than a throw. A conformer that
    /// collapsed the two would make a GitHub outage look like a server nobody had set up.
    @Test func gitHubBeingUnreachableIsA500NotA401() async throws {
        try await Self.makeApp(github: UnreachableGitHub()).test(.router) { client in
            let polled = try await Self.exchange(client, code: Self.ownerDeviceCode)
            #expect(polled.status == .internalServerError)
            #expect(polled.status != .unauthorized)
            #expect(polled.json["token"] == nil)

            let started = try await Self.start(client)
            #expect(started.status == .internalServerError)
            #expect(started.status != .unauthorized)
            #expect(started.json["deviceCode"] == nil)
        }
    }

    /// An `error` string GitHub has never documented is GitHub behaving unexpectedly, and it
    /// stays a `500` rather than a refusal all the way out to the wire.
    ///
    /// The decision is `GitHubAPI.verdict(forOAuthError:)`'s and `GitHubAPITests` pins it
    /// there; this is the route half, and it is worth having separately because the route is
    /// where the wrong answer would be felt. An unknown string is not the caller's fault and
    /// cannot be — they sent a device code, and every fact about a device code has a
    /// documented spelling — so blaming them for it would send a person round the sign-in
    /// loop over a GitHub change only the operator can act on.
    @Test func anUnrecognisedOAuthErrorIsA500NotARefusal() async throws {
        try await Self.makeApp(github: ConfusedGitHub()).test(.router) { client in
            let response = try await Self.exchange(client, code: Self.ownerDeviceCode)
            #expect(response.status == .internalServerError)
            #expect(response.status != .unauthorized)
            #expect(response.status != .accepted)
        }
    }

    /// The version gate is deliberately absent on both routes, and this is what would notice
    /// it coming back. It sits after authentication everywhere else so it never answers an
    /// unauthenticated prober; these routes have no authentication in front of them, and
    /// gating them would refuse the credential to exactly the user whose CLI is too old to
    /// have one — bootstrapping blocked by the thing being bootstrapped.
    @Test func neitherSignInRouteIsVersionGated() async throws {
        let ancient: HTTPFields = [
            .contentType: "application/json",
            .userAgent: "\(SteleCLI.userAgentProduct)/0.0.1",
        ]
        try await Self.makeApp().test(.router) { client in
            let started = try await Self.start(
                client, headers: [.userAgent: "\(SteleCLI.userAgentProduct)/0.0.1"]
            )
            #expect(started.status == .ok)
            #expect(started.status != .upgradeRequired)

            let created = try await Self.exchange(
                client, code: Self.ownerDeviceCode, headers: ancient
            )
            #expect(created.status == .created)

            // And a refusal under the same header is still the uniform 401 rather than a
            // 426 — a gate that fired only on the failing branch would be just as wrong and
            // much harder to see.
            let refused = try await Self.exchange(client, code: "dev_junk", headers: ancient)
            #expect(refused.status == .unauthorized)
            #expect(refused.status != .upgradeRequired)
        }
    }

    // MARK: - Signing in again

    /// Repeat sign-in is a rotation, not a conflict: the live credential under the login's
    /// name is revoked and a fresh one minted under the same name. That is the only recovery
    /// there can be for a lost token — the plaintext exists nowhere — and it rides the
    /// live-only name index that makes revoke-then-mint legal.
    @Test func aRepeatLoginRotatesTheCredentialUnderItsName() async throws {
        try await Self.makeApp().test(.router) { client in
            let first = try await Self.exchange(client, code: Self.ownerDeviceCode)
            #expect(first.status == .created)
            let firstToken = try #require(first.json["token"] as? String)

            let second = try await Self.exchange(client, code: Self.ownerDeviceCode)
            #expect(second.status == .created)
            let secondToken = try #require(second.json["token"] as? String)
            #expect(secondToken != firstToken)

            // The new one works and the old one is dead — not merely superseded in a
            // listing, but refused at the door.
            #expect(try await Self.publish(client, with: secondToken) == .created)
            #expect(try await Self.publish(client, with: firstToken) == .unauthorized)

            // Both rows survive under one name, the retired one carrying the `revoked_at`
            // that is the audit trail for the rotation.
            let listed = try await Self.listClients(client)
            #expect(listed.compactMap { $0["name"] as? String } == [Self.ownerName, Self.ownerName])
            #expect(listed.first?["revokedAt"] is String)
            #expect(listed.last?["revokedAt"] == nil || listed.last?["revokedAt"] is NSNull)

            // Both rows are attributed, which is what makes the listing readable as a
            // history rather than as two credentials that happen to share a name. The
            // retired row keeping its login is the half a `revoke` that rewrote more than
            // `revoked_at` would quietly lose, and it is the row an operator reads when
            // asking who was signed in at the time of something.
            #expect(listed.first?["githubLogin"] as? String == Self.ownerLogin)
            #expect(listed.last?["githubLogin"] as? String == Self.ownerLogin)
        }
    }

    /// What a rotation must *not* touch, which is the half a wrong `revoke` would get away
    /// with. A sign-in retires the live credential holding *that login's* name and nothing
    /// else: another owner's credential keeps publishing, an operator's hand-minted
    /// credential under a different name is untouched, and an earlier retirement keeps the
    /// timestamp it already had — that instant is the boundary an incident is reconstructed
    /// from, and a third sign-in that moved the first one would erase it.
    @Test func aRepeatLoginDisturbsNoOtherCredentialAndNoEarlierRetirement() async throws {
        let clients = InMemoryClientStore()
        let bystander = "stele_pat_operator-minted"
        await clients.seed(token: bystander, name: "claude-code", scopes: [.publish])

        let app = try Self.makeApp(
            clients: clients,
            github: InMemoryGitHub(
                [Self.ownerToken: Self.ownerLogin, Self.strangerToken: Self.strangerLogin],
                redeeming: [
                    Self.ownerDeviceCode: .token(Self.ownerToken),
                    Self.strangerDeviceCode: .token(Self.strangerToken),
                ]
            ),
            // Both logins are owners here, so the stranger's code redeems into a *second*
            // owner rather than a refusal.
            owners: "\(Self.ownerName), \(Self.strangerLogin)"
        )

        try await app.test(.router) { client in
            _ = try await Self.exchange(client, code: Self.ownerDeviceCode)
            let otherOwner = try await Self.exchange(client, code: Self.strangerDeviceCode)
            let otherOwnerToken = try #require(otherOwner.json["token"] as? String)

            let secondSignIn = try await Self.exchange(client, code: Self.ownerDeviceCode)
            #expect(secondSignIn.status == .created)
            let retirement = try #require(
                try await Self.listClients(client)
                    .first { $0["name"] as? String == Self.ownerName }?["revokedAt"] as? String
            )

            let thirdSignIn = try await Self.exchange(client, code: Self.ownerDeviceCode)
            #expect(thirdSignIn.status == .created)

            // The other owner's credential and the hand-minted one both still publish: a
            // `revoke` that resolved by anything looser than the name would have taken one
            // of them, and the failure would look like an unrelated agent losing access.
            #expect(try await Self.publish(client, with: otherOwnerToken) == .created)
            #expect(try await Self.publish(client, with: bystander) == .created)

            let listed = try await Self.listClients(client)
            #expect(listed.filter { $0["name"] as? String == Self.strangerLogin }.count == 1)
            #expect(listed.filter { $0["name"] as? String == "claude-code" }.count == 1)
            // Three rows for the owner, two retired; the first retirement's timestamp has
            // not moved under the second.
            let owned = listed.filter { $0["name"] as? String == Self.ownerName }
            #expect(owned.count == 3)
            #expect(owned.first?["revokedAt"] as? String == retirement)
            #expect(owned.last?["revokedAt"] == nil || owned.last?["revokedAt"] is NSNull)
        }
    }

    /// The sharp edge of naming a credential after a login: `POST /admin/clients` and this
    /// route mint into one namespace, and `revoke(name:)` resolves by name and by nothing
    /// else. So an operator who hand-mints `projedi1234` — the obvious name for their own
    /// credential, and exactly the name a sign-in derives — loses it to that person's next
    /// sign-in, whatever scopes it carried.
    ///
    /// Pinned rather than merely true, because it is inherited behaviour that reads as an
    /// accident: an `admin` credential silently downgraded to `publish` and revoked, with the
    /// route that would report it now out of the operator's reach. The alternative was a
    /// `github-` prefix carving the namespaces apart, which was weighed and refused — the
    /// name is the handle `stele auth status` shows — so this test is where the decision
    /// lives. If it starts failing, the question is which of the two behaviours was meant.
    ///
    /// `aRepeatLoginDisturbsNoOtherCredentialAndNoEarlierRetirement` is the other half and
    /// deliberately seeds its bystander under a *different* name: together they say the
    /// revoke reaches exactly the rows sharing the login's name and no others.
    @Test func aSignInRetiresAHandMintedCredentialUnderTheLoginsName() async throws {
        let clients = InMemoryClientStore()
        let operatorToken = "stele_pat_operators-own"
        await clients.seed(token: operatorToken, name: Self.ownerName, scopes: [.admin])

        try await Self.makeApp(clients: clients).test(.router) { client in
            // Live and `admin`-scoped before the sign-in: it can read the listing.
            #expect(try await Self.listingStatus(client, with: operatorToken) == .ok)

            let created = try await Self.exchange(client, code: Self.ownerDeviceCode)
            #expect(created.status == .created)

            // Revoked by the sign-in — refused at the door, not merely superseded.
            #expect(try await Self.listingStatus(client, with: operatorToken) == .unauthorized)

            // And what replaced it is an agent's credential: the `admin` scope does not
            // survive the rotation, so the sign-in is a demotion as well as a revocation.
            let replacement = try #require(created.json["token"] as? String)
            #expect(try await Self.listingStatus(client, with: replacement) == .forbidden)
            #expect(try await Self.publish(client, with: replacement) == .created)
        }
    }

    // MARK: - Provenance

    /// A credential minted by a sign-in records the account that signed in, and one minted by
    /// the operator records nothing — asserted in the same listing, because the whole value of
    /// the field is telling those two apart. A column that were always populated, or always
    /// null, would satisfy either assertion on its own.
    ///
    /// The casing is the second claim. What is stored is the login GitHub reports, not the
    /// folded spelling the credential is addressed by, so the two are visibly different values
    /// in the same object: an implementation that recorded `name` a second time under another
    /// key would pass a test written with an all-lowercase login and prove nothing.
    ///
    /// Reported in three places and checked in all three — the `201` the signer-in reads, the
    /// listing the operator reads, and the `whoami` the credential itself reads — because they
    /// are three separate outputs of one `ClientResponse` and a fourth could stop being one.
    ///
    /// The hand-minted leg *asks* for a login and is refused one, which is the negative half
    /// of the same property. `CreateClientRequest` has no such field and `JSONDecoder` drops
    /// the key, so today this passes by the shape of the request type alone; asserting it
    /// here is what turns that into a refusal, and a later "let the operator label who this
    /// credential is for" edit has to argue with a failing test rather than land quietly.
    /// The exchange is the only thing permitted to write this column, and that is the whole
    /// reason NULL means "nobody signed in for this" rather than "nobody filled it in".
    @Test func anExchangeMintedCredentialCarriesItsLoginEverywhereItIsReported() async throws {
        try await Self.makeApp().test(.router) { client in
            // Minted through the *admin* route, so both origins exist in one store and the
            // listing below is a genuine comparison rather than two runs of one shape. The
            // body asks for the very login the exchange writes a few lines down, so what is
            // pinned is the route ignoring it rather than the store failing to match.
            let handMinted = try await client.execute(
                uri: "/\(ServerRoute.admin)/\(ServerRoute.adminClients)",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.token)",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(
                    string: #"{"name":"claude-code","githubLogin":"\#(Self.ownerLogin)"}"#
                )
            ) { response -> [String: Any] in
                #expect(response.status == .created)
                return (try? JSONSerialization.jsonObject(with: Data(buffer: response.body)))
                    as? [String: Any] ?? [:]
            }
            let handMintedCredential = try #require(handMinted["client"] as? [String: Any])
            #expect(
                handMintedCredential["githubLogin"] == nil
                    || handMintedCredential["githubLogin"] is NSNull
            )

            let created = try await Self.exchange(client, code: Self.ownerDeviceCode)
            #expect(created.status == .created)
            let credential = try #require(created.json["client"] as? [String: Any])
            #expect(credential["githubLogin"] as? String == Self.ownerLogin)
            // The name is the fold and the login is not, in one object.
            #expect(credential["name"] as? String == Self.ownerName)

            let listed = try await Self.listClients(client)
            let signedInRow = try #require(listed.first { $0["name"] as? String == Self.ownerName })
            #expect(signedInRow["githubLogin"] as? String == Self.ownerLogin)
            let handMintedRow = try #require(listed.first { $0["name"] as? String == "claude-code" })
            #expect(
                handMintedRow["githubLogin"] == nil || handMintedRow["githubLogin"] is NSNull
            )

            // And the credential can read its own provenance, which is what `stele auth
            // status` shows the machine holding it.
            let token = try #require(created.json["token"] as? String)
            try await client.execute(
                uri: "/\(ServerRoute.admin)/\(ServerRoute.adminWhoami)",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let json = (try? JSONSerialization.jsonObject(with: Data(buffer: response.body)))
                    as? [String: Any] ?? [:]
                #expect(json["githubLogin"] as? String == Self.ownerLogin)
            }
        }
    }

    // MARK: - The secret

    /// The negative property this whole feature has to keep, asserted on the raw bytes
    /// rather than on a decoded shape so that a key some future `Encodable` conformance adds
    /// by accident is caught too. The token is in the `201` and in nothing else: not in the
    /// admin listing, not in the credential's own `whoami`, not in a refusal.
    @Test func theTokenAppearsInThe201AndInNoOtherResponse() async throws {
        try await Self.makeApp().test(.router) { client in
            let started = try await Self.start(client).raw
            let created = try await Self.exchange(client, code: Self.ownerDeviceCode)
            let token = try #require(created.json["token"] as? String)
            #expect(created.raw.contains(token))

            let listing = try await client.execute(
                uri: "/\(ServerRoute.admin)/\(ServerRoute.adminClients)",
                method: .get,
                headers: [.authorization: "Bearer \(TestFixture.token)"]
            ) { response -> String in
                // Guarded for the same reason `whoami` is below, and it is the leg where a
                // vacuous pass would be easiest to miss: a listing that answered `403` or an
                // empty envelope carries no token, no "token" and no "hash", so all six
                // expectations at the bottom would hold while checking nothing at all. The
                // credential just minted has to be *in* the body being scanned.
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains(Self.ownerName))
                return body
            }

            let whoami = try await client.execute(
                uri: "/\(ServerRoute.admin)/\(ServerRoute.adminWhoami)",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response -> String in
                // The credential really is the one just minted, so the scan below is over a
                // body that had every opportunity to carry the token.
                #expect(response.status == .ok)
                return String(buffer: response.body)
            }

            let refusal = try await Self.exchange(client, code: "dev_junk").raw

            for body in [listing, whoami, refusal] {
                #expect(!body.contains(token))
                #expect(!body.lowercased().contains("token"))
                #expect(!body.lowercased().contains("hash"))
            }
            // The start response is scanned on its own terms. It legitimately carries two
            // codes, so the vocabulary check does not apply to it; what does apply is that a
            // route which has minted nothing carries no credential and no digest.
            #expect(!started.contains(token))
            #expect(!started.lowercased().contains("hash"))
        }
    }

    /// The reason the flow was reshaped at all: the GitHub access token is born and dies
    /// inside one handler, so it appears in no response on either route.
    ///
    /// Asserted on raw bytes across every response a sign-in produces — the start, a pending
    /// poll, the `201`, and the refusal a non-owner gets *after* GitHub minted a token for
    /// them, which is the one leg where the value genuinely passed through the handler.
    /// The failure this guards against is a convenience: a handler that returned what GitHub
    /// gave it, or an error message that quoted the value it could not use. Either would put
    /// a live credential for somebody's entire GitHub account into a terminal, which is
    /// precisely what the client no longer holding one was for.
    @Test func theGitHubAccessTokenNeverLeavesTheServer() async throws {
        try await Self.makeApp().test(.router) { client in
            let bodies = try await [
                Self.start(client).raw,
                Self.exchange(client, code: Self.pendingDeviceCode).raw,
                Self.exchange(client, code: Self.ownerDeviceCode).raw,
                Self.exchange(client, code: Self.strangerDeviceCode).raw,
            ]
            for body in bodies {
                #expect(!body.contains(Self.ownerToken))
                #expect(!body.contains(Self.strangerToken))
            }
        }
    }

    /// What `GET /admin/clients` answers a given credential, for the tests that are asking
    /// about the credential rather than about the listing: `200` while it is live and holds
    /// `admin`, `403` while it is live and does not, `401` once it has been revoked.
    static func listingStatus(
        _ client: some TestClientProtocol,
        with token: String
    ) async throws -> HTTPResponse.Status {
        try await client.execute(
            uri: "/\(ServerRoute.admin)/\(ServerRoute.adminClients)",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { $0.status }
    }

    /// `GET /admin/clients` through the shared admin credential, which is the only thing in
    /// these tests holding `admin` — a sign-in mints `publish` and nothing more, so the
    /// credential under test cannot read its own listing.
    static func listClients(_ client: some TestClientProtocol) async throws -> [[String: Any]] {
        try await client.execute(
            uri: "/\(ServerRoute.admin)/\(ServerRoute.adminClients)",
            method: .get,
            headers: [.authorization: "Bearer \(TestFixture.token)"]
        ) { response in
            let payload = (try? JSONSerialization.jsonObject(with: Data(buffer: response.body)))
                as? [String: Any]
            return payload?["clients"] as? [[String: Any]] ?? []
        }
    }
}

/// GitHub, unreachable. Stands in for everything on the far side of the seam that is not an
/// answer: a connection that never opened, a 5xx, a body that did not decode.
///
/// It throws where `InMemoryGitHub` returns nil or `.refused`, and that difference is the
/// entire point of the type — the seam's contract is that nil is GitHub's *verdict* and a
/// thrown error is the absence of one, and this is what proves the routes keep them apart.
private struct UnreachableGitHub: GitHubIdentifying {
    struct Outage: Error {}

    func login(forAccessToken token: String) async throws -> String? {
        throw Outage()
    }

    func requestDeviceCode() async throws -> GitHubDeviceCode? {
        throw Outage()
    }

    func redeemDeviceCode(_ deviceCode: String) async throws -> GitHubDeviceRedemption {
        throw Outage()
    }
}

/// GitHub, reachable and saying something nobody has documented.
///
/// Distinct from `UnreachableGitHub` because the failure it stands for is different in kind:
/// the request completed, the body decoded, and the `error` string inside it matched none of
/// the spellings RFC 8628 and GitHub between them define. `GitHubAPI` turns that into a throw
/// — see `verdict(forOAuthError:)` — and this conformer is that decision arriving at the
/// route, so the route's job of not blaming the caller for it can be asserted without a
/// socket.
private struct ConfusedGitHub: GitHubIdentifying {
    func login(forAccessToken token: String) async throws -> String? {
        nil
    }

    func requestDeviceCode() async throws -> GitHubDeviceCode? {
        GitHubExchangeTests.issued
    }

    func redeemDeviceCode(_ deviceCode: String) async throws -> GitHubDeviceRedemption {
        throw GitHubAPIError.unexpectedOAuthError("the_moon_is_in_gemini")
    }
}
