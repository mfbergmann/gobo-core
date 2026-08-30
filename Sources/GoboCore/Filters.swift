// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Why a source event was not mirrored. Surfaced on the Preview screen so the
/// user can see exactly what the app decided and why.
public enum SkipReason: Codable, Sendable, Hashable {
    case canceled
    case declined
    /// The event itself carries a busysync marker — it is somebody's mirror,
    /// never a source. Loop prevention.
    case isMirror
    case allDay
    case markedFree
    case tentative
    case tooShort
    case keywordExcluded(keyword: String)
    case invalidTimes
}

public enum FilterDecision: Sendable, Hashable {
    case include
    case skip(SkipReason)
}

public enum EventFilter {
    /// Deliberately does not infer placeholder-ness from duration or the
    /// all-day flag: real users put "submit grant application" in a normal
    /// one-hour slot, and only the Free flag distinguishes it.
    public static func decide(_ event: SourceEvent, filters: FilterSettings) -> FilterDecision {
        if event.end < event.start {
            return .skip(.invalidTimes)
        }
        if event.status == .canceled {
            return .skip(.canceled)
        }
        if event.participation == .declined {
            return .skip(.declined)
        }
        if MirrorIdentity.containsAnyVersionMarker(event.notes) {
            return .skip(.isMirror)
        }
        if event.isAllDay && filters.skipAllDay {
            return .skip(.allDay)
        }
        if filters.respectFreeAvailability && event.availability == .free {
            return .skip(.markedFree)
        }
        if filters.skipTentative && (event.availability == .tentative || event.status == .tentative) {
            return .skip(.tentative)
        }
        if !event.isAllDay && filters.minimumDurationMinutes > 0 {
            let duration = event.end.timeIntervalSince(event.start)
            if duration < Double(filters.minimumDurationMinutes) * 60 {
                return .skip(.tooShort)
            }
        }
        if let title = event.title, !filters.excludeTitleKeywords.isEmpty {
            let lowered = title.lowercased()
            for keyword in filters.excludeTitleKeywords {
                let trimmed = keyword.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if lowered.contains(trimmed.lowercased()) {
                    return .skip(.keywordExcluded(keyword: keyword))
                }
            }
        }
        return .include
    }
}

public enum BufferCalculator {
    /// Padding baked into the mirrored block. All-day events are never
    /// buffered; travel buffers can be gated on the event having a location.
    public static func padding(
        for event: SourceEvent,
        settings: BufferSettings
    ) -> (before: TimeInterval, after: TimeInterval) {
        if event.isAllDay {
            return (0, 0)
        }
        if settings.applyOnlyWhenLocationPresent && !event.hasLocation {
            return (0, 0)
        }
        let beforeMinutes: Int
        let afterMinutes: Int
        if let override = settings.perCalendarOverrides[event.calendarID] {
            beforeMinutes = override
            afterMinutes = override
        } else {
            beforeMinutes = settings.beforeMinutes
            afterMinutes = settings.afterMinutes
        }
        return (Double(max(0, beforeMinutes)) * 60, Double(max(0, afterMinutes)) * 60)
    }
}
