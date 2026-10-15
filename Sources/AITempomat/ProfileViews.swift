import AppKit
import SwiftUI
import Charts

struct ProviderIcon: View {
    let provider: UsageProvider
    var size: CGFloat = 18
    /// App icons, read once: the switcher draws them on every reading.
    @MainActor private static var icons: [UsageProvider: NSImage?] = [:]
    private var icon: NSImage? {
        if let cached = Self.icons[provider] { return cached }
        let appPath = provider == .codex ? "/Applications/ChatGPT.app" : "/Applications/Claude.app"
        let icon = Bundle(path: appPath).flatMap { bundle -> NSImage? in
            guard let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else { return nil }
            let resource = file.hasSuffix(".icns") ? file : file + ".icns"
            return bundle.resourceURL.flatMap { NSImage(contentsOf: $0.appending(path: resource)) }
        }
        Self.icons[provider] = icon
        return icon
    }
    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: provider == .codex ? "bubble.left.and.bubble.right.fill" : "sun.max.fill").resizable()
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ProfilePanelView: View {
    let profiles: ProfilesStore
    var body: some View {
        if profiles.isShowingSettings {
            ProfileSettingsView(profiles: profiles)
        } else {
            PanelView(store: profiles.selected.store, fleet: profiles.selected.fleet, profiles: profiles)
                .id(profiles.selected.id)
        }
    }
}

/// The menu bar item: the selected profile's gauge and reading.
struct SelectedProfileLabel: View {
    let profiles: ProfilesStore
    var body: some View {
        HStack(spacing: 4) { MenuBarLabel(store: profiles.selected.store) }
            .help("\(profiles.selected.profile.name) — click to open usage")
    }
}

/// Every profile at a glance, app icon and percentage, one click to switch. The selected
/// profile's name sits at the end, which tells two accounts of the same app apart.
struct ProfileSwitcher: View {
    let profiles: ProfilesStore
    @AppStorage(SettingsKey.amount) private var amount = AmountShown.left

