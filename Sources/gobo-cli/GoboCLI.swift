// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ArgumentParser
import EventKit
import Foundation
import GoboCore
import GoboKit

@main
struct GoboCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gobo-cli",
        abstract: "Test harness for the Gobo sync engine against the real EventKit database.",
        discussion: """
        Everything runs locally. `plan` is read-only; `sync` writes to the \
        target calendar; `purge` removes every Gobo-created mirror. Grant \
        calendar access when prompted (the grant attaches to your terminal).
        """,
        subcommands: [Calendars.self, Plan.self, Sync.self, Purge.self],
        defaultSubcommand: Calendars.self
    )
}

// MARK: - Shared plumbing

func authorizedStore() async throws -> EventKitStore {
    let store = EventKitStore()
    if CalendarAccess.current != .fullAccess {
        let granted = try await CalendarAccess.requestFullAccess(using: store.eventStore)
        guard granted else {
            throw ValidationError("""
            Calendar access was not granted. Enable it in \
            System Settings > Privacy & Security > Calendars, then retry.
            """)
        }
    }
    return store
}

func loadRule(at path: String) throws -> SyncRule {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    return try decoder.decode(SyncRule.self, from: data)
}

func describe(_ plan: SyncPlan) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE yyyy-MM-dd HH:mm"
    var lines: [String] = []
    lines.append("Window: \(formatter.string(from: plan.window.start)) .. \(formatter.string(from: plan.window.end))")
    for warning in plan.warnings {
        lines.append("WARNING: \(warning)")
    }
    if plan.deletesSuppressed {
        lines.append("WARNING: deletes suppressed because a source calendar is missing")
    }
    lines.append("")
    lines.append("Creates (\(plan.creates.count)):")
    for create in plan.creates {
        let title = create.sourceTitle ?? "(untitled)"
        lines.append("  + \(formatter.string(from: create.spec.start)) .. \(formatter.string(from: create.spec.end))  <- \(title)")
    }
    lines.append("Updates (\(plan.updates.count)):")
    for update in plan.updates {
        let reasons = update.reasons.map(\.rawValue).joined(separator: ",")
        lines.append("  ~ \(formatter.string(from: update.spec.start)) .. \(formatter.string(from: update.spec.end))  [\(reasons)]")
    }
    lines.append("Deletes (\(plan.deletes.count)):")
    for delete in plan.deletes {
        lines.append("  - \(formatter.string(from: delete.start)) .. \(formatter.string(from: delete.end))  [\(delete.reason.rawValue)]")
    }
    if !plan.excluded.isEmpty {
        lines.append("Skipped (\(plan.excluded.count)):")
        for skip in plan.excluded {
            let title = skip.sourceTitle ?? "(untitled)"
            lines.append("  . \(formatter.string(from: skip.start))  \(title)  [\(skip.reason)]")
        }
    }
    return lines.joined(separator: "\n")
}

// MARK: - Subcommands

struct Calendars: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List calendars with identifiers, grouped by account."
    )

    func run() async throws {
        let store = try await authorizedStore()
        let calendars = try store.calendars()
        let grouped = Dictionary(grouping: calendars) { $0.accountTitle ?? "(no account)" }
        for (account, refs) in grouped.sorted(by: { $0.key < $1.key }) {
            print(account)
            for ref in refs.sorted(by: { $0.title < $1.title }) {
                var flags: [String] = []
                if !ref.allowsModifications { flags.append("read-only") }
                if !ref.supportsAvailability { flags.append("no busy/free flag") }
                let suffix = flags.isEmpty ? "" : "  (\(flags.joined(separator: ", ")))"
                print("  \(ref.title)\(suffix)")
                print("    id: \(ref.id)")
            }
        }
    }
}

struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compute and print what a sync would do, without writing anything."
    )

    @Option(name: .shortAndLong, help: "Path to a SyncRule JSON file.")
    var rule: String

    @Flag(help: "Emit the plan as JSON instead of a human-readable summary.")
    var json = false

    func run() async throws {
        let store = try await authorizedStore()
        let engine = SyncEngine(store: store)
        let syncRule = try loadRule(at: rule)
        let plan = try engine.plan(for: syncRule)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(plan), as: UTF8.self))
        } else {
            print(describe(plan))
        }
    }
}

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Plan and apply: write mirrors to the target calendar."
    )

    @Option(name: .shortAndLong, help: "Path to a SyncRule JSON file.")
    var rule: String

    func run() async throws {
        let store = try await authorizedStore()
        let engine = SyncEngine(store: store)
        let syncRule = try loadRule(at: rule)
        let plan = try engine.plan(for: syncRule)
        print(describe(plan))
        guard !plan.isEmpty else {
            print("\nNothing to do.")
            return
        }
        let result = try engine.apply(plan)
        print("\nApplied: \(result.created) created, \(result.updated) updated, \(result.deleted) deleted.")
    }
}

struct Purge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete every Gobo-created mirror in a calendar. Only marked events are touched."
    )

    @Option(name: .shortAndLong, help: "Target calendar identifier (see `gobo-cli calendars`).")
    var calendar: String

    @Option(help: "Days into the past to scan (default 366).")
    var daysBack = 366

    @Option(help: "Days into the future to scan (default 366).")
    var daysAhead = 366

    @Flag(help: "Actually delete. Without this flag the purge is printed only.")
    var confirm = false

    func run() async throws {
        let store = try await authorizedStore()
        let engine = SyncEngine(store: store)
        let now = Date()
        let plan = try engine.purgePlan(
            calendarIDs: [calendar],
            from: now.addingTimeInterval(-Double(daysBack) * 86_400),
            to: now.addingTimeInterval(Double(daysAhead) * 86_400)
        )
        print(describe(plan))
        guard confirm else {
            print("\nDry run. Re-run with --confirm to delete these \(plan.deletes.count) mirrors.")
            return
        }
        let result = try engine.apply(plan)
        print("\nDeleted \(result.deleted) mirrors.")
    }
}
