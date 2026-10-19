//
//  ThemeTests.swift
//  SandboxedDashboardTests
//
//  Unit tests for Theme and design system
//

import XCTest
import SwiftUI
@testable import sandboxed_sh

final class ThemeTests: XCTestCase {

    // MARK: - Color Definitions

    func testBackgroundColorsExist() {
        // Verify all background colors are defined
        XCTAssertNotNil(Theme.backgroundPrimary)
        XCTAssertNotNil(Theme.backgroundSecondary)
        XCTAssertNotNil(Theme.backgroundTertiary)
    }

    func testCardColorsExist() {
        XCTAssertNotNil(Theme.card)
        XCTAssertNotNil(Theme.cardElevated)
    }

    func testBorderColorsExist() {
        XCTAssertNotNil(Theme.border)
        XCTAssertNotNil(Theme.borderElevated)
        XCTAssertNotNil(Theme.borderSubtle)
    }

    func testSemanticColorsExist() {
        XCTAssertNotNil(Theme.success)
        XCTAssertNotNil(Theme.warning)
        XCTAssertNotNil(Theme.error)
        XCTAssertNotNil(Theme.info)
    }

    func testTextColorsExist() {
        XCTAssertNotNil(Theme.textPrimary)
        XCTAssertNotNil(Theme.textSecondary)
        XCTAssertNotNil(Theme.textTertiary)
        XCTAssertNotNil(Theme.textMuted)
    }

    func testAccentColorsExist() {
        XCTAssertNotNil(Theme.accent)
        XCTAssertNotNil(Theme.accentLight)
    }
}
