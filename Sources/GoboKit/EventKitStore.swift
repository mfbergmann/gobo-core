// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import EventKit
import Foundation
import GoboCore

public enum EventKitStoreError: Error {
    case calendarNotFound(String)
    case eventNotFound(String)
    /// The event resolved for this identifier carries no busysync marker.
    /// The store refuses to modify or delete unmarked events — a second line
    /// of defense behind the engine's own guarantee.
    case refusingUnmarkedEvent(String)
    /// The event resolved for this identifier belongs to a recurring series;
    /// occurrences share one identifier, so a single-event write would hit
    /// the wrong occurrence. Regular sync must never send these.
    case refusingRecurringEvent(String)
    /// setAvailability was pointed at a mirror block. Mirrors are always
    /// Busy; flip the source event instead.
    case refusingMirror(String)
    /// The event's calendar does not support the Busy/Free flag at all.
    case availabilityNotSupportedByCalendar(String)
}

/// `CalendarStore` backed by the user's local EventKit database. This is the
/// entire wedge: EventKit already holds every account the user has configured
/// — iCloud, Google, Exchange, CalDAV — and reads and writes all of them with
/// no network access of its own and no employer permission, because it acts
/// as the user's own Calendar client.
///
/// EKEventStore is documented thread-safe; this wrapper adds no mutable state
/// beyond it.
public final class EventKitStore: CalendarStore, @unchecked Sendable {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    /// The underlying store, exposed for change notifications
    /// (`.EKEventStoreChanged`) and permission checks.
    public var eventStore: EKEventStore { store }

    // MARK: - CalendarStore

    public func calendars() throws -> [CalendarRef] {
        store.calendars(for: .event).map { calendar in
            CalendarRef(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                accountTitle: calendar.source?.title,
                allowsModifications: calendar.allowsContentModifications,
                supportsAvailability: !calendar.supportedEventAvailabilities.isEmpty
            )
        }
    }

    public func events(in calendars: [CalendarRef], from: Date, to: Date) throws -> [SourceEvent] {
        let wanted = Set(calendars.map(\.id))
        let ekCalendars = store.calendars(for: .event)
            .filter { wanted.contains($0.calendarIdentifier) }
        guard !ekCalendars.isEmpty else { return [] }
        // Chunked because predicateForEvents silently truncates spans over
        // four years; an event straddling a chunk boundary appears in both
        // chunks, hence the dedup.
        var results: [SourceEvent] = []
        var seen = Set<String>()
        for chunk in DateRangeChunker.chunks(from: from, to: to) {
            let predicate = store.predicateForEvents(
                withStart: chunk.lowerBound, end: chunk.upperBound, calendars: ekCalendars
            )
            for ekEvent in store.events(matching: predicate) {
                guard let event = Self.sourceEvent(from: ekEvent) else { continue }
                let key = "\(event.eventIdentifier)|\(event.start.timeIntervalSinceReferenceDate)|\(event.calendarID)"
                if seen.insert(key).inserted {
                    results.append(event)
                }
            }
        }
        return results
    }

    public func create(_ mirror: MirrorSpec, in calendar: CalendarRef) throws -> String {
        guard let ekCalendar = store.calendar(withIdentifier: calendar.id) else {
            throw EventKitStoreError.calendarNotFound(calendar.id)
        }
        let event = EKEvent(eventStore: store)
        event.calendar = ekCalendar
        apply(mirror, to: event)
        try store.save(event, span: .thisEvent, commit: false)
        return event.eventIdentifier
    }

    public func update(id: String, to mirror: MirrorSpec) throws {
        let event = try managedSingleEvent(id: id)
        apply(mirror, to: event)
        try store.save(event, span: .thisEvent, commit: false)
    }

    public func delete(id: String) throws {
        let event = try managedSingleEvent(id: id)
        try store.remove(event, span: .thisEvent, commit: false)
    }

    public func deleteSeries(id: String) throws {
        guard let event = store.event(withIdentifier: id) else {
            throw EventKitStoreError.eventNotFound(id)
        }
        guard MirrorIdentity.containsAnyVersionMarker(event.notes) else {
            throw EventKitStoreError.refusingUnmarkedEvent(id)
        }
        // event(withIdentifier:) returns the series' first occurrence;
        // removing with .futureEvents from there deletes the entire series.
        try store.remove(event, span: .futureEvents, commit: false)
    }

    // MARK: - Source-event availability

