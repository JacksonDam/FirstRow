//
//  firstrowTests.swift
//  firstRowTests
//
//  Created by Jackson Dam on 19/12/2024.
//

import XCTest
@testable import First_Row

final class firstRowTests: XCTestCase {
    func testVirtualSceneLayoutMatchesReferenceSceneAt1080p() {
        let layout = MenuVirtualSceneLayout(
            containerSize: CGSize(width: 1920, height: 1080),
            virtualSize: MenuVirtualScenePreset.widescreen,
        )

        XCTAssertEqual(layout.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.width, 1920, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.height, 1080, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.width, 0, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.height, 0, accuracy: 0.0001)
    }

    func testVirtualSceneLayoutScalesUpOnHigherLogicalResolution() {
        let layout = MenuVirtualSceneLayout(
            containerSize: CGSize(width: 2560, height: 1440),
            virtualSize: MenuVirtualScenePreset.widescreen,
        )

        XCTAssertEqual(layout.scale, 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.width, 2560, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.height, 1440, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.width, 0, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.height, 0, accuracy: 0.0001)
    }

    func testVirtualSceneLayoutCentersOnNon16By9Display() {
        let layout = MenuVirtualSceneLayout(
            containerSize: CGSize(width: 1680, height: 1050),
            virtualSize: MenuVirtualScenePreset.widescreen,
        )

        XCTAssertEqual(layout.scale, 0.875, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.width, 1680, accuracy: 0.0001)
        XCTAssertEqual(layout.fittedSize.height, 945, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.width, 0, accuracy: 0.0001)
        XCTAssertEqual(layout.offset.height, 52.5, accuracy: 0.0001)
    }
}
