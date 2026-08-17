import SwiftUI

enum SessionStatus: Equatable {
    case waiting
    case signedOut
    case valid
    case expiring
    case expired
    case unavailable

    var color: Color {
        switch self {
        case .waiting, .signedOut, .unavailable: return .secondary
        case .valid: return .green
        case .expiring: return .orange
        case .expired: return .red
        }
    }

    var symbol: String {
        switch self {
        case .waiting: return "hourglass"
        case .signedOut: return "rectangle.portrait.and.arrow.right"
        case .valid: return "checkmark.shield.fill"
        case .expiring: return "clock.badge.exclamationmark.fill"
        case .expired: return "xmark.shield.fill"
        case .unavailable: return "questionmark.circle"
        }
    }
}

enum VPNState: Equatable {
    case officeNetwork
    case connected
    case notConnected

    var title: String {
        switch self {
        case .officeNetwork: return "Not required"
        case .connected: return "Connected"
        case .notConnected: return "Not Connected"
        }
    }

    var color: Color {
        switch self {
        case .officeNetwork, .connected: return .green
        case .notConnected: return .orange
        }
    }
}

enum KubernetesState: Equatable, Sendable {
    case connected
    case notConnected
    case authenticationRequired
    case noContext

    var title: String {
        switch self {
        case .connected: return "Connected"
        case .notConnected: return "Not Connected"
        case .authenticationRequired: return "Authentication Required"
        case .noContext: return "No Context"
        }
    }

    var color: Color {
        switch self {
        case .connected: return .green
        case .authenticationRequired: return .orange
        case .notConnected, .noContext: return .secondary
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let offersAWSLogin: Bool

    init(title: String, message: String, offersAWSLogin: Bool = true) {
        self.title = title
        self.message = message
        self.offersAWSLogin = offersAWSLogin
    }
}
