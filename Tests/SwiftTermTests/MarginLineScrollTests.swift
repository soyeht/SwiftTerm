//
//  MarginLineScrollTests.swift
//
//  Insert Line and Delete Line with left and right margins (DECLRMM) move the rows from the cursor
//  row to the bottom margin. They used to move as many rows as the scrolling region has, counted
//  from the cursor, which reached past the bottom margin and, after a resize, into lines of the
//  buffer's array that are no longer part of it and have another width: an out of range copy
//  (found by the fuzz test; a heap overflow in a release build).
//

import Testing

@testable import SwiftTerm

final class MarginLineScrollTests {
    private func screen(_ terminal: Terminal) -> [String] {
        (0..<terminal.rows).map { row in
            (terminal.getLine(row: row)?.translateToString(trimRight: false) ?? "")
                .replacingOccurrences(of: "\0", with: " ")
        }
    }

    /// Six rows of ten columns, a scrolling region of rows 2 to 5 and margins of columns 3 to 8.
    private func makeTerminal() -> Terminal {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 6, scrollback: 0)
        terminal.feed(text: "AAAAAAAAAA\r\nBBBBBBBBBB\r\nCCCCCCCCCC\r\nDDDDDDDDDD\r\nEEEEEEEEEE\r\nFFFFFFFFFF")
        terminal.feed(text: "\u{1b}[?69h\u{1b}[3;8s\u{1b}[2;5r")
        terminal.feed(text: "\u{1b}[3;4H")
        return terminal
    }

    @Test func deleteLineMovesTheRowsFromTheCursorToTheBottomMargin() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[M")
        #expect(screen(terminal) == [
            "AAAAAAAAAA", "BBBBBBBBBB", "CCDDDDDDCC", "DDEEEEEEDD", "EE      EE", "FFFFFFFFFF",
        ])
    }

    @Test func insertLineMovesTheRowsFromTheCursorToTheBottomMargin() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[L")
        #expect(screen(terminal) == [
            "AAAAAAAAAA", "BBBBBBBBBB", "CC      CC", "DDCCCCCCDD", "EEDDDDDDEE", "FFFFFFFFFF",
        ])
    }

    @Test func deleteLineOutsideTheScrollingRegionDoesNothing() {
        let terminal = makeTerminal()
        let before = screen(terminal)
        terminal.feed(text: "\u{1b}[6;4H\u{1b}[M")
        #expect(screen(terminal) == before)
    }

    @Test func aMarginScrollAfterAResizeStaysInsideTheBuffer() {
        // Shrinking the rows leaves lines of the old width in the array past the end of the
        // buffer; a margin scroll that read them copied more columns than they have.
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 30, rows: 20, scrollback: 50)
        terminal.feed(text: (0..<19).map { "row \($0)" }.joined(separator: "\r\n") + "\u{1b}[H")
        terminal.resize(cols: 30, rows: 5)
        terminal.resize(cols: 60, rows: 5)
        terminal.feed(text: "\u{1b}[?69h\u{1b}[1;60s\u{1b}[3;1H\u{1b}[M\u{1b}[L\u{1b}[2M\u{1b}[2L")
        #expect(terminal.buffer.lines.count == 5)
        #expect(screen(terminal).count == 5)
    }

    @Test func aCopyOrFillPastTheEndOfALineIsCutToFit() {
        let wide = BufferLine(cols: 20)
        let narrow = BufferLine(cols: 5)
        let mark = CharData(attribute: CharData.defaultAttr, code: 88, size: 1)
        wide.fill(with: mark, atCol: 0, len: 20)
        narrow.copyFrom(wide, srcCol: 0, dstCol: 0, len: 20)
        wide.copyFrom(narrow, srcCol: 3, dstCol: 15, len: 20)
        narrow.fill(with: CharData.Null, atCol: 2, len: 50)
        narrow.fill(with: CharData.Null, atCol: 9, len: 1)
        narrow.copyFrom(wide, srcCol: -1, dstCol: 0, len: 2)
        #expect(narrow.translateToString(trimRight: true) == "XX")
    }
}
