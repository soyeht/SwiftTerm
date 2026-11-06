//
//  CompactScrollbackTests.swift
//
//  The lines of the scrollback are stored packed (see PackedLine.swift and BufferHistory.swift).
//  These tests hold the rest of the library to its behaviour with full cells: the same output into
//  a terminal that packs and a terminal that does not has to give the same buffer, the same
//  selections and the same search results, after scrolling, wrapping and resizing.
//

import Foundation
import Testing

@testable import SwiftTerm

private typealias Cell = (
    code: Int32, width: Int8, attribute: Attribute, payload: String, semantic: UInt8
)

private func describe(_ cell: CharData) -> String {
    let payload = cell.getPayload().map { String(describing: $0) } ?? "-"
    let attribute = cell.attribute
    return "\(cell.code)/\(cell.width)/\(attribute.fg)/\(attribute.bg)/\(attribute.style.rawValue)/"
        + "\(attribute.underlineStyle)/\(String(describing: attribute.underlineColor))/\(payload)/"
        + "\(cell.rawSemanticContentCode)"
}

/// Everything a reader can see of a buffer's lines, in one comparable value.
private func snapshot(_ buffer: Buffer) -> [String] {
    var rows = ["count=\(buffer.lines.count) yBase=\(buffer.yBase) yDisp=\(buffer.yDisp) top=\(buffer.linesTop)"]
    for index in 0..<buffer.lines.count {
        let line = buffer.lines[index]
        var row = "\(index) w=\(line.isWrapped) m=\(line.renderMode) n=\(line.count) "
        for column in 0..<line.count {
            row += describe(line[column]) + "|"
        }
        rows.append(row)
    }
    return rows
}

private final class Generator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

private let words = [
    "alpha", "beta", "needle", "gamma", "x", "tab\there", "漢字かな", "🙂", "👍🏽", "e\u{301}x",
    "a\u{200d}b", "łódź", "0123456789",
]

/// Output with colours, wide and combining characters, links, prompts and long lines.
private func output(lines: Int, seed: UInt64) -> String {
    let random = Generator(seed: seed)
    var text = ""
    for line in 0..<lines {
        text += "line\(line) "
        for _ in 0..<(1 + random.next(14)) {
            switch random.next(14) {
            case 0: text += "\u{1b}[3\(random.next(8))m"
            case 1: text += "\u{1b}[48;5;\(random.next(256))m"
            case 2: text += "\u{1b}[38;2;\(random.next(256));\(random.next(256));\(random.next(256))m"
            case 3: text += "\u{1b}[1;4m"
            case 4: text += "\u{1b}[4:3m\u{1b}[58;2;\(random.next(256));9;200m"
            case 5: text += "\u{1b}[0m"
            case 6: text += "\u{1b}]8;;https://example.com/\(line)\u{07}link\(line)\u{1b}]8;;\u{07}"
            case 7: text += "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ls\u{1b}]133;C\u{07}"
            case 8: text += "\u{1b}[7m"
            default: text += words[random.next(words.count)]
            }
            text += " "
        }
        text += "\u{1b}[0m\r\n"
    }
    return text
}

private func makeTerminal(
    cols: Int, rows: Int, scrollback: Int, compact: Bool
) -> Terminal {
    let (terminal, _) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows, scrollback: scrollback)
    terminal.normalBuffer.compactsHistory = compact
    return terminal
}

private func expectSameBuffers(_ plain: Terminal, _ packed: Terminal, _ note: String) {
    let a = snapshot(plain.normalBuffer)
    let b = snapshot(packed.normalBuffer)
    guard a != b else { return }
    let first = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
    var left = first < a.count ? a[first] : "<none>"
    var right = first < b.count ? b[first] : "<none>"
    let common = zip(left, right).prefix { $0 == $1 }.count
    left = String(left.dropFirst(max(common - 60, 0)).prefix(240))
    right = String(right.dropFirst(max(common - 60, 0)).prefix(240))
    Issue.record("\(note): buffers differ at \(first) of \(a.count)/\(b.count)\nplain:  \(left)\npacked: \(right)")
}

private func packedLineCount(_ buffer: Buffer) -> Int {
    (0..<buffer.lines.count).filter { buffer.lines[$0].isPacked }.count
}

final class CompactScrollbackTests {
    // MARK: The cells round trip

