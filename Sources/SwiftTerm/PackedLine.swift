//
//  PackedLine.swift
//
//  A compact form for the cells of a line that has left the screen.
//
//  A `BufferLine` keeps one `CharData` per column, which is 26 bytes a cell. With a long scrollback
//  that is most of the memory a terminal uses, and most of it holds the same few values: ASCII
//  text, a handful of attributes and blanks to the end of the row. A line that has scrolled off the
//  top of the screen is therefore stored as `PackedCells` and expanded again, whole, the first time
//  something reads or writes one of its cells (see `BufferLine` and `Buffer.noteUnpacked`).
//
//  The layout is a text stream followed by a run stream, both read from the front:
//
//      varint   length of the text stream in bytes
//      text     one entry per cell, run length coded:
//                 0x00...0x7f   a cell with that ASCII code and width 1
//                 0x80          any other cell: varint code (as UInt32), one byte of width
//                 0x81          varint n: the previous cell again, n more times
//      runs     until the cell count is reached, one entry per run of cells that share an
//               attribute, a payload atom and a semantic role:
//                 varint   the number of cells of the run
//                 byte     flags: bits 0-1 foreground kind, 2-3 background kind, 4 style present,
//                          5 underline present, 6 payload present, 7 semantic role present
//                 ...      the foreground and background value (1 byte for a palette index, 3 for
//                          a true colour, none for a default), then, when present, the style byte,
//                          the underline style byte and colour, the 16-bit payload atom and the
//                          semantic role byte
//
//  The cell count is the line's width, which the line keeps, so the stream needs no terminator.
//  Everything a `CharData` holds is stored, so unpacking gives back the same cells.
//

import Foundation

enum PackedCells {
    private static let wideCell: UInt8 = 0x80
    private static let repeatCell: UInt8 = 0x81

    private enum ColorKind: UInt8 {
        case ansi256 = 0
        case trueColor = 1
        case defaultColor = 2
        case defaultInvertedColor = 3
    }

    private struct RunKey: Equatable {
        var attribute: Attribute
        var payload: UInt16
        var semantic: UInt8

        init(_ cell: CharData) {
            attribute = cell.attribute
            payload = cell.payload.code
            semantic = cell.rawSemanticContentCode
        }
    }

    // MARK: Writing

