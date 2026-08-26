import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// HTTP-level tests for `POST /auth/github/exchange`, the one route in this server that is
/// neither a public read nor behind a credential.
///
/// Two properties carry most of the weight here and neither is about the happy path. The
/// first is that *every* refusal is one byte-identical `401`, because a route that could
/// distinguish "not an owner" from "bad token" would let anyone holding a GitHub token of
/// their own read this deployment's owner list off the status codes. The second is that a
/// GitHub outage is emphatically **not** a refusal: it is a `500`, because telling a
/// legitimate owner their sign-in was refused when GitHub is down sends them to
/// re-authenticate in a loop against something that cannot answer.
///
/// Nothing here reaches the network. `InMemoryGitHub` answers the seam's one primitive from
/// a dictionary, so what these exercise is the real shared policy in `GitHubIdentifying`'s
/// extension and the real route around it.
@Suite("GitHub sign-in exchange")
struct GitHubExchangeTests {
    static let path =
        "/\(ServerRoute.auth)/\(ServerRoute.authGitHub)/\(ServerRoute.authExchange)"

    /// The access token the fake recognises, and the login it reports for it — in GitHub's
    /// canonical casing, which is *not* the casing the allowlist below is written in. Every
    /// test that mints here therefore crosses the case fold at least once, so a comparison
    /// that quietly became case-sensitive fails the whole suite rather than one test.
    static let ownerToken = "gho_owner"
    static let ownerLogin = "ProJedi1234"
    static let ownerName = "projedi1234"

    /// A GitHub account that exists and is nobody's owner — the case that must be
    /// indistinguishable from a junk token.
    static let strangerToken = "gho_stranger"
    static let strangerLogin = "passing-stranger"

    static var identifiedTokens: InMemoryGitHub {
        InMemoryGitHub([ownerToken: ownerLogin, strangerToken: strangerLogin])
    }

    /// An application whose credential store starts empty, so a listing shows exactly what
    /// the test under it minted, and whose allowlist holds one owner.
    ///
    /// The allowlist arrives as an environment variable rather than as a constructed
    /// `GitHubOwnerAllowlist`, so what these tests exercise is the real parse-then-permit
    /// path an operator's `STELE_GITHUB_OWNERS` takes.
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

    /// Exchanges `token`, returning the status and the decoded body.
    ///
    /// No `Authorization` header anywhere in this file, and its absence is the point: the
    /// route *is* the authentication, so a test that quietly presented a stele credential
    /// would be proving that some other middleware let it through.
    @discardableResult
    static func exchange(
        _ client: some TestClientProtocol,
        token: String,
        headers: HTTPFields = [.contentType: "application/json"]
    ) async throws -> (status: HTTPResponse.Status, raw: String, json: [String: Any]) {
        try await post(client, body: #"{"accessToken":"\#(token)"}"#, headers: headers)
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
        ) { response in
            let raw = String(buffer: response.body)
            let json = (try? JSONSerialization.jsonObject(with: Data(buffer: response.body)))
                as? [String: Any] ?? [:]
            return (response.status, raw, json)
        }
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

    // MARK: - Minting

    /// The happy path. A GitHub identity on the allowlist buys a credential with exactly the
    /// shape `POST /admin/clients` hands out — same body, same `201`, same one-time token —
    /// because the CLI decodes both with one type and a second shape here would be a second
    /// decoder to keep in agreement.
    @Test func anAllowlistedIdentityMintsAPublishScopedCredential() async throws {
        try await Self.makeApp().test(.router) { client in
            let created = try await Self.exchange(client, token: Self.ownerToken)
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
            let created = try await Self.exchange(client, token: Self.ownerToken)
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
            github: InMemoryGitHub([Self.ownerToken: login]), owners: allowlist
        )
        try await app.test(.router) { client in
            let created = try await Self.exchange(client, token: Self.ownerToken)
            #expect(created.status == .created, "\(allowlist) vs \(login)")
            let credential = try #require(created.json["client"] as? [String: Any])
            #expect(credential["name"] as? String == Self.ownerName)
        }
    }

    // MARK: - Refusing

    /// The property the whole route rests on: five different reasons to refuse produce one
    /// response, byte for byte, headers included.
    ///
    /// The comparison is whole-response rather than five `== .unauthorized` checks, because
    /// a shared status was never the part in doubt. What would leak is a `content-length` a
    /// few bytes apart, a header one branch sets and another does not, or a message that
    /// names which check failed — and the one that must never be nameable is "that is a real
    /// GitHub account, just not an owner here", which turns this route into a directory of
    /// who owns the deployment.
    ///
    /// The last shape is a *valid owner* against an application with no allowlist, which is
    /// the fail-closed configuration seen from outside: an unconfigured deployment must not
    /// be distinguishable from one that simply does not want you.
    @Test func everyRefusalIsOneByteIdentical401() async throws {
        let refusals = try await Self.makeApp().test(.router) { client -> [Rejection] in
            var collected: [Rejection] = []
            // A token GitHub does not know; a token GitHub knows, belonging to nobody on the
            // allowlist; a token carrying a byte no header can hold; and an empty one. The
            // last two never reach GitHub at all.
            for token in ["gho_junk", Self.strangerToken, #"gho_x\ny"#, ""] {
                collected.append(try await client.execute(
                    uri: Self.path,
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: #"{"accessToken":"\#(token)"}"#)
                ) { Rejection($0) })
            }
            return collected
        }

        let unconfigured = try await Self.makeApp(owners: nil).test(.router) { client in
            try await client.execute(
                uri: Self.path,
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"accessToken":"\#(Self.ownerToken)"}"#)
            ) { Rejection($0) }
        }

        let all = refusals + [unconfigured]
        for rejection in all {
            #expect(rejection.status == .unauthorized)
        }
        for index in all.indices.dropFirst() {
            #expect(all[index - 1] == all[index], "refusal \(index - 1) vs \(index)")
        }

        let first = try #require(all.first)
        // Not four copies of some *other* uniform answer: a route that threw the same 500
        // for all four would satisfy every comparison above.
        #expect(String(decoding: first.body, as: UTF8.self).contains("GitHub sign-in was refused"))
        // And the header half of the comparison is not vacuous. If these responses ever
        // carried no headers at all, "identical headers" would stay true for free — and go
        // on being true after somebody added a distinguishing one.
        #expect(!first.headers.isEmpty)
    }

