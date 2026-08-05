import Foundation
import Testing

@testable import SteleCore

/// The credential format and its storage form, both of which are pure functions and
/// neither of which any other test would notice going wrong: a token with the wrong
/// entropy still authenticates, and a hash that changed shape still round-trips within a
/// single build.
@Suite("Client credentials")
struct ClientCredentialTests {
    @Test func tokensCarryThePrefixAndThirtyTwoBytesOfSecret() throws {
        let token = ClientCredential.generate()
        #expect(token.hasPrefix(ClientCredential.prefix))

        // Decoded rather than counted in characters: base64 of 32 bytes is 43 unpadded
        // characters, and asserting on 43 would pass just as happily for a secret that
        // was truncated and re-encoded.
        let encoded = String(token.dropFirst(ClientCredential.prefix.count))
        let standard = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .padding(
                toLength: (encoded.count + 3) / 4 * 4, withPad: "=", startingAt: 0
            )
        let secret = try #require(Data(base64Encoded: standard))
        #expect(secret.count == ClientCredential.secretByteCount)
    }

    /// The three characters standard base64 has and base64url does not. Each of them has
    /// a second meaning in a shell, a URL or a JSON string, which is the whole reason for
    /// the alphabet swap.
    @Test func tokensAreUrlAndShellSafe() {
        for _ in 0..<32 {
            let token = ClientCredential.generate()
            #expect(!token.contains("+"))
            #expect(!token.contains("/"))
            #expect(!token.contains("="))
        }
    }

    /// The substitution table itself, on a vector chosen to exercise it: these three
    /// bytes encode to `+/8=` in standard base64, so every one of the three replacements
    /// fires exactly once.
    @Test func base64UrlSubstitutesTheWholeAlphabet() {
        #expect(Data([0xFB, 0xFF, 0x00]).base64EncodedString() == "+/8A")
        #expect(ClientCredential.base64URLEncoded([0xFB, 0xFF, 0x00]) == "-_8A")
        #expect(ClientCredential.base64URLEncoded([0x00]) == "AA")
    }

    /// Two draws must not collide. A generator that returned a constant — or drew from a
    /// seeded default — would satisfy every other test in this suite.
    @Test func everyDrawDiffers() {
        let tokens = Set((0..<64).map { _ in ClientCredential.generate() })
        #expect(tokens.count == 64)
    }

    /// The randomness is a parameter, which is what makes the format testable against a
    /// known secret rather than only against itself.
    @Test func generationTakesItsRandomnessAsAParameter() {
        var generator = FixedRandomNumberGenerator()
        let first = ClientCredential.generate(using: &generator)
        var identicalGenerator = FixedRandomNumberGenerator()
        let second = ClientCredential.generate(using: &identicalGenerator)
        #expect(first == second)
    }

    /// A digest over the whole presented string, prefix included. If the two sides ever
    /// disagreed about whether the prefix is part of the input, every credential would
    /// stop authenticating at once.
    @Test func hashingIsSha256OverTheEntireToken() {
        let hash = ClientCredential.hash("stele_pat_example")
        #expect(hash.count == 32)
        #expect(hash == ClientCredential.hash("stele_pat_example"))
        #expect(hash != ClientCredential.hash("example"))
        #expect(hash != ClientCredential.hash("stele_pat_examplf"))
    }

    /// A published test vector, so the stored form is pinned to SHA-256 itself and not
    /// merely to whatever this build's `hash` happens to compute.
    @Test func hashingMatchesTheKnownSha256Vector() {
        let hex = ClientCredential.hash("abc").map { String(format: "%02x", $0) }.joined()
        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

/// Deterministic randomness for the seeded-generation test. Not a stand-in for the system
/// generator anywhere else — it is the worst possible source of secrets.
private struct FixedRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64 = 0x5354_454C_4501

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
