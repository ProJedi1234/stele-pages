import Hummingbird

/// Turns a silent contract mismatch between this server and an installed `stele` CLI into a
/// loud, self-healing one.
///
/// A client too old to speak the current wire contract otherwise fails somewhere further
/// in — a field it cannot decode, a flag the server no longer honours — and every one of
/// those failures reads as "the server is broken". `426 Upgrade Required` names the actual
/// problem and the one command that fixes it, which is a failure an agent can act on
/// without asking anyone.
///
/// **A request that does not identify itself as the CLI is never rejected.** Curl keeps
/// working, which it has to: it is what the skill taught for the whole life of the server
/// before this, it is what the README's examples still show, and a version gate that broke
/// every unversioned client would be a far larger outage than the drift it prevents. That
/// also means the gate is advisory — anyone can omit the header — so it is a compatibility
/// signal, not a security control, and nothing behind it may assume a minimum client.
///
/// Registered *after* `BearerTokenMiddleware` in a group, so an old client with a bad
/// credential still gets its `401`: reinstalling the CLI would not have helped, and telling
/// it to is how an agent spends its retry on the wrong thing. It also keeps this middleware
/// from answering an unauthenticated prober at all.
public struct MinimumCLIVersionMiddleware: RouterMiddleware {
    /// Concrete for the same reason the other two middlewares' are: one context type exists
    /// in this server, and a generic parameter would only buy a conformer that does not.
    public typealias Context = SteleRequestContext

    private let minimum: CLIVersion

    /// - Parameter minimum: injectable so the tests can gate on a version the fixture can
    ///   sit either side of, rather than depending on where `minimumCLIVersion` happens to
    ///   be today — a test written against the live constant stops testing anything the
    ///   moment that constant is the lowest version there is.
    public init(_ minimum: CLIVersion = minimumCLIVersion) {
        self.minimum = minimum
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        switch SteleCLI.classify(userAgent: request.headers[.userAgent]) {
        case .notTheCLI:
            break
        case .version(let presented) where presented >= minimum:
            break
        case .version(let presented):
            context.logger.info(
                "rejected an outdated client",
                metadata: ["presented": "\(presented)", "minimum": "\(minimum)"]
            )
            throw upgradeRequired(presented: "\(presented)")
        case .unreadableVersion(let presented):
            // A client claiming to be the CLI with a version nobody can read is broken or
            // hand-written, and "reinstall" is the right answer to both. It cannot be waved
            // through as if it were curl: the point of the header is that a client which
            // sends it is asking to be version-checked.
            context.logger.info(
                "rejected a client with an unreadable version",
                metadata: ["presented": "\(presented)", "minimum": "\(minimum)"]
            )
            throw upgradeRequired(presented: presented)
        }

        return try await next(request, context)
    }

    /// The remedy is named in the body rather than left to the skill, because the caller
    /// most likely to see this is an agent that fetched the skill before the deployment
    /// moved — the copy it is holding is precisely the one that may not mention this yet.
    private func upgradeRequired(presented: String) -> HTTPError {
        HTTPError(
            .upgradeRequired,
            message: """
                This deployment requires \(SteleCLI.userAgentProduct) \(minimum) or newer, \
                and you are running \(presented). Run `\(SteleCLI.installCommand)` and \
                retry once.
                """
        )
    }
}
