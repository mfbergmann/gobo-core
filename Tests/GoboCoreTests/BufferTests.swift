// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import GoboCore

@Suite("Buffers")
struct BufferTests {
    @Test("Buffers are baked into the block, gated on location by default")
    func locationGating() throws {
        let s = Scenario()
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist downtown",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0),
            hasLocation: true
        )
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Phone call",
            start: at(2026, 6, 17, 9, 0), end: at(2026, 6, 17, 10, 0),
            hasLocation: false
        )
        let plan = try s.plan()
        #expect(plan.creates.count == 2)
        let buffered = plan.creates[0]
        #expect(buffered.spec.start == at(2026, 6, 16, 8, 40))
        #expect(buffered.spec.end == at(2026, 6, 16, 10, 20))
        let unbuffered = plan.creates[1]
        #expect(unbuffered.spec.start == at(2026, 6, 17, 9, 0))
        #expect(unbuffered.spec.end == at(2026, 6, 17, 10, 0))
    }

    @Test("Location gating off buffers everything")
    func bufferEverything() throws {
        let s = Scenario(buffers: BufferSettings(applyOnlyWhenLocationPresent: false, beforeMinutes: 10, afterMinutes: 30))
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Phone call",
            start: at(2026, 6, 17, 9, 0), end: at(2026, 6, 17, 10, 0)
        )
        let create = try #require(try s.plan().creates.first)
        #expect(create.spec.start == at(2026, 6, 17, 8, 50))
        #expect(create.spec.end == at(2026, 6, 17, 10, 30))
    }

    @Test("Per-calendar override replaces both sides of the buffer")
    func perCalendarOverride() throws {
        var s = Scenario(buffers: BufferSettings(
            applyOnlyWhenLocationPresent: false,
            beforeMinutes: 20, afterMinutes: 20,
            perCalendarOverrides: ["cal-medical": 45]
        ))
        s.rule.sourceCalendars = [s.personal.handle, s.medical.handle]
        s.store.seedEvent(
            calendarID: s.medical.id, title: "Hospital visit",
            start: at(2026, 6, 18, 13, 0), end: at(2026, 6, 18, 14, 0)
        )
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Coffee",
            start: at(2026, 6, 18, 9, 0), end: at(2026, 6, 18, 9, 30)
        )
        let plan = try s.plan()
        let coffee = plan.creates[0]
        #expect(coffee.spec.start == at(2026, 6, 18, 8, 40))
        let hospital = plan.creates[1]
        #expect(hospital.spec.start == at(2026, 6, 18, 12, 15))
        #expect(hospital.spec.end == at(2026, 6, 18, 14, 45))
    }

    @Test("All-day events are never buffered")
    func allDayNeverBuffered() throws {
        let s = Scenario(
            filters: FilterSettings(skipAllDay: false),
            buffers: BufferSettings(applyOnlyWhenLocationPresent: false)
        )
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Conference",
            start: at(2026, 6, 22), end: at(2026, 6, 23), isAllDay: true, hasLocation: true
        )
        let create = try #require(try s.plan().creates.first)
        #expect(create.spec.isAllDay)
        #expect(create.spec.start == at(2026, 6, 22))
        #expect(create.spec.end == at(2026, 6, 23))
    }

    @Test("Negative buffer minutes clamp to zero")
    func negativeClamped() {
        let event = SourceEvent(
            eventIdentifier: "e", calendarID: "c",
            start: defaultNow, end: defaultNow.addingTimeInterval(3600), hasLocation: true
        )
        let pad = BufferCalculator.padding(
            for: event,
            settings: BufferSettings(beforeMinutes: -10, afterMinutes: -5)
        )
        #expect(pad.before == 0)
        #expect(pad.after == 0)
    }

    @Test("Changing buffer settings updates existing mirrors in place")
    func bufferChangeUpdatesInPlace() throws {
        var s = Scenario(buffers: BufferSettings(applyOnlyWhenLocationPresent: false, beforeMinutes: 0, afterMinutes: 0))
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        try s.sync()
        s.rule.buffers.beforeMinutes = 30
        s.rule.buffers.afterMinutes = 15
        let plan = try s.plan()
        #expect(plan.updates.count == 1)
        #expect(plan.creates.isEmpty && plan.deletes.isEmpty)
        #expect(plan.updates.first?.spec.start == at(2026, 6, 16, 8, 30))
        #expect(plan.updates.first?.spec.end == at(2026, 6, 16, 10, 15))
    }
}
