import Foundation
import Testing

@testable import SteleCore

/// The `?ttl=` grammar, with no HTTP around it.
///
/// The single property this suite exists for is that nothing falls back to the default. A
/// parser that shrugged at a bad value and published a week-long page would produce a `201`
/// and a link that quietly dies on a date the caller never chose — a failure with no
/// symptom until it is far too late to fix.
@Suite("Page lifetime")
struct PageLifetimeTests {
    /// A fixed reference so the arithmetic is exact rather than "near enough". Every
    /// expectation below is an equality, which is only possible because the instant the
    /// lifetime is measured from is an argument rather than `Date()` read inside.
    static let reference = Date(timeIntervalSince1970: 1_700_000_000)

    /// The default is what an upload that says nothing gets, and it is the whole
    /// ephemeral-by-default decision expressed in one line. Written against the constant, so
    /// changing the constant changes the expectation rather than breaking the test.
    @Test func absentValueGetsTheDefaultLifetime() throws {
        let lifetime = try PageLifetime(raw: nil, from: Self.reference)
        #expect(
            lifetime.expiresAt
                == Self.reference.addingTimeInterval(
                    Double(PageLifetime.defaultDays) * PageLifetime.secondsPerDay
                )
        )
        // Anti-vacuity: nil would also satisfy an `== nil` mistake in either direction.
        #expect(lifetime.expiresAt != nil)
    }

    /// `never` is the opt-out, and nil is how permanence is stored. It is also the *only*
    /// thing that stores one: migration 2 gave every pre-expiry page a real deadline, so a
    /// NULL in that column always traces back to this line.
    @Test func neverMeansNoExpiry() throws {
        #expect(try PageLifetime(raw: PageLifetime.neverKeyword, from: Self.reference).expiresAt == nil)
    }

    /// The one expectation in the codebase that spells the number out, and the reason it has
    /// to exist: every other instant asserted here and in `PageExpiryTests` is *derived* from
    /// `secondsPerDay`, so all of them agree with a day of any length. Change the constant to
    /// 3,600 and the entire suite still passes while every page dies seven hours after
    /// publication. This line is what makes a day a day; the derived expectations catch a
    /// unit mistake at the arithmetic site, where code and expectation would disagree.
    @Test func aDayIsEightySixThousandFourHundredSeconds() throws {
        #expect(PageLifetime.secondsPerDay == 86_400)
        let lifetime = try PageLifetime(raw: "1", from: Self.reference)
        #expect(lifetime.expiresAt == Self.reference.addingTimeInterval(86_400))
    }

    /// Days are counted from the moment of the upload, at whatever length the constant above
    /// pins. One day and the bound both, because a unit mistake in the arithmetic and an
    /// off-by-one at the ceiling are the two ways it goes wrong quietly from here.
    @Test(arguments: [1, 7, 30, 365, PageLifetime.maxDays])
    func aPositiveDayCountIsThatManyDaysOut(days: Int) throws {
        let lifetime = try PageLifetime(raw: "\(days)", from: Self.reference)
        #expect(
            lifetime.expiresAt
                == Self.reference.addingTimeInterval(Double(days) * PageLifetime.secondsPerDay)
        )
    }

    /// Every shape that is not an accepted form, each of which would otherwise have a
    /// plausible-looking wrong answer: `0` and `-1` produce a page that is born dead, `7.5`
    /// and `7d` invite truncation, an empty or blank value is the shape `?ttl=` with nothing
    /// after it arrives as, and a number past the bound is where `Date` arithmetic stops
    /// being arithmetic.
    @Test(arguments: [
        "0", "-1", "-7", "7.5", "7d", "abc", "", " ", " 7", "7 ", "Never", "NEVER",
        "36501", "99999999999999999999999999",
    ])
    func everythingElseIsRejected(raw: String) {
        #expect(throws: PageLifetimeError.self, "\(raw)") {
            try PageLifetime(raw: raw, from: Self.reference)
        }
    }

    /// The bound is a real bound, not a rounding: the last accepted value and the first
    /// rejected one sit next to each other. Without this the two rules above could both pass
    /// with the comparison the wrong way round by one.
    @Test func theMaximumIsInclusiveAndTheNextDayIsNot() {
        #expect(throws: Never.self) {
            try PageLifetime(raw: "\(PageLifetime.maxDays)", from: Self.reference)
        }
        #expect(throws: PageLifetimeError.self) {
            try PageLifetime(raw: "\(PageLifetime.maxDays + 1)", from: Self.reference)
        }
    }

    /// A digit string too large for `Int` is an absurd lifetime, not a typo, and the message
    /// has to say which — a caller told "not a whole number" about `99999999999999999999`
    /// will go looking for a character that is not there.
    @Test func anOverlongDigitStringIsReportedAsTooLargeRatherThanUnparseable() {
        let error = #expect(throws: PageLifetimeError.self) {
            try PageLifetime(raw: "99999999999999999999", from: Self.reference)
        }
        #expect(error == .beyondMaximum("99999999999999999999", max: PageLifetime.maxDays))
    }

    /// Every rejection names a way forward. These messages are the only documentation a
    /// caller gets at the terminal, and "invalid ttl" with no accepted form named is a
    /// caller reading the source or guessing.
    @Test(arguments: ["0", "-1", "abc", "", "36501"])
    func everyRejectionNamesAnAcceptedForm(raw: String) {
        let error = #expect(throws: PageLifetimeError.self) {
            try PageLifetime(raw: raw, from: Self.reference)
        }
        #expect(error?.description.contains(PageLifetime.neverKeyword) == true, "\(raw)")
        #expect(error?.description.contains("day") == true, "\(raw)")
    }
}
