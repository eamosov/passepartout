// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if USE_CMAKE || canImport(PartoutOpenVPNConnection)
import Partout

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
            singBoxRunnerBlock: { newSingBoxRunner() }
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

        // Create sing-box runner if configuration has sb_enable
        let singBoxRunner: SingBoxRunner?
        if module.configuration?.singBoxEnabled == true {
            singBoxRunner = newSingBoxRunner()
        } else {
            singBoxRunner = nil
        }

        return try OpenVPNConnection(
            ctx,
            parameters: parameters,
            module: module,
            cachesURL: cachesURL,
            singBoxRunner: singBoxRunner,
            options: options
        )
    }
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
