import Foundation
import Testing
@testable import OpenIslandCore

struct UsagePercentageTests {
    @Test
    func remainingIsTheComplementOfUsed() {
        #expect(UsagePercentage.roundedRemaining(fromUsed: 42) == 58)
        #expect(UsagePercentage.roundedRemaining(fromUsed: 0) == 100)
        #expect(UsagePercentage.roundedRemaining(fromUsed: 100) == 0)
    }

    @Test
    func remainingClampsProviderOvershootToZero() {
        // Providers occasionally report past 100% once a window is exhausted.
        #expect(UsagePercentage.roundedRemaining(fromUsed: 104.2) == 0)
    }

    @Test
    func remainingClampsNegativeUsedToFullHeadroom() {
        #expect(UsagePercentage.roundedRemaining(fromUsed: -3) == 100)
    }

    @Test
    func remainingRoundsRatherThanTruncates() {
        // 100 - 42.4 = 57.6, which must present as 58 rather than 57.
        #expect(UsagePercentage.roundedRemaining(fromUsed: 42.4) == 58)
        #expect(UsagePercentage.roundedRemaining(fromUsed: 42.6) == 57)
    }

    @Test
    func toggleSelectsBetweenUsedAndRemaining() {
        #expect(UsagePercentage.rounded(used: 42.4, showingRemaining: false) == 42)
        #expect(UsagePercentage.rounded(used: 42.4, showingRemaining: true) == 58)
    }
}
