// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// MARK: - Calendar references

/// A calendar as seen by the engine. Produced by a `CalendarStore`; carries
/// everything the engine and the UI need without exposing EventKit types.
public struct CalendarRef: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// The account the calendar belongs to ("iCloud", "TMU Exchange", …), for
    /// grouping in the UI. Optional because some backends do not expose it.
    public var accountTitle: String?
    public var allowsModifications: Bool
    /// Whether the backing calendar supports the Busy/Free availability flag.
    /// When false, the primary filter cannot work and the UI must say so
    /// loudly (see FilterSettings.respectFreeAvailability).
    public var supportsAvailability: Bool

    public init(
        id: String,
        title: String,
        accountTitle: String? = nil,
        allowsModifications: Bool = true,
        supportsAvailability: Bool = true
    ) {
        self.id = id
        self.title = title
        self.accountTitle = accountTitle
        self.allowsModifications = allowsModifications
        self.supportsAvailability = supportsAvailability
    }

    public var handle: CalendarHandle { CalendarHandle(id: id, titleHint: title) }
}

/// A persisted reference to a calendar. Calendar identifiers are stable across
/// launches but not across account re-adds, so the title travels alongside as
/// a human-readable fallback: when the id no longer resolves, the UI can say
/// "the calendar 'Personal' no longer exists" instead of failing silently.
public struct CalendarHandle: Codable, Sendable, Hashable {
    public var id: String
    public var titleHint: String

    public init(id: String, titleHint: String) {
        self.id = id
        self.titleHint = titleHint
    }
}

// MARK: - Events

public enum EventAvailability: String, Codable, Sendable, Hashable {
    case busy
    case free
    case tentative
    case unavailable
    /// The backing calendar does not expose an availability flag
    /// (EKEventAvailabilityNotSupported). The Free filter cannot apply.
    case notSupported
}

public enum EventStatus: String, Codable, Sendable, Hashable {
    case none
    case confirmed
    case tentative
    case canceled
}

public enum ParticipationStatus: String, Codable, Sendable, Hashable {
    case unknown
    case pending
    case accepted
    case declined
    case tentative
    case delegated
    case completed
    case inProcess
}

/// One event occurrence as read from a calendar store. Used for both source
/// events and for reading back the target calendar during reconciliation.
///
/// Recurring series are expanded by the store: each occurrence arrives as its
/// own `SourceEvent` sharing `eventIdentifier`, distinguished by
/// `occurrenceDate` (the occurrence's *original* scheduled start, which stays
/// stable when an individual occurrence is rescheduled).
public struct SourceEvent: Codable, Sendable, Hashable {
    public var eventIdentifier: String
    public var calendarID: String
    /// Displayed locally only (Preview screen, keyword filter). Never written
    /// to a mirror.
    public var title: String?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// Non-nil only for occurrences of recurring events: the original
    /// scheduled start of this occurrence. Stable across in-place edits.
    public var occurrenceDate: Date?
    public var availability: EventAvailability
    public var status: EventStatus
    public var participation: ParticipationStatus
    public var hasLocation: Bool
    public var hasAlarms: Bool
    public var notes: String?

    public init(
        eventIdentifier: String,
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
    ) {
        self.eventIdentifier = eventIdentifier
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.occurrenceDate = occurrenceDate
        self.availability = availability
        self.status = status
        self.participation = participation
        self.hasLocation = hasLocation
        self.hasAlarms = hasAlarms
        self.notes = notes
    }
}

/// What a mirror event should look like. Availability is always Busy and
/// alarms are always absent; stores enforce both on create *and* update.
public struct MirrorSpec: Codable, Sendable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// Contains the identity marker line. Carries no source detail.
    public var notes: String

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, notes: String) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.notes = notes
    }
}

// MARK: - Rules

