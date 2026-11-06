//
//  CompactScrollbackFuzzTests.swift
//
//  Random output, resizes, history size changes and reads, fed to a terminal that packs the
//  scrollback and to one that does not, which have to stay the same cell for cell. The output has
//  colours, wide and combining characters, links, prompts, the alternate screen, scrolling regions
//  and left and right margins. It found the margin scroll bug that MarginLineScrollTests covers.
//  A few seeds run by default; FUZZ_SEEDS=41-340 runs others, and FUZZ_PLAIN=1 turns the packing
//  off in both terminals, to look for crashes of the library itself.
//

import Foundation
import Testing

@testable import SwiftTerm

private func desc(_ cell: CharData) -> String {
    let payload = cell.getPayload().map { String(describing: $0) } ?? "-"
    let a = cell.attribute
    return "\(cell.code)/\(cell.width)/\(a.fg)/\(a.bg)/\(a.style.rawValue)/\(a.underlineStyle)/\(String(describing: a.underlineColor))/\(payload)/\(cell.rawSemanticContentCode)"
}

private func snap(_ buffer: Buffer) -> [String] {
    var rows = ["count=\(buffer.lines.count) yBase=\(buffer.yBase) yDisp=\(buffer.yDisp) top=\(buffer.linesTop)"]
    for index in 0..<buffer.lines.count {
        let line = buffer.lines[index]
        var row = "\(index) w=\(line.isWrapped) n=\(line.count) "
        for column in 0..<line.count { row += desc(line[column]) + "|" }
        rows.append(row)
    }
    return rows
}

private struct Rng {
    var s: UInt64
    mutating func next(_ b: Int) -> Int {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Int((s >> 33) % UInt64(b))
    }
}

private let frags: [String] = [
    "hello", "漢字", "🙂", "👍🏽", "e\u{301}", "a\u{200d}b", "\r\n", "\r\n", "\r\n", "\n", "\t", "\u{8}",
    "\u{1b}[0m", "\u{1b}[1m", "\u{1b}[4:3m", "\u{1b}[58;5;12m", "\u{1b}[31m", "\u{1b}[48;2;1;2;3m",
    "\u{1b}[7m", "\u{1b}]8;;http://a/b\u{07}", "\u{1b}]8;id=1;http://c/d\u{1b}\\", "\u{1b}]8;;\u{07}",
    "\u{1b}]133;A\u{07}", "\u{1b}]133;B\u{07}", "\u{1b}]133;C\u{07}", "\u{1b}]133;D\u{07}",
    "\u{1b}[2J", "\u{1b}[H", "\u{1b}[3J", "\u{1b}[5;10r", "\u{1b}[r", "\u{1b}[?69l", "\u{1b}[?69h", "\u{1b}[3;12s", "\u{1b}[s", "\u{1b}[2;9s",
    "\u{1b}[3@", "\u{1b}[2P", "\u{1b}[2L", "\u{1b}[2M", "\u{1b}[3S", "\u{1b}[3T", "\u{1b}M", "\u{1b}D", "\u{1b}E",
    "\u{1b}[?1049h", "\u{1b}[?1049l", "\u{1b}[?47h", "\u{1b}[?47l", "\u{1b}[?7l", "\u{1b}[?7h", "\u{1b}[4h", "\u{1b}[4l",
    "\u{1b}[10;20H", "\u{1b}[K", "\u{1b}[1K", "\u{1b}[2K", "\u{1b}[J", "\u{1b}[1J", "\u{1b}[5X", "\u{1b}[10b",
    "\u{1b}#8", "\u{1b}#3", "\u{1b}#4", "\u{1b}#6", "\u{1b}c", "\u{1b}[!p", "\u{1b}7", "\u{1b}8",
    "wide\u{ff21}\u{ff22}", "abcdefghijklmnopqrstuvwxyz0123456789", "\u{1b}[38;5;200m", "\u{1b}[39m", "\u{1b}[49m",
]

