import Foundation
import CoreGraphics

/// Finds an exposed segment of the selected Dock edge in CoreGraphics coordinates.
enum RelocationGeometry {
    enum Edge { case bottom, left, right }

    static func target(frame: CGRect, others: [CGRect], edge: Edge, preferred: CGFloat) -> CGPoint? {
        let horizontal = edge == .bottom
        var segments = [(horizontal ? frame.minX : frame.minY,
                         horizontal ? frame.maxX : frame.maxY)]
        for other in others {
            let blocks: Bool
            switch edge {
            case .bottom: blocks = other.minY <= frame.maxY + 1 && other.maxY > frame.maxY + 1
            case .left: blocks = other.maxX >= frame.minX - 1 && other.minX < frame.minX - 1
            case .right: blocks = other.minX <= frame.maxX + 1 && other.maxX > frame.maxX + 1
            }
            guard blocks else { continue }
            let lo = horizontal ? other.minX : other.minY
            let hi = horizontal ? other.maxX : other.maxY
            segments = segments.flatMap { start, end -> [(CGFloat, CGFloat)] in
                guard lo < end && hi > start else { return [(start, end)] }
                var result: [(CGFloat, CGFloat)] = []
                if lo > start { result.append((start, min(lo, end))) }
                if hi < end { result.append((max(hi, start), end)) }
                return result
            }
        }
        // Keep away from corners and monitor junctions.
        let safe = segments.filter { $0.1 - $0.0 > 20 }
        guard let longest = safe.max(by: { $0.1 - $0.0 < $1.1 - $1.0 }) else { return nil }
        let position = safe.contains { preferred >= $0.0 + 10 && preferred <= $0.1 - 10 }
            ? preferred : (longest.0 + longest.1) / 2
        switch edge {
        case .bottom: return CGPoint(x: position, y: frame.maxY - 1)
        case .left: return CGPoint(x: frame.minX + 1, y: position)
        case .right: return CGPoint(x: frame.maxX - 1, y: position)
        }
    }
}
