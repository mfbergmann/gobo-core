// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import GoboCore

@Suite("Purge")
struct PurgeTests {
    @Test("Purge deletes only marked events, across versions, and spares everything else")
    func purgeScope() throws {
        let s = Scenario()
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        try s.sync()
        s.store.seedEvent(
            id: "user-own", calendarID: s.work.id, title: "Busy",
            start: at(2026, 6, 18, 9, 0), end: at(2026, 6, 18, 10, 0)
        )
        s.store.seedEvent(
            id: "old-version", calendarID: s.work.id, title: "Busy",
            start: at(2026, 6, 19, 9, 0), end: at(2026, 6, 19, 10, 0),
            notes: "busysync:v2:deadbeef"
        )
        let purge = try s.engine.purgePlan(
            calendarIDs: [s.work.id],
            from: at(2026, 1, 1), to: at(2027, 1, 1)
        )
        #expect(purge.deletes.count == 2)
        #expect(purge.deletes.allSatisfy { $0.reason == .purged })
        #expect(purge.creates.isEmpty && purge.updates.isEmpty)
        try s.engine.apply(purge)
        #expect(s.store.markedEvents(inCalendar: s.work.id).isEmpty)
        #expect(s.store.event(id: "user-own") != nil)
        #expect(s.store.event(id: "old-version") == nil)
    }

    @Test("Purge deletes a user-made recurring mirror as one whole series")
    func purgeRecurringSeries() throws {
        let s = Scenario()
        let phantom = SourceEvent(
            eventIdentifier: "phantom", calendarID: s.personal.id,
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        let notes = MirrorIdentity.canonicalNotes(marker: MirrorIdentity.marker(for: phantom))
        for (index, day) in [16, 23, 30].enumerated() {
            s.store.seedEvent(
                id: "rec-\(index)", eventIdentifier: "recurring-mirror",
                calendarID: s.work.id, title: "Busy",
                start: at(2026, 6, day, 9, 0), end: at(2026, 6, day, 10, 0),
                occurrenceDate: at(2026, 6, day, 9, 0),
                notes: notes
            )
        }
        // An unmarked recurring event must survive the purge untouched.
        for (index, day) in [17, 24].enumerated() {
            s.store.seedEvent(
                id: "user-rec-\(index)", eventIdentifier: "user-standup",
                calendarID: s.work.id, title: "Standup",
                start: at(2026, 6, day, 9, 0), end: at(2026, 6, day, 9, 15),
                occurrenceDate: at(2026, 6, day, 9, 0)
            )
        }
        let purge = try s.engine.purgePlan(
            calendarIDs: [s.work.id],
            from: at(2026, 1, 1), to: at(2027, 1, 1)
        )
        #expect(purge.deletes.count == 1)
        #expect(purge.deletes.first?.scope == .series)
        try s.engine.apply(purge)
        #expect(s.store.events(inCalendar: s.work.id).allSatisfy { $0.eventIdentifier == "user-standup" })
        #expect(s.store.events(inCalendar: s.work.id).count == 2)
    }

    @Test("Purge does not read calendars outside the requested set")
    func purgeStaysInLane() throws {
        let s = Scenario()
        let phantom = SourceEvent(
            eventIdentifier: "elsewhere", calendarID: s.personal.id,
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        s.store.seedEvent(
            id: "marked-elsewhere", calendarID: s.medical.id, title: "Busy",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0),
            notes: MirrorIdentity.canonicalNotes(marker: MirrorIdentity.marker(for: phantom))
        )
        let purge = try s.engine.purgePlan(
            calendarIDs: [s.work.id],
            from: at(2026, 1, 1), to: at(2027, 1, 1)
        )
        #expect(purge.deletes.isEmpty)
        #expect(s.store.event(id: "marked-elsewhere") != nil)
    }
}

@Suite("Apply semantics")
struct ApplySemanticsTests {
    /// Builds a store state whose next plan holds one delete, one update,
    /// and one create, so a failure at any operation kind exercises rollback
    /// with earlier writes already staged.
    private func stagedScenario() throws -> Scenario {
        let s = Scenario(buffers: BufferSettings(beforeMinutes: 0, afterMinutes: 0))
        s.store.seedEvent(
            id: "src-keep", calendarID: s.personal.id, title: "Keep, but move",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        s.store.seedEvent(
            id: "src-gone-later", calendarID: s.personal.id, title: "Will vanish",
            start: at(2026, 6, 17, 9, 0), end: at(2026, 6, 17, 10, 0)
        )
        try s.sync()
        s.store.removeEvent(id: "src-gone-later")
        let moved = s.store.event(id: "src-keep")!
        s.store.removeEvent(id: "src-keep")
        s.store.seedEvent(
            id: "src-keep", calendarID: moved.calendarID, title: moved.title,
            start: moved.start.addingTimeInterval(1800), end: moved.end.addingTimeInterval(1800)
        )
        s.store.seedEvent(
            id: "src-new", calendarID: s.personal.id, title: "Brand new",
            start: at(2026, 6, 18, 9, 0), end: at(2026, 6, 18, 10, 0)
        )
        return s
    }

    @Test(
        "A failure at any operation kind rolls back and leaves the target unchanged",
        arguments: ["delete", "update", "create", "commit"]
    )
    func rollbackOnFailure(failingOp: String) throws {
        let s = try stagedScenario()
        let stateBefore = s.store.markedEvents(inCalendar: s.work.id)
            .map { "\($0.id)|\($0.start.timeIntervalSinceReferenceDate)|\($0.notes ?? "")" }
        let commitsBefore = s.store.commitCount
        s.store.failOn = [failingOp]
        let plan = try s.plan()
        #expect(plan.deletes.count == 1 && plan.updates.count == 1 && plan.creates.count == 1)
        #expect(throws: ApplyError.self) {
            try s.engine.apply(plan)
        }
        #expect(s.store.rollbackCount == 1)
        #expect(s.store.commitCount == commitsBefore)
        let stateAfter = s.store.markedEvents(inCalendar: s.work.id)
            .map { "\($0.id)|\($0.start.timeIntervalSinceReferenceDate)|\($0.notes ?? "")" }
        #expect(stateAfter == stateBefore)
        // With the failure cleared, the same state syncs cleanly.
        s.store.failOn = []
        try s.sync()
        #expect(try s.plan().isEmpty)
    }

