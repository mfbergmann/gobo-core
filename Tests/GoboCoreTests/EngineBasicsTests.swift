// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import GoboCore

@Suite("Engine basics")
struct EngineBasicsTests {
    @Test("A busy event produces one create with the rule's mirror title")
    func createForBusyEvent() throws {
        let s = Scenario(buffers: BufferSettings(beforeMinutes: 0, afterMinutes: 0))
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        let plan = try s.plan()
        #expect(plan.creates.count == 1)
        #expect(plan.updates.isEmpty)
        #expect(plan.deletes.isEmpty)
        let create = try #require(plan.creates.first)
        #expect(create.spec.title == "Busy")
        #expect(create.spec.start == at(2026, 6, 16, 9, 0))
        #expect(create.spec.end == at(2026, 6, 16, 10, 0))
        #expect(create.sourceTitle == "Dentist")
        #expect(create.spec.notes.contains(create.marker.rawValue))
        // No source detail leaks into the spec.
        #expect(!create.spec.notes.contains("Dentist"))
    }

    @Test("Applying a plan writes mirrors with Busy availability, no alarms, and commits once")
    func applyWritesMirrors() throws {
        let s = Scenario(buffers: BufferSettings(beforeMinutes: 0, afterMinutes: 0))
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        let result = try s.sync()
        #expect(result == ApplyResult(created: 1, updated: 0, deleted: 0))
        #expect(s.store.commitCount == 1)
        let mirror = try #require(s.store.markedEvents(inCalendar: s.work.id).first)
        #expect(mirror.availability == .busy)
        #expect(mirror.hasAlarms == false)
        #expect(mirror.title == "Busy")
    }

    @Test("Update on time change: same marker, one update, no delete/create")
    func updateOnTimeChange() throws {
        let s = Scenario(buffers: BufferSettings(beforeMinutes: 0, afterMinutes: 0))
        let sourceID = s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        try s.sync()
        // Move the appointment by two hours.
        var index = 0
        index = s.store.storedEvents.firstIndex { $0.id == sourceID }!
        var moved = s.store.storedEvents[index]
        moved.start = at(2026, 6, 16, 11, 0)
        moved.end = at(2026, 6, 16, 12, 0)
        s.store.removeEvent(id: sourceID)
        s.store.seedEvent(
            id: sourceID, calendarID: moved.calendarID, title: moved.title,
            start: moved.start, end: moved.end
        )
        let plan = try s.plan()
        #expect(plan.creates.isEmpty)
        #expect(plan.deletes.isEmpty)
        #expect(plan.updates.count == 1)
        let update = try #require(plan.updates.first)
        #expect(update.reasons == [.timeChanged])
        #expect(update.spec.start == at(2026, 6, 16, 11, 0))
        try s.engine.apply(plan)
        #expect(try s.plan().isEmpty)
    }

    @Test("Delete on source deletion")
    func deleteOnSourceDeletion() throws {
        let s = Scenario()
        let sourceID = s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        try s.sync()
        s.store.removeEvent(id: sourceID)
        let plan = try s.plan()
        #expect(plan.creates.isEmpty && plan.updates.isEmpty)
        #expect(plan.deletes.count == 1)
        #expect(plan.deletes.first?.reason == .orphaned)
        try s.engine.apply(plan)
        #expect(s.store.markedEvents(inCalendar: s.work.id).isEmpty)
    }

    @Test("Delete when the source flips to Free")
    func deleteOnFlipToFree() throws {
        let s = Scenario()
        let sourceID = s.store.seedEvent(
            calendarID: s.personal.id, title: "Maybe gym",
            start: at(2026, 6, 16, 18, 0), end: at(2026, 6, 16, 19, 0)
        )
        try s.sync()
        #expect(s.store.markedEvents(inCalendar: s.work.id).count == 1)
        let stored = s.store.event(id: sourceID)!
        s.store.removeEvent(id: sourceID)
        s.store.seedEvent(
            id: sourceID, calendarID: stored.calendarID, title: stored.title,
            start: stored.start, end: stored.end, availability: .free
        )
        let plan = try s.plan()
        #expect(plan.deletes.count == 1)
        #expect(plan.deletes.first?.reason == .orphaned)
        #expect(plan.excluded.contains { $0.reason == .markedFree })
        try s.engine.apply(plan)
        #expect(s.store.markedEvents(inCalendar: s.work.id).isEmpty)
    }

    @Test("Mirror title follows the rule setting; renaming the rule updates existing mirrors")
    func mirrorTitleChange() throws {
        var s = Scenario()
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        try s.sync()
        s.rule.mirrorTitle = "Blocked"
        let plan = try s.plan()
        #expect(plan.updates.count == 1)
        #expect(plan.updates.first?.reasons == [.titleChanged])
        try s.engine.apply(plan)
        #expect(s.store.markedEvents(inCalendar: s.work.id).first?.title == "Blocked")
    }

