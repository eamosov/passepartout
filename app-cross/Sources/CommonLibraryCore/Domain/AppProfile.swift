// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Partout

extension ABI {
    public struct AppProfileHeader: Identifiable, Hashable, Comparable, Codable, Sendable {
        public struct ProviderInfo: Hashable, Codable, Sendable {
            public let providerId: ProviderID
            public let countryCode: String?

            public init(providerId: ProviderID, countryCode: String?) {
                self.providerId = providerId
                self.countryCode = countryCode
            }
        }

        public private(set) var id: Profile.ID
        public let name: String
        public let moduleTypes: [ModuleType]
        public let primaryModuleType: ModuleType?
        public let secondaryModuleTypes: [ModuleType]?
        public let providerInfo: ProviderInfo?
        public let fingerprint: String
        public let sharingFlags: [ProfileSharingFlag]
        public let requiredFeatures: Set<AppFeature>
        public let effectiveConnectionType: ConnectionType

        public init(
            id: Profile.ID,
            name: String,
            moduleTypes: [ModuleType],
            primaryModuleType: ModuleType?,
            secondaryModuleTypes: [ModuleType]?,
            providerInfo: ProviderInfo?,
            fingerprint: String,
            sharingFlags: [ProfileSharingFlag],
            requiredFeatures: Set<AppFeature>,
            effectiveConnectionType: ConnectionType = .direct
        ) {
            self.id = id
            self.name = name
            self.moduleTypes = moduleTypes
            self.primaryModuleType = primaryModuleType
            self.secondaryModuleTypes = secondaryModuleTypes
            self.providerInfo = providerInfo
            self.fingerprint = fingerprint
            self.sharingFlags = sharingFlags
            self.requiredFeatures = requiredFeatures
            self.effectiveConnectionType = effectiveConnectionType
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Profile.ID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            moduleTypes = try container.decode([ModuleType].self, forKey: .moduleTypes)
            primaryModuleType = try container.decodeIfPresent(ModuleType.self, forKey: .primaryModuleType)
            secondaryModuleTypes = try container.decodeIfPresent([ModuleType].self, forKey: .secondaryModuleTypes)
            providerInfo = try container.decodeIfPresent(ProviderInfo.self, forKey: .providerInfo)
            fingerprint = try container.decode(String.self, forKey: .fingerprint)
            sharingFlags = try container.decode([ProfileSharingFlag].self, forKey: .sharingFlags)
            requiredFeatures = try container.decode(Set<AppFeature>.self, forKey: .requiredFeatures)
            effectiveConnectionType = try container.decodeIfPresent(ConnectionType.self, forKey: .effectiveConnectionType) ?? .direct
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.name.lowercased() < rhs.name.lowercased()
        }
    }

    public enum AppTunnelStatus: Int, Codable, Sendable {
        case disconnected
        case connecting
        case connected
        case disconnecting
    }

    public struct AppTunnelInfo: Identifiable, Hashable, Codable, Sendable {
        public let id: Profile.ID
        public let status: AppTunnelStatus
        public let onDemand: Bool

        public init(id: Profile.ID, status: AppTunnelStatus, onDemand: Bool) {
            self.id = id
            self.status = status
            self.onDemand = onDemand
        }
    }
}
