// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !os(tvOS)

import CommonLibrary
import SwiftUI
import WebKit

struct YdtunStatusView: View {
    let apiPort: UInt16

    var body: some View {
        WebView(
            make: { LoadOnceCoordinator(port: apiPort) },
            update: { webView, coordinator in
                guard !coordinator.hasLoaded else { return }
                coordinator.hasLoaded = true
                let url = URL(string: "http://127.0.0.1:\(coordinator.port)/")!
                webView.load(URLRequest(url: url))
            }
        )
        .navigationTitle("Ydtun Status")
    }
}

private class LoadOnceCoordinator {
    let port: UInt16
    var hasLoaded = false

    init(port: UInt16) {
        self.port = port
    }
}

#endif
