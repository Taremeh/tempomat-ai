import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let store: UsageStore
    @AppStorage(SettingsKey.mode) private var mode = DisplayMode.relative
    @AppStorage(SettingsKey.amount) private var amount = AmountShown.left
    @AppStorage(SettingsKey.paceMethod) private var paceMethod = PaceMethod.sensitive

    var body: some View {
        if let meter = store.headline {
            let pace = store.pace(for: meter, method: paceMethod)
            let reading = mode == .total
                ? DialReading.total(meter: meter, pace: pace, shown: amount)
                : DialReading.relative(meter: meter, pace: pace)
            Image(nsImage: GaugeIcon.image(
                fraction: reading.value.map { $0 / reading.scale },
                zone: reading.zone.map { ($0.lowerBound / reading.scale, $0.upperBound / reading.scale) }))
                .renderingMode(.template)
            Text(text(meter: meter, pace: pace, reading: reading))
        } else {
            Image(nsImage: GaugeIcon.image(fraction: nil, zone: nil))
                .renderingMode(.template)
        }
    }

    /// "38% left", "62% used" or "123% pace", plus the run-out time when it comes before the reset.
    private func text(meter: Meter, pace: Pace, reading: DialReading) -> String {
        let main = mode == .total ? "\(reading.reading) \(amount.rawValue)" : "\(reading.reading) pace"
        return pace.limitAt.map { "\(main) · \(Format.clock($0))" } ?? main
    }
}

/// A small monochrome dial for the menu bar. The red zone of the big dial is drawn dimmed.
enum GaugeIcon {
    static func image(fraction: Double?, zone: (Double, Double)?) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: 6)
            let radius: CGFloat = 8
            // AppKit angles run counter-clockwise from east; the dial runs clockwise from 210° to -30°.
            func degrees(_ fraction: Double) -> CGFloat { 210 - 240 * min(1, max(0, fraction)) }

            func stroke(from: Double, to: Double, alpha: CGFloat) {
                guard to > from else { return }
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: degrees(from), endAngle: degrees(to), clockwise: true)
                arc.lineWidth = 1.6
                arc.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                arc.stroke()
            }
            let (zoneStart, zoneEnd) = zone ?? (1, 1)
            stroke(from: 0, to: zoneStart, alpha: 1)
            stroke(from: zoneStart, to: zoneEnd, alpha: 0.35)
            stroke(from: zoneEnd, to: 1, alpha: 1)

            let angle = degrees(fraction ?? 0) * .pi / 180
            let needle = NSBezierPath()
            needle.move(to: center)
            needle.line(to: NSPoint(x: center.x + cos(angle) * (radius - 2), y: center.y + sin(angle) * (radius - 2)))
            needle.lineWidth = 1.8
            needle.lineCapStyle = .round
            NSColor.black.withAlphaComponent(fraction == nil ? 0.4 : 1).setStroke()
            needle.stroke()

            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
