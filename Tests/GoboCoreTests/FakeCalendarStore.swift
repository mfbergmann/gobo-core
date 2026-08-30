// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
@testable import GoboCore

enum FakeStoreError: Error, Equatable {
    case noSuchEvent(String)
    case injectedFailure(String)
    case refusingUnmarkedEvent(String)
    case refusingRecurringEvent(String)
}

/// In-memory CalendarStore with EventKit-like semantics: overlap-based range
/// queries, expanded recurring occurrences, Busy availability (or
/// notSupported) stamped onto created mirrors, and snapshot-based rollback.
final class FakeCalendarStore: CalendarStore {
    struct FakeEvent {
        var id: String
        /// EventKit identity: shared across occurrences of a recurring
        /// series. Defaults to `id` for ordinary events. For mirrors (the
        /// only things the engine updates or deletes) it always equals `id`.
        var eventIdentifier: String
        var calendarID: String
        var title: String?
        var start: Date
        var end: Date
        var isAllDay: Bool
        var occurrenceDate: Date?
        var availability: EventAvailability
        var status: EventStatus
        var participation: ParticipationStatus
        var hasLocation: Bool
        var hasAlarms: Bool
        var notes: String?

        func asSourceEvent() -> SourceEvent {
            SourceEvent(
                eventIdentifier: eventIdentifier,
                calendarID: calendarID,
                title: title,
                start: start,
                end: end,
                isAllDay: isAllDay,
                occurrenceDate: occurrenceDate,
                availability: availability,
                status: status,
                participation: participation,
                hasLocation: hasLocation,
                hasAlarms: hasAlarms,
                notes: notes
            )
        }
    }

    private(set) var calendarsList: [CalendarRef] = []
    private(set) var storedEvents: [FakeEvent] = []
    private var snapshot: [FakeEvent]?
    private var nextID = 1
    private(set) var commitCount = 0
    private(set) var rollbackCount = 0
    private(set) var opLog: [String] = []
    /// Injects a failure when the given operation name would run.
    var failOn: Set<String> = []

    // MARK: Seeding

    func seedCalendar(_ ref: CalendarRef) {
        calendarsList.append(ref)
    }

    func removeCalendar(id: String) {
        calendarsList.removeAll { $0.id == id }
    }

    @discardableResult
    func seedEvent(
        id: String? = nil,
        eventIdentifier: String? = nil,
        calendarID: String,
        title: String? = nil,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        occurrenceDate: Date? = nil,
        availability: EventAvailability = .busy,
        status: EventStatus = .confirmed,
        participation: ParticipationStatus = .unknown,
        hasLocation: Bool = false,
        hasAlarms: Bool = false,
        notes: String? = nil
    ) -> String {
        let assignedID = id ?? generateID()
        storedEvents.append(FakeEvent(
            id: assignedID,
            eventIdentifier: eventIdentifier ?? assignedID,
            calendarID: calendarID,
            title: title,
            start: start,
            end: end,
            isAllDay: isAllDay,
            occurrenceDate: occurrenceDate,
            availability: availability,
            status: status,
            participation: participation,
            hasLocation: hasLocation,
            hasAlarms: hasAlarms,
            notes: notes
        ))
        return assignedID
    }

    func removeEvent(id: String) {
        storedEvents.removeAll { $0.id == id }
    }

    func event(id: String) -> FakeEvent? {
        storedEvents.first { $0.id == id }
    }

    func events(inCalendar calendarID: String) -> [FakeEvent] {
        storedEvents.filter { $0.calendarID == calendarID }
    }

    func markedEvents(inCalendar calendarID: String) -> [FakeEvent] {
        events(inCalendar: calendarID).filter { !MirrorIdentity.markers(inNotes: $0.notes).isEmpty }
    }

    // MARK: CalendarStore

    func calendars() throws -> [CalendarRef] {
        try maybeFail("calendars")
        return calendarsList
    }

    func events(in calendars: [CalendarRef], from: Date, to: Date) throws -> [SourceEvent] {
        try maybeFail("events")
        let ids = Set(calendars.map(\.id))
        return storedEvents
            .filter { ids.contains($0.calendarID) && $0.start < to && $0.end > from }
            .map { $0.asSourceEvent() }
    }

