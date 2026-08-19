import Foundation
import Testing

@testable import SteleCore

/// `RequestedRange` on its own, without a socket or a store.
///
/// The HTTP suite covers what a caller observes; this covers the arithmetic underneath,
/// and the two do not overlap as much as they look like they do. `parse` now clamps every
/// offset, so no request reaching `resolved` through the router can carry an unbounded one
/// — which means the guard *inside* `resolved` is unreachable from `ServeAttachmentTests`
/// and would sit there untested, and silently stop working, without this file.
@Suite("Requested ranges")
struct RequestedRangeTests {
    /// The shapes a client actually sends, and what each parses to.
    @Test func parsesTheShapesAClientSends() {
        #expect(RequestedRange.parse(nil) == .whole)
        #expect(RequestedRange.parse("bytes=0-1") == .from(0, through: 1))
        #expect(RequestedRange.parse("bytes=4-") == .from(4, through: nil))
        #expect(RequestedRange.parse("bytes=-500") == .suffix(500))
        // Case and surrounding whitespace are not the caller's mistake to pay for.
        #expect(RequestedRange.parse("  BYTES=0-1  ") == .from(0, through: 1))
    }

    /// Everything this server will not satisfy collapses to `.whole`, which is a `200` with
    /// the whole representation rather than a refusal — RFC 9110 §14.2's permission, taken
    /// in the direction that cannot deny a client a resource over a header.
    @Test func anythingNotWorthHonouringBecomesTheWholeRepresentation() {
        for header in [
            "bytes=abc-def", "items=0-1", "bytes=5-2", "bytes=0-1,4-5", "bytes=",
            "bytes=-0", "bytes=-", "bytes=--5", "0-1",
            // Past `Int` entirely: `Int(_:)` returns nil rather than saturating, so these
            // are unreadable rather than enormous, and unreadable means ignored.
            "bytes=0-99999999999999999999999999", "bytes=99999999999999999999999999-",
        ] {
            #expect(RequestedRange.parse(header) == .whole, "\(header)")
        }
    }

    /// Offsets are clamped to what anything downstream can address, and the clamp is
    /// meaning-preserving rather than a refusal.
    ///
    /// `bytes=5-2` is checked here too: the comparison that rejects it has to happen on the
    /// *unclamped* numbers, or two different absurd values would clamp to the same one and a
    /// malformed range would become a satisfiable one.
    @Test func absurdOffsetsAreClampedRatherThanRefused() {
        #expect(
            RequestedRange.parse("bytes=0-\(Int.max)")
                == .from(0, through: RequestedRange.maxAddressableByte)
        )
        #expect(
            RequestedRange.parse("bytes=\(Int.max)-")
                == .from(RequestedRange.maxAddressableByte, through: nil)
        )
        #expect(
            RequestedRange.parse("bytes=-\(Int.max)")
                == .suffix(RequestedRange.maxAddressableByte)
        )
        // Both ends absurd but still inverted, so still malformed.
        #expect(RequestedRange.parse("bytes=\(Int.max)-\(Int.max - 1)") == .whole)
    }

    /// The guard the router can no longer reach: `resolved` handed an unbounded offset
    /// directly.
    ///
    /// Every value here overflows the arithmetic this method used to do — `min($0 + 1, …)`
    /// adds before it clamps — and in Swift that is a trap, not a wrap. A regression makes
    /// this a *crashed test process* rather than a failed expectation, which is the same
    /// shape the bug had in production: one header, and every in-flight request goes with it.
    @Test func resolvingAnUnboundedOffsetDoesNotTrap() {
        #expect(RequestedRange.from(0, through: Int.max).resolved(totalSize: 16) == 0..<16)
        #expect(RequestedRange.from(4, through: Int.max).resolved(totalSize: 16) == 4..<16)
        #expect(RequestedRange.suffix(Int.max).resolved(totalSize: 16) == 0..<16)
        // A start past the end resolves to an empty range rather than an invalid one; the
        // route turns that into the `416`, which is a decision it makes and this does not.
        let past = try? #require(RequestedRange.from(Int.max, through: nil).resolved(totalSize: 16))
        #expect(past?.isEmpty == true)
        #expect(past?.lowerBound == Int.max)
        // `Int.max` at both ends, which is the one that reaches every operation at once.
        #expect(RequestedRange.from(Int.max, through: Int.max).resolved(totalSize: 16)?.isEmpty == true)
    }

    /// The ordinary resolutions, so the clamping above cannot quietly change what a normal
    /// range means.
    @Test func ordinaryRangesResolveExactly() {
        #expect(RequestedRange.whole.resolved(totalSize: 16) == nil)
        #expect(RequestedRange.from(0, through: 1).resolved(totalSize: 16) == 0..<2)
        #expect(RequestedRange.from(4, through: nil).resolved(totalSize: 16) == 4..<16)
        #expect(RequestedRange.suffix(4).resolved(totalSize: 16) == 12..<16)
        // A suffix at least as long as the file is the whole file.
        #expect(RequestedRange.suffix(16).resolved(totalSize: 16) == 0..<16)
        #expect(RequestedRange.suffix(99).resolved(totalSize: 16) == 0..<16)
        // An end past the file is clamped to it rather than refused.
        #expect(RequestedRange.from(8, through: 999).resolved(totalSize: 16) == 8..<16)
    }
}