/// The unit of configuration: mirror events from one or more source calendars
/// into a single target calendar. Many-to-one is supported from the start
/// because "Personal + Medical + Family into Work" is the real shape.
public struct SyncRule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var sourceCalendars: [CalendarHandle]
    public var targetCalendar: CalendarHandle
    public var mirrorTitle: String
    public var windowDaysBack: Int
    public var windowDaysAhead: Int
    public var filters: FilterSettings
    public var buffers: BufferSettings

    public var sourceCalendarIDs: [String] { sourceCalendars.map(\.id) }
    public var targetCalendarID: String { targetCalendar.id }

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        sourceCalendars: [CalendarHandle],
        targetCalendar: CalendarHandle,
        mirrorTitle: String = "Busy",
        windowDaysBack: Int = 1,
        windowDaysAhead: Int = 90,
        filters: FilterSettings = FilterSettings(),
        buffers: BufferSettings = BufferSettings()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.sourceCalendars = sourceCalendars
        self.targetCalendar = targetCalendar
        self.mirrorTitle = mirrorTitle
        self.windowDaysBack = windowDaysBack
        self.windowDaysAhead = windowDaysAhead
        self.filters = filters
        self.buffers = buffers
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, sourceCalendars, targetCalendar, mirrorTitle
        case windowDaysBack, windowDaysAhead, filters, buffers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sourceCalendars = try c.decode([CalendarHandle].self, forKey: .sourceCalendars)
        targetCalendar = try c.decode(CalendarHandle.self, forKey: .targetCalendar)
        mirrorTitle = try c.decodeIfPresent(String.self, forKey: .mirrorTitle) ?? "Busy"
        windowDaysBack = try c.decodeIfPresent(Int.self, forKey: .windowDaysBack) ?? 1
        windowDaysAhead = try c.decodeIfPresent(Int.self, forKey: .windowDaysAhead) ?? 90
        filters = try c.decodeIfPresent(FilterSettings.self, forKey: .filters) ?? FilterSettings()
        buffers = try c.decodeIfPresent(BufferSettings.self, forKey: .buffers) ?? BufferSettings()
    }
}

/// What gets mirrored. The primary filter is the event's own Busy/Free flag:
/// events marked Free are skipped, turning the user's existing habit of
/// marking non-committal items as Free into the opt-in switch.
public struct FilterSettings: Codable, Sendable, Hashable {
    public var respectFreeAvailability: Bool
    public var skipAllDay: Bool
    public var skipTentative: Bool
    public var minimumDurationMinutes: Int
    public var excludeTitleKeywords: [String]

    public init(
        respectFreeAvailability: Bool = true,
        skipAllDay: Bool = true,
        skipTentative: Bool = false,
        minimumDurationMinutes: Int = 0,
        excludeTitleKeywords: [String] = []
    ) {
        self.respectFreeAvailability = respectFreeAvailability
        self.skipAllDay = skipAllDay
        self.skipTentative = skipTentative
        self.minimumDurationMinutes = minimumDurationMinutes
        self.excludeTitleKeywords = excludeTitleKeywords
    }

    private enum CodingKeys: String, CodingKey {
        case respectFreeAvailability, skipAllDay, skipTentative
        case minimumDurationMinutes, excludeTitleKeywords
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        respectFreeAvailability = try c.decodeIfPresent(Bool.self, forKey: .respectFreeAvailability) ?? true
        skipAllDay = try c.decodeIfPresent(Bool.self, forKey: .skipAllDay) ?? true
        skipTentative = try c.decodeIfPresent(Bool.self, forKey: .skipTentative) ?? false
        minimumDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .minimumDurationMinutes) ?? 0
        excludeTitleKeywords = try c.decodeIfPresent([String].self, forKey: .excludeTitleKeywords) ?? []
    }
}

/// Travel buffers, baked into the single mirrored block rather than added as
/// separate events.
public struct BufferSettings: Codable, Sendable, Hashable {
    public var applyOnlyWhenLocationPresent: Bool
    public var beforeMinutes: Int
    public var afterMinutes: Int
    /// calendarID -> minutes; overrides both before and after for events from
    /// that calendar.
    public var perCalendarOverrides: [String: Int]
    /// Merging ships in v1.1; the engine currently ignores this flag and
    /// always emits unmerged blocks.
    public var mergeOverlappingBlocks: Bool

    public init(
        applyOnlyWhenLocationPresent: Bool = true,
        beforeMinutes: Int = 20,
        afterMinutes: Int = 20,
        perCalendarOverrides: [String: Int] = [:],
        mergeOverlappingBlocks: Bool = true
    ) {
        self.applyOnlyWhenLocationPresent = applyOnlyWhenLocationPresent
        self.beforeMinutes = beforeMinutes
        self.afterMinutes = afterMinutes
        self.perCalendarOverrides = perCalendarOverrides
        self.mergeOverlappingBlocks = mergeOverlappingBlocks
    }

    private enum CodingKeys: String, CodingKey {
        case applyOnlyWhenLocationPresent, beforeMinutes, afterMinutes
        case perCalendarOverrides, mergeOverlappingBlocks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applyOnlyWhenLocationPresent = try c.decodeIfPresent(Bool.self, forKey: .applyOnlyWhenLocationPresent) ?? true
        beforeMinutes = try c.decodeIfPresent(Int.self, forKey: .beforeMinutes) ?? 20
        afterMinutes = try c.decodeIfPresent(Int.self, forKey: .afterMinutes) ?? 20
        perCalendarOverrides = try c.decodeIfPresent([String: Int].self, forKey: .perCalendarOverrides) ?? [:]
        mergeOverlappingBlocks = try c.decodeIfPresent(Bool.self, forKey: .mergeOverlappingBlocks) ?? true
    }
}
