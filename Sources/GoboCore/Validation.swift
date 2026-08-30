// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Configuration-time loop prevention: a calendar may not be both source and
/// target, within a rule or across rules. The UI must refuse to save a rule
/// with any issue of severity `.error`.
public enum RuleValidationIssue: Codable, Sendable, Hashable {
    case emptyName
    case noSourceCalendars
    /// The rule's target is also one of its own sources.
    case targetIsSource(calendar: CalendarHandle)
    /// This rule's target is a source of another rule, or vice versa —
    /// mirrors would be re-mirrored.
    case crossRuleLoop(otherRuleID: UUID, calendar: CalendarHandle)
    /// Two rules mirror an overlapping source set into the same target; their
    /// plans would fight over the same markers and churn.
    case overlappingRules(otherRuleID: UUID, calendar: CalendarHandle)
    case invalidWindow

    public var isError: Bool {
        switch self {
        case .emptyName:
            return false
        case .noSourceCalendars, .targetIsSource, .crossRuleLoop, .overlappingRules, .invalidWindow:
            return true
        }
    }
}

public enum RuleValidator {
    /// Validates `rule` on its own and against every other rule, enabled or
    /// not — a disabled rule can be re-enabled at any time, so it still
    /// reserves its calendars.
    public static func validate(_ rule: SyncRule, against otherRules: [SyncRule]) -> [RuleValidationIssue] {
        var issues: [RuleValidationIssue] = []

        if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyName)
        }
        if rule.sourceCalendars.isEmpty {
            issues.append(.noSourceCalendars)
        }
        if rule.windowDaysBack < 0 || rule.windowDaysAhead < 0 || rule.windowDaysBack + rule.windowDaysAhead <= 0 {
            issues.append(.invalidWindow)
        }
        for source in rule.sourceCalendars where source.id == rule.targetCalendar.id {
            issues.append(.targetIsSource(calendar: source))
        }

        for other in otherRules where other.id != rule.id {
            // Our target feeding another rule's sources, or theirs feeding ours.
            if let clash = other.sourceCalendars.first(where: { $0.id == rule.targetCalendar.id }) {
                issues.append(.crossRuleLoop(otherRuleID: other.id, calendar: clash))
            }
            if let clash = rule.sourceCalendars.first(where: { $0.id == other.targetCalendar.id }) {
                issues.append(.crossRuleLoop(otherRuleID: other.id, calendar: clash))
            }
            // Same target + shared source: both rules would manage the same
            // markers, and differing buffers or titles would churn forever.
            if other.targetCalendar.id == rule.targetCalendar.id {
                let otherSourceIDs = Set(other.sourceCalendarIDs)
                if let shared = rule.sourceCalendars.first(where: { otherSourceIDs.contains($0.id) }) {
                    issues.append(.overlappingRules(otherRuleID: other.id, calendar: shared))
                }
            }
        }
        return issues
    }
}
