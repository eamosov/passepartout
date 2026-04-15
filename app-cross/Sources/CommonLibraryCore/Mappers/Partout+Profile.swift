// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Partout

extension Profile {
    public func abiHeaderWithBogusFlagsAndRequirements() -> ABI.AppProfileHeader {
        abiHeader(sharingFlags: [], requiredFeatures: [])
    }

    func abiHeader(
        sharingFlags: [ABI.ProfileSharingFlag],
        requiredFeatures: Set<ABI.AppFeature>
    ) -> ABI.AppProfileHeader {
        let primaryModuleType = activeModules
            .first(where: \.isPrimary)?
            .mainModuleType
        let secondaryModuleTypes = activeModules
            .filter { !$0.isPrimary }
            .map(\.moduleType)
            .nilIfEmpty

        let providerInfo: ABI.AppProfileHeader.ProviderInfo?
        if let activeProviderModule {
            providerInfo = ABI.AppProfileHeader.ProviderInfo(
                providerId: activeProviderModule.providerId,
                countryCode: activeProviderModule.entity?.header.countryCode
            )
        } else {
            providerInfo = nil
        }

        let effectiveConnectionType: ConnectionType
        if let override = attributes.connectionType {
            if override == .singBox && !hasSingBoxCapableModule {
                effectiveConnectionType = .direct
            } else {
                effectiveConnectionType = override
            }
        } else if hasSingBoxCapableModule {
            effectiveConnectionType = .singBox
        } else {
            effectiveConnectionType = .direct
        }

        return ABI.AppProfileHeader(
            id: id,
            name: name,
            moduleTypes: modules.map(\.moduleType),
            primaryModuleType: primaryModuleType,
            secondaryModuleTypes: secondaryModuleTypes,
            providerInfo: providerInfo,
            fingerprint: (attributes.fingerprint ?? UniqueID()).uuidString,
            sharingFlags: sharingFlags,
            requiredFeatures: requiredFeatures,
            effectiveConnectionType: effectiveConnectionType
        )
    }
}

private extension Profile {
    var hasSingBoxCapableModule: Bool {
        modules
            .compactMap { $0 as? OpenVPNModule }
            .contains { module in
                guard let config = module.configuration,
                      config.singBoxEnabled == true,
                      config.singBoxUUID != nil,
                      config.singBoxTLSServerName != nil,
                      config.singBoxTLSPublicKey != nil,
                      config.singBoxTLSShortId != nil else {
                    return false
                }
                return true
            }
    }
}

private extension Module {
    var isPrimary: Bool {
        self is ProviderModule || buildsConnection
    }

    var mainModuleType: ModuleType {
        if let providerModule = self as? ProviderModule {
            return providerModule.providerModuleType
        }
        return moduleType
    }
}
