// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Network
import SwiftUI

/// Diagnostic view that checks connectivity to external services and custom hosts.
/// Mirrors the StatusFragment from ics-openvpn.
struct StatusMonitorView: View {
    @State
    private var serviceResults: [ServiceCheckResult] = StatusMonitorView.defaultServices.map {
        ServiceCheckResult(service: $0)
    }

    @State
    private var pingResults: [PingCheckResult] = []

    @State
    private var pingHosts: [String] = UserDefaults.standard.stringArray(forKey: "statusMonitorPingHosts") ?? []

    @State
    private var lastUpdate: Date?

    @State
    private var isAddingHost = false

    @State
    private var newHostText = ""

    private let timer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            servicesSection
            pingSection
        }
        .navigationTitle("Status Monitor")
        .onAppear {
            rebuildPingResults()
            performChecks()
        }
        .onReceive(timer) { _ in
            performChecks()
        }
    }
}

// MARK: - Services Section

private extension StatusMonitorView {
    var servicesSection: some View {
        Section {
            ForEach(serviceResults) { result in
                ServiceCardView(result: result)
            }
            if let lastUpdate {
                Text("Last update: \(lastUpdate, format: .dateTime.hour().minute().second())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("IP Services")
        }
    }
}

// MARK: - Ping Section

private extension StatusMonitorView {
    var pingSection: some View {
        Section {
            ForEach(pingResults) { result in
                PingCardView(result: result)
            }
            .onDelete { offsets in
                let hostsToRemove = offsets.map { pingHosts[$0] }
                pingHosts.removeAll { hostsToRemove.contains($0) }
                savePingHosts()
                rebuildPingResults()
            }

            if isAddingHost {
                HStack {
                    TextField("hostname", text: $newHostText)
#if canImport(UIKit)
                        .textInputAutocapitalization(.never)
#endif
                        .autocorrectionDisabled()
                    Button {
                        addHost()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newHostText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            HStack {
                Text("Ping Hosts")
                Spacer()
                Button {
                    isAddingHost.toggle()
                } label: {
                    Image(systemName: isAddingHost ? "minus.circle" : "plus.circle")
                }
            }
        }
    }

    func addHost() {
        let host = newHostText.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !pingHosts.contains(host), pingHosts.count < 10 else {
            return
        }
        pingHosts.append(host)
        savePingHosts()
        rebuildPingResults()
        newHostText = ""
        isAddingHost = false
    }

    func rebuildPingResults() {
        pingResults = pingHosts.map { PingCheckResult(host: $0) }
    }

    func savePingHosts() {
        UserDefaults.standard.set(pingHosts, forKey: "statusMonitorPingHosts")
    }
}

// MARK: - Check Logic

private extension StatusMonitorView {
    func performChecks() {
        for i in serviceResults.indices {
            let service = serviceResults[i].service
            Task.detached {
                let result = await Self.checkService(service)
                await MainActor.run {
                    guard i < serviceResults.count else { return }
                    serviceResults[i].isReachable = result.isReachable
                    serviceResults[i].ip = result.ip
                    serviceResults[i].latencyMs = result.latencyMs
                    serviceResults[i].error = result.error
                }
            }
        }

        for i in pingResults.indices {
            let host = pingResults[i].host
            Task.detached {
                let result = await Self.pingHost(host)
                await MainActor.run {
                    guard i < pingResults.count else { return }
                    pingResults[i].isReachable = result.isReachable
                    pingResults[i].resolvedIP = result.resolvedIP
                    pingResults[i].latencyMs = result.latencyMs
                    pingResults[i].error = result.error
                }
            }
        }

        lastUpdate = Date()
    }

    static func checkService(_ service: IPService) async -> (isReachable: Bool, ip: String?, latencyMs: Int, error: String?) {
        let start = Date()
        do {
            var request = URLRequest(url: service.url)
            request.timeoutInterval = 5
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return (false, nil, 0, "HTTP \(code)")
            }

            let body = String(data: data, encoding: .utf8) ?? ""
            let ip = service.parseIP(from: body)
            return (true, ip, latency, nil)
        } catch {
            if (error as? URLError)?.code == .timedOut {
                return (false, nil, 0, "Timeout")
            }
            return (false, nil, 0, "Error")
        }
    }

    static func pingHost(_ host: String) async -> (isReachable: Bool, resolvedIP: String?, latencyMs: Int, error: String?) {
        // TCP connect to port 443 (matching ics-openvpn's doPingTcp fallback)
        let start = Date()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tcp)

        return await withCheckedContinuation { continuation in
            final class OnceGuard: @unchecked Sendable {
                private var resumed = false
                private let lock = NSLock()

                func tryResume(_ value: (Bool, String?, Int, String?), continuation: CheckedContinuation<(isReachable: Bool, resolvedIP: String?, latencyMs: Int, error: String?), Never>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: value)
                }
            }
            let guard_ = OnceGuard()

            let timeout = DispatchWorkItem {
                connection.cancel()
                guard_.tryResume((false, nil, 0, "Timeout"), continuation: continuation)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.0, execute: timeout)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeout.cancel()
                    let latency = Int(Date().timeIntervalSince(start) * 1000)
                    var ip: String?
                    if let endpoint = connection.currentPath?.remoteEndpoint {
                        ip = "\(endpoint)"
                    }
                    connection.cancel()
                    guard_.tryResume((true, ip, latency, nil), continuation: continuation)

                case .failed(let error):
                    timeout.cancel()
                    connection.cancel()
                    guard_.tryResume((false, nil, 0, error.localizedDescription), continuation: continuation)

                case .cancelled:
                    timeout.cancel()
                    guard_.tryResume((false, nil, 0, "Cancelled"), continuation: continuation)

                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }
}

// MARK: - Models

private extension StatusMonitorView {
    struct IPService: Identifiable, Sendable {
        let id: String
        let name: String
        let url: URL
        let ipParser: @Sendable (String) -> String?

        func parseIP(from body: String) -> String? {
            ipParser(body)
        }
    }

    struct ServiceCheckResult: Identifiable {
        let service: IPService
        var isReachable: Bool?
        var ip: String?
        var latencyMs: Int = 0
        var error: String?

        var id: String { service.id }
    }

    struct PingCheckResult: Identifiable {
        let host: String
        var isReachable: Bool?
        var resolvedIP: String?
        var latencyMs: Int = 0
        var error: String?

        var id: String { host }
    }

    // Matches StatusFragment.mServices in ics-openvpn
    static let defaultServices: [IPService] = [
        IPService(
            id: "ifconfig",
            name: "ifconfig.me",
            url: URL(string: "https://ifconfig.me/all.json")!,
            ipParser: { body in
                extractJSON(key: "ip_addr", from: body)
            }
        ),
        IPService(
            id: "yandex",
            name: "yandex.ru/internet",
            url: URL(string: "https://yandex.ru/internet/")!,
            ipParser: { body in
                extractJSON(key: "v4", from: body)
            }
        ),
        IPService(
            id: "ipify",
            name: "api.ipify.org",
            url: URL(string: "https://api.ipify.org/?format=json")!,
            ipParser: { body in
                extractJSON(key: "ip", from: body)
            }
        ),
        IPService(
            id: "tunnelblick",
            name: "tunnelblick.net",
            url: URL(string: "https://tunnelblick.net/ipinfo")!,
            ipParser: { body in
                body.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: ",")
                    .first
            }
        )
    ]

    /// Extracts a string value for a given JSON key using simple regex
    /// (matching ics-openvpn's parseIp approach).
    static func extractJSON(key: String, from body: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else {
            return nil
        }
        return String(body[range])
    }
}

// MARK: - Card Views

private struct ServiceCardView: View {
    let result: StatusMonitorView.ServiceCheckResult

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.service.name)
                    .font(.headline)

                if let isReachable = result.isReachable {
                    if isReachable {
                        Text("Reachable (\(result.latencyMs) ms)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(result.error ?? "Unreachable")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("Checking...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let ip = result.ip {
                Text(ip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    var indicatorColor: Color {
        guard let isReachable = result.isReachable else {
            return .gray
        }
        return isReachable ? .green : .red
    }
}

private struct PingCardView: View {
    let result: StatusMonitorView.PingCheckResult

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.host)
                    .font(.headline)

                if let isReachable = result.isReachable {
                    if isReachable {
                        Text("\(result.latencyMs) ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(result.error ?? "Unreachable")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("Checking...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let ip = result.resolvedIP {
                Text(ip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var indicatorColor: Color {
        guard let isReachable = result.isReachable else {
            return .gray
        }
        return isReachable ? .green : .red
    }
}

// MARK: - Previews

#Preview {
    NavigationStack {
        StatusMonitorView()
    }
}
