import Testing

@testable import SteleCore

/// The shared policy in `GitHubIdentifying`'s extension, exercised directly rather than
/// through a route.
///
/// The route arrives in a later commit and will assert the same collapse from outside, on the
/// bytes of the response. This suite is the other half of that and is not made redundant by
/// it: what a caller can observe is one `401`, so an HTTP test can only ever prove that four
/// paths *look* alike. Here the four paths are named individually and each is pinned to nil,
/// which is what makes a later edit that reintroduces a distinction fail with a message
/// saying which distinction came back.
///
/// The nil-versus-throw contract is the reason the last test exists. Every other refusal is a
/// nil; only "GitHub could not be asked" throws, and a conformer that collapsed the two would
/// tell a legitimate owner during a GitHub outage that their sign-in was refused.
@Suite("GitHub identity policy")
struct GitHubIdentifyingTests {
    static let owner = "Octocat"
    static let ownerToken = "gho_owner"
    static let stranger = "hubot"
    static let strangerToken = "gho_stranger"

    static let github = InMemoryGitHub([ownerToken: owner, strangerToken: stranger])

    /// A GitHub that is reachable for nobody, standing in for an outage. File-private to this
    /// suite because its only job is to throw.
    private struct UnreachableGitHub: GitHubIdentifying {
        struct Unreachable: Error {}
        func login(forAccessToken token: String) async throws -> String? { throw Unreachable() }
        func requestDeviceCode() async throws -> GitHubDeviceCode? { throw Unreachable() }
        func redeemDeviceCode(_ deviceCode: String) async throws -> GitHubDeviceRedemption {
            throw Unreachable()
        }
    }

    /// The one accepting path, and it pins the *casing* as well as the acceptance. What comes
    /// back is the login GitHub reports rather than the folded spelling the allowlist matched
    /// on — the credential minted from it is named after the fold, so a policy that returned
    /// its own lowercased copy would pass every test that never looked and lose the only
    /// human-readable record of which account signed in.
    @Test func anAllowlistedOwnerIsIdentifiedInGitHubsCasing() async throws {
        let allowlist = GitHubOwnerAllowlist(parsing: "octocat")
        let login = try await Self.github.owner(presenting: Self.ownerToken, allowedBy: allowlist)
        #expect(login == Self.owner)
    }

    /// A real account that is simply not an owner here. The single most important nil in this
    /// file: distinguishing it from the one below would make the exchange route an oracle for
    /// who owns the deployment, walkable by anyone holding a GitHub token of their own.
    @Test func aRealAccountThatIsNotAnOwnerIsRefused() async throws {
        let allowlist = GitHubOwnerAllowlist(parsing: "octocat")
        let login = try await Self.github.owner(
            presenting: Self.strangerToken, allowedBy: allowlist
        )
        #expect(login == nil)
    }

    /// A token GitHub does not recognise — the fake answers nil for anything it was not
    /// given, which is what the live conformer does for a `401`.
    @Test func aTokenGitHubDoesNotRecogniseIsRefused() async throws {
        let allowlist = GitHubOwnerAllowlist(parsing: "octocat")
        let login = try await Self.github.owner(presenting: "gho_junk", allowedBy: allowlist)
        #expect(login == nil)
    }

    /// Fail-closed, seen from inside the policy: an owner GitHub vouches for, against a
    /// deployment that named nobody. There is no branch for this case anywhere — `permits(_:)`
    /// refuses everything when the allowlist is empty, so an unconfigured deployment falls out
    /// of the same guard a stranger does. A `guard allowlist.isEmpty` added "for clarity" at
    /// any call site is what this test exists to make unnecessary.
    @Test func anEmptyAllowlistRefusesAnAccountGitHubVouchesFor() async throws {
        for raw in [nil, "", "   ", ",,"] as [String?] {
            let login = try await Self.github.owner(
                presenting: Self.ownerToken, allowedBy: GitHubOwnerAllowlist(parsing: raw)
            )
            #expect(login == nil, "an allowlist parsed from \(String(describing: raw)) permitted someone")
        }
    }

