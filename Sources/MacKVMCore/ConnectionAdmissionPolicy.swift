import Foundation

/// Shared admission limits for unauthenticated Bonjour/TCP listeners.
public enum ConnectionAdmissionPolicy {
    public static let maximumUnauthenticatedConnectionsPerWindow = 32
    public static let unauthenticatedConnectionWindow: TimeInterval = 10
}
