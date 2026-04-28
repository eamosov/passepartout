// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if USE_CMAKE || canImport(PartoutOpenVPNConnection)
import CommonLibraryCore
import Partout
import PartoutOpenVPNConnection

struct OpenVPNImplementationBuilder: Sendable {
    private let distributionTarget: ABI.DistributionTarget

    private let cachesURL: URL

    private let configBlock: @Sendable () -> Set<ABI.ConfigFlag>

    init(
        distributionTarget: ABI.DistributionTarget,
        cachesURL: URL,
        configBlock: @escaping @Sendable () -> Set<ABI.ConfigFlag>
    ) {
        self.distributionTarget = distributionTarget
        self.cachesURL = cachesURL
        self.configBlock = configBlock
    }

    func build() -> OpenVPNModule.Implementation {
        OpenVPNModule.Implementation(
            importerBlock: { StandardOpenVPNParser() },
            connectionBlock: {
                try crossConnection(with: $0, module: $1)
            },
            singBoxRunnerBlock: { newSingBoxRunner() },
            ydtunRunnerBlock: { newYdtunRunner() }
        )
    }
}

private extension OpenVPNImplementationBuilder {
    func crossConnection(
        with parameters: ConnectionParameters,
        module: OpenVPNModule
    ) throws -> Connection {
        let ctx = PartoutLoggerContext(parameters.profile.id)
        var options = OpenVPNConnection.Options()
        options.writeTimeout = TimeInterval(parameters.options.linkWriteTimeout) / 1000.0
        options.minDataCountInterval = TimeInterval(parameters.options.minDataCountInterval) / 1000.0

        // Create sidecar runner based on connection type override or auto-detection
        // Mutually exclusive: sing-box XOR ydtun XOR none
        let singBoxRunner: SingBoxRunner?
        let ydtunRunner: YdtunRunner?
        let connectionType = parameters.profile.attributes.connectionType

        let hasSingBoxConfig = module.configuration?.hasUsableSingBoxOutbound == true
        let hasTelemostConfig = module.configuration?.hasUsableTelemost == true

        if connectionType == .direct {
            singBoxRunner = nil
            ydtunRunner = nil
        } else if (connectionType == .singBox || connectionType == nil) && hasSingBoxConfig {
            singBoxRunner = newSingBoxRunner()
            ydtunRunner = nil
        } else if (connectionType == .telemost || connectionType == nil) && hasTelemostConfig {
            singBoxRunner = nil
            ydtunRunner = newYdtunRunner()
        } else {
            singBoxRunner = nil
            ydtunRunner = nil
        }

        return try OpenVPNConnection(
            ctx,
            parameters: parameters,
            module: module,
            cachesURL: cachesURL,
            singBoxRunner: singBoxRunner,
            ydtunRunner: ydtunRunner,
            options: options
        )
    }
}

private func newYdtunRunner() -> YdtunRunner {
#if canImport(_PartoutYdtun_C)
    return LibYdtunRunner()
#elseif os(macOS)
    if let bundlePath = Bundle.main.path(forResource: "ydtun", ofType: nil) {
        return ProcessYdtunRunner(binaryPath: bundlePath)
    }
    return ProcessYdtunRunner(binaryPath: "/usr/local/bin/ydtun")
#else
    fatalError("No YdtunRunner available")
#endif
}

private func newSingBoxRunner() -> SingBoxRunner {
#if canImport(_PartoutSingBox_C)
    return LibSingBoxRunner()
#elseif os(macOS)
    // Fallback: try to find sing-box binary in PATH or bundle
    if let bundlePath = Bundle.main.path(forResource: "sing-box", ofType: nil) {
        return ProcessSingBoxRunner(binaryPath: bundlePath)
    }
    return ProcessSingBoxRunner(binaryPath: "/usr/local/bin/sing-box")
#else
    fatalError("No SingBoxRunner available: build with sing-box xcframework or use macOS")
#endif
}
#endif
