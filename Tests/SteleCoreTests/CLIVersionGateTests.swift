import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// Parsing and ordering of `stele-cli` versions, and what a `User-Agent` is taken to mean.
///
/// Pure functions, so they are tested as pure functions — the HTTP suite below only has to
/// establish that the middleware is wired in and consults these, not re-derive every case
/// through a router.
@Suite("CLI versions")
struct CLIVersionTests {
    @Test(arguments: [
        ("0.1.0", CLIVersion(0, 1, 0)),
        ("1.0.0", CLIVersion(1, 0, 0)),
        ("10.20.30", CLIVersion(10, 20, 30)),
        ("0.0.0", CLIVersion(0, 0, 0)),
        // A build from the client's working tree. Read as its release, deliberately: it is
        // by definition newer than the release it is named after, and answering a
        // developer's own build with "upgrade required" would be a lie about a binary that
        // is ahead of the requirement rather than behind it.
        ("1.2.3-dev", CLIVersion(1, 2, 3)),
        ("1.2.3+2f8a1c", CLIVersion(1, 2, 3)),
    ])
    func parsesAVersion(raw: String, expected: CLIVersion) {
        #expect(CLIVersion(parsing: raw) == expected)
    }

    /// `Int` accepts a leading sign and non-ASCII digits, so a version made of those would
    /// otherwise parse — and a nonsense string that parses to something large is a client
    /// that walks straight through the gate.
    @Test(arguments: ["", "1", "1.2", "1.2.3.4", "v1.2.3", "1.+2.3", "1.-2.3", "a.b.c", "..",
                      "1..3", "١.٢.٣"])
    func rejectsAnythingElse(raw: String) {
        #expect(CLIVersion(parsing: raw) == nil, "\(raw)")
    }

    /// Ordered by component, not lexicographically — the bug this catches is `0.10.0`
    /// comparing below `0.9.0`, which would reject exactly the clients that had upgraded.
    @Test func ordersByComponent() {
        #expect(CLIVersion(0, 9, 0) < CLIVersion(0, 10, 0))
        #expect(CLIVersion(0, 1, 9) < CLIVersion(0, 2, 0))
        #expect(CLIVersion(1, 0, 0) > CLIVersion(0, 99, 99))
        #expect(CLIVersion(1, 2, 3) == CLIVersion(1, 2, 3))
        #expect(!(CLIVersion(1, 2, 3) < CLIVersion(1, 2, 3)))
        #expect("\(CLIVersion(1, 2, 3))" == "1.2.3")
    }

    /// The three answers, and the one that matters most is `notTheCLI`: everything that is
    /// not this tool has to pass through untouched, because curl is still a supported way to
    /// publish and a gate that broke it would be a bigger outage than any drift it prevents.
    @Test(arguments: [
        (nil, CLIUserAgent.notTheCLI),
        ("", .notTheCLI),
        ("curl/8.6.0", .notTheCLI),
        ("Mozilla/5.0 (X11; Linux x86_64)", .notTheCLI),
        // Named but not versioned: not this product token, so not gated.
        ("stele-cli", .notTheCLI),
        ("stele-cli/0.1.0", .version(CLIVersion(0, 1, 0))),
        // A wrapper that prepends its own product still identifies the CLI.
        ("some-wrapper/2.0 stele-cli/1.4.2", .version(CLIVersion(1, 4, 2))),
        ("stele-cli/banana", .unreadableVersion("banana")),
        ("stele-cli/", .unreadableVersion("")),
    ])
    func classifiesAUserAgent(header: String?, expected: CLIUserAgent) {
        #expect(SteleCLI.classify(userAgent: header) == expected, "\(header ?? "nil")")
    }

    /// The two facts this repository hardcodes about the client repository, and the commands
    /// derived from them. Pinned here rather than only through the rendered skill so that
    /// the derivation — not just the document — is what a change has to survive.
    @Test func derivesTheInstallCommandsFromTheCheckoutPath() {
        #expect(SteleCLI.cloneCommand == "git clone \(SteleCLI.repository) \(SteleCLI.checkout)")
        #expect(SteleCLI.installCommand.hasSuffix(" install"))
        #expect(SteleCLI.installCommand.contains(SteleCLI.checkout))
        #expect(SteleCLI.completionsCommand.contains(SteleCLI.checkout))
    }
}

/// Two majors above the live constant, so "newer" and "older" are unambiguous below without
/// depending on where the real minimum sits today. At file scope, like `skillDocument` in
/// `PublishSkillTests`, so the parameterised cases can read it in their argument lists.
private let gate = CLIVersion(minimumCLIVersion.major + 2, 0, 0)

/// The version the wiring tests send: below any plausible minimum, and asserted to be below
/// the live one by `theFixturesOutdatedAgentIsActuallyOutdated`.
private let outdated = "stele-cli/0.0.1"

/// The `426` gate as HTTP behaviour.
///
/// Split in two on purpose. The first half drives the middleware through a router of its
/// own with an injected minimum, so the semantics are pinned against a version the test
/// chose and stay meaningful whatever `minimumCLIVersion` becomes. The second half asserts
/// only that the real write routes carry the middleware at all, and where in the chain —
/// which is the part that would silently rot if someone added a route to the wrong group.
@Suite("Minimum CLI version")
struct CLIVersionGateTests {
    static func gatedApp(_ minimum: CLIVersion = gate)
        -> Application<RouterResponder<SteleRequestContext>>
    {
        let router = Router(context: SteleRequestContext.self)
        router.group(RouterPath("gated"))
            .add(middleware: MinimumCLIVersionMiddleware(minimum))
            .post("") { _, _ -> String in "published" }
        return Application(router: router)
    }

