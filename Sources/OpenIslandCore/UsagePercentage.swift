import Foundation

/// Formatting helpers shared by every usage surface.
///
/// Providers report consumption (`usedPercentage`); showing headroom instead
/// is purely a display choice, so the conversion lives here rather than in the
/// snapshot models.
public enum UsagePercentage {
    /// Headroom left in a window, rounded for display.
    ///
    /// Clamped to `0...100` because providers occasionally report slightly
    /// over 100% once a window is exhausted, and a negative "remaining"
    /// reads as a bug.
    public static func roundedRemaining(fromUsed used: Double) -> Int {
        Int(min(100, max(0, 100 - used)).rounded())
    }

    /// The number to render for a window, honouring the remaining/used toggle.
    public static func rounded(used: Double, showingRemaining: Bool) -> Int {
        showingRemaining ? roundedRemaining(fromUsed: used) : Int(used.rounded())
    }
}
