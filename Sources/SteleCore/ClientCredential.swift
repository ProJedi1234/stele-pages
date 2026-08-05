import Crypto
import Foundation

/// Minting and hashing the tokens clients authenticate with.
///
/// Both operations are pure functions over their input — `generate(using:)` takes its
/// randomness as a parameter and `hash(_:)` is a plain digest — so the format and the
/// storage form are testable without a database, a server, or a mocked clock.
public enum ClientCredential {
    /// Marks the string as a stele credential wherever it turns up: a secret scanner can
    /// match on it, and a token pasted into a log line or an issue is recognisable as
    /// something to revoke rather than as an opaque blob.
    public static let prefix = "stele_pat_"

    /// 256 bits of randomness. This is the *only* thing standing between an attacker and
    /// a valid token — see `hash(_:)` for why that is enough on its own.
    public static let secretByteCount = 32

    /// Mints a fresh credential from the system CSPRNG.
    ///
    /// The returned string is the only time the token exists in plaintext anywhere in
    /// this process; the database stores `hash(_:)` of it and nothing else, so a caller
    /// that fails to hand it to the operator has lost it for good.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    /// Seedable variant, so tests can assert on exact output.
    public static func generate<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let secret = (0..<secretByteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
        return token(secret: secret)
    }

    /// The wire format: the prefix followed by base64url of the raw secret.
    ///
    /// base64url rather than plain base64 because the token travels in an
    /// `Authorization` header and gets pasted into shells and JSON — `+`, `/` and `=`
    /// all have a second meaning in at least one of those, and none of them survive a
    /// careless copy reliably.
    public static func token(secret: [UInt8]) -> String {
        prefix + base64URLEncoded(secret)
    }

    /// The value stored in `clients.token_hash`, and the value a presented token is
    /// looked up by.
    ///
    /// Plain SHA-256, deliberately not bcrypt or Argon2. Those exist to make brute force
    /// expensive against low-entropy human passwords; there is nothing to brute-force in
    /// 256 bits of CSPRNG output, and a slow hash on the read path would only make every
    /// authenticated request slower. Lookup is by hash on a unique index, so the
    /// presented token is never compared byte-by-byte and there is no timing oracle here
    /// to close.
    ///
    /// The digest covers the *entire* presented string, prefix included. Hashing a
    /// stripped form would create two spellings of the same credential and a chance for
    /// the minting side and the checking side to disagree about which one is canonical.
    public static func hash(_ token: String) -> [UInt8] {
        Array(SHA256.hash(data: Array(token.utf8)))
    }

    /// RFC 4648 §5 without padding, spelled out rather than pulled in: Foundation emits
    /// standard base64, and the three substitutions below are the whole difference.
    static func base64URLEncoded(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
