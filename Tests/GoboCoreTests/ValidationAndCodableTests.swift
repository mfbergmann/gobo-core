// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import GoboCore

@Suite("Rule validation")
struct ValidationTests {
    private let personal = CalendarHandle(id: "cal-personal", titleHint: "Personal")
    private let medical = CalendarHandle(id: "cal-medical", titleHint: "Medical")
    private let work = CalendarHandle(id: "cal-work", titleHint: "Work")
    private let second = CalendarHandle(id: "cal-second", titleHint: "Second Job")

    @Test("A calendar may not be both source and target within a rule")
    func targetIsSource() {
        let rule = SyncRule(name: "Bad", sourceCalendars: [personal, work], targetCalendar: work)
        let issues = RuleValidator.validate(rule, against: [])
        #expect(issues.contains(.targetIsSource(calendar: work)))
        #expect(issues.contains { $0.isError })
    }

    @Test("Cross-rule loops are refused in both directions")
    func crossRuleLoops() {
        let existing = SyncRule(name: "Personal into Work", sourceCalendars: [personal], targetCalendar: work)

        // New rule uses the existing rule's target as a source.
        let mirrorReader = SyncRule(name: "Work into Second", sourceCalendars: [work], targetCalendar: second)
        #expect(RuleValidator.validate(mirrorReader, against: [existing]).contains(
            .crossRuleLoop(otherRuleID: existing.id, calendar: work)
        ))

        // New rule targets a calendar the existing rule reads from.
        let mirrorWriter = SyncRule(name: "Medical into Personal", sourceCalendars: [medical], targetCalendar: personal)
        #expect(RuleValidator.validate(mirrorWriter, against: [existing]).contains(
            .crossRuleLoop(otherRuleID: existing.id, calendar: personal)
        ))

        // Disabled rules still count; they can be re-enabled any time.
        var disabled = existing
        disabled.enabled = false
        #expect(!RuleValidator.validate(mirrorReader, against: [disabled]).isEmpty)
    }

    @Test("Two rules may not mirror a shared source into the same target")
    func overlappingRules() {
        let existing = SyncRule(name: "A", sourceCalendars: [personal, medical], targetCalendar: work)
        let overlapping = SyncRule(name: "B", sourceCalendars: [medical], targetCalendar: work)
        #expect(RuleValidator.validate(overlapping, against: [existing]).contains(
            .overlappingRules(otherRuleID: existing.id, calendar: medical)
        ))
        // Different targets are fine.
        let differentTarget = SyncRule(name: "C", sourceCalendars: [medical], targetCalendar: second)
        #expect(RuleValidator.validate(differentTarget, against: [existing]).isEmpty)
    }

    @Test("Structural checks: sources required, window sane, name advisory")
    func structuralChecks() {
        let empty = SyncRule(name: " ", sourceCalendars: [], targetCalendar: work, windowDaysBack: 0, windowDaysAhead: 0)
        let issues = RuleValidator.validate(empty, against: [])
        #expect(issues.contains(.noSourceCalendars))
        #expect(issues.contains(.invalidWindow))
        #expect(issues.contains(.emptyName))
        #expect(RuleValidationIssue.emptyName.isError == false)
    }

    @Test("A valid rule has no issues, and re-validating against itself is fine")
    func validRule() {
        let rule = SyncRule(name: "Good", sourceCalendars: [personal], targetCalendar: work)
        #expect(RuleValidator.validate(rule, against: []).isEmpty)
        // Editing an existing rule: it is present in the collection.
        #expect(RuleValidator.validate(rule, against: [rule]).isEmpty)
    }
}

@Suite("Codable stability")
struct CodableTests {
    @Test("Rules round-trip through JSON")
    func ruleRoundTrip() throws {
        let rule = SyncRule(
            name: "Personal life -> TMU",
            sourceCalendars: [CalendarHandle(id: "a", titleHint: "Personal")],
            targetCalendar: CalendarHandle(id: "b", titleHint: "Work"),
            mirrorTitle: "Blocked",
            windowDaysBack: 2,
            windowDaysAhead: 45,
            filters: FilterSettings(skipTentative: true, excludeTitleKeywords: ["focus"]),
            buffers: BufferSettings(beforeMinutes: 15, afterMinutes: 25, perCalendarOverrides: ["a": 5])
        )
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(SyncRule.self, from: data)
        #expect(decoded == rule)
    }

    @Test("Old JSON without newer keys decodes with documented defaults")
    func decodingDefaults() throws {
        let json = """
        {
            "id": "F6E4B4E4-8E8D-4E7B-9F26-6D1F0E4C2222",
            "name": "Minimal",
            "sourceCalendars": [{"id": "a", "titleHint": "Personal"}],
            "targetCalendar": {"id": "b", "titleHint": "Work"}
        }
        """
        let rule = try JSONDecoder().decode(SyncRule.self, from: Data(json.utf8))
        #expect(rule.enabled == true)
        #expect(rule.mirrorTitle == "Busy")
        #expect(rule.windowDaysBack == 1)
        #expect(rule.windowDaysAhead == 90)
        #expect(rule.filters == FilterSettings())
        #expect(rule.buffers == BufferSettings())
        #expect(rule.filters.respectFreeAvailability == true)
        #expect(rule.filters.skipAllDay == true)
        #expect(rule.buffers.beforeMinutes == 20)
        #expect(rule.buffers.afterMinutes == 20)
        #expect(rule.buffers.applyOnlyWhenLocationPresent == true)
    }

    @Test("Plans round-trip through JSON, so Preview can hand one to apply later")
    func planRoundTrip() throws {
        let s = Scenario()
        s.store.seedEvent(
            calendarID: s.personal.id, title: "Dentist",
            start: at(2026, 6, 16, 9, 0), end: at(2026, 6, 16, 10, 0)
        )
        let plan = try s.plan()
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(SyncPlan.self, from: data)
        #expect(decoded == plan)
    }
}
