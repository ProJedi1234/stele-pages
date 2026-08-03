import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// The one fixture every HTTP-level suite builds its application from, so the boundary
/// values it pins — the token length, the base URL, the parse-only database URL — are
/// asserted in exactly one place instead of drifting per file.
enum TestFixture {
    /// Exactly the minimum accepted token length, so the fixture pins that boundary
    /// rather than drifting past it.
    static let token = String(repeating: "t", count: 16)

    /// A base URL that could not be a default, so an assertion on it proves the
    /// configured value reached the response rather than a hard-coded one.
    static let baseURL = "https://stele.example"

    /// The smallest environment that builds a `Configuration`. The `DATABASE_URL` only
    /// has to parse — nothing here constructs a `PostgresClient`, which only
    /// `buildApplication` does. `environment` lets a single test vary one setting (the
    /// byte limit) without a second fixture that could drift from this one.
    static func configuration(environment extra: [String: String] = [:]) throws -> Configuration {
        var environment = [
            "STELE_UPLOAD_TOKEN": token,
            "DATABASE_URL": "postgres://stele:secret@localhost:5432/stele",
            "STELE_BASE_URL": baseURL,
        ]
        for (key, value) in extra { environment[key] = value }
        return try Configuration(environment: environment)
    }

    /// Each test gets its own application and its own fake — swift-testing runs tests in
    /// parallel, so nothing is shared.
    static func makeApp(
        store: InMemoryPageStore = InMemoryPageStore(),
        environment: [String: String] = [:]
    ) throws -> Application<RouterResponder<BasicRequestContext>> {
        Application(router: buildRouter(
            configuration: try configuration(environment: environment),
            store: store
        ))
    }

    /// Pulls the message out of Hummingbird's JSON error envelope.
    ///
    /// Read as JSON rather than substring-matched on the raw body: the encoder escapes
    /// slashes, so the wire bytes can read `text\/html` and a plain `contains` would miss.
    static func errorMessage(_ body: ByteBuffer) throws -> String {
        let payload = try JSONSerialization.jsonObject(with: Data(buffer: body))
        return try #require((payload as? [String: [String: String]])?["error"]?["message"])
    }
}