    /// A token carrying bytes no `Authorization` header can hold is refused on this side of
    /// the seam, before any conformer is asked.
    ///
    /// Asserted against `UnreachableGitHub`, which is the only way to state the claim: if the
    /// guard were removed, the conformer would be reached and this would *throw* rather than
    /// return nil. So a nil here proves the primitive was never called. That matters because
    /// the throw would surface as a `500` — the one status reserved for a GitHub outage —
    /// manufactured on demand by an unauthenticated caller sending one newline.
    @Test func aTokenThatCouldNotBePresentedIsRefusedWithoutAskingGitHub() async throws {
        let allowlist = GitHubOwnerAllowlist(parsing: "octocat")
        for unusable in ["", "gho_x\ny", "gho_x y", "gho_x\u{0}y"] {
            let login = try await UnreachableGitHub().owner(
                presenting: unusable, allowedBy: allowlist
            )
            #expect(login == nil, "\(unusable.debugDescription) reached the conformer")
        }
    }

    /// The counterweight to every test above: being unable to ask is not a refusal. This is
    /// the distinction the whole seam is shaped around, and the simplification that erases it
    /// — catching the error and returning nil, so that "the caller gets one answer" — is what
    /// turns a GitHub outage into a page of owners being told their accounts were rejected.
    @Test func gitHubBeingUnreachableThrowsRatherThanRefusing() async throws {
        let allowlist = GitHubOwnerAllowlist(parsing: "octocat")
        await #expect(throws: UnreachableGitHub.Unreachable.self) {
            _ = try await UnreachableGitHub().owner(
                presenting: Self.ownerToken, allowedBy: allowlist
            )
        }
    }

    // MARK: - The device flow's policy

    static let ownerCode = "device-owner"
    static let strangerCode = "device-stranger"
    static let pendingCode = "device-pending"
    static let deadCode = "device-dead"

    /// A GitHub that has issued four device codes: one an owner authorised, one a stranger
    /// authorised, one nobody has got to yet, and one that will never be redeemed. Anything
    /// else is `.refused`, which is what the live conformer answers `incorrect_device_code`
    /// with.
    static let devices = InMemoryGitHub(
        [ownerToken: owner, strangerToken: stranger],
        redeeming: [
            ownerCode: .token(ownerToken),
            strangerCode: .token(strangerToken),
            pendingCode: .pending(retryAfterSeconds: 5),
            deadCode: .refused,
        ]
    )

    /// The accepting path, and it pins the same casing the token path does. The login that
    /// comes back is GitHub's spelling, because the credential minted downstream is named
    /// after it and a policy returning its own folded copy would lose the only human-readable
    /// record of which account signed in.
    @Test func anAuthorisedCodeFromAnOwnerIdentifiesThemInGitHubsCasing() async throws {
        let allowlist = GitHubOwnerAllowlist(parsing: "octocat")
        let outcome = try await Self.devices.owner(
            redeeming: Self.ownerCode, allowedBy: allowlist
        )
        #expect(outcome == .identified(login: Self.owner))
    }

    /// Waiting is not refusing, and it is the one answer that must survive the collapse
    /// everything else falls into. This is the normal state of the flow for as long as
    /// somebody takes to type a code into a browser; a nil here would end a sign-in seconds
    /// after it began, and the interval is what the client is told to wait.
    @Test func anUnauthorisedCodeIsStillPendingRatherThanRefused() async throws {
        let allowlist = GitHubOwnerAllowlist(parsing: "octocat")
        let outcome = try await Self.devices.owner(
            redeeming: Self.pendingCode, allowedBy: allowlist
        )
        #expect(outcome == .pending(retryAfterSeconds: 5))
    }

    /// GitHub's `slow_down` is the pending case with a bigger number and nothing else. It is
    /// asserted here rather than only in the transport because the shape is what matters: the
    /// day this becomes a case of its own is the day a route grows a branch for it.
    @Test func slowingDownIsAPendingWithABiggerNumber() async throws {
        let allowlist = GitHubOwnerAllowlist(parsing: "octocat")
        let slowed = InMemoryGitHub(redeeming: ["slowed": .pending(retryAfterSeconds: 10)])
        let outcome = try await slowed.owner(redeeming: "slowed", allowedBy: allowlist)
        #expect(outcome == .pending(retryAfterSeconds: 10))
    }

    /// Four terminal refusals, one nil, and this is the whole security argument of the flow
    /// stated where it can be read: a dead code, a code GitHub never issued, a real account
    /// that is not an owner here, and a deployment that named nobody. The route sees one
    /// shape for all four and so cannot report which — the same collapse the token path
    /// makes, over a wider set of facts.
    @Test func everyTerminalRefusalIsTheSameNil() async throws {
        let allowlist = GitHubOwnerAllowlist(parsing: "octocat")
        let unconfigured = GitHubOwnerAllowlist(parsing: nil)
        for (code, list) in [
            (Self.deadCode, allowlist),
            ("device-never-issued", allowlist),
            (Self.strangerCode, allowlist),
            (Self.ownerCode, unconfigured),
        ] {
            let outcome = try await Self.devices.owner(redeeming: code, allowedBy: list)
            #expect(outcome == nil, "\(code) was not refused")
        }
    }

    /// A device code with no client ID behind it refuses rather than failing, and the fake
    /// with nothing scripted is exactly that deployment. It matters that this is the *same*
    /// nil as above: an unconfigured deployment answering differently would let a prober tell
    /// "not set up here" from "set up and not for you".
    @Test func aDeploymentWithNoClientIDRefusesRatherThanFailing() async throws {
        let allowlist = GitHubOwnerAllowlist(parsing: "octocat")
        let unconfigured = InMemoryGitHub()
        #expect(try await unconfigured.requestDeviceCode() == nil)
        #expect(try await unconfigured.owner(redeeming: "anything", allowedBy: allowlist) == nil)
    }

    /// The device code's counterpart to the token guard, asserted against a conformer that
    /// throws so that a nil proves the primitive was never reached. The stakes are lower here
    /// — a device code travels in a form body, so nothing downstream throws on a byte it
    /// dislikes — but the shape of the claim is the same and the round trip saved is real.
    @Test func aDeviceCodeThatCouldNotBePresentedIsRefusedWithoutAskingGitHub() async throws {
        let allowlist = GitHubOwnerAllowlist(parsing: "octocat")
        for unusable in ["", "code\ny", "code y", "code\u{0}y"] {
            let outcome = try await UnreachableGitHub().owner(
                redeeming: unusable, allowedBy: allowlist
            )
            #expect(outcome == nil, "\(unusable.debugDescription) reached the conformer")
        }
    }

    /// The counterweight, once more: being unable to ask is not a refusal. A poll that
    /// swallowed the outage would report `.refused` to a CLI polling a code that is perfectly
    /// valid, and the person would be told their sign-in was cancelled by a GitHub that was
    /// merely down.
    @Test func gitHubBeingUnreachableDuringAPollThrowsRatherThanRefusing() async throws {
        let allowlist = GitHubOwnerAllowlist(parsing: "octocat")
        await #expect(throws: UnreachableGitHub.Unreachable.self) {
            _ = try await UnreachableGitHub().owner(
                redeeming: Self.ownerCode, allowedBy: allowlist
            )
        }
    }

    /// The same claim for the start of the flow. A conformer that could not reach GitHub must
    /// not answer nil, because nil is what an unconfigured deployment says and the route turns
    /// it into a refusal — so an outage would arrive as "this deployment does not do GitHub
    /// sign-in", which is a lie with a long tail.
    @Test func gitHubBeingUnreachableAtTheStartThrowsRatherThanReturningNil() async throws {
        await #expect(throws: UnreachableGitHub.Unreachable.self) {
            _ = try await UnreachableGitHub().requestDeviceCode()
        }
    }
}