    private static func put(varint value: UInt64, to out: inout [UInt8]) {
        var value = value
        while value >= 0x80 {
            out.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
    }

    private static func kind(of color: Attribute.Color) -> ColorKind {
        switch color {
        case .ansi256: return .ansi256
        case .trueColor: return .trueColor
        case .defaultColor: return .defaultColor
        case .defaultInvertedColor: return .defaultInvertedColor
        }
    }

    private static func putValue(of color: Attribute.Color, to out: inout [UInt8]) {
        switch color {
        case .ansi256(let code):
            out.append(code)
        case .trueColor(let red, let green, let blue):
            out.append(red)
            out.append(green)
            out.append(blue)
        case .defaultColor, .defaultInvertedColor:
            break
        }
    }

    private static func put(run key: RunKey, length: Int, to out: inout [UInt8]) {
        let attribute = key.attribute
        let hasUnderline = attribute.underlineStyle != .none || attribute.underlineColor != nil
        var flags = kind(of: attribute.fg).rawValue | kind(of: attribute.bg).rawValue << 2
        if attribute.style.rawValue != 0 { flags |= 0x10 }
        if hasUnderline { flags |= 0x20 }
        if key.payload != 0 { flags |= 0x40 }
        if key.semantic != 0 { flags |= 0x80 }
        put(varint: UInt64(length), to: &out)
        out.append(flags)
        putValue(of: attribute.fg, to: &out)
        putValue(of: attribute.bg, to: &out)
        if attribute.style.rawValue != 0 {
            out.append(attribute.style.rawValue)
        }
        if hasUnderline {
            out.append(attribute.underlineStyle.rawValue)
            if let color = attribute.underlineColor {
                out.append(kind(of: color).rawValue + 1)
                putValue(of: color, to: &out)
            } else {
                out.append(0)
            }
        }
        if key.payload != 0 {
            out.append(UInt8(truncatingIfNeeded: key.payload))
            out.append(UInt8(truncatingIfNeeded: key.payload >> 8))
        }
        if key.semantic != 0 {
            out.append(key.semantic)
        }
    }

    /// Returns the packed form of `cells`, in memory the caller frees with `deallocate()`.
    static func pack(_ cells: UnsafeBufferPointer<CharData>) -> UnsafeMutablePointer<UInt8> {
        var text = [UInt8]()
        text.reserveCapacity(cells.count + 8)
        var runs = [UInt8]()
        runs.reserveCapacity(16)

        func putCell(_ cell: CharData) {
            if cell.code >= 0 && cell.code < 0x80 && cell.width == 1 {
                text.append(UInt8(cell.code))
            } else {
                text.append(wideCell)
                put(varint: UInt64(UInt32(bitPattern: cell.code)), to: &text)
                text.append(UInt8(bitPattern: cell.width))
            }
        }

        var index = 0
        while index < cells.count {
            let cell = cells[index]
            var same = 0
            while index + 1 + same < cells.count,
                cells[index + 1 + same].code == cell.code,
                cells[index + 1 + same].width == cell.width
            {
                same += 1
            }
            putCell(cell)
            if same >= 2 {
                text.append(repeatCell)
                put(varint: UInt64(same), to: &text)
            } else if same == 1 {
                putCell(cell)
            }
            index += 1 + same
        }

        var runStart = 0
        var key = RunKey(cells.isEmpty ? CharData.Null : cells[0])
        for index in 1..<max(cells.count, 1) {
            let next = RunKey(cells[index])
            if next != key {
                put(run: key, length: index - runStart, to: &runs)
                runStart = index
                key = next
            }
        }
        put(run: key, length: cells.count - runStart, to: &runs)

        var header = [UInt8]()
        put(varint: UInt64(text.count), to: &header)
        let blob = UnsafeMutablePointer<UInt8>.allocate(capacity: header.count + text.count + runs.count)
        header.withUnsafeBufferPointer { blob.update(from: $0.baseAddress!, count: header.count) }
        text.withUnsafeBufferPointer {
            (blob + header.count).update(from: $0.baseAddress!, count: text.count)
        }
        runs.withUnsafeBufferPointer {
            (blob + header.count + text.count).update(from: $0.baseAddress!, count: runs.count)
        }
        return blob
    }

    // MARK: Reading

    private static func varint(_ blob: UnsafePointer<UInt8>, _ offset: inout Int) -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = blob[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return value }
            shift += 7
        }
    }

    private static func color(_ kind: UInt8, _ blob: UnsafePointer<UInt8>, _ offset: inout Int)
        -> Attribute.Color
    {
        switch ColorKind(rawValue: kind) ?? .defaultColor {
        case .ansi256:
            offset += 1
            return .ansi256(code: blob[offset - 1])
        case .trueColor:
            offset += 3
            return .trueColor(red: blob[offset - 3], green: blob[offset - 2], blue: blob[offset - 1])
        case .defaultColor:
            return .defaultColor
        case .defaultInvertedColor:
            return .defaultInvertedColor
        }
    }

    /// Reads the runs, calling `visit` with the first cell, the number of cells, the attribute, the
    /// payload atom and the semantic role of each.
    @discardableResult
    private static func forEachRun(
        _ blob: UnsafePointer<UInt8>, count: Int,
        _ visit: (Int, Int, Attribute, UInt16, UInt8) -> Void
    ) -> Int {
        var offset = 0
        let textLength = Int(varint(blob, &offset))
        offset += textLength
        var cell = 0
        while cell < count {
            let length = Int(varint(blob, &offset))
            let flags = blob[offset]
            offset += 1
            let fg = color(flags & 3, blob, &offset)
            let bg = color(flags >> 2 & 3, blob, &offset)
            var style = CharacterStyle.none
            if flags & 0x10 != 0 {
                style = CharacterStyle(rawValue: blob[offset])
                offset += 1
            }
            var underlineStyle = UnderlineStyle.none
            var underlineColor: Attribute.Color? = nil
            if flags & 0x20 != 0 {
                underlineStyle = UnderlineStyle(rawValue: blob[offset]) ?? .none
                let kind = blob[offset + 1]
                offset += 2
                if kind != 0 {
                    underlineColor = color(kind - 1, blob, &offset)
                }
            }
            var payload: UInt16 = 0
            if flags & 0x40 != 0 {
                payload = UInt16(blob[offset]) | UInt16(blob[offset + 1]) << 8
                offset += 2
            }
            var semantic: UInt8 = 0
            if flags & 0x80 != 0 {
                semantic = blob[offset]
                offset += 1
            }
            let attribute = Attribute(
                fg: fg, bg: bg, style: style, underlineStyle: underlineStyle,
                underlineColor: underlineColor)
            visit(cell, length, attribute, payload, semantic)
            cell += length
        }
        return offset
    }

    /// The number of bytes of the packed form of `count` cells.
    static func byteCount(_ blob: UnsafePointer<UInt8>, count: Int) -> Int {
        forEachRun(blob, count: count) { _, _, _, _, _ in }
    }

    /// Writes the `count` cells of `blob` to `cells`, which holds no initialized cell yet.
    static func unpack(
        _ blob: UnsafePointer<UInt8>, count: Int, into cells: UnsafeMutablePointer<CharData>
    ) {
        var offset = 0
        let textEnd = Int(varint(blob, &offset)) + offset
        var cell = 0
        var previous = CharData.Null
        while offset < textEnd {
            let byte = blob[offset]
            offset += 1
            switch byte {
            case wideCell:
                let code = Int32(bitPattern: UInt32(truncatingIfNeeded: varint(blob, &offset)))
                let width = Int8(bitPattern: blob[offset])
                offset += 1
                previous = CharData(attribute: CharData.defaultAttr, code: code, size: width)
                (cells + cell).initialize(to: previous)
                cell += 1
            case repeatCell:
                let repeats = Int(varint(blob, &offset))
                for _ in 0..<repeats {
                    (cells + cell).initialize(to: previous)
                    cell += 1
                }
            default:
                previous = CharData(attribute: CharData.defaultAttr, code: Int32(byte), size: 1)
                (cells + cell).initialize(to: previous)
                cell += 1
            }
        }
        forEachRun(blob, count: count) { first, length, attribute, payload, semantic in
            for index in first..<first + length {
                cells[index].attribute = attribute
                if payload != 0 {
                    cells[index].setPayload(atom: TinyAtom(code: payload))
                }
                cells[index].rawSemanticContentCode = semantic
            }
        }
    }

    /// Adds the payload atoms of the `count` cells of `blob` to `used`, without unpacking them.
    static func collectPayloadCodes(
        _ blob: UnsafePointer<UInt8>, count: Int, into used: inout Set<UInt16>
    ) {
        var found = Set<UInt16>()
        forEachRun(blob, count: count) { _, _, _, payload, _ in
            if payload != 0 { found.insert(payload) }
        }
        used.formUnion(found)
    }
}
