import SwiftUI
import UIKit
import RexKit

/// "Show details": the installer's tab, live and read-only. It is the app's terminal view in
/// mirror mode, so the tab keeps its own size, and it takes no touches, so it never gets the
/// keyboard or the key bar and nothing can be typed into it.
struct SetupDetailsTerminal: View {
    let run: HelperSetupRun
    let theme: TermTheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .clipShape(shape)
            .overlay(shape.stroke(theme.chrome.divider, lineWidth: 1))
            .accessibilityLabel("Installer output")
    }

    @ViewBuilder
    private var content: some View {
        if let server = run.server, let tab = run.tab {
            Mirror(server: server, sessionID: tab.session, blockID: tab.block, theme: theme)
                .allowsHitTesting(false)
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        #if DEBUG
        if let text = run.simulatedDetails {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        } else {
            waiting
        }
        #else
        waiting
        #endif
    }

    private var waiting: some View {
        Text("Nothing has run on \(run.name) yet.")
            .font(.footnote)
            .foregroundStyle(theme.chrome.tertiary)
            .multilineTextAlignment(.center)
            .padding()
    }

    /// The terminal host for one block, outside the tab's host pool: it belongs to this view and
    /// lets go of its stream when the view goes.
    private struct Mirror: UIViewRepresentable {
        let server: ServerConnection
        let sessionID: String
        let blockID: String
        let theme: TermTheme

        func makeUIView(context: Context) -> TerminalHost {
            let stream = TerminalStream(control: server.control, sessionID: sessionID, blockID: blockID)
            let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: Prefs.defaultFontSize, theme: theme)
            host.isUserInteractionEnabled = false
            return host
        }

        func updateUIView(_ host: TerminalHost, context: Context) {
            if host.theme != theme { host.applyTheme(theme) }
        }

        static func dismantleUIView(_ host: TerminalHost, coordinator: ()) {
            host.scheduleStop()
        }
    }
}
