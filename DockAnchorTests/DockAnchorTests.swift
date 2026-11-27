//
//  DockAnchorTests.swift
//  DockAnchorTests
//
//  Created by Bradley Wyatt on 7/2/25.
//

import Testing
import CoreGraphics
@testable import DockAnchor

struct DockAnchorTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    /// Regression test for #30: dragging a file to a non-anchor display's edge moved the Dock,
    /// because the event tap only listened for `.mouseMoved`.
    @Test func eventMaskIncludesDragEvents() {
        let mask = DockMonitor.pointerMotionEventMask
        for type in [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
            #expect(mask & (CGEventMask(1) << CGEventMask(type.rawValue)) != 0, "missing \(type)")
        }
        // Clicks must not be intercepted.
        #expect(mask & (CGEventMask(1) << CGEventMask(CGEventType.leftMouseDown.rawValue)) == 0)
        #expect(mask & (CGEventMask(1) << CGEventMask(CGEventType.leftMouseUp.rawValue)) == 0)
    }

}
