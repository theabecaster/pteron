import Foundation

/// Collects a Ghostty snapshot as it arrives, for one restore at its end.
///
/// The restore needs one contiguous buffer (`GhosttyTerminalView.restoreSnapshot`), and the size
/// isn't known until the last byte. An array that grows by doubling holds the old and the new
/// storage at every step: up to three times the snapshot near the end. So the bytes are kept in
/// blocks of a fixed size, which never move, and `take()` joins them into an array of the exact
/// size while it frees each block behind it. Memory in use stays at about the snapshot's size
/// plus one block, and a snapshot that fits one block is handed over without a copy.
struct SnapshotBuffer {
    /// The largest snapshot a phone restores. A real one is small: a screen and 10,000 lines of
    /// history are well under 1 MiB (pages compress blank and repeated cells), and only the
    /// pixels of Kitty images or megabytes of unfinished input make one large. Several panes
    /// restore at once after a reconnect, each also holding the decoded terminal, so this stays
    /// far below what the stream's filter would pass on. Past it the pane falls back to
    /// `terminal.format`, which always works.
    static let limit = 16 << 20
    static let blockSize = 256 << 10
    static let firstBlockSize = 16 << 10

    private let limit: Int
    private let blockSize: Int
    private var blocks: [[UInt8]] = []
    private(set) var count = 0

    init(limit: Int = SnapshotBuffer.limit, blockSize: Int = SnapshotBuffer.blockSize) {
        self.limit = limit
        self.blockSize = max(1, blockSize)
    }

    /// Bytes allocated for the blocks now.
    var capacity: Int { blocks.reduce(0) { $0 + $1.capacity } }

    /// Adds bytes. False when the snapshot grew past the limit: everything held is freed, and
    /// the caller refuses the snapshot.
    mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard count + bytes.count <= limit else {
            reset()
            return false
        }
        var rest = UnsafeBufferPointer(rebasing: bytes[...])
        while !rest.isEmpty {
            // A block is filled to the capacity it was given and never grows, so it never moves.
            if blocks.isEmpty || blocks[blocks.count - 1].count == blocks[blocks.count - 1].capacity {
                var block: [UInt8] = []
                // The first block starts small: most snapshots are a few KB.
                block.reserveCapacity(blocks.isEmpty ? min(blockSize, max(rest.count, Self.firstBlockSize)) : blockSize)
                blocks.append(block)
            }
            let last = blocks.count - 1
            let n = min(rest.count, blocks[last].capacity - blocks[last].count)
            blocks[last].append(contentsOf: UnsafeBufferPointer(rebasing: rest[..<n]))
            rest = UnsafeBufferPointer(rebasing: rest[n...])
        }
        count += bytes.count
        return true
    }

    /// Frees everything held.
    mutating func reset() {
        blocks = []
        count = 0
    }

    /// The snapshot as one array. The buffer is empty afterwards.
    mutating func take() -> [UInt8] {
        defer { reset() }
        if blocks.count == 1 { return blocks[0] }
        let total = count
        return [UInt8](unsafeUninitializedCapacity: total) { out, written in
            var at = 0
            for i in blocks.indices {
                blocks[i].withUnsafeBufferPointer { block in
                    if let base = block.baseAddress, let dest = out.baseAddress { (dest + at).update(from: base, count: block.count) }
                    at += block.count
                }
                // Freed as soon as it is copied: the two never both hold the whole snapshot.
                blocks[i] = []
            }
            written = at
        }
    }
}
