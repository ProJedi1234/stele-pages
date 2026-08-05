import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// HTTP-level tests for the `Content-Type` allowlist on `POST /pages`.
///
/// The allowlist is what keeps this a page server rather than a way to serve arbitrary
/// bytes under someone else's `Content-Type`, so these tests cover all three outcomes:
/// rejected, absent-and-defaulted, and accepted-but-normalised.
@Suite("Upload content types")
struct UploadContentTypeTests {
    /// Posts a page and returns the slug it landed on.
    static func upload(
        client: some TestClientProtocol,
        headers: HTTPFields,
        body: String
    ) async throws -> String {
        var headers = headers
        headers[.authorization] = "Bearer \(TestFixture.publishToken)"
        return try await client.execute(
            uri: "/pages",
            method: .post,
            headers: headers,
            body: ByteBuffer(string: body)
        ) { response -> String in
            #expect(response.status == .created)
            let payload = try TestFixture.writeResponse(response.body)
            return try #require(payload["slug"] as? String)
        }
    }

    /// A type outside the allowlist is refused, and the refusal names what would work —
    /// the message is the only documentation the caller gets at the terminal.
    @Test func uploadWithDisallowedContentTypeIs415() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.publishToken)",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"hello":"world"}"#)
            ) { response in
                #expect(response.status == .unsupportedMediaType)
                let message = try TestFixture.errorMessage(response.body)
                for allowed in PageContentType.allowed.keys {
                    #expect(message.contains(allowed))
                }
            }
        }
    }

    /// `curl --data-binary` without an explicit header is the common case, and it should
    /// publish HTML rather than fail.
    @Test func uploadWithoutContentTypeDefaultsToHTML() async throws {
        let uploaded = "<h1>no content type</h1>"

        try await TestFixture.makeApp().test(.router) { client in
            let slug = try await Self.upload(client: client, headers: [:], body: uploaded)

            try await client.execute(uri: "/\(slug)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == uploaded)
                #expect(response.headers[.contentType] == PageContentType.default)
                #expect(response.headers[.xContentTypeOptions] == "nosniff")
            }
        }
    }

    /// The stored type is the canonical form of the allowlisted base type, not whatever
    /// the client attached: parameters are dropped, case and whitespace are forgiven,
    /// and a bare type gains its charset. One argument pair per normalisation rule,
    /// covering every allowlisted type.
    @Test(arguments: [
        ("text/plain; charset=latin1", "text/plain; charset=utf-8"),
        ("TEXT/HTML", "text/html; charset=utf-8"),
        (" text/css ; media=screen", "text/css; charset=utf-8"),
        ("text/markdown", "text/markdown; charset=utf-8"),
    ])
    func contentTypeIsNormalized(uploadedType: String, servedType: String) async throws {
        let uploaded = "page body"

        try await TestFixture.makeApp().test(.router) { client in
            let slug = try await Self.upload(
                client: client,
                headers: [.contentType: uploadedType],
                body: uploaded
            )

            try await client.execute(uri: "/\(slug)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == uploaded)
                #expect(response.headers[.contentType] == servedType)
                #expect(response.headers[.xContentTypeOptions] == "nosniff")
            }
        }
    }
}