    var body: some View {
        HStack(spacing: 4) {
            ForEach(profiles.visibleProfiles) { runtime in
                let selected = runtime.id == profiles.selectedID
                Button {
                    withAnimation(.snappy(duration: 0.2)) { profiles.select(runtime.id) }
                } label: {
                    HStack(spacing: 4) {
                        ProviderIcon(provider: runtime.profile.provider, size: 14)
                        reading(runtime)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(selected ? AnyShapeStyle(.primary.opacity(0.12)) : AnyShapeStyle(.clear), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? .primary : .secondary)
                .help("\(runtime.profile.name) · \(description(runtime))")
                .accessibilityLabel("\(runtime.profile.name), \(description(runtime))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 8)
            Text(profiles.selected.profile.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
    }

    @ViewBuilder private func reading(_ runtime: ProfileRuntime) -> some View {
        if let meter = runtime.store.headline, runtime.store.problem == nil {
            Text(Format.percent(amount.value(meter.percent)))
        } else if runtime.store.problem != nil {
            Image(systemName: "exclamationmark.circle")
        } else {
            Text("—")
        }
    }

    private func description(_ runtime: ProfileRuntime) -> String {
        if let problem = runtime.store.problem { return problem.title }
        guard let meter = runtime.store.headline else { return "no reading yet" }
        return "\(Format.percent(amount.value(meter.percent))) \(amount.rawValue)"
    }
}

struct ProfileSettingsView: View {
    let profiles: ProfilesStore
    @State private var adding = false
    @State private var provider = UsageProvider.claudeDesktop
    @State private var name = ""
    @State private var path = UsageProvider.claudeDesktop.defaultPath

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { profiles.isShowingSettings = false } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).help("Back to usage")
                Text("Profiles").font(.headline)
                Spacer()
                Button("Done") { profiles.isShowingSettings = false }
            }
            Text("Choose which accounts appear in the panel’s switcher. The menu bar shows the one you pick there.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(profiles.profiles) { runtime in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                ProviderIcon(provider: runtime.profile.provider, size: 22)
                                TextField("Profile name", text: Binding(get: { runtime.profile.name }, set: { profiles.rename(runtime, to: $0) }))
                                    .textFieldStyle(.roundedBorder)
                                Toggle("Show", isOn: Binding(get: { runtime.profile.showInMenuBar }, set: { profiles.setVisible(runtime, $0) }))
                                    .toggleStyle(.checkbox).fixedSize()
                                Button { profiles.remove(runtime) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).disabled(profiles.profiles.count == 1)
                                    .help("Remove profile; saved history is retained")
                            }
                            Text(runtime.profile.provider.title).font(.caption.weight(.medium))
                            Text(runtime.profile.path).font(.caption2).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(2)
                            if runtime.profile.provider == .claudeDesktop {
                                ProfileConnectionButton(runtime: runtime)
                            }
                            if let problem = runtime.store.problem {
                                Text(problem.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if adding {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("App", selection: $provider) {
                                ForEach(UsageProvider.allCases) { Text($0.title).tag($0) }
                            }
                            .onChange(of: provider) { _, value in path = value.defaultPath }
                            TextField("Profile name", text: $name)
                            TextField("Profile folder", text: $path)
                            Text(provider == .claudeDesktop ? "Use the desktop app’s profile folder, such as Claude-Work."
                                 : provider == .codex ? "Use the Codex home folder for this login."
                                 : "Use a Claude Code configuration folder with its own plan login.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Cancel") { adding = false }
                                Spacer()
                                Button("Add") {
                                    profiles.add(name: name, provider: provider, path: path)
                                    name = ""
                                    adding = false
                                }
                                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !path.hasPrefix("/") && !path.hasPrefix("~/"))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 410)
            HStack {
                Button { adding.toggle() } label: { Label("Add profile", systemImage: "plus") }
                Spacer()
                Text("\(profiles.visibleProfiles.count) in switcher").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 490)
    }
}

struct ProfileConnectionButton: View {
    let runtime: ProfileRuntime
    @State private var confirming = false
    @State private var connected = false

    var body: some View {
        Button(connected ? "Reconnect Claude…" : "Connect Claude…") { confirming = true }
            .font(.caption)
            .disabled(runtime.isDemo)
            .onAppear { connected = ClaudeDesktopSource.isAccessAllowed(to: runtime.profile.directory) }
            .alert("Connect \(runtime.profile.name)?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) { }
                Button("Allow local sign-in access") {
                    guard !runtime.isDemo else { return }
                    ClaudeDesktopSource.allowAccess(to: runtime.profile.directory)
                    connected = true
                    Task { await runtime.store.refresh() }
                }
            } message: {
                Text("Tempomat will read Claude’s Keychain encryption key and decrypt the saved sign-in in this profile folder. The token stays in memory and is sent only to Anthropic to read usage. Tempomat does not save tokens or change your Claude login. macOS may ask for Keychain access.")
            }
    }
}

/// Usage-only profiles have percentage history without borrowing another account's transcripts.
struct ProfileUsageHistory: View {
    let store: UsageStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Usage history").font(.headline)
                ForEach(store.meters) { meter in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(meter.title).font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(Format.percent(meter.percent)) used").font(.caption).monospacedDigit()
                        }
                        let samples = store.samples(for: meter)
                        if samples.count > 1 {
                            Chart(Array(samples.enumerated()), id: \.offset) { sample in
                                LineMark(x: .value("Time", sample.element.t), y: .value("Used", sample.element.p))
                            }
                            .chartYScale(domain: 0...100)
                            .frame(height: 110)
                        } else {
                            Text("Readings build up while Tempomat runs.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !store.archive.windows.isEmpty {
                    Divider()
                    Text("Completed windows").font(.caption.weight(.semibold))
                    ForEach(Array(store.archive.windows.suffix(30).reversed().enumerated()), id: \.offset) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(store.meters.first { $0.id == item.element.meter }?.title ?? item.element.meter)
                                Text(item.element.reset.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.element.samples.last.map { "\(Format.percent($0.p)) used" } ?? "—")
                        }
                        .font(.caption)
                    }
                }
                Text("Percentages and reset times come from this profile’s subscription. Local session and token details are available for Claude Code CLI profiles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: 430)
    }
}
