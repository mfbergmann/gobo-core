// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import GoboCore

/// The property from the handoff: for any source set, applying the plan and
/// planning again must produce zero changes. Idempotence catches a large
/// class of reconciliation bugs.
@Suite("Idempotence property")
struct IdempotenceTests {
    @Test("plan → apply → plan is empty for randomized source sets", arguments: 0..<40)
    func idempotent(seed: Int) throws {
        var rng = SplitMix64(seed: UInt64(seed))

        let targetSupports = Bool.random(using: &rng)
        let filters = FilterSettings(
            respectFreeAvailability: Bool.random(using: &rng),
            skipAllDay: Bool.random(using: &rng),
            skipTentative: Bool.random(using: &rng),
            minimumDurationMinutes: [0, 0, 15, 45].randomElement(using: &rng)!,
            excludeTitleKeywords: Bool.random(using: &rng) ? ["focus"] : []
        )
        let buffers = BufferSettings(
            applyOnlyWhenLocationPresent: Bool.random(using: &rng),
            beforeMinutes: Int.random(in: 0...45, using: &rng),
            afterMinutes: Int.random(in: 0...45, using: &rng),
            perCalendarOverrides: Bool.random(using: &rng) ? ["cal-medical": Int.random(in: 0...60, using: &rng)] : [:]
        )
        var s = Scenario(targetSupportsAvailability: targetSupports, filters: filters, buffers: buffers)
        s.rule.sourceCalendars = [s.personal.handle, s.medical.handle]
        s.rule.windowDaysBack = Int.random(in: 0...3, using: &rng)
        s.rule.windowDaysAhead = Int.random(in: 1...60, using: &rng)

        let calendars = ["cal-personal", "cal-medical"]
        let titles = ["Dentist", "focus time", "Trip", "submit grant application", nil]
        let availabilities: [EventAvailability] = [.busy, .busy, .free, .tentative, .unavailable, .notSupported]
        let statuses: [EventStatus] = [.confirmed, .confirmed, .none, .tentative, .canceled]
        let participations: [ParticipationStatus] = [.unknown, .accepted, .declined, .tentative]

        let eventCount = Int.random(in: 0...40, using: &rng)
        for index in 0..<eventCount {
            let dayOffset = Int.random(in: -5...70, using: &rng)
            let startHour = Int.random(in: 0...22, using: &rng)
            let durationMinutes = [0, 15, 30, 60, 90, 240, 1440].randomElement(using: &rng)!
            let start = toronto.date(byAdding: .day, value: dayOffset, to: defaultNow)!
                .addingTimeInterval(Double(startHour - 12) * 3600)
            let isAllDay = Int.random(in: 0..<8, using: &rng) == 0
            let recurring = Int.random(in: 0..<4, using: &rng) == 0

            if recurring {
                let occurrences = Int.random(in: 1...3, using: &rng)
                for occ in 0..<occurrences {
                    let occStart = toronto.date(byAdding: .day, value: 7 * occ, to: start)!
                    s.store.seedEvent(
                        eventIdentifier: "series-\(index)",
                        calendarID: calendars.randomElement(using: &rng)!,
                        title: titles.randomElement(using: &rng)!,
                        start: occStart,
                        end: occStart.addingTimeInterval(Double(durationMinutes) * 60),
                        occurrenceDate: occStart,
                        availability: availabilities.randomElement(using: &rng)!,
                        status: statuses.randomElement(using: &rng)!,
                        participation: participations.randomElement(using: &rng)!,
                        hasLocation: Bool.random(using: &rng)
                    )
                }
            } else {
                s.store.seedEvent(
                    calendarID: calendars.randomElement(using: &rng)!,
                    title: titles.randomElement(using: &rng)!,
                    start: start,
                    end: start.addingTimeInterval(Double(durationMinutes) * 60),
                    isAllDay: isAllDay,
                    availability: availabilities.randomElement(using: &rng)!,
                    status: statuses.randomElement(using: &rng)!,
                    participation: participations.randomElement(using: &rng)!,
                    hasLocation: Bool.random(using: &rng),
                    hasAlarms: Bool.random(using: &rng)
                )
            }
        }

        // Pre-existing junk on the target: unmarked events that must survive,
        // and a stale marked mirror that should get cleaned up.
        let unmarkedID = s.store.seedEvent(
            calendarID: s.work.id, title: "Busy",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        let phantom = SourceEvent(
            eventIdentifier: "phantom-\(seed)", calendarID: s.personal.id,
            start: at(2026, 6, 17, 9, 0), end: at(2026, 6, 17, 10, 0)
        )
        s.store.seedEvent(
            calendarID: s.work.id, title: "Busy",
            start: at(2026, 6, 17, 9, 0), end: at(2026, 6, 17, 10, 0),
            notes: MirrorIdentity.canonicalNotes(marker: MirrorIdentity.marker(for: phantom))
        )

        let first = try s.plan()
        #expect(!first.deletesSuppressed)
        try s.engine.apply(first)

        let second = try s.plan()
        #expect(second.isEmpty, "seed \(seed) not idempotent: \(second.creates.count)c \(second.updates.count)u \(second.deletes.count)d")

        // Applying the empty plan is also a no-op.
        let opsBefore = s.store.opLog.count
        try s.engine.apply(second)
        #expect(s.store.opLog.count == opsBefore + 1) // just the commit

        // The user's own event was never touched.
        #expect(s.store.event(id: unmarkedID) != nil)
    }
}
