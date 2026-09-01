import RemoteKit
import SwiftUI

/// How full the model's context window is — the number that says when to
/// /summarize. Quiet by design: a caption-sized instrument beside the
/// working indicator, raising its voice (caution tint) only once the
/// window is actually getting tight.
struct UsageBadge: View {
    let usage: TurnUsage

    var body: some View {
        Text(label)
            .font(.caption.monospacedDigit())
            .foregroundStyle(tight ? Color.caution : Color.inkMuted)
            .accessibilityLabel(spoken)
    }

    private var label: String {
        guard let fraction = usage.fraction else {
            return "\(Self.compact(usage.total)) tokens"
        }
        return "\(Self.compact(usage.total)) · \(Self.percent(fraction))"
    }

    private var spoken: String {
        guard let fraction = usage.fraction else {
            return "\(usage.total) tokens used"
        }
        return "\(usage.total) tokens used, \(Self.percent(fraction)) of the context window"
    }

    /// Past this, the next few turns are the ones to spend carefully —
    /// the whole reason to show the number.
    private var tight: Bool { (usage.fraction ?? 0) >= 0.8 }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// "12.4k", "1.2M" — token counts read as magnitudes, not digits.
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
