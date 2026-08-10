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
}
