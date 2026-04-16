// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import CommonLibrary
import Observation

@MainActor @Observable
public final class TunnelObservable {
    private let abi: AppABITunnelProtocol
    private let formatter: LogFormatter?

    public private(set) var activeProfiles: [Profile.ID: ABI.AppTunnelInfo]
    public private(set) var transfers: [Profile.ID: ABI.ProfileTransfer]
    public private(set) var subStatuses: [Profile.ID: String] = [:]
    public private(set) var ydtunAliveStates: [Profile.ID: Bool] = [:]
    public private(set) var ydtunApiPorts: [Profile.ID: UInt16] = [:]
    private var subscription: Task<Void, Never>?
    private var environmentPollingTask: Task<Void, Never>?

    public init(abi: AppABITunnelProtocol, formatter: LogFormatter?) {
        self.abi = abi
        self.formatter = formatter
        activeProfiles = [:]
        transfers = [:]
    }
}

// MARK: - Actions

extension TunnelObservable {
//    public func connect(to profileId: Profile.ID, force: Bool = false) async throws {
//        try await abi.connect(to: profileId, force: force)
//    }

    public func connect(to profile: Profile, force: Bool = false) async throws {
        // Optimistic update: immediately show .connecting so toggle flips instantly
        // Only if profile is not already active (avoid downgrading .connected → .connecting)
        if activeProfiles[profile.id] == nil {
            activeProfiles[profile.id] = ABI.AppTunnelInfo(
                id: profile.id,
                status: .connecting,
                onDemand: false
            )
        }
        do {
            try await abi.connect(to: profile, force: force)
        } catch {
            // Only remove if still our optimistic entry (not overwritten by real refresh)
            if activeProfiles[profile.id]?.status == .connecting {
                activeProfiles.removeValue(forKey: profile.id)
            }
            throw error
        }
    }

//    public func reconnect(to profileId: Profile.ID) async throws {
//        try await abi.reconnect(to: profileId)
//    }

    public func disconnect(from profileId: Profile.ID) async throws {
        // Immediately clear UI state
        subStatuses.removeValue(forKey: profileId)
        ydtunAliveStates.removeValue(forKey: profileId)
        ydtunApiPorts.removeValue(forKey: profileId)
        transfers.removeValue(forKey: profileId)
        try await abi.disconnect(from: profileId)
    }

    public func currentLog() async -> [String] {
        await abi.currentLog().map {
            formatter?.formattedLog(timestamp: $0.timestamp, message: $0.message) ?? $0.message
        }
    }
}

// MARK: - State

extension TunnelObservable {
    public var activeProfile: ABI.AppTunnelInfo? {
        activeProfiles.first?.value
    }

    public func isActiveProfile(withId profileId: Profile.ID) -> Bool {
        activeProfiles.keys.contains(profileId)
    }

    public func status(for profileId: Profile.ID) -> ABI.AppTunnelStatus {
        activeProfiles[profileId]?.status ?? .disconnected
    }

    public func lastError(for profileId: Profile.ID) -> ABI.AppError? {
        abi.lastError(ofProfileId: profileId)
    }

    public func openVPNServerConfiguration(for profileId: Profile.ID) -> OpenVPN.Configuration? {
        abi.environmentValue(for: .openVPNServerConfiguration, ofProfileId: profileId) as? OpenVPN.Configuration
    }

    public func connectionSubStatus(for profileId: Profile.ID) -> String? {
        subStatuses[profileId]
    }

    public func ydtunAlive(for profileId: Profile.ID) -> Bool? {
        ydtunAliveStates[profileId]
    }

    public func ydtunApiPort(for profileId: Profile.ID) -> UInt16? {
        ydtunApiPorts[profileId]
    }

    private func updateEnvironmentPolling() {
        if activeProfiles.isEmpty {
            environmentPollingTask?.cancel()
            environmentPollingTask = nil
        } else if environmentPollingTask == nil {
            environmentPollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    self?.refreshEnvironmentValues()
                }
            }
        }
    }

    private func refreshEnvironmentValues() {
        // Only read environment values for profiles that are actually connecting/connected
        // (not for optimistic entries or disconnected profiles with stale env data)
        let activeIds = activeProfiles.filter { $0.value.status != .disconnected }
        subStatuses = activeIds.compactMapValues {
            abi.environmentValue(for: .connectionSubStatus, ofProfileId: $0.id) as? String
        }
        ydtunAliveStates = activeIds.compactMapValues {
            abi.environmentValue(for: .ydtunAlive, ofProfileId: $0.id) as? Bool
        }
        ydtunApiPorts = activeIds.compactMapValues {
            abi.environmentValue(for: .ydtunApiPort, ofProfileId: $0.id) as? UInt16
        }
    }

    func onUpdate(_ event: ABI.TunnelEvent) {
//        pspLog(.core, .debug, "TunnelObservable.onUpdate(): \(event)")
        switch event {
        case .refresh(let payload):
            pspLog(.core, .debug, "TunnelObservable.onUpdate(): \(event)")
            // Preserve optimistic .connecting entries when payload has .disconnected
            // (lastUsedProfile inserts a phantom .disconnected before NE actually starts)
            var merged = payload.active
            for (id, info) in activeProfiles where info.status == .connecting {
                if merged[id] == nil || merged[id]?.status == .disconnected {
                    merged[id] = info
                }
            }
            activeProfiles = merged
            refreshEnvironmentValues()
            updateEnvironmentPolling()
        case .dataCount:
            transfers = activeProfiles.compactMapValues {
                abi.transfer(ofProfileId: $0.id)
            }
            refreshEnvironmentValues()
            pspLog(.core, .debug, "TunnelObservable.dataCount: transfers=\(transfers)")
        }
    }
}