    @Test(arguments: [
        // Nothing that fails to identify itself as this tool is gated.
        nil,
        "curl/8.6.0",
        // Exactly the minimum passes: the check is "at least", not "after".
        "stele-cli/\(gate)",
        "stele-cli/\(CLIVersion(gate.major + 1, 0, 0))",
        "stele-cli/\(gate)-dev",
    ])
    func acceptedAgents(header: String?) async throws {
        try await Self.gatedApp().test(.router) { client in
            try await client.execute(
                uri: "/gated",
                method: .post,
                headers: header.map { [.userAgent: $0] } ?? [:]
            ) { response in
                #expect(response.status == .ok, "\(header ?? "nil")")
            }
        }
    }

    @Test(arguments: [
        "stele-cli/\(CLIVersion(gate.major - 1, 99, 99))",
        "stele-cli/0.0.1",
        // Claims the product token and gives nothing readable: broken or hand-rolled, and
        // "reinstall" is the right answer to both. Not waved through as if it were curl —
        // a client that sends the header is asking to be version-checked.
        "stele-cli/banana",
    ])
    func rejectedAgents(header: String) async throws {
        try await Self.gatedApp().test(.router) { client in
            try await client.execute(
                uri: "/gated", method: .post, headers: [.userAgent: header]
            ) { response in
                #expect(response.status == .upgradeRequired, "\(header)")
                #expect(response.status.code == 426)

                // The body has to carry the remedy, because the caller most likely to see
                // this is an agent holding a copy of the skill fetched before the
                // deployment moved — the copy that may not mention 426 at all.
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("\(gate)"))
                #expect(message.contains(SteleCLI.installCommand))
            }
        }
    }

    // MARK: - Wiring

    /// Non-vacuity for every assertion below: if the live minimum ever dropped to the
    /// bottom of the range, `outdated` would stop being outdated and each `426` expectation
    /// would silently become unreachable.
    @Test func theFixturesOutdatedAgentIsActuallyOutdated() throws {
        let presented = try #require(CLIVersion(parsing: "0.0.1"))
        #expect(presented < minimumCLIVersion)
    }

    @Test(arguments: [true, false])
    func publishFromAnOutdatedClientIs426(update: Bool) async throws {
        let store = InMemoryPageStore()
        await store.seed(slug: try Slug(custom: "amber-willow-heron"), body: "<h1>here</h1>")

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(
                uri: update ? "/\(ServerRoute.pages)/amber-willow-heron" : "/\(ServerRoute.pages)",
                method: update ? .put : .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.publishToken)",
                    .contentType: "text/html",
                    .userAgent: outdated,
                ],
                body: ByteBuffer(string: "<h1>hi</h1>")
            ) { response in
                #expect(response.status == .upgradeRequired)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("\(minimumCLIVersion)"))
            }
        }
    }

    /// The admin routes are gated on the same minimum. The token in a `201` here is shown
    /// exactly once and cannot be reproduced, so a client too old to decode the response is
    /// one that loses a credential rather than one that merely fails.
    @Test func adminFromAnOutdatedClientIs426() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.admin)/\(ServerRoute.adminClients)",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.token)",
                    .contentType: "application/json",
                    .userAgent: outdated,
                ],
                body: ByteBuffer(string: #"{"name":"agent"}"#)
            ) { response in
                #expect(response.status == .upgradeRequired)
            }
        }
    }

    /// Curl has to keep working: it is what this server taught for its whole life before the
    /// CLI existed, and a version gate that rejected unversioned clients would be a far
    /// larger outage than the drift it prevents.
    @Test(arguments: [nil, "curl/8.6.0", "stele-cli/\(CLIVersion(minimumCLIVersion.major + 1, 0, 0))"])
    func anUngatedClientStillPublishes(header: String?) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            var headers: HTTPFields = [
                .authorization: "Bearer \(TestFixture.publishToken)",
                .contentType: "text/html",
            ]
            if let header { headers[.userAgent] = header }

            try await client.execute(
                uri: "/\(ServerRoute.pages)",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "<h1>hi</h1>")
            ) { response in
                #expect(response.status == .created, "\(header ?? "nil")")
            }
        }
    }

    /// Ordering, and the reason the middleware is registered last in its group: an outdated
    /// client with no usable credential is told about the credential. Reinstalling would not
    /// have helped it, and a `426` would spend its one retry on the wrong thing.
    @Test func authenticationIsAnsweredBeforeTheVersion() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)",
                method: .post,
                headers: [.contentType: "text/html", .userAgent: outdated],
                body: ByteBuffer(string: "<h1>hi</h1>")
            ) { response in
                #expect(response.status == .unauthorized)
            }

            // …and a valid credential without the scope for this route likewise: the
            // credential is the thing to fix, not the install.
            try await client.execute(
                uri: "/\(ServerRoute.pages)",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.token)",
                    .contentType: "text/html",
                    .userAgent: outdated,
                ],
                body: ByteBuffer(string: "<h1>hi</h1>")
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// Reads are not gated at all. The version check lives in the write groups, and an
    /// outdated client — or a browser, which is every reader — must still be able to fetch a
    /// page, the stylesheet and the skill that tells it how to upgrade.
    @Test(arguments: ["/amber-willow-heron", Stylesheet.path, PublishSkill.path])
    func readsAreNeverGated(path: String) async throws {
        let store = InMemoryPageStore()
        await store.seed(slug: try Slug(custom: "amber-willow-heron"), body: "<h1>here</h1>")

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(
                uri: path, method: .get, headers: [.userAgent: outdated]
            ) { response in
                #expect(response.status == .ok, "\(path)")
            }
        }
    }
}
