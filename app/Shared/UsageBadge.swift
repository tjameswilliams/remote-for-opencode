import RemoteKit
import SwiftUI

/// How full the model's context window is: the number that says when to
/// /summarize. Quiet by design: a caption-sized instrument beside the
/// working indicator, raising its voice (caution tint) only once the
/// window is actually getting tight.
///
/// When the window is known, a ring leads the text: the filled arc is
/// what the conversation has used, the open track is what is left before
/// compaction, readable at a glance without parsing a percentage.
struct UsageBadge: View {
    let usage: TurnUsage

    var body: some View {
        HStack(spacing: 5) {
            if let fraction = usage.fraction {
                ContextRing(fraction: fraction, tint: tint)
            }
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        #if os(macOS)
        .help(spoken)
        #endif
    }

    private var label: String {
        guard let fraction = usage.fraction else {
            return "\(Self.compact(usage.total)) tokens"
        }
        return "\(Self.compact(usage.total)) · \(Self.percent(fraction))"
    }

    private var spoken: String {
        guard let fraction = usage.fraction, let limit = usage.contextLimit else {
            return "\(usage.total) tokens used"
        }
        let left = max(0, limit - usage.total)
        return "\(Self.percent(fraction)) of the context window used, \(Self.compact(left)) of \(Self.compact(limit)) tokens left"
    }

    /// Muted while there is room, caution once the next few turns are the
    /// ones to spend carefully, negative when compaction is imminent.
    private var tint: Color {
        let fraction = usage.fraction ?? 0
        if fraction >= 0.95 { return Color.negative }
        if fraction >= 0.8 { return Color.caution }
        return Color.inkMuted
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// "12.4k", "1.2M": token counts read as magnitudes, not digits.
    static func compact(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return trimmed(Double(count) / 1000) + "k"
        default: return trimmed(Double(count) / 1_000_000) + "M"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }
}

/// The context meter's dial: a hairline track with the used fraction
/// drawn over it from twelve o'clock. Sized to the caption line so it
/// reads as part of the text, not a chart.
struct ContextRing: View {
    let fraction: Double
    let tint: Color
    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 12

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.easeOut(Motion.feedback), value: fraction)
        }
        .frame(width: diameter, height: diameter)
    }

    private var lineWidth: CGFloat { max(1.5, diameter / 6) }
}