    /// The fail-closed acceptance, spelled at the level an operator would feel it. Unset,
    /// blank and nothing-but-commas are the three ways `STELE_GITHUB_OWNERS` ends up
    /// permitting nobody, and a token the fake *would* identify is refused under each — so
    /// the refusal is the allowlist's and not the fake's.
    @Test(arguments: [nil, "", "   ", " , ,"])
    func anAbsentOrBlankAllowlistRefusesEveryExchange(owners: String?) async throws {
        try await Self.makeApp(owners: owners).test(.router) { client in
            let refused = try await Self.exchange(client, token: Self.ownerToken)
            #expect(refused.status == .unauthorized, "\(owners ?? "<unset>")")
            #expect(refused.json["token"] == nil)
        }
    }

    /// The one refusal on this route that is *not* the uniform 401, and it is the same
    /// distinction `BearerTokenMiddleware` draws for a missing `Authorization` header: a
    /// caller who presented no credential at all has learned nothing about which credentials
    /// exist, and telling them the shape of the body is what makes a mistyped field name
    /// fixable rather than indistinguishable.
    @Test func aMalformedBodyIs400AndNamesTheShapeExpected() async throws {
        try await Self.makeApp().test(.router) { client in
            for body in ["", "not json", #"{"token":"gho_owner"}"#, #"{"access_token":"x"}"#] {
                let response = try await Self.post(client, body: body)
                #expect(response.status == .badRequest, "\(body)")
                #expect(response.raw.contains("accessToken"), "\(body)")
                #expect(response.json["token"] == nil, "\(body)")
            }
        }
    }

