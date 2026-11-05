import SwiftUI

/// Which Claude account the limits are for, and a way to switch it.
///
/// The limits come from `claude`, which has one login of its own. The desktop app has its own too,
/// so its Code sessions can run on another account than the one whose limits the panel shows (and
/// the panel leaves them out). The card says so when it finds them, and offers to sign `claude` in
/// to their account; opened from the header, it offers to switch to any account.
struct AccountCard: View {
    let logins: RunningLogins
    let store: UsageStore
    var setup: ClaudeSetup = .shared
    /// Opened from the header: it shows the account even when nothing's amiss, and can be closed.
    let close: (() -> Void)?
    @AppStorage(SettingsKey.dismissedAccountNotice) private var dismissed = ""

    /// The other account the running sessions use, unless that notice was put away.
    static func notice(_ logins: RunningLogins, dismissed: String) -> RunningLogins.Elsewhere? {
        guard let other = logins.elsewhere.first, noticeKey(logins.claude, other.login) != dismissed else { return nil }
        return other
    }

    private static func noticeKey(_ claude: ClaudeLogin?, _ other: ClaudeLogin) -> String {
        [claude?.account, claude?.organization, other.account, other.organization].map { $0 ?? "" }.joined(separator: "/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let other = logins.elsewhere.first {
                elsewhere(other.login, sessions: other.sessions)
            } else {
                current
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { setup.forgetFailures(olderThan: 15 * 60) }
    }

    // MARK: Sessions on another account

    @ViewBuilder
    private func elsewhere(_ other: ClaudeLogin, sessions: Int) -> some View {
        title("Your sessions run on another account", systemImage: "person.crop.circle.badge.exclamationmark")
        Text("\(sessions == 1 ? "1 running Claude Code session uses" : "\(sessions) running Claude Code sessions use") "
             + "\(name(other)). These limits are \(name(logins.claude))'s, the account Claude Code in Terminal is "
             + "signed in to, so the panel leaves those sessions out.")
            .modifier(Detail())
        switchActions(to: other, title: "Switch to \(other.email ?? "that account")",
                      note: "Signs the claude command in to it, for everything else that uses it too.") {
            if close == nil {
                Button("Not now") { dismissed = Self.noticeKey(logins.claude, other) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Hides this until the accounts change. The account icon at the top still has it.")
            }
        }
        // A second desktop instance on a third account.
        ForEach(logins.elsewhere.dropFirst(), id: \.self) { more in
            if case .idle = setup.signInState {
                Button("Or switch to \(more.login.email ?? "the other account") (\(more.sessions) running)") {
                    setup.signIn(as: more.login, refresh: refreshed)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
            }
        }
    }

    // MARK: The account as it is

    @ViewBuilder
    private var current: some View {
        if let claude = logins.claude {
            title("Limits for \(claude.email ?? "your Claude account")", systemImage: "person.crop.circle")
            Text(logins.started.isEmpty
                 ? "The account Claude Code in Terminal is signed in to."
                 : "The account Claude Code in Terminal is signed in to. Your running sessions use it too.")
                .modifier(Detail())
        } else {
            title("Account", systemImage: "person.crop.circle")
            Text("Claude Code in Terminal doesn't say which account it's signed in to.")
                .modifier(Detail())
        }
        switchActions(to: nil, title: logins.claude == nil ? "Sign in" : "Switch account",
                      note: "Opens claude.com in your browser: approve with the account you want. The claude command "
                          + "in Terminal switches with it.") { EmptyView() }
    }

    // MARK: Parts

    private func title(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(text, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.blue)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let close {
                Button("Done", action: close)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
    }

    /// The switch button, what's under way, or why it stopped; `target` nil switches to whichever
    /// account you approve in the browser.
    @ViewBuilder
    private func switchActions(to target: ClaudeLogin?, title: String, note: String,
                               @ViewBuilder trailing: () -> some View) -> some View {
        let command = "claude auth login" + (target?.email.map { " --email \($0)" } ?? "")
        switch setup.signInState {
        case .idle:
            HStack(spacing: 10) {
                AccentButton(title: title) { setup.signIn(as: target, refresh: refreshed) }
                    .help(note)
                Spacer(minLength: 0)
                trailing()
            }
            Text(note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .signingIn(let link):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(setup.signInTarget?.email.map { "Approve in your browser as \($0), then come back here." }
                     ?? "Approve in your browser, then come back here.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Cancel") { setup.cancelSignIn() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if let link {
                Link("Browser didn't open? Open the sign-in page", destination: link)
                    .font(.caption)
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline) {
                Text(message)
                    .font(.caption.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Try again") { setup.signIn(as: setup.signInTarget ?? target, refresh: refreshed) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            Text("Or in Terminal:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProblemCommand(command: command)
        }
    }

    private func name(_ login: ClaudeLogin?) -> String { login?.email ?? "another account" }

    /// Reads usage again once the sign-in is through (see `ProblemBanner`), and returns the problem that's left.
    private func refreshed() async -> UsageProblem? {
        while store.isRefreshing, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
        await store.refresh()
        return store.problem
    }

    private struct Detail: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
