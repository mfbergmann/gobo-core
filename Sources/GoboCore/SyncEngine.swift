// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// One-way mirror planner and executor. `plan` is pure with respect to the
/// target: it reads, diffs, and returns what it *would* do; `apply` executes
/// a plan as a single batch.
///
/// Invariants the engine guarantees:
/// - It never touches an event on the target calendar that does not carry a
///   busysync marker, including events the user titled "Busy" themselves.
/// - An event carrying any busysync marker is never treated as a source.
/// - Applying the same plan twice, or planning immediately after applying,
///   produces zero changes (idempotence).
public struct SyncEngine {
    private let store: any CalendarStore

    /// How far beyond the source window the target calendar is read, so a
    /// mirror whose buffer pushed it past the boundary is reconciled rather
    /// than orphaned.
    private static let targetWindowMargin: TimeInterval = 2 * 86_400

    /// EventKit round-trips dates at second granularity; comparing with a
    /// small tolerance avoids perpetual update churn.
    private static let dateTolerance: TimeInterval = 1.0

    public init(store: any CalendarStore) {
        self.store = store
    }

    // MARK: - Planning

    public func plan(
        for rule: SyncRule,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> SyncPlan {
        guard rule.windowDaysBack >= 0, rule.windowDaysAhead >= 0,
              rule.windowDaysBack + rule.windowDaysAhead > 0 else {
            throw PlanError.invalidWindow
        }
        if let clash = rule.sourceCalendars.first(where: { $0.id == rule.targetCalendarID }) {
            throw PlanError.calendarIsBothSourceAndTarget(clash)
        }

        let allCalendars = try store.calendars()
        var calendarsByID: [String: CalendarRef] = [:]
        for cal in allCalendars where calendarsByID[cal.id] == nil {
            calendarsByID[cal.id] = cal
        }

        guard let target = calendarsByID[rule.targetCalendar.id] else {
            throw PlanError.targetCalendarMissing(rule.targetCalendar)
        }
        guard target.allowsModifications else {
            throw PlanError.targetNotWritable(rule.targetCalendar)
        }

        var warnings: [PlanWarning] = []
        var sourceRefs: [CalendarRef] = []
        for handle in rule.sourceCalendars {
            if let ref = calendarsByID[handle.id] {
                sourceRefs.append(ref)
            } else {
                warnings.append(.sourceCalendarMissing(calendar: handle))
            }
        }
        let anySourceMissing = sourceRefs.count < rule.sourceCalendars.count

        if rule.filters.respectFreeAvailability {
            for ref in sourceRefs where !ref.supportsAvailability {
                warnings.append(.availabilityNotSupported(calendar: ref.handle))
            }
        }

        guard let windowStart = calendar.date(byAdding: .day, value: -rule.windowDaysBack, to: now),
              let windowEnd = calendar.date(byAdding: .day, value: rule.windowDaysAhead, to: now),
              windowStart < windowEnd else {
            throw PlanError.invalidWindow
        }
        let window = DateInterval(start: windowStart, end: windowEnd)

        // Desired state: marker -> block.
        let sourceEvents = sourceRefs.isEmpty
            ? []
            : try store.events(in: sourceRefs, from: windowStart, to: windowEnd)

        var desired: [MirrorMarker: DesiredBlock] = [:]
        var excluded: [SyncPlan.ExcludedEvent] = []
        for event in sourceEvents {
            switch EventFilter.decide(event, filters: rule.filters) {
            case .skip(let reason):
                excluded.append(SyncPlan.ExcludedEvent(
                    sourceTitle: event.title,
                    sourceCalendarID: event.calendarID,
                    start: event.start,
                    end: event.end,
                    reason: reason
                ))
                continue
            case .include:
                break
            }
            let pad = BufferCalculator.padding(for: event, settings: rule.buffers)
            let block = DesiredBlock(
                start: event.start.addingTimeInterval(-pad.before),
                end: event.end.addingTimeInterval(pad.after),
                isAllDay: event.isAllDay,
                sourceTitle: event.title,
                sourceCalendarID: event.calendarID
            )
            let marker = MirrorIdentity.marker(for: event)
            if let existing = desired[marker] {
                // The same physical event can appear in two source calendars
                // (or, astronomically rarely, two events can collide). One
                // mirror covering both is the deterministic answer.
                desired[marker] = existing.union(block)
            } else {
                desired[marker] = block
            }
        }

        // Existing state: marked events on the target, read slightly wide.
        let targetEvents = try store.events(
            in: [target],
            from: windowStart.addingTimeInterval(-Self.targetWindowMargin),
            to: windowEnd.addingTimeInterval(Self.targetWindowMargin)
        )

        var singles: [MirrorMarker: [SourceEvent]] = [:]
        var deletes: [SyncPlan.Delete] = []
        var recurringSeriesIgnored: Set<String> = []
        for event in targetEvents {
            let markers = MirrorIdentity.markers(inNotes: event.notes)
            if markers.isEmpty {
                continue // Never touch an unmarked event. Ever.
            }
            if event.occurrenceDate != nil {
                // The user opened a mirror in Calendar and made it repeat:
                // every occurrence now carries the marker but they all share
                // one event identifier, so per-event update/delete cannot
                // address them safely. Leave the series alone and say so.
                recurringSeriesIgnored.insert(event.eventIdentifier)
                continue
            }
            if markers.count > 1 {
                deletes.append(SyncPlan.Delete(
                    mirrorID: event.eventIdentifier,
                    start: event.start,
                    end: event.end,
                    reason: .multipleMarkers
                ))
                continue
            }
            singles[markers[0], default: []].append(event)
        }

        var creates: [SyncPlan.Create] = []
        var updates: [SyncPlan.Update] = []

        for (marker, block) in desired {
            let candidates = (singles[marker] ?? [])
                .sorted { $0.eventIdentifier < $1.eventIdentifier }
            guard let keeper = candidates.first else {
                creates.append(SyncPlan.Create(
                    marker: marker,
                    spec: spec(for: block, rule: rule, notes: MirrorIdentity.canonicalNotes(marker: marker)),
                    sourceTitle: block.sourceTitle,
                    sourceCalendarID: block.sourceCalendarID
                ))
                continue
            }
            for duplicate in candidates.dropFirst() {
                deletes.append(SyncPlan.Delete(
                    mirrorID: duplicate.eventIdentifier,
                    start: duplicate.start,
                    end: duplicate.end,
                    reason: .duplicate
                ))
            }

            var reasons: [UpdateReason] = []
            if !datesMatch(keeper.start, block.start) || !datesMatch(keeper.end, block.end) {
                reasons.append(.timeChanged)
            }
            if keeper.title != rule.mirrorTitle {
                reasons.append(.titleChanged)
            }
            if keeper.isAllDay != block.isAllDay {
                reasons.append(.allDayChanged)
            }
            // A target that does not support availability reads back
            // .notSupported forever; demanding Busy there would churn.
            if keeper.availability != .busy && keeper.availability != .notSupported {
                reasons.append(.availabilityNotBusy)
            }
            if keeper.hasAlarms {
                reasons.append(.hasAlarms)
            }
            if !reasons.isEmpty {
                // Preserve the existing notes: the marker is verified present,
                // and the user may have added their own text.
                updates.append(SyncPlan.Update(
                    mirrorID: keeper.eventIdentifier,
                    marker: marker,
                    spec: spec(for: block, rule: rule, notes: keeper.notes ?? MirrorIdentity.canonicalNotes(marker: marker)),
                    sourceTitle: block.sourceTitle,
                    reasons: reasons
                ))
            }
        }

        for (marker, events) in singles where desired[marker] == nil {
            for event in events {
                deletes.append(SyncPlan.Delete(
                    mirrorID: event.eventIdentifier,
                    start: event.start,
                    end: event.end,
                    reason: .orphaned
                ))
            }
        }

        if !recurringSeriesIgnored.isEmpty {
            warnings.append(.recurringMirrorsIgnored(seriesCount: recurringSeriesIgnored.count))
        }

        var deletesSuppressed = false
        if anySourceMissing && !deletes.isEmpty {
            deletes = []
            deletesSuppressed = true
        }

        creates.sort { ($0.spec.start, $0.marker.rawValue) < ($1.spec.start, $1.marker.rawValue) }
        updates.sort { ($0.spec.start, $0.marker.rawValue) < ($1.spec.start, $1.marker.rawValue) }
        deletes.sort { ($0.start, $0.mirrorID) < ($1.start, $1.mirrorID) }
        excluded.sort { ($0.start, $0.sourceCalendarID, $0.sourceTitle ?? "") < ($1.start, $1.sourceCalendarID, $1.sourceTitle ?? "") }

        return SyncPlan(
            ruleID: rule.id,
            targetCalendarID: target.id,
            window: window,
            creates: creates,
            updates: updates,
            deletes: deletes,
            excluded: excluded,
            warnings: warnings,
            deletesSuppressed: deletesSuppressed,
            managedCount: desired.count
        )
    }

    /// A plan deleting every marked event (any marker version) in the given
    /// calendars and range. Backs "Remove all mirrors created by this app."
    /// Unmarked events are untouched even here.
    public func purgePlan(calendarIDs: [String], from: Date, to: Date) throws -> SyncPlan {
        let allCalendars = try store.calendars()
        let targets = allCalendars.filter { calendarIDs.contains($0.id) }
        var deletes: [SyncPlan.Delete] = []
        if !targets.isEmpty {
            let events = try store.events(in: targets, from: from, to: to)
            var seriesSeen: Set<String> = []
            for event in events where MirrorIdentity.containsAnyVersionMarker(event.notes) {
                if event.occurrenceDate != nil {
                    // A mirror the user made recurring: all occurrences share
                    // one identifier, so emit a single whole-series delete.
                    guard seriesSeen.insert(event.eventIdentifier).inserted else { continue }
                    deletes.append(SyncPlan.Delete(
                        mirrorID: event.eventIdentifier,
                        start: event.start,
                        end: event.end,
                        reason: .purged,
                        scope: .series
                    ))
                } else {
                    deletes.append(SyncPlan.Delete(
                        mirrorID: event.eventIdentifier,
                        start: event.start,
                        end: event.end,
                        reason: .purged
                    ))
                }
            }
        }
        deletes.sort { ($0.start, $0.mirrorID) < ($1.start, $1.mirrorID) }
        return SyncPlan(
            ruleID: nil,
            targetCalendarID: nil,
            window: DateInterval(start: from, end: to),
            deletes: deletes
        )
    }

    // MARK: - Applying

    /// Executes a plan all-or-nothing: deletes, then updates, then creates,
    /// then one commit. Any failure rolls back pending writes and rethrows as
    /// `ApplyError.rolledBack`, leaving the target calendar unchanged.
    public func apply(_ plan: SyncPlan) throws -> ApplyResult {
        var result = ApplyResult()
        do {
            for delete in plan.deletes {
                switch delete.scope {
                case .single:
                    try store.delete(id: delete.mirrorID)
                case .series:
                    try store.deleteSeries(id: delete.mirrorID)
                }
                result.deleted += 1
            }
            for update in plan.updates {
                try store.update(id: update.mirrorID, to: update.spec)
                result.updated += 1
            }
            if !plan.creates.isEmpty {
                guard let targetID = plan.targetCalendarID,
                      let target = try store.calendars().first(where: { $0.id == targetID }) else {
                    throw ApplyError.missingTargetCalendar
                }
                for create in plan.creates {
                    _ = try store.create(create.spec, in: target)
                    result.created += 1
                }
            }
            try store.commit()
        } catch {
            store.rollback()
            throw ApplyError.rolledBack(underlying: error)
        }
        return result
    }

    // MARK: - Internals

    private struct DesiredBlock {
        var start: Date
        var end: Date
        var isAllDay: Bool
        var sourceTitle: String?
        var sourceCalendarID: String

        func union(_ other: DesiredBlock) -> DesiredBlock {
            DesiredBlock(
                start: min(start, other.start),
                end: max(end, other.end),
                isAllDay: isAllDay || other.isAllDay,
                sourceTitle: sourceTitle ?? other.sourceTitle,
                sourceCalendarID: sourceCalendarID
            )
        }
    }

    private func spec(for block: DesiredBlock, rule: SyncRule, notes: String) -> MirrorSpec {
        MirrorSpec(
            title: rule.mirrorTitle,
            start: block.start,
            end: block.end,
            isAllDay: block.isAllDay,
            notes: notes
        )
    }

    private func datesMatch(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < Self.dateTolerance
    }
}