    func create(_ mirror: MirrorSpec, in calendar: CalendarRef) throws -> String {
        try maybeFail("create")
        beginWriteIfNeeded()
        let id = generateID()
        storedEvents.append(FakeEvent(
            id: id,
            eventIdentifier: id,
            calendarID: calendar.id,
            title: mirror.title,
            start: mirror.start,
            end: mirror.end,
            isAllDay: mirror.isAllDay,
            occurrenceDate: nil,
            availability: calendar.supportsAvailability ? .busy : .notSupported,
            status: .confirmed,
            participation: .unknown,
            hasLocation: false,
            hasAlarms: false,
            notes: mirror.notes
        ))
        opLog.append("create \(id)")
        return id
    }

    func update(id: String, to mirror: MirrorSpec) throws {
        try maybeFail("update")
        beginWriteIfNeeded()
        let index = try managedSingleIndex(id: id)
        storedEvents[index].title = mirror.title
        storedEvents[index].start = mirror.start
        storedEvents[index].end = mirror.end
        storedEvents[index].isAllDay = mirror.isAllDay
        storedEvents[index].notes = mirror.notes
        storedEvents[index].hasAlarms = false
        let supportsAvailability = calendarsList
            .first { $0.id == storedEvents[index].calendarID }?
            .supportsAvailability ?? true
        storedEvents[index].availability = supportsAvailability ? .busy : .notSupported
        opLog.append("update \(id)")
    }

    func delete(id: String) throws {
        try maybeFail("delete")
        beginWriteIfNeeded()
        let index = try managedSingleIndex(id: id)
        let removedID = storedEvents[index].id
        storedEvents.remove(at: index)
        opLog.append("delete \(removedID)")
    }

    func deleteSeries(id: String) throws {
        try maybeFail("deleteSeries")
        beginWriteIfNeeded()
        let matches = storedEvents.filter { $0.eventIdentifier == id }
        guard !matches.isEmpty else {
            throw FakeStoreError.noSuchEvent(id)
        }
        guard matches.contains(where: { MirrorIdentity.containsAnyVersionMarker($0.notes) }) else {
            throw FakeStoreError.refusingUnmarkedEvent(id)
        }
        storedEvents.removeAll { $0.eventIdentifier == id }
        opLog.append("deleteSeries \(id)")
    }

    /// Mimics EventKit: identifiers resolve via eventIdentifier, a recurring
    /// series shares one, and lookup lands on the earliest occurrence. The
    /// same refusal guards as EventKitStore keep engine invariants honest in
    /// tests.
    private func managedSingleIndex(id: String) throws -> Int {
        let matches = storedEvents.indices.filter { storedEvents[$0].eventIdentifier == id }
        guard let index = matches.min(by: { storedEvents[$0].start < storedEvents[$1].start }) else {
            throw FakeStoreError.noSuchEvent(id)
        }
        guard MirrorIdentity.containsAnyVersionMarker(storedEvents[index].notes) else {
            throw FakeStoreError.refusingUnmarkedEvent(id)
        }
        guard storedEvents[index].occurrenceDate == nil, matches.count == 1 else {
            throw FakeStoreError.refusingRecurringEvent(id)
        }
        return index
    }

    func commit() throws {
        try maybeFail("commit")
        snapshot = nil
        commitCount += 1
        opLog.append("commit")
    }

    func rollback() {
        if let snapshot {
            storedEvents = snapshot
        }
        snapshot = nil
        rollbackCount += 1
        opLog.append("rollback")
    }

    // MARK: Internals

    private func generateID() -> String {
        defer { nextID += 1 }
        return String(format: "ev-%04d", nextID)
    }

    private func beginWriteIfNeeded() {
        if snapshot == nil {
            snapshot = storedEvents
        }
    }

    private func maybeFail(_ op: String) throws {
        if failOn.contains(op) {
            throw FakeStoreError.injectedFailure(op)
        }
    }
}
