import Hummingbird

/// Guards write routes with a shared bearer token.
///
/// Reads are intentionally left open — the whole point is that anyone with the link
/// can see the page. Only publishing is gated.
public struct BearerTokenMiddleware<Context: RequestContext>: RouterMiddleware {
    private let token: String

    public init(token: String) {
        self.token = token
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let header = request.headers[.authorization] else {
            throw HTTPError(.unauthorized, message: "Missing Authorization header.")
        }
        // RFC 7235 allows any run of spaces between the scheme and the credential
        // (`auth-scheme 1*SP token68`), so trim rather than split on the first space.
        let presented = header.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        guard header.lowercased().hasPrefix("bearer "),
              constantTimeEquals(presented, token)
        else {
            throw HTTPError(.unauthorized, message: "Invalid upload token.")
        }
        return try await next(request, context)
    }
}

/// Compares two strings without an early exit on the first differing byte.
///
/// A plain `==` returns as soon as it finds a mismatch, so response latency reveals how
/// many leading bytes were correct — enough to recover a token one byte at a time.
/// Length is still observable, which is fine: the token length isn't the secret.
func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    guard lhsBytes.count == rhsBytes.count else { return false }

    var difference: UInt8 = 0
    for index in lhsBytes.indices {
        difference |= lhsBytes[index] ^ rhsBytes[index]
    }
    return difference == 0
}
