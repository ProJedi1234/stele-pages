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
///
/// `verdict(forOAuthError:)` is the same job on the device flow's half of the file and is
/// pinned here for the same reason, with one thing extra to defend. GitHub reports a
/// device-code failure inside a `200`, so the status code says nothing at all there and this
/// string is the only evidence — and it carries three quite different kinds of news at once:
/// wait, no, and *the deployment is misconfigured*. The third is the one with no analogue on
/// the status side and the one a tidy-up flattens.
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

    /// The two strings that mean "not yet", and they must mean the same thing. `slow_down`
    /// is GitHub complaining about the polling rate, not about the sign-in; a conformer that
    /// made it a refusal would end a sign-in the person is halfway through, and the person
    /// would see a failure caused entirely by their client polling too eagerly. The interval
    /// that distinguishes the two rides in the response body, deliberately not here — this
    /// function classifies, it does not count.
    @Test(arguments: ["authorization_pending", "slow_down"])
    func waitingIsNotFailing(error: String) {
        #expect(GitHubAPI.verdict(forOAuthError: error) == .pending)
    }

    /// The three ways a device code dies. All one verdict, because the route answers all of
    /// them with one 401: "you took too long", "you said no" and "there is no such code" are
    /// three facts a stranger polling codes they did not obtain would happily read off the
    /// difference between.
    @Test(arguments: ["expired_token", "access_denied", "incorrect_device_code"])
    func aDeadDeviceCodeIsRefusedWhicheverWayItDied(error: String) {
        #expect(GitHubAPI.verdict(forOAuthError: error) == .refused)
    }

    /// The narrowing that matters on this side, and the exact analogue of `403` above.
    /// `unsupported_grant_type` is a wrong URN in this repository's own request,
    /// `incorrect_client_credentials` is a `STELE_GITHUB_CLIENT_ID` GitHub does not know, and
    /// `device_flow_disabled` is an OAuth app with the box unticked. Not one of them is a
    /// judgement on the person signing in, and not one of them clears by trying again — so a
    /// refusal here would tell every owner in turn that their account was rejected while the
    /// single fault that could be fixed left no trace anywhere.
    @Test(arguments: [
        "unsupported_grant_type", "incorrect_client_credentials", "device_flow_disabled",
    ])
    func aMisconfiguredDeploymentIsNotARefusedUser(error: String) {
        #expect(GitHubAPI.verdict(forOAuthError: error) == .unavailable)
        #expect(GitHubAPI.verdict(forOAuthError: error) != .refused)
    }

    /// The default arm, and the one most likely to be "simplified" into `.refused` on the
    /// grounds that anything that is not a success is a failure. A string this server has
    /// never been taught to read is GitHub doing something new, so the honest answer is that
    /// the question could not be answered — never that the caller was refused. The empty
    /// string and a near-miss spelling are in here because both are what a wire-format change
    /// or a typo actually looks like.
    @Test(arguments: ["", "AUTHORIZATION_PENDING", "authorization pending", "rate_limited", "nope"])
    func anUnrecognisedErrorIsGitHubBehavingUnexpectedly(error: String) {
        #expect(GitHubAPI.verdict(forOAuthError: error) == .unavailable)
        #expect(GitHubAPI.verdict(forOAuthError: error) != .refused)
        #expect(GitHubAPI.verdict(forOAuthError: error) != .pending)
    }
}
