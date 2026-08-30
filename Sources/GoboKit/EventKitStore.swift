// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import EventKit
import Foundation
import GoboCore

public enum EventKitStoreError: Error {
    case calendarNotFound(String)
    case eventNotFound(String)
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
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: ekCalendars)
        return store.events(matching: predicate).compactMap { Self.sourceEvent(from: $0) }
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
        guard let event = store.event(withIdentifier: id) else {
            throw EventKitStoreError.eventNotFound(id)
        }
        apply(mirror, to: event)
        try store.save(event, span: .thisEvent, commit: false)
    }

    public func delete(id: String) throws {
        guard let event = store.event(withIdentifier: id) else {
            throw EventKitStoreError.eventNotFound(id)
        }
        try store.remove(event, span: .thisEvent, commit: false)
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