    /// Writes the Busy/Free flag on one of the user's own events, addressed
    /// as a specific occurrence by (identifier, start).
    ///
    /// This is deliberately the ONLY write Gobo ever makes to a source
    /// calendar, and it exists because Apple's Calendar app stopped exposing
    /// the "Show As: Busy/Free" control for iCloud events — leaving Gobo's
    /// primary filter unreachable for exactly the users it targets. It is
    /// fully separate from the mirror engine's write path: it refuses to
    /// touch mirror blocks, does not carry any content anywhere, and edits a
    /// recurring occurrence in place (detaching just that occurrence), so
    /// "mark this Tuesday's instance Free" means exactly that.
    public func setAvailability(
        eventIdentifier: String,
        start: Date,
        to availability: EventAvailability
    ) throws {
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-2),
            end: start.addingTimeInterval(2),
            calendars: nil
        )
        guard let event = store.events(matching: predicate).first(where: {
            $0.eventIdentifier == eventIdentifier
                && abs($0.startDate.timeIntervalSince(start)) < 2
        }) else {
            throw EventKitStoreError.eventNotFound(eventIdentifier)
        }
        if MirrorIdentity.containsAnyVersionMarker(event.notes) {
            throw EventKitStoreError.refusingMirror(eventIdentifier)
        }
        guard let calendar = event.calendar, !calendar.supportedEventAvailabilities.isEmpty else {
            throw EventKitStoreError.availabilityNotSupportedByCalendar(event.calendar?.title ?? eventIdentifier)
        }
        let desired: EKEventAvailability = (availability == .free) ? .free : .busy
        guard event.availability != desired else { return }
        event.availability = desired
        try store.save(event, span: .thisEvent, commit: true)
    }

    /// Resolves an identifier the engine believes names one of our mirrors,
    /// refusing anything unmarked or recurring. Both conditions are engine
    /// invariants already; enforcing them here means a bug upstream fails
    /// loudly instead of touching the wrong event on a user's work calendar.
    private func managedSingleEvent(id: String) throws -> EKEvent {
        guard let event = store.event(withIdentifier: id) else {
            throw EventKitStoreError.eventNotFound(id)
        }
        guard MirrorIdentity.containsAnyVersionMarker(event.notes) else {
            throw EventKitStoreError.refusingUnmarkedEvent(id)
        }
        guard !event.hasRecurrenceRules, !event.isDetached else {
            throw EventKitStoreError.refusingRecurringEvent(id)
        }
        return event
    }

    public func commit() throws {
        try store.commit()
    }

    public func rollback() {
        store.reset()
    }

    // MARK: - Mapping

    private func apply(_ mirror: MirrorSpec, to event: EKEvent) {
        event.title = mirror.title
        event.startDate = mirror.start
        event.endDate = mirror.end
        event.isAllDay = mirror.isAllDay
        event.notes = mirror.notes
        event.availability = .busy
        // Mirrors must never notify: strip anything inherited or added.
        event.alarms = nil
        event.url = nil
        event.location = nil
    }

    static func sourceEvent(from event: EKEvent) -> SourceEvent? {
        guard let identifier = event.eventIdentifier else { return nil }

        // The occurrence anchor: only meaningful for recurring events, where
        // it stays fixed at the original scheduled start even when the
        // occurrence is rescheduled. For plain events EventKit reports the
        // (movable) start date here, which must not enter the identity hash.
        var occurrenceAnchor: Date?
        if event.hasRecurrenceRules || event.isDetached {
            let anchor: Date? = event.occurrenceDate
            occurrenceAnchor = anchor
        }

        let participation: GoboCore.ParticipationStatus
        if let attendees = event.attendees,
           let me = attendees.first(where: { $0.isCurrentUser }) {
            participation = Self.map(me.participantStatus)
        } else {
            participation = .unknown
        }

        let hasLocation = (event.location?.isEmpty == false) || event.structuredLocation != nil

        return SourceEvent(
            eventIdentifier: identifier,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            title: event.title,
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            occurrenceDate: occurrenceAnchor,
            availability: Self.map(event.availability),
            status: Self.map(event.status),
            participation: participation,
            hasLocation: hasLocation,
            hasAlarms: event.hasAlarms,
            notes: event.notes
        )
    }

    static func map(_ availability: EKEventAvailability) -> EventAvailability {
        switch availability {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        case .notSupported: .notSupported
        @unknown default: .busy
        }
    }

    static func map(_ status: EKEventStatus) -> EventStatus {
        switch status {
        case .none: .none
        case .confirmed: .confirmed
        case .tentative: .tentative
        case .canceled: .canceled
        @unknown default: .none
        }
    }

    static func map(_ status: EKParticipantStatus) -> GoboCore.ParticipationStatus {
        switch status {
        case .unknown: .unknown
        case .pending: .pending
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .delegated: .delegated
        case .completed: .completed
        case .inProcess: .inProcess
        @unknown default: .unknown
        }
    }
}
