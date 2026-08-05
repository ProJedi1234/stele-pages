import Hummingbird

/// The per-request metadata container this server's routes are generic over.
///
/// Hummingbird makes the context a type parameter rather than a global request type with
/// extensions hung off it, so carrying anything of our own means declaring it here and
/// making the router generic over it. The whole cost is this struct plus one annotation in
/// the test fixture: the handlers only ever reach for `logger` and `parameters`, both of
/// which come from `coreContext` and compile unchanged against any conforming type.
///
/// It exists for `client`. Authentication resolves a credential once, in
/// `BearerTokenMiddleware`, and everything downstream — the scope checks, and eventually
/// the `pages.client_id` attribution the schema already has a column for — reads it from
/// here rather than re-deriving it from the header. A second place that turned a token
/// into a decision is a second place that could disagree about what the token means.
public struct SteleRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage

    /// The authenticated credential, or nil on an unauthenticated route.
    ///
    /// Set only by `BearerTokenMiddleware`, and only after the credential has been checked
    /// — so a handler behind that middleware may read it as "this request is authorised",
    /// while a handler outside it must not treat nil as anything but "nobody asked".
    ///
    /// The token is deliberately not here. `Client` carries the digest's *row*, never the
    /// secret, so nothing on the context could be logged or echoed into a response and
    /// leak a credential.
    public var client: Client?

    public init(source: Source) {
        self.coreContext = .init(source: source)
    }
}
