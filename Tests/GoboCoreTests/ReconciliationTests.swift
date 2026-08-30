// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import GoboCore

@Suite("Reconciliation")
struct ReconciliationTests {
    @Test("Unmarked events on the target are never touched, even ones titled Busy")
    func neverTouchUnmarked() throws {
        let s = Scenario()
        s.store.seedEvent(
            id: "user-busy", calendarID: s.work.id, title: "Busy",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        s.store.seedEvent(
            id: "user-prose", calendarID: s.work.id, title: "Notes mention the tool",
            start: at(2026, 6, 17, 9, 0), end: at(2026, 6, 17, 10, 0),
            notes: "talked about busysync: markers today"
        )
        // A marker-shaped line with invalid hex is not a marker.
        s.store.seedEvent(
            id: "user-nothex", calendarID: s.work.id, title: "Odd",
            start: at(2026, 6, 18, 9, 0), end: at(2026, 6, 18, 10, 0),
            notes: "busysync:v1:nothexnothexnoth"
        )
        let plan = try s.plan()
        #expect(plan.isEmpty)
        try s.engine.apply(plan)
        #expect(s.store.event(id: "user-busy") != nil)
        #expect(s.store.event(id: "user-prose") != nil)
        #expect(s.store.event(id: "user-nothex") != nil)
    }

    @Test("Orphan cleanup: a marked event with no corresponding source is deleted")
    func orphanCleanup() throws {
        let s = Scenario()
        let phantom = SourceEvent(
            eventIdentifier: "long-gone", calendarID: s.personal.id,
            start: at(2026, 6, 20, 9, 0), end: at(2026, 6, 20, 10, 0)
        )
        let marker = MirrorIdentity.marker(for: phantom)
        s.store.seedEvent(
            id: "stale-mirror", calendarID: s.work.id, title: "Busy",
            start: at(2026, 6, 20, 9, 0), end: at(2026, 6, 20, 10, 0),
            notes: MirrorIdentity.canonicalNotes(marker: marker)
        )
        let plan = try s.plan()
        #expect(plan.deletes.map(\.mirrorID) == ["stale-mirror"])
        #expect(plan.deletes.first?.reason == .orphaned)
    }

    @Test("Duplicate mirror cleanup keeps exactly one, deterministically")
    func duplicateCleanup() throws {
        let s = Scenario(buffers: BufferSettings(beforeMinutes: 0, afterMinutes: 0))
        s.store.seedEvent(
            id: "src", calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        let marker = MirrorIdentity.marker(for: s.store.event(id: "src")!.asSourceEvent())
        let notes = MirrorIdentity.canonicalNotes(marker: marker)
        for dupID in ["mirror-b", "mirror-a", "mirror-c"] {
            s.store.seedEvent(
                id: dupID, calendarID: s.work.id, title: "Busy",
                start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0),
                notes: notes
            )
        }
        let plan = try s.plan()
        #expect(plan.creates.isEmpty && plan.updates.isEmpty)
        #expect(plan.deletes.count == 2)
        #expect(Set(plan.deletes.map(\.mirrorID)) == ["mirror-b", "mirror-c"])
        #expect(plan.deletes.allSatisfy { $0.reason == .duplicate })
        try s.engine.apply(plan)
        #expect(try s.plan().isEmpty)
    }

    @Test("Events carrying multiple markers are foreign: deleted and recreated as singles")
    func multiMarkerReplaced() throws {
        let s = Scenario(buffers: BufferSettings(beforeMinutes: 0, afterMinutes: 0))
        s.store.seedEvent(
            id: "src-1", calendarID: s.personal.id, title: "A",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        s.store.seedEvent(
            id: "src-2", calendarID: s.personal.id, title: "B",
            start: at(2026, 6, 16, 9, 30), end: at(2026, 6, 16, 10, 30)
        )
        let m1 = MirrorIdentity.marker(for: s.store.event(id: "src-1")!.asSourceEvent())
        let m2 = MirrorIdentity.marker(for: s.store.event(id: "src-2")!.asSourceEvent())
        s.store.seedEvent(
            id: "merged", calendarID: s.work.id, title: "Busy",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 30),
            notes: "merged block\n\(m1.rawValue)\n\(m2.rawValue)"
        )
        let plan = try s.plan()
        #expect(plan.deletes.map(\.mirrorID) == ["merged"])
        #expect(plan.deletes.first?.reason == .multipleMarkers)
        #expect(plan.creates.count == 2)
        try s.engine.apply(plan)
        #expect(try s.plan().isEmpty)
    }

    @Test("Same physical event in two source calendars folds to one mirror covering both paddings")
    func markerCollisionUnions() throws {
        var s = Scenario(buffers: BufferSettings(
            applyOnlyWhenLocationPresent: false,
            beforeMinutes: 10, afterMinutes: 10,
            perCalendarOverrides: ["cal-medical": 30]
        ))
        s.rule.sourceCalendars = [s.personal.handle, s.medical.handle]
        // The same invitation appears in both calendars with one identifier.
        s.store.seedEvent(
            id: "copy-1", eventIdentifier: "shared-event", calendarID: s.personal.id,
            title: "Appointment", start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        s.store.seedEvent(
            id: "copy-2", eventIdentifier: "shared-event", calendarID: s.medical.id,
            title: "Appointment", start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        let plan = try s.plan()
        #expect(plan.creates.count == 1)
        let create = try #require(plan.creates.first)
        // Union of 10-minute and 30-minute paddings.
        #expect(create.spec.start == at(2026, 6, 16, 8, 30))
        #expect(create.spec.end == at(2026, 6, 16, 10, 30))
        try s.engine.apply(plan)
        #expect(try s.plan().isEmpty)
    }

    @Test("Duplicate cleanup and a keeper update in the same plan")
    func duplicateCleanupWithKeeperUpdate() throws {
        let s = Scenario(buffers: BufferSettings(beforeMinutes: 0, afterMinutes: 0))
        s.store.seedEvent(
            id: "src", calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        let marker = MirrorIdentity.marker(for: s.store.event(id: "src")!.asSourceEvent())
        let notes = MirrorIdentity.canonicalNotes(marker: marker)
        // Three duplicates, all at the WRONG time, so the keeper also needs
        // an update in the same plan.
        for dupID in ["mirror-b", "mirror-a", "mirror-c"] {
            s.store.seedEvent(
                id: dupID, calendarID: s.work.id, title: "Busy",
                start: at(2026, 6, 16, 11, 0), end: at(2026, 6, 16, 12, 0),
                notes: notes
            )
        }
        let plan = try s.plan()
        #expect(plan.creates.isEmpty)
        #expect(Set(plan.deletes.map(\.mirrorID)) == ["mirror-b", "mirror-c"])
        #expect(plan.deletes.allSatisfy { $0.reason == .duplicate })
        #expect(plan.updates.map(\.mirrorID) == ["mirror-a"])
        #expect(plan.updates.first?.reasons == [.timeChanged])
        try s.engine.apply(plan)
        let survivors = s.store.markedEvents(inCalendar: s.work.id)
        #expect(survivors.map(\.id) == ["mirror-a"])
        #expect(survivors.first?.start == at(2026, 6, 16, 9, 0))
        #expect(try s.plan().isEmpty)
    }

    @Test("A mirror the user made recurring is left alone, with a loud warning")
    func recurringMirrorIgnored() throws {
        let s = Scenario(buffers: BufferSettings(beforeMinutes: 0, afterMinutes: 0))
        s.store.seedEvent(
            id: "src", calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        let marker = MirrorIdentity.marker(for: s.store.event(id: "src")!.asSourceEvent())
        let notes = MirrorIdentity.canonicalNotes(marker: marker)
        // The user opened the mirror in Calendar and made it repeat weekly:
        // three occurrences sharing one identifier, marker copied to each.
        for (index, day) in [16, 23, 30].enumerated() {
            s.store.seedEvent(
                id: "rec-occ-\(index)", eventIdentifier: "recurring-mirror",
                calendarID: s.work.id, title: "Busy",
                start: at(2026, 6, day, 9, 0), end: at(2026, 6, day, 10, 0),
                occurrenceDate: at(2026, 6, day, 9, 0),
                notes: notes
            )
        }
        let plan = try s.plan()
        // The series is never targeted by deletes or updates...
        #expect(plan.deletes.isEmpty)
        #expect(plan.updates.isEmpty)
        #expect(plan.warnings.contains(.recurringMirrorsIgnored(seriesCount: 1)))
        // ...and since the series cannot be adopted as the keeper, a fresh
        // proper mirror is created for the source event.
        #expect(plan.creates.count == 1)
        try s.engine.apply(plan)
        // The whole state is stable on the next run.
        let second = try s.plan()
        #expect(second.isEmpty)
        #expect(second.warnings.contains(.recurringMirrorsIgnored(seriesCount: 1)))
        #expect(s.store.events(inCalendar: s.work.id).count == 4)
    }

    @Test("A target that does not support availability does not churn updates forever")
    func notSupportedTargetNoChurn() throws {
        let s = Scenario(targetSupportsAvailability: false)
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        try s.sync()
        let mirror = s.store.markedEvents(inCalendar: s.work.id).first!
        #expect(mirror.availability == .notSupported)
        #expect(try s.plan().isEmpty)
    }

    @Test("A mirror the user deleted comes back on the next sync")
    func deletedMirrorRecreated() throws {
        let s = Scenario()
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        try s.sync()
        let mirror = s.store.markedEvents(inCalendar: s.work.id).first!
        s.store.removeEvent(id: mirror.id)
        let plan = try s.plan()
        #expect(plan.creates.count == 1)
        try s.engine.apply(plan)
        #expect(s.store.markedEvents(inCalendar: s.work.id).count == 1)
    }
}
