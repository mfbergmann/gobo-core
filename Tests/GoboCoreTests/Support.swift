// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
@testable import GoboCore

let torontoTZ = TimeZone(identifier: "America/Toronto")!

var toronto: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = torontoTZ
    return calendar
}

/// Local Toronto wall-clock date.
func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    let components = DateComponents(
        timeZone: torontoTZ, year: year, month: month, day: day, hour: hour, minute: minute
    )
    return toronto.date(from: components)!
}

/// A quiet mid-June noon, far from DST edges.
let defaultNow = at(2026, 6, 15, 12, 0)

struct Scenario {
    let store: FakeCalendarStore
    let engine: SyncEngine
    let personal: CalendarRef
    let medical: CalendarRef
    let work: CalendarRef

    var rule: SyncRule

    init(
        targetSupportsAvailability: Bool = true,
        filters: FilterSettings = FilterSettings(),
        buffers: BufferSettings = BufferSettings()
    ) {
        let store = FakeCalendarStore()
        personal = CalendarRef(id: "cal-personal", title: "Personal", accountTitle: "iCloud")
        medical = CalendarRef(id: "cal-medical", title: "Medical", accountTitle: "iCloud")
        work = CalendarRef(
            id: "cal-work", title: "Work", accountTitle: "Exchange",
            supportsAvailability: targetSupportsAvailability
        )
        store.seedCalendar(personal)
        store.seedCalendar(medical)
        store.seedCalendar(work)
        self.store = store
        self.engine = SyncEngine(store: store)
        self.rule = SyncRule(
            name: "Personal into Work",
            sourceCalendars: [personal.handle],
            targetCalendar: work.handle,
            filters: filters,
            buffers: buffers
        )
    }

    func plan(now: Date = defaultNow) throws -> SyncPlan {
        try engine.plan(for: rule, now: now, calendar: toronto)
    }

    @discardableResult
    func sync(now: Date = defaultNow) throws -> ApplyResult {
        try engine.apply(try plan(now: now))
    }
}

/// Deterministic RNG for property tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