/// Left and right margins (DECLRMM and DECSLRM), which the other fragments leave to chance.
private let marginFrags: [String] = [
    "\u{1b}[?69h", "\u{1b}[?69h", "\u{1b}[?69l", "\u{1b}[2;9s", "\u{1b}[3;40s", "\u{1b}[1;5s",
    "\u{1b}[7;20s", "\u{1b}[5;5s", "\u{1b}[s", "\u{1b}[2M", "\u{1b}[3L", "\u{1b}[4P", "\u{1b}[2@",
    "\u{1b}[1M", "\u{1b}[M", "\u{1b}[3;6r", "\u{1b}[r", "\u{1b}[4;4H", "\u{1b}[20;70H",
]

private func bytes(_ rng: inout Rng, count: Int) -> [UInt8] {
    var out = [UInt8]()
    for _ in 0..<count {
        let r = rng.next(100)
        if r < 55 {
            out += Array(frags[rng.next(frags.count)].utf8)
        } else if r < 80 {
            out += Array(marginFrags[rng.next(marginFrags.count)].utf8)
        } else if r < 90 {
            out.append(UInt8(rng.next(256)))   // raw garbage
        } else {
            out += Array("line \(rng.next(100000)) ".utf8) + [13, 10]
        }
    }
    return out
}

private func make(cols: Int, rows: Int, scrollback: Int, compact: Bool) -> Terminal {
    let (t, _) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows, scrollback: scrollback)
    let c = compact && ProcessInfo.processInfo.environment["FUZZ_PLAIN"] == nil
    t.normalBuffer.compactsHistory = c
    t.altBuffer.compactsHistory = c
    return t
}

final class CompactScrollbackFuzzTests {
    /// A short pass of seeded runs. FUZZ_SEEDS=a-b runs another range, for a longer look.
    private var seeds: ClosedRange<Int> {
        let parts = (ProcessInfo.processInfo.environment["FUZZ_SEEDS"] ?? "1-4").split(separator: "-")
        guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) else { return 1...4 }
        return low...high
    }

    @Test func fuzzPackedEqualsPlain() {
        var failures = 0
        for seed in seeds {
            var rng = Rng(s: UInt64(seed) &* 7919)
            let cols = 5 + rng.next(60), rows = 2 + rng.next(20), sb = 1 + rng.next(200)
            let plain = make(cols: cols, rows: rows, scrollback: sb, compact: false)
            let packed = make(cols: cols, rows: rows, scrollback: sb, compact: true)
            var step = 0
            while step < 120 {
                step += 1
                if step == 1 { FileHandle.standardError.write(Data("SEED \(seed)\n".utf8)) }
                switch rng.next(12) {
                case 0:
                    let c = 3 + rng.next(80), r = 1 + rng.next(30)
                    plain.resize(cols: c, rows: r); packed.resize(cols: c, rows: r)
                case 1:
                    let n = rng.next(300)
                    plain.changeHistorySize(n); packed.changeHistorySize(n)
                case 2:
                    plain.garbageCollectPayload(); packed.garbageCollectPayload()
                case 3:
                    // read random lines (mixes the ring)
                    for _ in 0..<20 {
                        let b = packed.normalBuffer
                        if b.lines.count > 0 { _ = b.lines[rng.next(b.lines.count)].translateToString() }
                    }
                case 4:
                    let b = packed.buffer
                    let d = rng.next(40) - 20
                    packed.buffer.yDisp = max(0, min(b.yBase, b.yDisp + d))
                    plain.buffer.yDisp = packed.buffer.yDisp
                default:
                    let data = bytes(&rng, count: 1 + rng.next(30))
                    var rest = data[...]
                    while !rest.isEmpty {
                        let n = min(rest.count, 1 + rng.next(50))
                        plain.feed(buffer: rest.prefix(n)); packed.feed(buffer: rest.prefix(n))
                        rest = rest.dropFirst(n)
                    }
                }
                if step % 7 == 0 {
                    let a = snap(plain.normalBuffer), b = snap(packed.normalBuffer)
                    if a != b {
                        failures += 1
                        let i = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
                        Issue.record("seed \(seed) step \(step) normal buffers differ at row \(i) (\(a.count)/\(b.count))")
                        break
                    }
                    let a2 = snap(plain.altBuffer), b2 = snap(packed.altBuffer)
                    if a2 != b2 { failures += 1; Issue.record("seed \(seed) step \(step) alt differ"); break }
                }
            }
        }
        #expect(failures == 0)
    }
}
