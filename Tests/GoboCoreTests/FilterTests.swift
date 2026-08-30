// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import GoboCore

@Suite("Filtering")
struct FilterTests {
    private func event(
        availability: EventAvailability = .busy,
        status: EventStatus = .confirmed,
        participation: ParticipationStatus = .unknown,
        isAllDay: Bool = false,
        title: String? = "Something",
        minutes: Int = 60,
        notes: String? = nil
    ) -> SourceEvent {
        SourceEvent(
            eventIdentifier: "e1", calendarID: "cal-personal", title: title,
            start: defaultNow, end: defaultNow.addingTimeInterval(Double(minutes) * 60),
            isAllDay: isAllDay, availability: availability, status: status,
            participation: participation, notes: notes
        )
    }

    @Test("Free events are skipped; that is the opt-in switch")
    func freeSkipped() {
        #expect(EventFilter.decide(event(availability: .free), filters: FilterSettings()) == .skip(.markedFree))
        #expect(EventFilter.decide(
            event(availability: .free),
            filters: FilterSettings(respectFreeAvailability: false)
        ) == .include)
    }

    @Test("Busy, unavailable (OOO), and availability-not-supported events are mirrored")
    func busyVariantsIncluded() {
        for availability in [EventAvailability.busy, .unavailable, .notSupported] {
            #expect(EventFilter.decide(event(availability: availability), filters: FilterSettings()) == .include)
        }
    }

    @Test("No placeholder inference: a short timed event with a task-like title is still mirrored")
    func noPlaceholderInference() {
        let grant = event(title: "submit grant application", minutes: 60)
        #expect(EventFilter.decide(grant, filters: FilterSettings()) == .include)
    }

    @Test("All-day skipped by default, mirrored when configured")
    func allDay() {
        #expect(EventFilter.decide(event(isAllDay: true), filters: FilterSettings()) == .skip(.allDay))
        #expect(EventFilter.decide(
            event(isAllDay: true),
            filters: FilterSettings(skipAllDay: false)
        ) == .include)
    }

    @Test("Tentative skipped only when configured, via availability or status")
    func tentative() {
        let byAvailability = event(availability: .tentative)
        let byStatus = event(status: .tentative)
        #expect(EventFilter.decide(byAvailability, filters: FilterSettings()) == .include)
        #expect(EventFilter.decide(byAvailability, filters: FilterSettings(skipTentative: true)) == .skip(.tentative))
        #expect(EventFilter.decide(byStatus, filters: FilterSettings(skipTentative: true)) == .skip(.tentative))
    }

    @Test("Minimum duration filter")
    func minimumDuration() {
        let short = event(minutes: 10)
        #expect(EventFilter.decide(short, filters: FilterSettings()) == .include)
        #expect(EventFilter.decide(
            short,
            filters: FilterSettings(minimumDurationMinutes: 15)
        ) == .skip(.tooShort))
        #expect(EventFilter.decide(
            event(minutes: 15),
            filters: FilterSettings(minimumDurationMinutes: 15)
        ) == .include)
    }

    @Test("Keyword exclusion is case-insensitive substring matching")
    func keywords() {
        let filters = FilterSettings(excludeTitleKeywords: ["Focus", "  lunch "])
        #expect(EventFilter.decide(
            event(title: "Deep FOCUS block"), filters: filters
        ) == .skip(.keywordExcluded(keyword: "Focus")))
        #expect(EventFilter.decide(
            event(title: "Lunch with Sam"), filters: filters
        ) == .skip(.keywordExcluded(keyword: "  lunch ")))
        #expect(EventFilter.decide(event(title: "Board meeting"), filters: filters) == .include)
        #expect(EventFilter.decide(event(title: nil), filters: filters) == .include)
    }

    @Test("Cancelled and declined events are skipped")
    func cancelledAndDeclined() {
        #expect(EventFilter.decide(event(status: .canceled), filters: FilterSettings()) == .skip(.canceled))
        #expect(EventFilter.decide(
            event(participation: .declined), filters: FilterSettings()
        ) == .skip(.declined))
    }

    @Test("Loop prevention: any event carrying a busysync marker is never a source")
    func markerNeverSource() {
        let v1 = event(notes: "This busy block is managed by Gobo.\nbusysync:v1:0123456789abcdef")
        #expect(EventFilter.decide(v1, filters: FilterSettings()) == .skip(.isMirror))
        // Future versions count too.
        let v2 = event(notes: "busysync:v2:00ff00ff")
        #expect(EventFilter.decide(v2, filters: FilterSettings()) == .skip(.isMirror))
        // Prose mentioning the word does not.
        let prose = event(notes: "I read about busysync: tools yesterday")
        #expect(EventFilter.decide(prose, filters: FilterSettings()) == .include)
    }

    @Test("Corrupt events (end before start) are skipped")
    func invalidTimes() {
        var bad = event()
        bad.end = bad.start.addingTimeInterval(-60)
        #expect(EventFilter.decide(bad, filters: FilterSettings()) == .skip(.invalidTimes))
    }

    @Test("Availability-not-supported source calendar raises a loud plan warning")
    func availabilityWarning() throws {
        var s = Scenario()
        let flat = CalendarRef(
            id: "cal-flat", title: "Old CalDAV", supportsAvailability: false
        )
        s.store.seedCalendar(flat)
        s.rule.sourceCalendars = [flat.handle]
        s.store.seedEvent(
            calendarID: flat.id, title: "Anything", start: at(2026, 6, 16, 9, 0),
            end: at(2026, 6, 16, 10, 0), availability: .notSupported
        )
        let plan = try s.plan()
        #expect(plan.warnings.contains(.availabilityNotSupported(calendar: flat.handle)))
        // Every event mirrors, since Free cannot be expressed.
        #expect(plan.creates.count == 1)

        // With the Free filter off, no warning: the flag is irrelevant.
        s.rule.filters.respectFreeAvailability = false
        #expect(try s.plan().warnings.isEmpty)
    }
}