    @Test("Mirrors with alarms are updated to strip them")
    func stripsInheritedAlarms() throws {
        let s = Scenario()
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        try s.sync()
        // Simulate an alarm having been attached to the mirror out-of-band.
        let mirror = s.store.markedEvents(inCalendar: s.work.id).first!
        let saved = mirror
        s.store.removeEvent(id: mirror.id)
        s.store.seedEvent(
            id: saved.id, calendarID: saved.calendarID, title: saved.title,
            start: saved.start, end: saved.end, hasAlarms: true, notes: saved.notes
        )
        let plan = try s.plan()
        #expect(plan.updates.count == 1)
        #expect(plan.updates.first?.reasons == [.hasAlarms])
        try s.engine.apply(plan)
        #expect(s.store.markedEvents(inCalendar: s.work.id).first?.hasAlarms == false)
    }

    @Test("Updates preserve user-edited notes as long as the marker survives")
    func updatePreservesNotes() throws {
        let s = Scenario()
        let sourceID = s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        try s.sync()
        let mirror = s.store.markedEvents(inCalendar: s.work.id).first!
        let editedNotes = "my own annotation\n" + mirror.notes!
        let saved = mirror
        s.store.removeEvent(id: mirror.id)
        s.store.seedEvent(
            id: saved.id, calendarID: saved.calendarID, title: saved.title,
            start: saved.start, end: saved.end, notes: editedNotes
        )
        // Move the source so an update is needed.
        let source = s.store.event(id: sourceID)!
        s.store.removeEvent(id: sourceID)
        s.store.seedEvent(
            id: sourceID, calendarID: source.calendarID, title: source.title,
            start: source.start.addingTimeInterval(3600), end: source.end.addingTimeInterval(3600)
        )
        try s.sync()
        let after = s.store.markedEvents(inCalendar: s.work.id).first!
        #expect(after.notes == editedNotes)
    }

    @Test("Many-to-one: several source calendars feed one target")
    func manyToOne() throws {
        var s = Scenario()
        s.rule.sourceCalendars = [s.personal.handle, s.medical.handle]
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        s.store.seedEvent(
            calendarID: s.medical.id, title: "Physio",
            start: at(2026, 6, 17, 14, 0), end: at(2026, 6, 17, 15, 0)
        )
        let plan = try s.plan()
        #expect(plan.creates.count == 2)
    }

    @Test("Plan output ordering is deterministic")
    func deterministicOrdering() throws {
        let s = Scenario()
        for day in [20, 18, 16, 19, 17] {
            s.store.seedEvent(
                calendarID: s.personal.id, title: "Event \(day)",
                start: at(2026, 6, day, 9, 0), end: at(2026, 6, day, 10, 0)
            )
        }
        let plan = try s.plan()
        let starts = plan.creates.map(\.spec.start)
        #expect(starts == starts.sorted())
        let again = try s.plan()
        #expect(plan.creates == again.creates)
    }

    @Test("Plan errors: missing target, read-only target, target within sources")
    func planErrors() throws {
        var s = Scenario()

        s.rule.targetCalendar = CalendarHandle(id: "gone", titleHint: "Old Work")
        #expect(throws: PlanError.targetCalendarMissing(CalendarHandle(id: "gone", titleHint: "Old Work"))) {
            try s.plan()
        }

        let readOnly = CalendarRef(id: "cal-ro", title: "Holidays", allowsModifications: false)
        s.store.seedCalendar(readOnly)
        s.rule.targetCalendar = readOnly.handle
        #expect(throws: PlanError.targetNotWritable(readOnly.handle)) {
            try s.plan()
        }

        s.rule.targetCalendar = s.personal.handle
        #expect(throws: PlanError.calendarIsBothSourceAndTarget(s.personal.handle)) {
            try s.plan()
        }
    }

    @Test("Missing source calendar: warning raised, deletes suppressed, creates still flow")
    func missingSourceSuppressesDeletes() throws {
        var s = Scenario()
        let ghost = CalendarHandle(id: "cal-ghost", titleHint: "Family")
        s.rule.sourceCalendars = [s.personal.handle, ghost]
        // An existing mirror that would look orphaned with the ghost calendar gone.
        let strandedMarker = MirrorIdentity.marker(for: SourceEvent(
            eventIdentifier: "ghost-event", calendarID: ghost.id,
            start: at(2026, 6, 20, 9, 0), end: at(2026, 6, 20, 10, 0)
        ))
        s.store.seedEvent(
            calendarID: s.work.id, title: "Busy",
            start: at(2026, 6, 20, 9, 0), end: at(2026, 6, 20, 10, 0),
            notes: MirrorIdentity.canonicalNotes(marker: strandedMarker)
        )
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        let plan = try s.plan()
        #expect(plan.warnings.contains(.sourceCalendarMissing(calendar: ghost)))
        #expect(plan.deletesSuppressed)
        #expect(plan.deletes.isEmpty)
        #expect(plan.creates.count == 1)
    }
}
