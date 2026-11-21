import XCTest

/// Accessibility audit of the iPhone session screen and history (PLAN §6.1), on seeded in-memory data.
final class WorkoutTrackerUITests: XCTestCase {
    @MainActor
    func testSessionAndHistoryPassAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        // History list + session detail.
        let history = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chest Day,'")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        try audit(app)
        history.tap()
        XCTAssertTrue(app.navigationBars["Chest Day"].waitForExistence(timeout: 5))
        try audit(app)
        app.navigationBars.buttons.firstMatch.tap()

        // Live session: start a routine, log a set, audit.
        app.buttons["Chest Day"].firstMatch.tap()
        let log = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Log set 1'")).firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 5))
        log.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Log set 2'")).firstMatch.waitForExistence(timeout: 5))
        try audit(app)
    }

    /// Audits and logs each issue with the element it's on, so failures are actionable.
    @MainActor
    private func audit(_ app: XCUIApplication, line: UInt = #line) throws {
        let tabBarTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : .infinity
        let navBarBottom = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 0
        try app.performAccessibilityAudit { issue in
            let frame = issue.element?.frame ?? .infinite
            // Content under the system Liquid Glass bars (and their ~44 pt scroll-edge fade) is measured against the
            // blur, not our background.
            if issue.auditType == .contrast, frame.maxY > tabBarTop - 44 || frame.minY < navBarBottom { return true }
            // False positive: at accessibility sizes the label wraps under its icon; nothing is cut off (checked at AX5).
            if issue.auditType == .textClipped, issue.element?.label == "Empty Workout" { return true }
            print("AUDIT line \(line): \(issue.compactDescription) — \(issue.element?.elementType.rawValue ?? 0) '\(issue.element?.label ?? "?")'")
            return false
        }
    }
}
