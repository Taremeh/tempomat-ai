import AppKit
import SwiftUI

/// A newer version is out: what's new, and the Update button that pulls and builds it in the
/// clone the app was built from, or the command to run there. Then the build under way, or the
/// line it failed on.
struct UpdateBanner: View {
    let release: Release
    let state: UpdateChecker.InstallState
    /// The clone the Update button updates; without one the banner shows the command instead.
    let folder: URL?
    var install: () -> Void = {}
    var showLog: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .idle: available
            case .installing: installing
            case .failed(let line): failed(line)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var available: some View {
        HStack(alignment: .center) {
            Label("Version \(release.version) is out", systemImage: "arrow.down.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
            Spacer()
            if folder != nil {
                // Drawn here: a prominent system button turns gray in the panel, which never
                // activates the app.
                Button(action: install) {
                    Text("Update")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Pulls the new version and builds it, then restarts the app. Takes about a minute.")
            }
        }
        if let notes = release.notes {
            Text(notes)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let url = release.url {
            Link("What's new", destination: url)
                .font(.caption)
        }
        if folder == nil {
            Text("Run this in the folder you built the app from:")
                .font(.caption)
                .foregroundStyle(.secondary)
            CopyableCommand(command: UpdateInstaller.command)
        }
    }

    @ViewBuilder
    private var installing: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Updating to \(release.version)…")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
        }
        Text("Pulling and building. Takes about a minute; the app restarts when it's done.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func failed(_ line: String) -> some View {
        HStack(alignment: .center) {
            Label("Couldn't update", systemImage: "exclamationmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Spacer()
            Group {
                Button("Show log", action: showLog)
                if folder != nil {
                    Button("Try again", action: install)
                        .padding(.leading, 6)
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tint)
        }
        Text(line)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        Text("Or run it yourself:")
            .font(.caption)
            .foregroundStyle(.secondary)
        CopyableCommand(command: folder.map(UpdateInstaller.command(in:)) ?? UpdateInstaller.command)
    }
}

/// A command in a box, with a button that copies it. Too long for one line, it breaks after
/// each `&&`, where the shell reads on to the next line too, rather than mid-word.
private struct CopyableCommand: View {
    let command: String

    var body: some View {
        HStack {
            ViewThatFits(in: .horizontal) {
                Text(command)
                    .fixedSize()
                Text(command.replacingOccurrences(of: " && ", with: " &&\n"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(8)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        // In the wide layouts, the copy button stays by the command.
        .frame(maxWidth: 520, alignment: .leading)
    }
}
