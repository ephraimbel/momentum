import Foundation

/// Which community post ids are safe to keep engagement against — and which are not (2026-08-29).
///
/// **What this exists to close.** `CommunityGenerator.postID` mints two kinds of id. A ledger
/// tile's id is `handleHash(handle) * 1000 + slot`: pure, identity-bound, and stable forever, so a
/// comment written on it is still on the same post next week. A pull-to-refresh "pulse" post's id
/// lives at or above `ephemeralFloor` and is minted from `CommunityPulse`'s per-process counter,
/// which starts at zero every launch — so the same id space is handed out again on the next cold
/// start, for a different workout.
///
/// It was worse than that until 2026-08-29: the pulse branch read `900_000_000_000 + (pulse * 50
/// + slot)` with `handle` in scope and never used, so two DIFFERENT athletes pulsed at the same
/// (pulse, slot) were handed the same UUID inside one process. That is fixed upstream (the handle
/// is now folded in) and the property is pinned by
/// `EphemeralPostIDTests.twoAthletesPulsedAtTheSameSlotGetDifferentIDs`.
///
/// **This guard stays anyway, and is the permanently-correct half.** Identity-binding stops the id
/// from being actively wrong; it does not make a pulse post durable. The counter still restarts,
/// so the same id still denotes a different workout next launch. Anything the engagement stores
/// persist against one can reattach to a post the athlete never opened: a comment they wrote under
/// a nine-mile run reappearing under a different session, a heart already filled on a post they
/// have never seen, and a respect count carrying a +1 that belongs to something else.
///
/// **The rule: a pulse post is explicitly ephemeral, so the engagement on it is too.** Reacting
/// and commenting still work while the post is on screen — nothing reads as a dead control — but
/// nothing is written to disk, so nothing can bleed into the next launch. Persisting it would be
/// promising something the content model cannot keep.
///
/// The floor knowledge is duplicated from the generator on purpose, and pinned:
/// `classifierSortsRealMintedIDs` mints a real pulse post and real ledger tiles through the actual
/// generator and asserts this sorts them correctly, so a format drift fails loudly here instead of
/// silently letting engagement bleed again.
enum CommunityPostID {

    /// Ids at or above this value are pulse posts. Mirrors `CommunityGenerator.postID`'s pulse
    /// branch; ledger ids cannot reach it (`0xFFF_FFFF * 1000 + 999` ≈ 2.68e11).
    static let ephemeralFloor: Int64 = 900_000_000_000

    /// The fixed prefix every generated community id carries.
    static let generatedPrefix = "00000000-0000-0000-0001-"

    /// True for a pull-to-refresh pulse post: its id is not bound to an athlete and is re-minted
    /// from zero on the next launch, so nothing may be persisted against it.
    static func isEphemeral(_ id: UUID) -> Bool {
        isEphemeral(id.uuidString)
    }

    /// String overload — the stores key their persisted dictionaries by `uuidString`, and going
    /// back through `UUID(uuidString:)` for every entry on every write is pure waste.
    static func isEphemeral(_ uuidString: String) -> Bool {
        let s = uuidString.uppercased()
        guard s.hasPrefix(generatedPrefix.uppercased()) else { return false }
        let tail = s.dropFirst(generatedPrefix.count)
        guard let n = Int64(tail) else { return false }
        return n >= ephemeralFloor
    }
}