    private func roundTrip(_ cells: [CharData]) -> [CharData] {
        let blob = cells.withUnsafeBufferPointer { PackedCells.pack($0) }
        defer { blob.deallocate() }
        let out = UnsafeMutablePointer<CharData>.allocate(capacity: cells.count)
        defer {
            out.deinitialize(count: cells.count)
            out.deallocate()
        }
        PackedCells.unpack(blob, count: cells.count, into: out)
        return (0..<cells.count).map { out[$0] }
    }

    @Test func attributesAndColoursSurvivePacking() {
        let colors: [Attribute.Color] = [
            .ansi256(code: 0), .ansi256(code: 255), .trueColor(red: 1, green: 2, blue: 3),
            .trueColor(red: 255, green: 0, blue: 128), .defaultColor, .defaultInvertedColor,
        ]
        var cells: [CharData] = []
        for fg in colors {
            for bg in colors {
                for style in [CharacterStyle.none, [.bold, .italic], [.underline, .inverse, .crossedOut]] {
                    let underline: [(UnderlineStyle, Attribute.Color?)] = [
                        (.none, nil), (.single, nil), (.curly, .trueColor(red: 9, green: 8, blue: 7)),
                        (.dashed, .ansi256(code: 3)), (.none, .defaultInvertedColor),
                    ]
                    for (underlineStyle, underlineColor) in underline {
                        let attribute = Attribute(
                            fg: fg, bg: bg, style: style, underlineStyle: underlineStyle,
                            underlineColor: underlineColor)
                        cells.append(CharData(attribute: attribute, code: 65, size: 1))
                    }
                }
            }
        }
        let back = roundTrip(cells)
        #expect(back.count == cells.count)
        for (before, after) in zip(cells, back) {
            #expect(describe(before) == describe(after))
        }
    }

    @Test func wideCombiningAndEmptyCellsSurvivePacking() {
        var cells: [CharData] = []
        let plain = CharData.defaultAttr
        // A wide character takes two cells, the second one empty, as the parser stores it.
        cells.append(CharData(attribute: plain, code: 0x6F22, size: 2))
        cells.append(CharData(attribute: plain, code: 0, size: 0))
        // An index into the grapheme table, which is outside the Unicode range.
        cells.append(CharData(attribute: plain, code: Int32(CharData.maxRune + 7), size: 1))
        cells.append(CharData(attribute: plain, code: Int32(CharData.maxRune + 7), size: 2))
        cells.append(CharData(attribute: plain, code: 0x1F44D, size: 2))
        cells.append(CharData(attribute: plain, code: 0, size: 0))
        cells.append(CharData(attribute: plain, code: 0x7f, size: 1))
        cells.append(CharData(attribute: plain, code: 0x80, size: 1))
        cells.append(CharData(attribute: plain, code: 66, size: 3))
        for _ in 0..<40 { cells.append(CharData(attribute: plain, code: 0, size: 1)) }
        for _ in 0..<2 { cells.append(CharData(attribute: plain, code: 120, size: 1)) }
        for _ in 0..<2 { cells.append(CharData(attribute: plain, code: 0x6F22, size: 2)) }
        for _ in 0..<5 { cells.append(CharData(attribute: plain, code: 0x6F22, size: 2)) }
        let back = roundTrip(cells)
        #expect(back.count == cells.count)
        for (before, after) in zip(cells, back) {
            #expect(describe(before) == describe(after))
        }
    }

    @Test func payloadAtomsAndSemanticRolesSurvivePacking() {
        let atom = TinyAtom.lookup(value: "https://example.com/packed")
        defer { atom?.release() }
        var cells: [CharData] = []
        for index in 0..<30 {
            var cell = CharData(attribute: CharData.defaultAttr, code: Int32(97 + index % 26), size: 1)
            if index % 3 == 0, let atom { cell.setPayload(atom: atom) }
            cell.setSemanticContent(index < 10 ? .prompt(.initial) : (index < 20 ? .input : .output))
            cells.append(cell)
        }
        let back = roundTrip(cells)
        for (before, after) in zip(cells, back) {
            #expect(describe(before) == describe(after))
        }
        #expect(back[0].getPayload() as? String == "https://example.com/packed")
        #expect(back[1].getPayload() == nil)
    }

