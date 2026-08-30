// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import GoboCore

@Suite("Windows and DST")
struct WindowAndDSTTests {
    @Test("Events outside the window are ignored; straddlers are included")
    func windowEdges() throws {
        var s = Scenario(buffers: BufferSettings(beforeMinutes: 0, afterMinutes: 0))
        s.rule.windowDaysBack = 1
        s.rule.windowDaysAhead = 7
        // Window: June 14 12:00 .. June 22 12:00.
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Too old",
            start: at(2026, 6, 13, 9, 0), end: at(2026, 6, 13, 10, 0)
        )
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Straddles window start",
            start: at(2026, 6, 14, 11, 0), end: at(2026, 6, 14, 13, 0)
        )
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Comfortably inside",
            start: at(2026, 6, 18, 9, 0), end: at(2026, 6, 18, 10, 0)
        )
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Straddles window end",
            start: at(2026, 6, 22, 11, 0), end: at(2026, 6, 22, 13, 0)
        )
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Too far out",
            start: at(2026, 6, 25, 9, 0), end: at(2026, 6, 25, 10, 0)
        )
        let plan = try s.plan()
        #expect(plan.creates.map(\.sourceTitle) == [
            "Straddles window start", "Comfortably inside", "Straddles window end",
        ])
    }

    @Test("The target is read wider than the source window, so drifted mirrors reconcile")
    func targetMargin() throws {
        var s = Scenario()
        s.rule.windowDaysBack = 1
        s.rule.windowDaysAhead = 7
        // An orphaned mirror one day past the window end: outside the source
        // window, inside the widened target read.
        let ghost = SourceEvent(
            eventIdentifier: "ghost", calendarID: s.personal.id,
            start: at(2026, 6, 23, 9, 0), end: at(2026, 6, 23, 10, 0)
        )
        s.store.seedEvent(
            id: "drifted", calendarID: s.work.id, title: "Busy",
            start: at(2026, 6, 23, 9, 0), end: at(2026, 6, 23, 10, 0),
            notes: MirrorIdentity.canonicalNotes(marker: MirrorIdentity.marker(for: ghost))
        )
        // A much older mirror far outside even the margin stays untouched.
        let ancient = SourceEvent(
            eventIdentifier: "ancient", calendarID: s.personal.id,
            start: at(2026, 5, 1, 9, 0), end: at(2026, 5, 1, 10, 0)
        )
        s.store.seedEvent(
            id: "ancient-mirror", calendarID: s.work.id, title: "Busy",
            start: at(2026, 5, 1, 9, 0), end: at(2026, 5, 1, 10, 0),
            notes: MirrorIdentity.canonicalNotes(marker: MirrorIdentity.marker(for: ancient))
        )
        let plan = try s.plan()
        #expect(plan.deletes.map(\.mirrorID) == ["drifted"])
        try s.engine.apply(plan)
        #expect(s.store.event(id: "ancient-mirror") != nil)
    }

    @Test("Buffers stay absolute across the spring-forward gap")
    func springForward() throws {
        // America/Toronto springs forward 2026-03-08 02:00 -> 03:00.
        let s = Scenario(buffers: BufferSettings(applyOnlyWhenLocationPresent: false, beforeMinutes: 20, afterMinutes: 20))
        let start = at(2026, 3, 8, 1, 30)
        let end = at(2026, 3, 8, 3, 30) // 1 wall-clock gap hour inside
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Overnight shift",
            start: start, end: end
        )
        let plan = try s.plan(now: at(2026, 3, 7, 12, 0))
        let create = try #require(plan.creates.first)
        #expect(create.spec.start == start.addingTimeInterval(-1200))
        #expect(create.spec.end == end.addingTimeInterval(1200))
        // The absolute duration is event + 40 min, regardless of wall clocks.
        #expect(create.spec.end.timeIntervalSince(create.spec.start)
            == end.timeIntervalSince(start) + 2400)
    }

    @Test("Fall-back day events mirror by absolute time")
    func fallBack() throws {
        // America/Toronto falls back 2026-11-01 02:00 -> 01:00.
        let s = Scenario(buffers: BufferSettings(beforeMinutes: 0, afterMinutes: 0))
        let start = at(2026, 11, 1, 0, 30)
        let end = start.addingTimeInterval(3 * 3600) // crosses the repeated hour
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Late night",
            start: start, end: end
        )
        let plan = try s.plan(now: at(2026, 10, 31, 12, 0))
        let create = try #require(plan.creates.first)
        #expect(create.spec.start == start)
        #expect(create.spec.end == end)
        try s.engine.apply(plan)
        #expect(try s.plan(now: at(2026, 10, 31, 12, 0)).isEmpty)
    }

    @Test("Window boundaries computed across a DST transition stay on local wall clock")
    func windowAcrossDST() throws {
        var s = Scenario()
        s.rule.windowDaysBack = 0
        s.rule.windowDaysAhead = 2
        let now = at(2026, 3, 7, 12, 0) // day before spring-forward
        // Window end should be March 9 12:00 local (67 absolute hours, not 72).
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Just inside",
            start: at(2026, 3, 9, 10, 0), end: at(2026, 3, 9, 11, 0)
        )
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Just outside",
            start: at(2026, 3, 9, 13, 0), end: at(2026, 3, 9, 14, 0)
        )
        let plan = try s.plan(now: now)
        #expect(plan.creates.map(\.sourceTitle) == ["Just inside"])
    }

    @Test("All-day events across DST mirror as all-day with identical dates")
    func allDayAcrossDST() throws {
        let s = Scenario(filters: FilterSettings(skipAllDay: false))
        // All-day on the spring-forward day is 23 absolute hours.
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Spring workshop",
            start: at(2026, 3, 8), end: at(2026, 3, 9), isAllDay: true
        )
        let plan = try s.plan(now: at(2026, 3, 7, 12, 0))
        let create = try #require(plan.creates.first)
        #expect(create.spec.isAllDay)
        #expect(create.spec.start == at(2026, 3, 8))
        #expect(create.spec.end == at(2026, 3, 9))
        try s.engine.apply(plan)
        #expect(try s.plan(now: at(2026, 3, 7, 12, 0)).isEmpty)
    }
}
