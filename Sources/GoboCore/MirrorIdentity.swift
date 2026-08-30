// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation

/// An opaque identity marker carried in a mirror event's notes, of the form
/// `busysync:v1:<16 hex chars>`. The hash means no source title, location, or
/// identifier is legible in the target account.
public struct MirrorMarker: Hashable, Sendable, Codable, RawRepresentable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard MirrorIdentity.isV1Marker(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: MirrorMarker, rhs: MirrorMarker) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum MirrorIdentity {
    public static let v1Prefix = "busysync:v1:"

    /// The identity hash is over the source's event identifier plus, for
    /// occurrences of recurring events, the occurrence's *original* start
    /// (recurring events share one identifier across occurrences, so the
    /// occurrence must be folded in). Using the original occurrence date —
    /// rather than the current start — means rescheduling an event produces a
    /// clean update of its mirror instead of a delete-and-create.
    public static func marker(for event: SourceEvent) -> MirrorMarker {
        let key: String
        if let occurrence = event.occurrenceDate {
            key = "\(event.eventIdentifier)|\(Int(occurrence.timeIntervalSince1970.rounded()))"
        } else {
            key = event.eventIdentifier
        }
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return MirrorMarker(unchecked: v1Prefix + hex)
    }

    /// All v1 markers found in a notes field, one per line. Lines that are
    /// markers of a *different* version parse as none here — a future v2's
    /// mirrors must never be adopted (or orphan-deleted) by a v1 engine.
    public static func markers(inNotes notes: String?) -> [MirrorMarker] {
        guard let notes else { return [] }
        return notes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isV1Marker($0) }
            .map { MirrorMarker(unchecked: $0) }
    }

    /// Whether the notes carry a marker line of *any* version. Loop
    /// prevention: an event carrying any `busysync:` marker is never treated
    /// as a source, even under a misconfigured rule. The full-purge scan uses
    /// the same test so it removes mirrors from every app version.
    public static func containsAnyVersionMarker(_ notes: String?) -> Bool {
        guard let notes else { return false }
        return notes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { isAnyVersionMarker($0) }
    }

    /// Canonical notes text for a freshly created mirror.
    public static func canonicalNotes(marker: MirrorMarker) -> String {
        "This busy block is managed by Gobo.\n\(marker.rawValue)"
    }

    static func isV1Marker(_ line: String) -> Bool {
        guard line.hasPrefix(v1Prefix) else { return false }
        let suffix = line.dropFirst(v1Prefix.count)
        return suffix.count == 16 && suffix.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    static func isAnyVersionMarker(_ line: String) -> Bool {
        // busysync:v<digits>:<hex>
        guard line.hasPrefix("busysync:v") else { return false }
        let rest = line.dropFirst("busysync:v".count)
        guard let colon = rest.firstIndex(of: ":") else { return false }
        let version = rest[..<colon]
        let payload = rest[rest.index(after: colon)...]
        guard !version.isEmpty, version.allSatisfy(\.isNumber) else { return false }
        return !payload.isEmpty && payload.allSatisfy(\.isHexDigit)
    }
}
