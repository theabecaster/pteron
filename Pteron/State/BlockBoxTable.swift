import Observation

/// One block's value, observed on its own: a write re-renders only the views that read this box.
@MainActor
@Observable
final class BlockBox<Value: Equatable> {
    fileprivate(set) var value: Value?

    fileprivate init(_ value: Value) { self.value = value }
}

/// Per-block state that changes often and only a few small views read, kept out of `BlockMeta`
/// so that a write doesn't re-render whatever reads a block's metadata. One per kind of state and
/// server, owned by `ServerConnection` (progress here; ports reuse it).
///
/// - A read never allocates, so a view body never writes state. A view observes its block's box
///   and `generation`, and reads again when a box is added or removed; values change no
///   generation, so a write re-renders only that block's readers.
/// - Only the owner writes, from its flush: the first non-nil value creates the block's box.
/// - The owner removes boxes when their block closes, its session goes, on a resync and on a new
///   connection. No box outlives its block.
@MainActor
@Observable
final class BlockBoxTable<Value: Equatable> {
    /// Changes when a box is added or removed, so views read their block's box again.
    private(set) var generation = 0
    @ObservationIgnored private var boxes: [String: BlockBox<Value>] = [:]

    /// The block's box, or nil without allocating one. Every reader also observes `generation`:
    /// one that found no box learns when it comes, and one holding a box that is removed (even
    /// a box without a value) reads the block's new box instead of the dead one.
    subscript(id: String) -> BlockBox<Value>? {
        _ = generation
        return boxes[id]
    }

    /// The block's value. Observes its box, or the table while it has none.
    func value(_ id: String) -> Value? { self[id]?.value }

    /// Writes a value; equal values write nothing. The first non-nil value creates the box.
    func set(_ id: String, _ value: Value?) {
        if let b = boxes[id] {
            if b.value != value { b.value = value }
        } else if let value {
            boxes[id] = BlockBox(value)
            generation &+= 1
        }
    }

    /// Takes the block's box away. Readers hear it through `generation` and read again.
    func remove(_ id: String) {
        guard removeBox(id) else { return }
        generation &+= 1
    }

    /// Takes away every box whose block fails the test, with one change for the readers.
    func removeAll(where gone: (String) -> Bool) {
        var removed = false
        for id in Array(boxes.keys) where gone(id) { removed = removeBox(id) || removed }
        if removed { generation &+= 1 }
    }

    /// A view still holding the box sees nil too.
    private func removeBox(_ id: String) -> Bool {
        guard let b = boxes.removeValue(forKey: id) else { return false }
        if b.value != nil { b.value = nil }
        return true
    }

    func removeAll() { removeAll { _ in true } }

    /// Blocks with a box, set or not.
    var ids: [String] { Array(boxes.keys) }

    /// Blocks whose box holds a value.
    var setIDs: [String] { boxes.compactMap { $0.value.value == nil ? nil : $0.key } }

    var isEmpty: Bool { boxes.isEmpty }
}
