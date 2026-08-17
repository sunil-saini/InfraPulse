import Foundation

/// VPN and office-network detection.
enum VPNDetector {
    static let defaultOfficePublicIPs: [String] = [
        "115.110.137.194",
        "182.76.180.62",
        "219.65.79.134",
        "27.123.111.126",
    ]

    private static let publicIPAddressURL = URL(string: "https://api.ipify.org")!
    private static let publicIPCache = PublicIPCache()

    static func isOnOfficeNetwork(officePublicIPs: Set<String>) async -> Bool {
        await publicIPCache.isOfficeNetwork(officePublicIPs: officePublicIPs)
    }

    /// A path change is the one event the cached IP would sit through
    static func invalidatePublicIPCache() async {
        await publicIPCache.invalidate()
    }

    private static func fetchPublicIPAddress() async -> String? {
        var request = URLRequest(url: publicIPAddressURL)
        request.timeoutInterval = 5

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let address = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidIPv4Address(trimmedAddress) ? trimmedAddress : nil
    }

    static func isValidIPv4Address(_ address: String) -> Bool {
        let octets = address.split(separator: ".")
        return octets.count == 4 && octets.allSatisfy { octet in
            guard let value = Int(octet) else { return false }
            return 0...255 ~= value
        }
    }

    static func isVPNConnected() -> Bool {
        guard let scutil = Shell.run(URL(fileURLWithPath: "/usr/sbin/scutil"), ["--nc", "list"]) else {
            return false
        }
        let result = scutil.stdout
        if result.split(whereSeparator: \.isNewline).contains(where: { $0.contains("(Connected)") }) {
            return true
        }

        return hasActiveTunnelInterface()
    }

    /// One `ifconfig` covering every interface: querying each tunnel separately
    /// cost a process per interface, several times a minute, for the same answer.
    private static func hasActiveTunnelInterface() -> Bool {
        guard let all = Shell.run(URL(fileURLWithPath: "/sbin/ifconfig"), []) else { return false }

        var isTunnel = false
        var flagsAreUp = false
        var hasAddress = false

        for line in all.stdout.split(whereSeparator: \.isNewline) {
            if !(line.first?.isWhitespace ?? true) {
                // A new interface block begins; judge the one that just ended.
                if isTunnel && flagsAreUp && hasAddress { return true }
                let name = line.prefix { $0 != ":" }
                isTunnel = ["utun", "tun", "tap", "ppp"].contains { name.hasPrefix($0) }
                flagsAreUp = line.contains("UP")
                hasAddress = false
            } else if line.contains("\tinet ") || (line.contains("\tinet6 ") && !line.contains("fe80::")) {
                hasAddress = true
            }
        }

        return isTunnel && flagsAreUp && hasAddress
    }

    private actor PublicIPCache {
        private var isOfficeNetwork = false
        private var checkedAt: Date?
        private var cachedOfficePublicIPs: Set<String> = []
        private let cacheDuration: TimeInterval = 30

        func invalidate() {
            checkedAt = nil
        }

        func isOfficeNetwork(officePublicIPs: Set<String>) async -> Bool {
            if let checkedAt,
                Date().timeIntervalSince(checkedAt) < cacheDuration,
                cachedOfficePublicIPs == officePublicIPs
            {
                return isOfficeNetwork
            }

            let publicIPAddress = await VPNDetector.fetchPublicIPAddress()
            isOfficeNetwork = publicIPAddress.map { officePublicIPs.contains($0) } ?? false
            cachedOfficePublicIPs = officePublicIPs
            checkedAt = Date()
            return isOfficeNetwork
        }
    }
}
