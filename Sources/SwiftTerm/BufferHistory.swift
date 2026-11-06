//
//  BufferHistory.swift
//
//  Keeps the lines of the scrollback packed (see `PackedCells`).
//
//  A line is packed when it leaves the screen and unpacked by the first access to its cells (a
//  render of the scrolled view, a selection, a search, a resize). The buffer remembers the lines it
//  unpacked most recently, and packs the oldest of them again when there are more than
//  `UnpackedLineRing.capacity`, so reading all of a long history one line after another never holds
//  more than that many lines of full cells.
//

import Foundation

/// The lines of the scrollback that were unpacked last, oldest first.
struct UnpackedLineRing {
    private struct Entry {
        let line: BufferLine
        let ticket: UInt32
        let generation: UInt64

        /// False for a line that was unpacked again since (it has a newer entry) and for a line
        /// that was recycled into a line of the screen, which stays unpacked.
        var isCurrent: Bool { ticket == line.unpackTicket && generation == line.recycleGeneration }
    }

    private var entries: [Entry?] = []
    private var next = 0
    private var tickets: UInt32 = 0

    var capacity: Int { entries.count }

    /// Empties the ring and gives it a new capacity. Returns the lines it held.
    mutating func reset(capacity: Int) -> [BufferLine] {
        let held = entries.compactMap { $0 }.filter { $0.isCurrent }.map { $0.line }
        entries = Array(repeating: nil, count: capacity)
        next = 0
        return held
    }

    /// Remembers `line`, and returns the line that falls out of the ring, if one does.
    mutating func add(_ line: BufferLine) -> BufferLine? {
        tickets &+= 1
        line.unpackTicket = tickets
        let old = entries[next]
        entries[next] = Entry(line: line, ticket: tickets, generation: line.recycleGeneration)
        next = (next + 1) % entries.count
        guard let old, old.isCurrent else { return nil }
        return old.line
    }
}

extension Buffer {
    /// How many lines the buffer keeps unpacked after they were read: a few screens, so that
    /// drawing and scrolling the view never packs a line the next frame needs.
    private var unpackedLineCapacity: Int { max(512, rows * 4) }

    /// Called by a line of this buffer that was just unpacked.
    func noteUnpacked(_ line: BufferLine) {
        guard compactsHistory else { return }
        // The line is unpacked now: an entry of an earlier unpacking must not repack it.
        line.unpackTicket = 0
        if unpackedLines.capacity != unpackedLineCapacity {
            // The screen changed its height: start the ring over.
            unpackedLines.reset(capacity: unpackedLineCapacity).forEach { $0.pack() }
        }
        if let oldest = unpackedLines.add(line) {
            oldest.pack()
        }
    }

    /// Packs the line that has just scrolled off the top of the screen.
    func packLineThatLeftTheScreen() {
        guard compactsHistory, hasScrollback, yBase > 0, yBase - 1 < lines.count else { return }
        lines[yBase - 1].pack()
    }

    /// Packs every line above the screen, for the ways lines reach the scrollback that are not a
    /// scroll (a resize that reflows them, a change of the history size).
    func packHistory() {
        guard compactsHistory, hasScrollback else { return }
        for index in 0..<min(yBase, lines.count) {
            lines[index].pack()
        }
    }
}