    @Test func aFullPlainLineTakesAboutAByteACell() {
        let cells = (0..<80).map { CharData(attribute: CharData.defaultAttr, code: Int32(48 + $0 % 10), size: 1) }
        let blob = cells.withUnsafeBufferPointer { PackedCells.pack($0) }
        defer { blob.deallocate() }
        let size = PackedCells.byteCount(blob, count: cells.count)
        #expect(size <= 80 + 8)
        #expect(MemoryLayout<CharData>.stride * cells.count > size * 20)
    }

    @Test func aBlankTailCostsAFewBytes() {
        var cells = (0..<10).map { CharData(attribute: CharData.defaultAttr, code: Int32(97 + $0), size: 1) }
        cells += Array(repeating: CharData(attribute: CharData.defaultAttr, code: 0, size: 1), count: 190)
        let blob = cells.withUnsafeBufferPointer { PackedCells.pack($0) }
        defer { blob.deallocate() }
        #expect(PackedCells.byteCount(blob, count: cells.count) <= 20)
    }

    @Test func aCellHoldsNoFieldThePackingDoesNotKnow() {
        // If a rebase adds a field to CharData or Attribute, PackedCells must learn to store it.
        #expect(Mirror(reflecting: CharData.Null).children.map { $0.label } ==
            ["code", "width", "payload", "semanticContentCode", "attribute"])
        #expect(Mirror(reflecting: Attribute.empty).children.map { $0.label } ==
            ["fg", "bg", "style", "underlineStyle", "underlineColor"])
    }

    // MARK: The buffer behaves as before

    @Test func linesAreStoredPackedOnceTheyLeaveTheScreen() {
        let terminal = makeTerminal(cols: 80, rows: 10, scrollback: 2000, compact: true)
        terminal.feed(text: output(lines: 1500, seed: 3))
        let buffer = terminal.normalBuffer
        #expect(buffer.yBase > 1000)
        #expect(packedLineCount(buffer) >= buffer.yBase - 1)
        // The lines of the screen are never packed.
        for index in buffer.yBase..<buffer.lines.count {
            #expect(!buffer.lines[index].isPacked)
        }
    }

    @Test func theSameOutputGivesTheSameBuffer() {
        let plain = makeTerminal(cols: 40, rows: 10, scrollback: 400, compact: false)
        let packed = makeTerminal(cols: 40, rows: 10, scrollback: 400, compact: true)
        let text = output(lines: 1200, seed: 11)
        // In pieces, as a process writes it.
        var rest = Substring(text)
        let random = Generator(seed: 5)
        while !rest.isEmpty {
            let piece = rest.prefix(1 + random.next(400))
            plain.feed(text: String(piece))
            packed.feed(text: String(piece))
            rest = rest.dropFirst(piece.count)
        }
        #expect(packedLineCount(packed.normalBuffer) > 300)
        #expect(snapshot(plain.normalBuffer) == snapshot(packed.normalBuffer))
        #expect(packed.getBufferAsData(kind: .normal) == plain.getBufferAsData(kind: .normal))
    }

    @Test func theSameOutputGivesTheSameBufferAfterResizes() {
        let plain = makeTerminal(cols: 40, rows: 10, scrollback: 500, compact: false)
        let packed = makeTerminal(cols: 40, rows: 10, scrollback: 500, compact: true)
        let text = output(lines: 900, seed: 21)
        plain.feed(text: text)
        packed.feed(text: text)
        for (cols, rows) in [(30, 12), (60, 8), (25, 10), (80, 10), (40, 6), (40, 10)] {
            plain.resize(cols: cols, rows: rows)
            packed.resize(cols: cols, rows: rows)
            #expect(packedLineCount(packed.normalBuffer) >= packed.normalBuffer.yBase - 1)
            expectSameBuffers(plain, packed, "\(cols)x\(rows)")
            plain.feed(text: output(lines: 60, seed: UInt64(cols)))
            packed.feed(text: output(lines: 60, seed: UInt64(cols)))
        }
        #expect(snapshot(plain.normalBuffer) == snapshot(packed.normalBuffer))
    }

    @Test func wrappedLinesStayWrapped() {
        let packed = makeTerminal(cols: 20, rows: 4, scrollback: 100, compact: true)
        let plain = makeTerminal(cols: 20, rows: 4, scrollback: 100, compact: false)
        let long = String(repeating: "abcdefghij", count: 12)
        for terminal in [packed, plain] {
            for _ in 0..<5 { terminal.feed(text: long + "\r\n") }
        }
        let buffer = packed.normalBuffer
        let wrapped = (0..<buffer.yBase).filter { buffer.lines[$0].isWrapped }
        #expect(!wrapped.isEmpty)
        #expect(snapshot(packed.normalBuffer) == snapshot(plain.normalBuffer))
        packed.resize(cols: 60, rows: 4)
        plain.resize(cols: 60, rows: 4)
        #expect(snapshot(packed.normalBuffer) == snapshot(plain.normalBuffer))
    }

    @Test func theScrollbackCapEvictsTheOldestLines() {
        let packed = makeTerminal(cols: 20, rows: 5, scrollback: 100, compact: true)
        let plain = makeTerminal(cols: 20, rows: 5, scrollback: 100, compact: false)
        let text = (0..<1000).map { "row \($0)\r\n" }.joined()
        packed.feed(text: text)
        plain.feed(text: text)
        let buffer = packed.normalBuffer
        #expect(buffer.lines.count == 105)
        #expect(buffer.linesTop == plain.normalBuffer.linesTop)
        #expect(buffer.linesTop > 800)
        let first = buffer.lines[0].translateToString(trimRight: true)
        #expect(first == plain.normalBuffer.lines[0].translateToString(trimRight: true))
        #expect(first == "row \(1001 - 105)")
        #expect(snapshot(packed.normalBuffer) == snapshot(plain.normalBuffer))
    }

    @Test func readingAllTheHistoryNeverKeepsMoreThanTheRingUnpacked() {
        let terminal = makeTerminal(cols: 80, rows: 24, scrollback: 5000, compact: true)
        terminal.feed(text: output(lines: 6000, seed: 9))
        let buffer = terminal.normalBuffer
        var text = ""
        for index in 0..<buffer.lines.count {
            text += buffer.lines[index].translateToString(trimRight: true) + "\n"
        }
        #expect(text.contains("line5999"))
        let unpackedHistory = (0..<buffer.yBase).filter { !buffer.lines[$0].isPacked }.count
        // The ring is max (512, 4 * rows) lines, and the test reads one more line while counting.
        #expect(unpackedHistory <= 512 + 1)
    }

    @Test func readingTheHistoryAgainAfterTheRingWrappedGivesTheSameText() {
        let packed = makeTerminal(cols: 60, rows: 24, scrollback: 3000, compact: true)
        let plain = makeTerminal(cols: 60, rows: 24, scrollback: 3000, compact: false)
        let text = output(lines: 3500, seed: 77)
        packed.feed(text: text)
        plain.feed(text: text)
        let buffer = packed.normalBuffer
        let expected = (0..<plain.normalBuffer.lines.count).map {
            plain.normalBuffer.lines[$0].translateToString()
        }
        for round in 0..<3 {
            let read = (0..<buffer.lines.count).map { buffer.lines[$0].translateToString() }
            #expect(read == expected, "round \(round)")
            // Lines that are packed again while the ring still remembers them.
            buffer.packHistory()
            let backwards = (0..<buffer.lines.count).reversed().map { buffer.lines[$0].translateToString() }
            #expect(backwards.reversed() == expected, "backwards \(round)")
        }
    }

    @Test func writingToAPackedLineUnpacksIt() {
        let terminal = makeTerminal(cols: 20, rows: 3, scrollback: 50, compact: true)
        terminal.feed(text: "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n")
        let buffer = terminal.normalBuffer
        let line = buffer.lines[0]
        #expect(line.isPacked)
        line[0] = CharData(attribute: CharData.defaultAttr, code: 90, size: 1)
        #expect(!line.isPacked)
        #expect(line.translateToString(trimRight: true) == "Zne")
    }

    @Test func selectingAcrossTheHistoryGivesTheSameText() {
        let packed = makeTerminal(cols: 40, rows: 10, scrollback: 300, compact: true)
        let plain = makeTerminal(cols: 40, rows: 10, scrollback: 300, compact: false)
        let text = output(lines: 700, seed: 31)
        packed.feed(text: text)
        plain.feed(text: text)
        for terminal in [packed, plain] {
            terminal.userScrolling = true
        }
        let packedSelection = SelectionService(terminal: packed)
        let plainSelection = SelectionService(terminal: plain)
        packedSelection.selectAll()
        plainSelection.selectAll()
        #expect(!packedSelection.getSelectedText().isEmpty)
        #expect(packedSelection.getSelectedText() == plainSelection.getSelectedText())

        let from = Position(col: 3, row: 20)
        let to = Position(col: 17, row: packed.normalBuffer.yBase + 4)
        packedSelection.setSelection(start: from, end: to)
        plainSelection.setSelection(start: from, end: to)
        let selected = packedSelection.getSelectedText()
        #expect(selected.contains("\n"))
        #expect(selected == plainSelection.getSelectedText())

        packedSelection.selectWordOrExpression(at: Position(col: 1, row: 5), in: packed.buffer)
        plainSelection.selectWordOrExpression(at: Position(col: 1, row: 5), in: plain.buffer)
        #expect(packedSelection.getSelectedText() == plainSelection.getSelectedText())
    }

    @Test func searchingTheHistoryFindsTheSameMatches() {
        let packed = makeTerminal(cols: 50, rows: 10, scrollback: 400, compact: true)
        let plain = makeTerminal(cols: 50, rows: 10, scrollback: 400, compact: false)
        let text = output(lines: 800, seed: 41)
        packed.feed(text: text)
        plain.feed(text: text)
        let packedSearch = SearchService(terminal: packed)
        let plainSearch = SearchService(terminal: plain)
        for term in ["needle", "line700", "漢字かな", "link5"] {
            let found = packedSearch.findAll(term: term, limit: 5000)
            #expect(found == plainSearch.findAll(term: term, limit: 5000), "\(term)")
            #expect(!found.isEmpty, "\(term)")
        }
        #expect(packedSearch.findAll(term: "needle", limit: 5000).contains { $0.row < packed.normalBuffer.yBase })
    }

    @Test func hyperlinksInTheHistoryStayResolvable() {
        let terminal = makeTerminal(cols: 40, rows: 4, scrollback: 100, compact: true)
        terminal.feed(text: "\u{1b}]8;;https://example.com/old\u{07}old link\u{1b}]8;;\u{07}\r\n")
        for index in 0..<30 { terminal.feed(text: "filler \(index)\r\n") }
        let buffer = terminal.normalBuffer
        #expect(buffer.lines[0].isPacked)
        terminal.garbageCollectPayload()
        let cell = buffer.lines[0][0]
        #expect(cell.hasPayload)
        #expect("\(String(describing: cell.getPayload()))".contains("https://example.com/old"))
    }

    @Test func collectingPayloadsDoesNotUnpackTheHistory() {
        let terminal = makeTerminal(cols: 40, rows: 4, scrollback: 200, compact: true)
        terminal.feed(text: output(lines: 150, seed: 7))
        let buffer = terminal.normalBuffer
        let before = packedLineCount(buffer)
        terminal.garbageCollectPayload()
        #expect(packedLineCount(buffer) == before)
    }

    @Test func clearingTheScrollbackLeavesTheScreen() {
        let terminal = makeTerminal(cols: 30, rows: 4, scrollback: 100, compact: true)
        terminal.feed(text: output(lines: 80, seed: 2))
        let screen = (0..<4).map { terminal.normalBuffer.lines[terminal.normalBuffer.yBase + $0].translateToString() }
        terminal.normalBuffer.clearScrollback()
        #expect(terminal.normalBuffer.yBase == 0)
        let after = (0..<4).map { terminal.normalBuffer.lines[$0].translateToString() }
        #expect(after == screen)
    }

    @Test func changingTheHistorySizeKeepsTheLines() {
        let packed = makeTerminal(cols: 30, rows: 4, scrollback: 300, compact: true)
        let plain = makeTerminal(cols: 30, rows: 4, scrollback: 300, compact: false)
        let text = output(lines: 250, seed: 17)
        packed.feed(text: text)
        plain.feed(text: text)
        for size in [100, 600, 150] {
            packed.changeHistorySize(size)
            plain.changeHistorySize(size)
            #expect(snapshot(packed.normalBuffer) == snapshot(plain.normalBuffer), "\(size)")
        }
    }

    @Test func theAlternateScreenHasNoHistory() {
        let terminal = makeTerminal(cols: 30, rows: 5, scrollback: 100, compact: true)
        terminal.feed(text: "\u{1b}[?1049h")
        terminal.feed(text: output(lines: 40, seed: 4))
        #expect(packedLineCount(terminal.altBuffer) == 0)
    }
}
