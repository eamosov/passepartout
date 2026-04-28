// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import CommonLibrary
import Partout

extension ABI.AppConfiguration {
    public func newConnectionTunnelRegistry(
        preferences: ABI.AppPreferenceValues,
        cachesURL: URL
    ) -> Registry {
        assert(preferences.deviceId != nil, "No Device ID found in preferences")
        pspLog(.core, .info, "Device ID: \(preferences.deviceId ?? "not set")")
        return newConnectionRegistry(
            deviceId: preferences.deviceId ?? "MissingDeviceID",
            cachesURL: cachesURL,
            configBlock: {
                preferences.enabledFlags()
            }
        )
    }

    private func newConnectionRegistry(
        deviceId: String,
        cachesURL: URL,
        configBlock: @escaping @Sendable () -> Set<ABI.ConfigFlag>
    ) -> Registry {
        let customHandlers: [ModuleHandler] = [
            ProviderModule.moduleHandler
        ]
        var allImplementations: [ModuleImplementation] = []
        var providerResolvers: [ProviderModuleResolver] = []

#if USE_CMAKE || canImport(PartoutOpenVPNConnection)
        allImplementations.append(
            OpenVPNImplementationBuilder(
                distributionTarget: bundle.distributionTarget,
                cachesURL: cachesURL,
                configBlock: configBlock
            ).build()
        )
#if !USE_CMAKE
        providerResolvers.append(OpenVPNProviderResolver())
#endif
#endif

#if USE_CMAKE || canImport(PartoutWireGuardConnection)
        allImplementations.append(
            WireGuardImplementationBuilder(
                configBlock: configBlock
            ).build()
        )
#if !USE_CMAKE
        providerResolvers.append(WireGuardProviderResolver(deviceId: deviceId))
#endif
#endif

        let mappedResolvers = providerResolvers
            .reduce(into: [:]) {
                $0[$1.moduleType] = $1
            }

        return Registry(
            withKnown: true,
            customHandlers: customHandlers,
            allImplementations: allImplementations,
            resolvedModuleBlock: {
                do {
                    return try Registry.resolvedConnectionModule($0, in: $1, with: mappedResolvers)
                } catch {
                    pspLog($1?.id, .core, .error, "Unable to resolve module: \(error)")
                    throw error
                }
            }
        )
    }
}

private extension Registry {
    @Sendable
    static func resolvedConnectionModule(
        _ module: Module,
        in profile: Profile?,
        with resolvers: [ModuleType: ProviderModuleResolver]
    ) throws -> Module {
        do {
            if let profile {
                profile.assertSingleActiveProviderModule()
                guard profile.isActiveModule(withId: module.id) else {
                    return module
                }
            }
            guard let providerModule = module as? ProviderModule else {
                return module
            }
            guard let resolver = resolvers[providerModule.providerModuleType] else {
                return module
            }
            return try resolver.resolved(from: providerModule)
        } catch {
            throw error as? PartoutError ?? PartoutError(.Providers.corruptModule, error)
        }
    }
}
