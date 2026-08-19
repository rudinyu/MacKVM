import Foundation
import MacKVMCore

struct SupportPeerInfo: Equatable, Sendable {
    let peerID: UUID
    let friendlyName: String
    let model: String
    let lastConnectedAt: Date?
    let keyFingerprint: String
}

enum SupportInformationFormatter {
    static func make(
        appVersion: String,
        appBuild: String,
        operatingSystem: String,
        localFriendlyName: String,
        localModel: String,
        localKeyFingerprint: String,
        peers: [SupportPeerInfo],
        connectionStatus: String,
        connectedPeerID: UUID?
    ) -> String {
        var lines = [
            "MacKVM Support Information",
            "App: " + singleLine(appVersion)
                + " (build " + singleLine(appBuild) + ")",
            "Operating system: " + singleLine(operatingSystem),
            "",
            "Local device",
            "  Friendly name: " + singleLine(localFriendlyName),
            "  Model: " + singleLine(localModel),
            "  Key fingerprint: " + singleLine(localKeyFingerprint),
            "",
            "Connection",
            "  Status: " + singleLine(connectionStatus),
            "  Connected peer: " + (connectedPeerID?.uuidString ?? "None"),
            "",
            "Paired devices"
        ]

        let sortedPeers = peers.sorted {
            let nameComparison = $0.friendlyName.localizedStandardCompare(
                $1.friendlyName
            )
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return $0.peerID.uuidString < $1.peerID.uuidString
        }
        if sortedPeers.isEmpty {
            lines.append("  None")
        } else {
            sortedPeers.forEach { peer in
                lines.append("  - " + singleLine(peer.friendlyName))
                lines.append("    ID: " + peer.peerID.uuidString)
                lines.append("    Model: " + singleLine(peer.model))
                lines.append(
                    "    Last connected: " + dateString(peer.lastConnectedAt)
                )
                lines.append(
                    "    Key fingerprint: " + singleLine(peer.keyFingerprint)
                )
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func singleLine(_ value: String) -> String {
        value
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
