import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// What a `Range:` header asked for, before anything is known about how big the
/// attachment is.
///
/// A type of its own because the header can be answered only in two steps: `bytes=-500`
/// means "the last 500 bytes", which is not a `Range<Int>` until the total is known, and
/// the total comes from the same read that returns the bytes. Resolving the header into an
/// absolute range up front would need the size first and would turn every ranged read into
/// two.
enum RequestedRange: Equatable {
    /// No `Range:` header, or one this server chooses not to honour. Both are the same
    /// answer — a `200` with everything — which is why they are one case.
    case whole
    /// `bytes=start-end` or `bytes=start-`, with `end` inclusive as the header writes it.
    case from(Int, through: Int?)
    /// `bytes=-n`: the final `n` bytes, whatever the total turns out to be.
    case suffix(Int)

    /// The largest byte offset a range may name once parsed.
    ///
    /// Not a policy about how big an attachment may be — that is
    /// `STELE_MAX_ATTACHMENT_BYTES` — but the widest offset anything downstream can
    /// address: `substring` takes an `integer`, so a position past this cannot be asked for
    /// in the first place. Clamping here rather than rejecting keeps every request's
    /// meaning exactly as it was: a start past the end is still unsatisfiable and still a
    /// `416`, an end past the end still means "to the end", and a suffix longer than the
    /// file still means the whole file.
    ///
    /// What it removes is the unbounded operand. These numbers come off the wire, so
    /// `Int.max` is a value any caller can send, and Swift's arithmetic traps on overflow
    /// — which turns one header into an unauthenticated way to stop the process.
    static let maxAddressableByte = Int(Int32.max)

    /// Parses the header, or answers `.whole` for anything not worth honouring.
    ///
    /// RFC 9110 §14.2 permits a server to ignore a `Range` it does not wish to satisfy, and
    /// this takes that permission twice. A syntactically broken header is ignored rather
    /// than refused, because a `416` would deny a client the resource over a header it
    /// could simply not have sent. And a *multi-range* request is ignored too: answering
    /// one means `multipart/byteranges`, a second body format built for a request no
    /// browser makes for media — a video player asks for one contiguous range at a time.
    ///
    /// The one thing this does not do is guess. Every shape it cannot read exactly becomes
    /// `.whole`, so the failure mode is a larger response rather than a wrong one.
    static func parse(_ header: String?) -> RequestedRange {
        guard let header else { return .whole }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return .whole }
        let spec = trimmed.dropFirst("bytes=".count)
        // One range only; see above.
        guard !spec.contains(",") else { return .whole }

        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .whole }
        let first = parts[0].trimmingCharacters(in: .whitespaces)
        let second = parts[1].trimmingCharacters(in: .whitespaces)

        if first.isEmpty {
            // `bytes=-n`. A zero-length suffix is meaningless rather than empty — RFC 9110
            // calls it unsatisfiable — and this server's answer to a range it will not
            // satisfy is the whole representation.
            guard let length = Int(second), length > 0 else { return .whole }
            return .suffix(min(length, maxAddressableByte))
        }
        guard let start = Int(first), start >= 0 else { return .whole }
        let clampedStart = min(start, maxAddressableByte)
        if second.isEmpty { return .from(clampedStart, through: nil) }
        // Compared before either is clamped: `bytes=5-2` is a malformed range whichever
        // widths the numbers happen to need, and clamping first could make two different
        // absurd numbers compare equal and turn a malformed header into a satisfiable one.
        guard let end = Int(second), end >= start else { return .whole }
        return .from(clampedStart, through: min(end, maxAddressableByte))
    }

    /// The half-open range to read, given a total that is not yet known at parse time.
    ///
    /// Nil for `.whole`, which reads everything and takes a different path — a nil here and
    /// a nil passed to `fetchBlob` mean the same thing, which is why this returns one.
    func resolved(totalSize: Int) -> Range<Int>? {
        switch self {
        case .whole:
            return nil
        case .from(let start, let through):
            // `through` is inclusive in the header and exclusive in a `Range`, hence the
            // `+ 1`; clamped to the total, because a client is allowed to ask for more than
            // exists and must be answered with what does.
            //
            // Written as a comparison rather than `min($0 + 1, totalSize)`, which adds
            // before it clamps. `parse` bounds these values now, and this deliberately does
            // not lean on that: the operand came off the wire, the addition traps on
            // overflow, and a trap in a request handler takes every in-flight request with
            // it. Two guards against one unauthenticated crash is the right number.
            let end: Int
            if let through {
                end = through >= totalSize ? totalSize : through + 1
            } else {
                end = totalSize
            }
            return start..<max(start, end)
        case .suffix(let length):
            // The last `length` bytes, or all of them if the file is shorter — which is the
            // one case where a suffix range is always satisfiable. Also written as a
            // comparison, for the reason above rather than because the subtraction can
            // overflow: `totalSize - length` with a non-negative total cannot underflow an
            // `Int`, and a reader should not have to work that out to trust the line.
            return (length >= totalSize ? 0 : totalSize - length)..<totalSize
        }
    }
}

/// Whether a stored type is one a browser should render in place rather than save.
///
/// Images and video are embedded — that is what an attachment is mostly for — so they get
/// `inline` and a filename to save under if somebody chooses to. Everything else gets
/// `attachment`, which is the honest disposition for bytes no `<img>` will ever point at.
///
/// A prefix test rather than a third table keyed by the same strings the other two are.
/// `PageContentType.label(for:)` makes the same argument at more length: a table listing
/// which of this server's types are images, sitting beside the table of this server's
/// types, is a pair that drifts.
func isInlineAttachment(_ storedContentType: String) -> Bool {
    storedContentType.hasPrefix("image/") || storedContentType.hasPrefix("video/")
}

/// The `Content-Disposition` an attachment is served with, or nil when there is no filename
/// to offer and the type renders in place anyway.
///
/// The filename reaches this having passed `validatedFilename`, so it carries no quote, no
/// backslash and no control character — which is what makes the quoted-string form below
/// safe to build by interpolation. This is the one response header in the server assembled
/// from something a caller chose; the validation is at the write, and this is the reason it
/// is there.
func attachmentDisposition(contentType: String, filename: String?) -> String? {
    let kind = isInlineAttachment(contentType) ? "inline" : "attachment"
    guard let filename else {
        // Nothing to name it. `inline` alone says nothing a browser does not already assume
        // from the content type, so it is left off rather than sent as decoration.
        return isInlineAttachment(contentType) ? nil : kind
    }
    return "\(kind); filename=\"\(filename)\""
}
