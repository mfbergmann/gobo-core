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
    @Test("A failure mid-apply rolls back and leaves the target unchanged")
    func rollbackOnFailure() throws {
        let s = Scenario()
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        try s.sync()
        // Now stage a second change and make creates fail.
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Physio",
            start: at(2026, 6, 17, 9, 0), end: at(2026, 6, 17, 10, 0)
        )
        let mirrorsBefore = s.store.markedEvents(inCalendar: s.work.id)
        s.store.failOn = ["create"]
        let plan = try s.plan()
        #expect(plan.creates.count == 1)
        #expect(throws: ApplyError.self) {
            try s.engine.apply(plan)
        }
        #expect(s.store.rollbackCount == 1)
        #expect(s.store.commitCount == 1) // only the first sync's commit
        let mirrorsAfter = s.store.markedEvents(inCalendar: s.work.id)
        #expect(mirrorsAfter.map(\.id) == mirrorsBefore.map(\.id))
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
