// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import CommonLibrary
import SwiftUI

public struct ConnectionBadgeView: View {
    let header: ABI.AppProfileHeader
    let tunnel: TunnelObservable

    public init(header: ABI.AppProfileHeader, tunnel: TunnelObservable) {
        self.header = header
        self.tunnel = tunnel
    }

    public var body: some View {
        if let (text, color) = badgeInfo {
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
        }
    }

    private var badgeInfo: (String, Color)? {
        switch header.effectiveConnectionType {
        case .telemost:
            if let alive = tunnel.ydtunAlive(for: header.id) {
                return (alive ? "[tm:alive]" : "[tm:dead]", alive ? .green : .red)
            }
            return ("[tm]", .secondary)
        case .singBox:
            return ("[sb]", .secondary)
        case .direct:
            return nil
        }
    }
}
