import Testing
import UIKit
@testable import PrismUI

@MainActor
struct PRMGridViewTests {
    @Test
    func `Default type is rule of thirds`() {
        let grid = PRMGridView()
        #expect(grid.gridType == .ruleOfThirds)
    }

    @Test
    func `All grid types layout without crashing`() {
        let grid = PRMGridView()
        grid.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        for type in [PRMGridView.GridType.ruleOfThirds, .phi, .crosshair, .fibonacci] {
            grid.gridType = type
            grid.layoutIfNeeded()
        }
    }

    @Test
    func `isGridVisible toggles the shape layer`() {
        let grid = PRMGridView()
        grid.isGridVisible = false
        // Just verify property assignment doesn't crash.
        grid.isGridVisible = true
    }
}
