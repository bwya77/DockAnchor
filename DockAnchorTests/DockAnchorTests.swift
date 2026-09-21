import CoreGraphics
import Testing
@testable import DockAnchor

struct DockAnchorTests {
    private let ultrawide = CGRect(x: 0, y: 0, width: 3840, height: 1600)
    private let below = CGRect(x: 939, y: 1600, width: 1920, height: 1080)
    private let right = CGRect(x: 3840, y: -223, width: 1440, height: 2560)

    @Test func avoidsMonitorBelowPreferredTarget() throws {
        let target = try #require(RelocationGeometry.target(
            frame: ultrawide, others: [below, right], edge: .bottom, preferred: 1920))
        #expect(target == CGPoint(x: 3349.5, y: 1599))
    }

    @Test func preservesExposedPreferredTarget() {
        #expect(RelocationGeometry.target(
            frame: ultrawide, others: [], edge: .bottom, preferred: 1920)
            == CGPoint(x: 1920, y: 1599))
    }

    @Test func rejectsFullyBlockedBottomEdge() {
        let covering = CGRect(x: 0, y: 1600, width: 3840, height: 100)
        #expect(RelocationGeometry.target(
            frame: ultrawide, others: [covering], edge: .bottom, preferred: 1920) == nil)
    }

    @Test func rejectsFullyBlockedRightEdge() {
        #expect(RelocationGeometry.target(
            frame: ultrawide, others: [right], edge: .right, preferred: 800) == nil)
    }

    @Test func usesExposedLeftEdge() {
        #expect(RelocationGeometry.target(
            frame: ultrawide, others: [below], edge: .left, preferred: 800)
            == CGPoint(x: 1, y: 800))
    }

    @Test func subtractsOverlappingNeighbors() throws {
        let overlapping = CGRect(x: 0, y: 1600, width: 1000, height: 100)
        let target = try #require(RelocationGeometry.target(
            frame: ultrawide, others: [below, overlapping], edge: .bottom, preferred: 1920))
        #expect(target == CGPoint(x: 3349.5, y: 1599))
    }

    @Test func avoidsCornerTargets() {
        #expect(RelocationGeometry.target(
            frame: ultrawide, others: [], edge: .bottom, preferred: 0)
            == CGPoint(x: 1920, y: 1599))
    }
}
