// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import CommonLibrary
import SwiftUI

struct ProfileBehaviorSection: View {
    let profileEditor: ProfileEditor

    var body: some View {
        Group {
            connectionTypePicker
            keepAliveToggle
            enforceTunnelToggle
        }
        .themeContainer(header: Strings.Modules.General.Sections.Behavior.header)
    }
}

private extension ProfileBehaviorSection {
    var isSingBoxAvailable: Bool {
        profileEditor.modules
            .compactMap { $0 as? OpenVPNModule.Builder }
            .contains { builder in
                guard let cfg = builder.configurationBuilder,
                      cfg.singBoxOverrideAddress != nil else {
                    return false
                }
                let hasReality = cfg.singBoxUUID != nil
                    && cfg.singBoxTLSServerName != nil
                    && cfg.singBoxTLSPublicKey != nil
                    && cfg.singBoxTLSShortId != nil
                let hasWS = cfg.singBoxUUID != nil && cfg.singBoxWsServerName != nil
                let hasValidHy2Obfs = (cfg.singBoxHy2ObfsType == nil && cfg.singBoxHy2ObfsPassword == nil)
                    || (cfg.singBoxHy2ObfsType != nil && cfg.singBoxHy2ObfsPassword != nil)
                let hasHy2 = cfg.singBoxHy2Password != nil && cfg.singBoxHy2ServerName != nil && hasValidHy2Obfs
                return hasReality || hasWS || hasHy2
            }
    }

    var isTelemostAvailable: Bool {
        profileEditor.modules
            .compactMap { $0 as? OpenVPNModule.Builder }
            .contains { builder in
                guard let cfg = builder.configurationBuilder,
                      let url = cfg.telemostCcUrl,
                      !url.isEmpty else {
                    return false
                }
                return true
            }
    }

    var defaultConnectionType: ConnectionType {
        if isSingBoxAvailable {
            return .singBox
        } else if isTelemostAvailable {
            return .telemost
        }
        return .direct
    }

    var effectiveConnectionType: ConnectionType {
        let stored = profileEditor.connectionType ?? defaultConnectionType
        if stored == .singBox && !isSingBoxAvailable {
            return isTelemostAvailable ? .telemost : .direct
        }
        if stored == .telemost && !isTelemostAvailable {
            return isSingBoxAvailable ? .singBox : .direct
        }
        return stored
    }

    var connectionTypePicker: some View {
        Picker("Connection Type", selection: Binding(
            get: { effectiveConnectionType },
            set: {
                if $0 == defaultConnectionType {
                    profileEditor.connectionType = nil
                } else {
                    profileEditor.connectionType = $0
                }
            }
        )) {
            Text("Direct").tag(ConnectionType.direct)
            if isSingBoxAvailable {
                Text("SingBox").tag(ConnectionType.singBox)
            }
            if isTelemostAvailable {
                Text("Telemost").tag(ConnectionType.telemost)
            }
        }
        .themeContainerEntry()
    }

    var keepAliveToggle: some View {
        Toggle(Strings.Modules.General.Rows.keepAliveOnSleep, isOn: profileEditor.binding(\.keepsAliveOnSleep))
            .themeContainerEntry(
                header: Strings.Modules.General.Sections.Behavior.header,
                subtitle: Strings.Modules.General.Rows.KeepAliveOnSleep.footer
            )
    }

    var enforceTunnelToggle: some View {
        Toggle(Strings.Modules.General.Rows.enforceTunnel, isOn: profileEditor.binding(\.enforceTunnel))
            .themeContainerEntry(subtitle: Strings.Modules.General.Rows.EnforceTunnel.footer)
    }
}

#Preview {
    Form {
        ProfileBehaviorSection(profileEditor: ProfileEditor())
    }
    .themeForm()
    .withMockEnvironment()
}