    @Test("Creates against a since-deleted target calendar roll back prior operations")
    func missingTargetCalendarRollsBack() throws {
        let s = try stagedScenario()
        let plan = try s.plan()
        #expect(!plan.creates.isEmpty)
        // The target calendar disappears between plan and apply.
        s.store.removeCalendar(id: s.work.id)
        let stateBefore = s.store.markedEvents(inCalendar: s.work.id).map(\.id)
        #expect(throws: ApplyError.self) {
            try s.engine.apply(plan)
        }
        #expect(s.store.rollbackCount == 1)
        #expect(s.store.markedEvents(inCalendar: s.work.id).map(\.id) == stateBefore)
    }

    @Test("Deletes run before updates before creates, then a single commit")
    func operationOrder() throws {
        let s = Scenario(buffers: BufferSettings(beforeMinutes: 0, afterMinutes: 0))
        // One of each kind of change.
        s.store.seedEvent(
            id: "src-keep", calendarID: s.personal.id, title: "Keep, but move",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        s.store.seedEvent(
            id: "src-gone-later", calendarID: s.personal.id, title: "Will vanish",
            start: at(2026, 6, 17, 9, 0), end: at(2026, 6, 17, 10, 0)
        )
        try s.sync()
        s.store.removeEvent(id: "src-gone-later")
        let moved = s.store.event(id: "src-keep")!
        s.store.removeEvent(id: "src-keep")
        s.store.seedEvent(
            id: "src-keep", calendarID: moved.calendarID, title: moved.title,
            start: moved.start.addingTimeInterval(1800), end: moved.end.addingTimeInterval(1800)
        )
        s.store.seedEvent(
            id: "src-new", calendarID: s.personal.id, title: "Brand new",
            start: at(2026, 6, 18, 9, 0), end: at(2026, 6, 18, 10, 0)
        )
        let marker = s.store.opLog.count
        try s.sync()
        let ops = s.store.opLog[marker...].map { $0.split(separator: " ").first.map(String.init) ?? "" }
        #expect(ops == ["delete", "update", "create", "commit"])
    }
}
