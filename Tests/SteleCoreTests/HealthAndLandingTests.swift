import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// The two routes that answer without touching the store: the health probe and the
/// landing page. Both run through `buildRouter` in `.router` mode, so there is no socket
/// and no database — only the routing, the status, and the headers we promise.
@Suite("Health and landing")
struct HealthAndLandingTests {
    @Test func healthzReturnsOK() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(ServerRoute.healthz)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "ok")
            }
        }
    }

    /// The landing page interpolates the configured base URL into its curl example, so
    /// this pins that flow-through as well as the content type. It deliberately does not
    /// carry `nosniff`: that header is for stored pages, whose bodies we didn't write.
    @Test func landingPageIsHTML() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/html; charset=utf-8")
                #expect(String(buffer: response.body)
                    .contains("\(TestFixture.baseURL)/\(ServerRoute.pages)"))
                #expect(response.headers[.xContentTypeOptions] == nil)
            }
        }
    }
}
