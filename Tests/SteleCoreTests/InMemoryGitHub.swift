@testable import SteleCore

/// An in-memory `GitHubIdentifying`, mirroring `InMemoryClientStore`.
///
/// It implements the seam's one primitive and nothing else, which is the point: the collapse
/// the exchange tests exercise — GitHub's refusal, a non-owner and an empty allowlist all
/// arriving as one nil — is the real shared policy in `GitHubIdentifying`'s extension rather
/// than a reimplementation here that could quietly reach a different verdict.
///
/// A struct rather than an actor, unlike the store fakes: nothing mutates after `init`, so
/// there is no state for isolation to protect and no `await` for the tests to thread through
/// their arrangements.
///
/// The empty instance identifies no token at all, and that is the right default for every
/// suite that does not care: an app built without arranging a GitHub identity refuses every
/// exchange, which is also the posture a real deployment has before anyone signs in.
struct InMemoryGitHub: GitHubIdentifying {
    /// Access token → the login GitHub reports for it, in GitHub's canonical casing.
    ///
    /// Canonical casing matters in the tests that use this: the allowlist folds case and the
    /// credential name is lowercased, so a fake that only ever answered in lowercase would
    /// make both of those assertions pass without exercising anything.
    let logins: [String: String]

    init(_ logins: [String: String] = [:]) {
        self.logins = logins
    }

    func login(forAccessToken token: String) async throws -> String? {
        logins[token]
    }
}