    /// A string that could never be presented to GitHub is refused without asking GitHub, and
    /// `UnreachableGitHub` is what makes that assertion mean something: it throws for every
    /// token it is handed, so a `401` here proves it was never handed this one — and
    /// `gitHubBeingUnreachableIsA500NotA401` below is the positive control, the same
    /// conformer producing its `500` for a token that *is* presentable.
    ///
    /// The shape matters because of where the value goes. `accessToken` is unauthenticated
    /// input interpolated into an `Authorization` header, and `AsyncHTTPClient` throws on a
    /// header value carrying a control character rather than sending it — which the seam
    /// reads as "the question could not be asked", so a token with a stray newline in it
    /// would answer `500`, the one status on this route that means GitHub is down. Anyone
    /// could then manufacture that signal at will, and a token pasted with a trailing newline
    /// would be told the server broke rather than that its token was no good.
    ///
    /// The first two are raw strings, so their backslashes reach the wire as JSON escapes
    /// and arrive at the handler as a real newline and a real NUL. The third is a plain
    /// space, which a header would in fact carry — the rule is "printable, and no spaces",
    /// because a bearer token with a space in it is not a token either.
    @Test(arguments: [#"gho_x\ny"#, #"gho_x\u0000y"#, "gho_x y", ""])
    func aTokenThatCouldNotBePresentedIsRefusedWithoutAskingGitHub(token: String) async throws {
        try await Self.makeApp(github: UnreachableGitHub()).test(.router) { client in
            let refused = try await Self.exchange(client, token: token)
            #expect(refused.status == .unauthorized, "\(token)")
            #expect(refused.status != .internalServerError, "\(token)")
        }
    }

    /// An outage is not a refusal. `UnreachableGitHub` throws where the real conformer would
    /// have thrown on a 5xx or a dead connection, and the answer has to be a `500`: a `401`
    /// would tell every legitimate owner that their sign-in was refused, which reads as "my
    /// account is no longer allowed" and sends them round a re-authentication loop against a
    /// dependency that cannot answer. The bearer routes make the same call about a database
    /// that is down.
    @Test func gitHubBeingUnreachableIsA500NotA401() async throws {
        try await Self.makeApp(github: UnreachableGitHub()).test(.router) { client in
            let response = try await Self.exchange(client, token: Self.ownerToken)
            #expect(response.status == .internalServerError)
            #expect(response.status != .unauthorized)
            #expect(response.json["token"] == nil)
        }
    }

    /// The version gate is deliberately absent here, and this is what would notice it coming
    /// back. It sits after authentication everywhere else so it never answers an
    /// unauthenticated prober; this route has no authentication in front of it, and gating it
    /// would refuse the credential to exactly the user whose CLI is too old to have one —
    /// bootstrapping blocked by the thing being bootstrapped.
    @Test func theExchangeIsNotVersionGated() async throws {
        let ancient: HTTPFields = [
            .contentType: "application/json",
            .userAgent: "\(SteleCLI.userAgentProduct)/0.0.1",
        ]
        try await Self.makeApp().test(.router) { client in
            let created = try await Self.exchange(
                client, token: Self.ownerToken, headers: ancient
            )
            #expect(created.status == .created)

            // And a refusal under the same header is still the uniform 401 rather than a
            // 426 — a gate that fired only on the failing branch would be just as wrong and
            // much harder to see.
            let refused = try await Self.exchange(client, token: "gho_junk", headers: ancient)
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
            let first = try await Self.exchange(client, token: Self.ownerToken)
            #expect(first.status == .created)
            let firstToken = try #require(first.json["token"] as? String)

            let second = try await Self.exchange(client, token: Self.ownerToken)
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
            github: InMemoryGitHub([
                Self.ownerToken: Self.ownerLogin, Self.strangerToken: Self.strangerLogin,
            ]),
            // Both logins are owners here, so the stranger's token is a *second* owner
            // rather than a refusal.
            owners: "\(Self.ownerName), \(Self.strangerLogin)"
        )

        try await app.test(.router) { client in
            _ = try await Self.exchange(client, token: Self.ownerToken)
            let otherOwner = try await Self.exchange(client, token: Self.strangerToken)
            let otherOwnerToken = try #require(otherOwner.json["token"] as? String)

            let secondSignIn = try await Self.exchange(client, token: Self.ownerToken)
            #expect(secondSignIn.status == .created)
            let retirement = try #require(
                try await Self.listClients(client)
                    .first { $0["name"] as? String == Self.ownerName }?["revokedAt"] as? String
            )

            let thirdSignIn = try await Self.exchange(client, token: Self.ownerToken)
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

            let created = try await Self.exchange(client, token: Self.ownerToken)
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

            let created = try await Self.exchange(client, token: Self.ownerToken)
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
            let created = try await Self.exchange(client, token: Self.ownerToken)
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

            let refusal = try await Self.exchange(client, token: "gho_junk").raw

            for body in [listing, whoami, refusal] {
                #expect(!body.contains(token))
                #expect(!body.lowercased().contains("token"))
                #expect(!body.lowercased().contains("hash"))
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
/// It throws where `InMemoryGitHub` returns nil, and that difference is the entire point of
/// the type — the seam's contract is that nil is GitHub's *verdict* and a thrown error is the
/// absence of one, and this is what proves the route keeps them apart.
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
