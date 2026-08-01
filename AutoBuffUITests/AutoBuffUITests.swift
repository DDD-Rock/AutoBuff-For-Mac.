//
//  AutoBuffUITests.swift
//  AutoBuffUITests
//
//  Created by 王新伟 on 2026/6/6.
//

import XCTest
import ApplicationServices
import AppKit

final class AutoBuffUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 3))
        let elements = app.descendants(matching: .any)
        XCTAssertTrue(elements["app.title"].exists)
        XCTAssertTrue(elements["window.identify"].exists)
        let workerButton = elements["worker.toggle"]
        XCTAssertTrue(workerButton.exists)
        XCTAssertGreaterThan(workerButton.frame.width, 220)
        XCTAssertTrue(elements["settings.title"].exists)
        XCTAssertTrue(elements["mode.dead"].exists)
        XCTAssertTrue(elements["mode.live"].exists)
        XCTAssertTrue(elements["mode.temple"].exists)
    }

    @MainActor
    func testDurationFieldStartsUnfocusedAndBlankTapDismissesFocus() throws {
        let app = XCUIApplication()
        app.launch()

        let durationField = app.textFields["buff.duration.1"]
        XCTAssertTrue(durationField.waitForExistence(timeout: 3))
        XCTAssertNotEqual(focusedRole(for: app), kAXTextFieldRole as String)

        durationField.click()
        XCTAssertEqual(focusedRole(for: app), kAXTextFieldRole as String)

        let appHeader = app.descendants(matching: .any)["app.title"]
        XCTAssertTrue(appHeader.exists)
        appHeader.click()
        XCTAssertNotEqual(focusedRole(for: app), kAXTextFieldRole as String)
    }

    @MainActor
    func testSidebarIsAlwaysVisibleWithoutAToggle() throws {
        let app = XCUIApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        let toggle = app.descendants(matching: .any)["sidebar.toggle"]
        XCTAssertFalse(toggle.exists)
        XCTAssertTrue(app.descendants(matching: .any)["app.title"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["mode.dead"].exists)
        XCTAssertTrue(window.exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }

    private func focusedRole(for app: XCUIApplication) -> String? {
        guard let processID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "cc.juanwang.AutoBuff")
            .first?
            .processIdentifier else {
            return nil
        }
        let application = AXUIElementCreateApplication(processID)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue else {
            return nil
        }

        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success else {
            return nil
        }
        return roleValue as? String
    }
}
