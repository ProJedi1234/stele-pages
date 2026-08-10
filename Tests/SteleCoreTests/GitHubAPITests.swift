import Testing

@testable import SteleCore

/// The one decision inside `GitHubAPI`, pinned.
///
/// Everything else in that file is transport — a request built, a body collected — and is
/// exercised only by production, which is the bargain the hermetic suite strikes with it.
/// What is *not* transport is which of GitHub's answers count as a verdict on the token and
/// which count as GitHub declining to answer, because that mapping is the entire load-bearing
/// half of `GitHubIdentifying`'s nil-versus-throw contract and `InMemoryGitHub` is a
/// dictionary standing beside it rather than a check on it — the same relationship
/// `InMemoryPageStore.hasExpired` has with `PageStore`'s SQL predicates, and the reason those
/// get a suite of their own.
///
/// Both directions of getting it wrong are silent. Widening `rejected` to everything that is
/// not a `200` turns every GitHub 5xx into "your sign-in was refused" and sends legitimate
/// owners round a re-authentication loop during an outage; narrowing `identity` breaks
/// sign-in outright but at least says so. `verdict(forStatus:)` takes a plain code so this
/// costs no socket and no injected client.
@Suite("GitHub's answers, classified")
struct GitHubAPITests {
    /// `200` is the only answer that carries an identity, and `401` is the only one that is a
    /// judgement on the token: GitHub looked at the credential and refused it.
    @Test func onlyAnOkCarriesAnIdentityAndOnlyA401IsARefusal() {
        #expect(GitHubAPI.verdict(forStatus: 200) == .identity)
        #expect(GitHubAPI.verdict(forStatus: 401) == .rejected)
    }

    /// The narrowing that matters, and the one a tidy-up would undo. `403` is where GitHub
    /// puts its primary rate limit, its secondary limits and a source address that has
    /// offered too many bad credentials — all facts about *this server*, all reachable by an
    /// unauthenticated stranger posting junk tokens at the exchange. Classifying it as a
    /// refusal would hand a legitimate owner holding a perfectly good token a `401`, which
    /// reads as "my account is no longer allowed".
    @Test(arguments: [403, 429, 500, 502, 503, 504, 301, 418])
    func everythingElseIsGitHubDecliningToAnswer(code: UInt) {
        #expect(GitHubAPI.verdict(forStatus: code) == .unavailable)
        #expect(GitHubAPI.verdict(forStatus: code) != .rejected)
    }
}
