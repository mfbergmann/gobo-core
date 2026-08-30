// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import EventKit
import Foundation

/// Calendar permission state, simplified to what the sync engine needs.
/// Write-only access is *not* sufficient: the app must read sources and read
/// the target back to reconcile.
public enum CalendarAccess: Sendable, Equatable {
    case notDetermined
    case fullAccess
    /// Denied, restricted, or write-only — all unusable for syncing.
    case unusable

    public static var current: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .notDetermined
        case .fullAccess:
            return .fullAccess
        case .denied, .restricted, .writeOnly:
            return .unusable
        @unknown default:
            return .unusable
        }
    }

    /// Prompts for full access on first run. Access can also be *revoked*
    /// while the app is running; callers must re-check `current` before every
    /// sync, stop syncing when it goes away, and show a recovery path.
    @discardableResult
    public static func requestFullAccess(using store: EKEventStore) async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }
}
