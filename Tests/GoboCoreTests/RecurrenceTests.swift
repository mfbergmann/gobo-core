// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import GoboCore

@Suite("Recurrence")
struct RecurrenceTests {
    /// Seeds three weekly occurrences of one recurring event, the way a store
    /// expands them: shared eventIdentifier, distinct occurrenceDates.
    private func seedWeekly(_ s: Scenario) -> [String] {
        var ids: [String] = []
        for (index, day) in [16, 23, 30].enumerated() {
            let start = at(2026, 6, day, 9, 0)
            let id = s.store.seedEvent(
                id: "occ-\(index)", eventIdentifier: "recurring-1",
                calendarID: s.personal.id, title: "Standup",
                start: start, end: at(2026, 6, day, 9, 30),
                occurrenceDate: start
            )
            ids.append(id)
        }
        return ids
    }

    @Test("Each occurrence gets its own mirror with a distinct marker")
    func occurrencesExpand() throws {
        let s = Scenario()
        _ = seedWeekly(s)
        let plan = try s.plan()
        #expect(plan.creates.count == 3)
        #expect(Set(plan.creates.map(\.marker)).count == 3)
    }

    @Test("Rescheduling one occurrence updates its mirror in place")
    func movedOccurrenceUpdates() throws {
        let s = Scenario()
        let ids = seedWeekly(s)
        try s.sync()
        // Move the middle occurrence two hours later; its occurrenceDate (the
        // original scheduled start) stays put — that is EventKit's behavior.
        let occurrence = s.store.event(id: ids[1])!
        s.store.removeEvent(id: ids[1])
        s.store.seedEvent(
            id: ids[1], eventIdentifier: occurrence.eventIdentifier,
            calendarID: occurrence.calendarID, title: occurrence.title,
            start: occurrence.start.addingTimeInterval(7200),
            end: occurrence.end.addingTimeInterval(7200),
            occurrenceDate: occurrence.occurrenceDate
        )
        let plan = try s.plan()
        #expect(plan.creates.isEmpty)
        #expect(plan.deletes.isEmpty)
        #expect(plan.updates.count == 1)
        #expect(plan.updates.first?.reasons == [.timeChanged])
        try s.engine.apply(plan)
        #expect(try s.plan().isEmpty)
    }

    @Test("Deleting one occurrence orphans only its mirror")
    func deletedOccurrence() throws {
        let s = Scenario()
        let ids = seedWeekly(s)
        try s.sync()
        s.store.removeEvent(id: ids[2])
        let plan = try s.plan()
        #expect(plan.deletes.count == 1)
        #expect(plan.creates.isEmpty && plan.updates.isEmpty)
        try s.engine.apply(plan)
        #expect(s.store.markedEvents(inCalendar: s.work.id).count == 2)
    }

    @Test("Occurrences on the same day as a same-id single event stay distinct")
    func recurringAndOccurrenceDateDistinguish() {
        let occurrence = SourceEvent(
            eventIdentifier: "recurring-1", calendarID: "cal-personal",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 9, 30),
            occurrenceDate: at(2026, 6, 16, 9, 0)
        )
        let single = SourceEvent(
            eventIdentifier: "recurring-1", calendarID: "cal-personal",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 9, 30)
        )
        #expect(MirrorIdentity.marker(for: occurrence) != MirrorIdentity.marker(for: single))
    }
}

@Suite("Marker identity")
struct MirrorIdentityTests {
    @Test("Markers have the documented v1 shape")
    func markerShape() {
        let event = SourceEvent(
            eventIdentifier: "abc", calendarID: "c",
            start: defaultNow, end: defaultNow.addingTimeInterval(3600)
        )
        let marker = MirrorIdentity.marker(for: event)
        #expect(marker.rawValue.hasPrefix("busysync:v1:"))
        #expect(marker.rawValue.count == "busysync:v1:".count + 16)
        #expect(MirrorMarker(rawValue: marker.rawValue) == marker)
        #expect(MirrorMarker(rawValue: "busysync:v1:xyz") == nil)
    }

    @Test("Marker is stable under time changes for non-recurring events")
    func stableForNonRecurring() {
        var event = SourceEvent(
            eventIdentifier: "abc", calendarID: "c",
            start: defaultNow, end: defaultNow.addingTimeInterval(3600)
        )
        let before = MirrorIdentity.marker(for: event)
        event.start = event.start.addingTimeInterval(86_400)
        event.end = event.end.addingTimeInterval(86_400)
        #expect(MirrorIdentity.marker(for: event) == before)
    }

    @Test("Marker does not leak the source identifier")
    func markerOpacity() {
        let event = SourceEvent(
            eventIdentifier: "ABCDEF-my-secret-meeting-id", calendarID: "c",
            start: defaultNow, end: defaultNow.addingTimeInterval(3600)
        )
        let marker = MirrorIdentity.marker(for: event)
        #expect(!marker.rawValue.lowercased().contains("secret"))
        #expect(!marker.rawValue.contains("ABCDEF"))
    }

    @Test("Marker parsing tolerates surrounding whitespace and prose")
    func markerParsing() {
        let notes = "  user text before\n  busysync:v1:00ff00ff00ff00ff  \nafter"
        let markers = MirrorIdentity.markers(inNotes: notes)
        #expect(markers.map(\.rawValue) == ["busysync:v1:00ff00ff00ff00ff"])
        #expect(MirrorIdentity.markers(inNotes: nil).isEmpty)
        #expect(MirrorIdentity.markers(inNotes: "no markers here").isEmpty)
        // Uppercase hex is not adopted as v1 identity...
        #expect(MirrorIdentity.markers(inNotes: "busysync:v1:00FF00FF00FF00FF").isEmpty)
        // ...but still recognized as a marker for loop prevention and purge.
        #expect(MirrorIdentity.containsAnyVersionMarker("busysync:v1:00FF00FF00FF00FF"))
        #expect(MirrorIdentity.containsAnyVersionMarker("busysync:v2:abcd"))
        #expect(!MirrorIdentity.containsAnyVersionMarker("busysync:vX:abcd"))
        #expect(!MirrorIdentity.containsAnyVersionMarker("see busysync:v1:00ff00ff00ff00ff inline"))
    }
}
