import Hummingbird

/// Requires that the authenticated credential carries a particular scope.
///
/// Sits *after* `BearerTokenMiddleware` in a group and reads what that middleware wrote,
/// rather than re-deriving anything from the header: authentication answers "who is this?"
/// exactly once, and this answers "may they?".
///
/// A middleware rather than a `guard` at the top of each handler, because the failure mode
/// of the guard version is silence. A route added without its check compiles, passes its
/// own tests, and is simply open — whereas a route added to a group inherits the group's
/// middleware and cannot be registered without it.
public struct RequireScopeMiddleware: RouterMiddleware {
    /// Concrete for the same reason `BearerTokenMiddleware`'s is: it reads `client` off the
    /// context, and there is exactly one context type in this server that has one.
    public typealias Context = SteleRequestContext

    private let scope: ClientScope

    public init(_ scope: ClientScope) {
        self.scope = scope
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let client = context.client else {
            // Only reachable if this middleware is registered without an authenticating
            // one in front of it, which is a wiring mistake rather than a caller's. Fail
            // closed, and say so in the log where it can be found — the 401 on its own
            // would look like an ordinary missing header.
            context.logger.error(
                "scope check ran with no authenticated client; check the middleware order",
                metadata: ["scope": "\(scope.rawValue)"]
            )
            throw HTTPError(.unauthorized, message: "Missing Authorization header.")
        }

        guard client.has(scope) else {
            // 403, not 401. The credential is valid and the caller is behind the token, so
            // the README's rule about indistinguishable failures does not reach here:
            // there is no namespace left to leak, and answering 401 would send an operator
            // to rotate a credential that is working exactly as issued. The message names
            // both sides because the caller already knows both — it is their credential.
            throw HTTPError(
                .forbidden,
                message: """
                    This credential is not permitted here: the route requires the \
                    '\(scope.rawValue)' scope and this credential carries \
                    \(client.scopes.isEmpty ? "none" : client.scopes.sorted().joined(separator: ", ")).
                    """
            )
        }

        return try await next(request, context)
    }
}
