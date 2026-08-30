// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import GoboCore

@Suite("Date range chunking")
struct DateRangeChunkerTests {
    @Test("Small ranges are a single chunk")
    func singleChunk() {
        let from = at(2026, 1, 1)
        let to = at(2026, 12, 31)
        let chunks = DateRangeChunker.chunks(from: from, to: to)
        #expect(chunks == [from..<to])
    }

    @Test("Wide ranges split below EventKit's four-year cap, covering exactly, in order, without gaps")
    func wideRangeCoverage() {
        let from = at(2016, 1, 1)
        let to = at(2036, 1, 1) // 20 years
        let chunks = DateRangeChunker.chunks(from: from, to: to)
        #expect(chunks.count > 1)
        #expect(chunks.first?.lowerBound == from)
        #expect(chunks.last?.upperBound == to)
        for chunk in chunks {
            #expect(chunk.upperBound.timeIntervalSince(chunk.lowerBound) <= DateRangeChunker.maxChunkSeconds)
            #expect(chunk.upperBound.timeIntervalSince(chunk.lowerBound) < 4 * 365.25 * 86_400)
        }
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(a.upperBound == b.lowerBound)
        }
    }

    @Test("Degenerate ranges produce no chunks")
    func degenerate() {
        let now = at(2026, 6, 15)
        #expect(DateRangeChunker.chunks(from: now, to: now).isEmpty)
        #expect(DateRangeChunker.chunks(from: now, to: now.addingTimeInterval(-1)).isEmpty)
    }
}
