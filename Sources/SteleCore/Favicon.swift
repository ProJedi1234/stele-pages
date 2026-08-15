import Foundation

/// The site icon, served at `GET /assets/favicon.png` and at `GET /favicon.ico`.
///
/// Base64 in a Swift file for the reason `Stylesheet` is a Swift string: the Dockerfile's
/// runtime stage copies only the executable, and a SwiftPM resource bundle is a sibling
/// directory that `--static-swift-stdlib` does not embed — so `Bundle.module` would pass
/// `swift test` here and 404 in production. Bytes rather than an inline SVG because what
/// arrived is a raster — the artwork may have been drawn as vectors, but no vector original
/// reached this repository, and hand-tracing one would be a second copy that drifts.
///
/// 64x64: a tab renders it at 16 or 32 CSS pixels, so 64 covers 2x displays with the
/// downscale left to the browser, and one size costs less than a set nothing measures.
enum Favicon {
    static let fileName = "favicon.png"

    /// Built from `ServerRoute.assets` so the route registration and the `<link rel="icon">`
    /// on every built-in page come from one string, the way `Stylesheet.path` is.
    static let path = "/\(ServerRoute.assets)/\(fileName)"

    static let contentType = "image/png"

    /// Decoded once, and to empty rather than trapping on a `!`. A static `let` is lazy, so
    /// a force-unwrap here would run inside the first request that asked for the icon and
    /// take the process with it — a site icon is not worth a crash. `FaviconTests` pins the
    /// signature and the byte count, so a corrupted literal fails the build instead.
    static let bytes: [UInt8] = Array(
        Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) ?? Data()
    )

    static let etag: String = strongETag(over: bytes)

    /// Wrapped, which is why the decode ignores unknown characters: the newlines and the
    /// leading indentation of this literal are not base64 and must not be.
    private static let encoded = """
        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
        """
}
