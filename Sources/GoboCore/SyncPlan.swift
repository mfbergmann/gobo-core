// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Everything a sync run would do, computed without touching the target.
/// The Preview screen renders one of these before the user lets the app
/// write anything; `SyncEngine.apply` executes one.
public struct SyncPlan: Codable, Sendable, Equatable {
    /// Nil for purge plans, which are not tied to a rule.
    public var ruleID: UUID?
    /// Nil for purge plans (they contain only deletes).
    public var targetCalendarID: String?
    public var window: DateInterval
    public var creates: [Create]
    public var updates: [Update]
    public var deletes: [Delete]
    /// Source events that were considered and skipped, with reasons — the
    /// Preview screen's other half.
    public var excluded: [ExcludedEvent]
    public var warnings: [PlanWarning]
    /// True when deletes were withheld because a source calendar failed to
    /// resolve: with an incomplete desired set, every unmatched mirror would
    /// look like an orphan, and a transient identifier change (an account
    /// re-add) must not wipe the target calendar.
    public var deletesSuppressed: Bool
    /// How many mirror blocks will exist within the window once this plan is
    /// applied (created + kept). Zero for purge plans.
    public var managedCount: Int

    public var isEmpty: Bool {
        creates.isEmpty && updates.isEmpty && deletes.isEmpty
    }

    public var changeCount: Int {
        creates.count + updates.count + deletes.count
    }

    public init(
        ruleID: UUID?,
        targetCalendarID: String?,
        window: DateInterval,
        creates: [Create] = [],
        updates: [Update] = [],
        deletes: [Delete] = [],
        excluded: [ExcludedEvent] = [],
        warnings: [PlanWarning] = [],
        deletesSuppressed: Bool = false,
        managedCount: Int = 0
    ) {
        self.ruleID = ruleID
        self.targetCalendarID = targetCalendarID
        self.window = window
        self.creates = creates
        self.updates = updates
        self.deletes = deletes
        self.excluded = excluded
        self.warnings = warnings
        self.deletesSuppressed = deletesSuppressed
        self.managedCount = managedCount
    }

    public struct Create: Codable, Sendable, Hashable {
        public var marker: MirrorMarker
        public var spec: MirrorSpec
        /// Local-only display; never written anywhere.
        public var sourceTitle: String?
        public var sourceCalendarID: String

        public init(marker: MirrorMarker, spec: MirrorSpec, sourceTitle: String?, sourceCalendarID: String) {
            self.marker = marker
            self.spec = spec
            self.sourceTitle = sourceTitle
            self.sourceCalendarID = sourceCalendarID
        }
    }

    public struct Update: Codable, Sendable, Hashable {
        public var mirrorID: String
        public var marker: MirrorMarker
        public var spec: MirrorSpec
        public var sourceTitle: String?
        public var reasons: [UpdateReason]

        public init(mirrorID: String, marker: MirrorMarker, spec: MirrorSpec, sourceTitle: String?, reasons: [UpdateReason]) {
            self.mirrorID = mirrorID
            self.marker = marker
            self.spec = spec
            self.sourceTitle = sourceTitle
            self.reasons = reasons
        }
    }

    public struct Delete: Codable, Sendable, Hashable {
        public var mirrorID: String
        public var start: Date
        public var end: Date
        public var reason: DeleteReason

        public init(mirrorID: String, start: Date, end: Date, reason: DeleteReason) {
            self.mirrorID = mirrorID
            self.start = start
            self.end = end
            self.reason = reason
        }
    }

    public struct ExcludedEvent: Codable, Sendable, Hashable {
        public var sourceTitle: String?
        public var sourceCalendarID: String
        public var start: Date
        public var end: Date
        public var reason: SkipReason

        public init(sourceTitle: String?, sourceCalendarID: String, start: Date, end: Date, reason: SkipReason) {
            self.sourceTitle = sourceTitle
            self.sourceCalendarID = sourceCalendarID
            self.start = start
            self.end = end
            self.reason = reason
        }
    }
}

public enum UpdateReason: String, Codable, Sendable, Hashable {
    case timeChanged
    case titleChanged
    case allDayChanged
    case availabilityNotBusy
    case hasAlarms
}

public enum DeleteReason: String, Codable, Sendable, Hashable {
    /// A marked event whose source no longer exists (or is now filtered out).
    case orphaned
    /// A second marked event carrying the same identity; one is kept.
    case duplicate
    /// An event carrying several v1 markers. This engine version never
    /// produces those, so any it finds are foreign; they are removed and the
    /// constituent blocks recreated individually.
    case multipleMarkers
    /// Removed by an explicit "remove all mirrors" purge.
    case purged
}

public enum PlanWarning: Codable, Sendable, Hashable {
    /// "This calendar does not support Busy/Free; every event will be
    /// mirrored." Must be shown loudly in the rule's UI, with keyword
    /// exclusion offered as the fallback.
    case availabilityNotSupported(calendar: CalendarHandle)
    case sourceCalendarMissing(calendar: CalendarHandle)
}

public enum PlanError: Error, Equatable, Sendable {
    case targetCalendarMissing(CalendarHandle)
    case targetNotWritable(CalendarHandle)
    case calendarIsBothSourceAndTarget(CalendarHandle)
    case invalidWindow
}

public struct ApplyResult: Codable, Sendable, Equatable {
    public var created: Int
    public var updated: Int
    public var deleted: Int

    public init(created: Int = 0, updated: Int = 0, deleted: Int = 0) {
        self.created = created
        self.updated = updated
        self.deleted = deleted
    }
}

public enum ApplyError: Error, Sendable {
    /// A store operation failed; pending writes were rolled back and the
    /// target calendar is unchanged.
    case rolledBack(underlying: any Error)
    case missingTargetCalendar
}
