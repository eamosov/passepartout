// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Partout
import Testing

struct EmulatorImportTests {
    @Test
    func givenRawOpenVPNProfileWithPemBlocks_whenImport_thenFallsBackToModuleImporter() throws {
        let registry = Registry(
            withKnown: true,
            allImplementations: [
                OpenVPNModule.Implementation(
                    importerBlock: { StandardOpenVPNParser() },
                    connectionBlock: { _, _ in throw PartoutError(.OpenVPN.connectionFailure) }
                )
            ]
        )
        let contents = """
        client
        remote example.com 1197
        proto udp
        dev tun
        setenv-safe sb_enable true
        setenv-safe sb_override_address 192.168.0.21
        setenv-safe sb_uuid 0881b6e7-8642-4bc3-a5ca-221cb21117e5
        setenv-safe sb_tls_server_name www.example.com
        setenv-safe sb_tls_public_key n4RZItVHKcv4FWHHulrn3H1SvchThXWOlKf5LDjxWnc
        setenv-safe sb_tls_short_id 53e3f896f2eadbd6
        setenv-safe telemost_display_name Alice Bob
        <key>
        -----BEGIN PRIVATE KEY-----
        AA==
        -----END PRIVATE KEY-----
        </key>
        <cert>
        -----BEGIN CERTIFICATE-----
        AA==
        -----END CERTIFICATE-----
        </cert>
        <ca>
        -----BEGIN CERTIFICATE-----
        AA==
        -----END CERTIFICATE-----
        </ca>
        """
        let profile = try registry.importedProfile(
            from: ABI.ProfileImporterInput.contents(filename: "emulator.ovpn", data: contents),
            passphrase: nil
        )
        let header = profile.abiHeaderWithBogusFlagsAndRequirements()
        #expect(header.effectiveConnectionType == ConnectionType.singBox)
    }
}
