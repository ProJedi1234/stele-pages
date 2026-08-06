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

    /// Every type this server accepts gets a badge in the landing page's index, except HTML,
    /// which gets none because it is what a page is by default.
    ///
    /// Driven off `PageContentType.allowed` rather than a list of the types that exist today,
    /// which is the whole reason `label(for:)` derives its answer from the subtype instead of
    /// looking it up in a second table. A table would let a newly allowed type render a badge
    /// with nothing in it, and nothing would fail. Adding one here fails this instead — and
    /// passes the moment the derivation covers it.
    @Test func everyAcceptedTypeHasABadgeExceptHTML() {
        for stored in PageContentType.allowed.values {
            let label = PageContentType.label(for: stored)
            if stored == PageContentType.default {
                #expect(label == nil, "HTML is the default and needs no badge")
            } else {
                #expect(label?.isEmpty == false, "no badge for \(stored)")
                // Uppercase, so a badge cannot arrive looking like prose.
                #expect(label == label?.uppercased())
            }
        }
        // The parameter is a *stored* type, which always carries a charset. Reading the label
        // off the full header rather than a pre-split subtype is what makes that safe.
        #expect(PageContentType.label(for: "text/css; charset=utf-8") == "CSS")
        #expect(PageContentType.label(for: "text/html; charset=utf-8") == nil)
    }
}
