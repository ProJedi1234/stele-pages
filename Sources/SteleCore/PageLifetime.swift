import Foundation

/// Why a `?ttl=` value was rejected. Each case carries enough detail to tell the caller
/// exactly what to change, and every message names the forms that *are* accepted — the
/// same shape as `SlugError`, for the same reason: this text is the only documentation a
/// caller gets at the terminal.
public enum PageLifetimeError: Error, Equatable, CustomStringConvertible {
    case notAWholeNumberOfDays(String)
    case notPositive(Int)
    case beyondMaximum(String, max: Int)

    public var description: String {
        switch self {
        case .notAWholeNumberOfDays(let raw):
            """
            '\(raw)' is not a whole number of days; use a positive integer of days \
            or '\(PageLifetime.neverKeyword)'
            """
        case .notPositive(let days):
            """
            \(days) is not a positive number of days; a page lives at least one day, \
            or '\(PageLifetime.neverKeyword)' to keep it forever
            """
        case .beyondMaximum(let raw, let max):
            """
            '\(raw)' is beyond the \(max)-day maximum; use '\(PageLifetime.neverKeyword)' \
            for a page that should never expire
            """
        }
    }
}

/// How long a newly published page lives, resolved to the absolute instant it dies.
///
/// An absolute `Date` rather than a stored duration, because expiry is enforced by the
/// database — `expires_at > now()` on every read, a `DELETE` on every upload — and a
/// duration would have to be added to *something* at each of those sites. Resolving once,
/// against the moment of the upload, is what makes "seven days" mean seven days from
/// publication rather than seven days from whenever the row was last looked at.
///
/// The parse is deliberately unforgiving: every input that is not an accepted form throws,
/// and nothing falls back to the default. A caller who mistyped a lifetime and got a
/// week-long page instead of an error would not find out until the link died.
public struct PageLifetime: Sendable, Equatable {
    /// The query parameter a caller sets. A constant rather than a string typed at each
    /// use, so the router's lookup and the publish skill's prose move together.
    public static let queryParameter = "ttl"

    /// The spelling that opts out of expiry entirely. A constant for the same reason, and
    /// more urgently: a parser that accepts `never` while the document teaches `forever`
    /// fails silently and totally for an agent that has no other source of truth.
    public static let neverKeyword = "never"

    /// What an upload that says nothing about its lifetime gets.
    ///
    /// Ephemeral by default; permanence is the deliberate choice. The two failures are not
    /// symmetric — a page that outlives its purpose fails quietly and forever, while a page
    /// that expires too soon fails loudly to somebody who can republish it.
    public static let defaultDays = 7

    /// The largest lifetime that is still a lifetime: a century.
    ///
    /// A bound rather than "whatever fits in an `Int`", for two reasons. `Date` arithmetic
    /// on an unbounded day count runs off into infinities rather than failing, and the
    /// database would then reject the bind — a 500 for what was really a bad request. And a
    /// caller asking for a million days means `neverKeyword`; making them write it keeps
    /// "this page is permanent" a fact the row states outright rather than one a reader has
    /// to infer from a date in the year 4000.
    public static let maxDays = 36_500

    /// Seconds in a day, as this type counts them.
    ///
    /// A flat 86,400 rather than a calendar computation: `expires_at` is an absolute
    /// instant, and a lifetime that stretched or shrank by an hour across a daylight-saving
    /// boundary would be a difference nobody asked for and nobody could see.
    static let secondsPerDay: TimeInterval = 86_400

    /// When the page stops being served, or nil if it never does.
    ///
    /// Nil is stored as SQL `NULL`, and it is the only thing a `NULL` in that column means.
    /// Pages published before expiry existed were given a real deadline by migration 2 rather
    /// than left permanent, so "no deadline" is always something a caller asked for.
    public let expiresAt: Date?

    /// - Parameters:
    ///   - raw: the `?ttl=` value exactly as it arrived, or nil if the caller sent none.
    ///     Not trimmed and not lowercased. `?ttl=` with nothing after it arrives here as
    ///     `""`, which is a mistake and must be reported as one — the absent case is the
    ///     only one that means "no opinion".
    ///   - reference: the instant the lifetime is measured from, which is the upload.
    public init(raw: String?, from reference: Date = Date()) throws(PageLifetimeError) {
        guard let raw else {
            self.expiresAt = Self.instant(daysAfter: reference, days: Self.defaultDays)
            return
        }
        if raw == Self.neverKeyword {
            self.expiresAt = nil
            return
        }
        // `Int(_:)` is the entire grammar check, and it is exactly strict enough: it rejects
        // `7.5`, `abc`, `""`, ` 7` and a digit string too large to hold. Rounding or
        // truncating any of those would store a lifetime the caller never asked for.
        guard let days = Int(raw) else {
            // A run of digits that overflows `Int` is a lifetime, just an absurd one.
            // Reporting it as "not a number" would send the caller hunting for a typo that
            // is not there, so it earns the bound's message instead.
            guard raw.isEmpty || !raw.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw .beyondMaximum(raw, max: Self.maxDays)
            }
            throw .notAWholeNumberOfDays(raw)
        }
        guard days > 0 else { throw .notPositive(days) }
        guard days <= Self.maxDays else { throw .beyondMaximum(raw, max: Self.maxDays) }
        self.expiresAt = Self.instant(daysAfter: reference, days: days)
    }

    private static func instant(daysAfter reference: Date, days: Int) -> Date {
        reference.addingTimeInterval(Double(days) * secondsPerDay)
    }
}
