import AppKit
import SwiftUI

/// The menu bar item and its panel. The app places the panel itself: centered under the item
/// before it is shown, so it never jumps, and when its content changes size (another page) it
/// grows around that center. Near a screen edge it stops at the edge.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = StatusPanel()
    private let background = NSVisualEffectView()
    /// Over the blur, so text stays readable when a dark window is behind the panel.
    private let tint = PanelTint()
    private let content: SizingHostingView<AnyView>
    private let label: SizingHostingView<AnyView>
    private let contentSize = SizeReport()
    private let labelSize = SizeReport()
    /// When the panel last closed, so the click on the item that took its focus doesn't reopen it.
    private var closedAt = Date.distantPast
    /// Closes the panel on a click in another app, which doesn't always take its focus (the menu bar).
    private var outsideClicks: Any?

    private static let gap: CGFloat = 5
    private static let margin: CGFloat = 6
    private static let cornerRadius: CGFloat = 10

    init(store: UsageStore, fleet: FleetStore) {
        // Both views take their ideal size and report it; the window follows (see `place`).
        content = SizingHostingView(rootView: AnyView(
            PanelView(store: store, fleet: fleet)
                .fixedSize()
                .reportingSize(to: contentSize)))
        label = SizingHostingView(rootView: AnyView(
            HStack(spacing: 4) { MenuBarLabel(store: store) }
                .font(.system(size: 13))
                .fixedSize()
                .reportingSize(to: labelSize)))
        super.init()

        // Constraints would let AppKit resize the window from its bottom-left corner, so the
        // content just fills whatever frame `place` sets.
        content.sizingOptions = []
        content.autoresizingMask = [.width, .height]
        contentSize.onChange = { [weak self] size in
            // The first report, before layout, is empty.
            if size.width > 0, size.height > 0 { self?.place() }
        }

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        panel.contentView = background
        // Under the content, which show() adds on top.
        tint.frame = background.bounds
        tint.autoresizingMask = [.width, .height]
        tint.cornerRadius = Self.cornerRadius
        background.addSubview(tint)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        // Remembers where you ⌘-drag the item in the menu bar.
        statusItem.autosaveName = "AITempomat"
        if let button = statusItem.button {
            label.passesClicksThrough = true
            label.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        labelSize.onChange = { [weak self] _ in self?.fitLabel() }
        fitLabel()
    }

    @objc private func toggle() {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.3 {
            show()
        }
    }

    func show() {
        // Back in the window, the views run their onAppear again (refresh usage, poll the fleet).
        if content.superview == nil {
            content.frame = background.bounds
            background.addSubview(content)
        }
        place()
        // The panel takes the keyboard without activating the app, so the app you were in stays
        // in front, as with a menu.
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // Out of the window, the views run their onDisappear: the fleet stops polling.
        content.removeFromSuperview()
        statusItem.button?.highlight(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        closedAt = Date()
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    /// Centers the panel under the menu bar item at its content's size, its top just below the menu bar.
    private func place() {
        guard let button = statusItem.button, let itemWindow = button.window,
              let screen = itemWindow.screen ?? NSScreen.main else { return }
        let item = itemWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let fitting = contentSize.size ?? content.fittingSize
        let size = NSSize(width: min(fitting.width, visible.width - 2 * Self.margin),
                          height: min(fitting.height, visible.height - Self.gap - Self.margin))
        let x = min(max(item.midX - size.width / 2, visible.minX + Self.margin), visible.maxX - size.width - Self.margin)
        let top = min(item.minY, visible.maxY) - Self.gap
        let frame = NSRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// Sizes the menu bar item to its label. A wider label moves the item, and the open panel with it.
    private func fitLabel() {
        statusItem.length = ceil((labelSize.size ?? label.fittingSize).width) + 8
        if panel.isVisible { place() }
    }

    /// A stretchable rounded rectangle: the panel's shape, and so the shape of its shadow.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The panel window: borderless and translucent, above other windows, and able to take the
/// keyboard (without first activating the app) so its buttons, hover and shortcuts work.
/// Esc closes it.
final class StatusPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The panel's color over its blur: the light or dark panel background, mostly opaque. The
/// popover material alone lets a dark window behind show through enough to wash out the text;
/// this keeps a hint of the desktop and the text readable over anything.
final class PanelTint: NSView {
    static let color = NSColor(name: "AITempomatPanelTint") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.15, alpha: 0.9)
            : NSColor(white: 0.97, alpha: 0.9)
    }

    /// The panel's own, so the color stops where the blur does.
    var cornerRadius: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = Self.color.cgColor
        }
    }

    /// Light and dark mode switch the color.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A hosting view that can let clicks through to the view behind it (the menu bar button
/// under the label).
final class SizingHostingView<Content: View>: NSHostingView<Content> {
    var passesClicksThrough = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicksThrough ? nil : super.hitTest(point)
    }
}

/// The latest size a SwiftUI view reported, and who to tell when it changes.
@MainActor
final class SizeReport {
    private(set) var size: CGSize?
    var onChange: ((CGSize) -> Void)?

    func update(_ newSize: CGSize) {
        guard newSize != size else { return }
        size = newSize
        onChange?(newSize)
    }
}

extension View {
    /// Reports this view's laid-out size whenever it changes.
    func reportingSize(to report: SizeReport) -> some View {
        onGeometryChange(for: CGSize.self, of: { $0.size }) { report.update($0) }
    }
}
