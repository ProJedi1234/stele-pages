@testable import SteleCore

/// An in-memory `GitHubIdentifying`, mirroring `InMemoryClientStore`.
///
/// It implements the seam's primitives and nothing else, which is the point: the collapse
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

    /// The bundle `requestDeviceCode()` answers with, or nil for a deployment that has no
    /// client ID.
    ///
    /// nil is the default for the same reason the empty `logins` is: a suite that has not
    /// arranged a GitHub identity should get the posture of a deployment nobody has
    /// configured, which refuses. Handing out a plausible-looking bundle by default would
    /// make the start route's fail-closed test the only one exercising the refusal.
    let deviceCode: GitHubDeviceCode?

    /// Device code → what GitHub says when it is redeemed.
    ///
    /// A dictionary rather than a single scripted answer because a poll is asked more than
    /// once and the interesting arrangements are per-code: this code is pending, that one
    /// expired, this other one belongs to a stranger. A code that was never scripted is
    /// `.refused`, which is what GitHub says about a code it never issued.
    let redemptions: [String: GitHubDeviceRedemption]

    init(
        _ logins: [String: String] = [:],
        issuing deviceCode: GitHubDeviceCode? = nil,
        redeeming redemptions: [String: GitHubDeviceRedemption] = [:]
    ) {
        self.logins = logins
        self.deviceCode = deviceCode
        self.redemptions = redemptions
    }

    func login(forAccessToken token: String) async throws -> String? {
        logins[token]
    }

    func requestDeviceCode() async throws -> GitHubDeviceCode? {
        deviceCode
    }

    func redeemDeviceCode(_ deviceCode: String) async throws -> GitHubDeviceRedemption {
        redemptions[deviceCode] ?? .refused
    }
}
