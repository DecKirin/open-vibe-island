import Foundation
import SwiftUI
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct AgentsGridLayoutTests {
    @Test
    func balancedRowsTableMatchesDesignSpec() {
        #expect(V6RightSlotView.balancedRows(0) == [])
        #expect(V6RightSlotView.balancedRows(1) == [1])
        #expect(V6RightSlotView.balancedRows(2) == [2])
        #expect(V6RightSlotView.balancedRows(3) == [3])
        #expect(V6RightSlotView.balancedRows(4) == [4])
        #expect(V6RightSlotView.balancedRows(5) == [5])
        #expect(V6RightSlotView.balancedRows(6) == [6])
        #expect(V6RightSlotView.balancedRows(7) == [4, 3])
        #expect(V6RightSlotView.balancedRows(8) == [4, 4])
        #expect(V6RightSlotView.balancedRows(9) == [5, 4])
        #expect(V6RightSlotView.balancedRows(10) == [5, 5])
        #expect(V6RightSlotView.balancedRows(11) == [6, 5])
        #expect(V6RightSlotView.balancedRows(12) == [6, 6])
        #expect(V6RightSlotView.balancedRows(20) == [6, 6])
    }

    @Test
    func cellGeometryShrinksWhenMatrixNeedsThreeRows() {
        let twoRow = V6RightSlotView.cellGeometry(rowCount: 2)
        let threeRow = V6RightSlotView.cellGeometry(rowCount: 3)
        #expect(twoRow.cell == 8)
        #expect(threeRow.cell == 6)
        #expect(threeRow.cell < twoRow.cell)
    }

    @Test
    func intrinsicWidthMatchesWidestRow() {
        let claude = Color(hex: AgentTool.claudeCode.brandColorHex)!
        func cells(_ n: Int) -> [AgentGridCell] {
            (0..<n).map { _ in .session(color: claude, state: .running) }
        }
        // n=5 → [5]: single row of 5 cells → 5*8 + 4*2 = 48
        #expect(V6RightSlotView.intrinsicWidth(of: .agents(cells(5))) == 48)
        // n=8 → [4, 4]: 4*8 + 3*2 = 38
        #expect(V6RightSlotView.intrinsicWidth(of: .agents(cells(8))) == 38)
        // n=9 → [5, 4]: max row is 5 cells → 5*8 + 4*2 = 48
        #expect(V6RightSlotView.intrinsicWidth(of: .agents(cells(9))) == 48)
        // empty grid collapses to zero
        #expect(V6RightSlotView.intrinsicWidth(of: .agents([])) == 0)
    }

    @Test
    func splitIntoRowsDistributesCellsByRowSizes() {
        let claude = Color(hex: AgentTool.claudeCode.brandColorHex)!
        let cells: [AgentGridCell] = (0..<5).map { _ in .session(color: claude, state: .running) }
        let rows = V6RightSlotView.splitIntoRows(cells, rowSizes: [3, 2])
        #expect(rows.count == 2)
        #expect(rows[0].count == 3)
        #expect(rows[1].count == 2)
    }
}
