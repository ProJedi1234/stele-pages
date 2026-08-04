/// A strong HTTP entity-tag over `bytes`, quoted per RFC 9110 — an unquoted entity-tag is
/// not a valid one.
///
/// FNV-1a rather than `String.hashValue`: Swift seeds its hasher per process, so a
/// `hashValue` ETag would change on every restart and differ between instances behind the
/// same address — validating nothing. FNV-1a is fixed, so the same bytes produce the same
/// tag in every process, forever.
///
/// Takes bytes rather than a `String` so callers that already hold the encoded form — a
/// stored page's body, a buffer read off the wire — hash exactly what they will send,
/// rather than a re-encoding of it.
///
/// Not a security primitive: FNV-1a is a non-cryptographic hash, and a validator only has
/// to change when the bytes change, not resist an adversary choosing bytes that collide.
func strongETag(over bytes: some Sequence<UInt8>) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return "\"\(String(hash, radix: 16))\""
}
