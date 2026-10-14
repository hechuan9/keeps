import Foundation
import Testing
@testable import PhotoAssetManager

struct JustifiedAssetGridLayoutTests {
    @Test func movingPhotosKeepsNearestSurvivingScrollAnchor() {
        let ids = (0..<12).map { _ in UUID() }
        #expect(JustifiedAssetGridLayout.retainedAnchorIndex(oldIDs: ids, newIDs: Array(ids.dropFirst(2)), topIndex: 6) == 4)
        let withoutVisibleFirst = Array(ids.prefix(6)) + Array(ids.suffix(4))
        #expect(JustifiedAssetGridLayout.retainedAnchorIndex(oldIDs: ids, newIDs: withoutVisibleFirst, topIndex: 6) == 6)
        #expect(JustifiedAssetGridLayout.retainedAnchorIndex(oldIDs: ids, newIDs: Array(ids.prefix(3)), topIndex: 6) == 2)
        #expect(JustifiedAssetGridLayout.retainedAnchorIndex(oldIDs: ids, newIDs: [UUID()], topIndex: 6) == nil)
        #expect(JustifiedAssetGridLayout.retainedAnchorIndex(oldIDs: ids, newIDs: [], topIndex: 6) == nil)
    }

    @Test func mixedOrientationsFillRowsWithOnePointGaps() {
        let ratios: [CGFloat] = [1.5, 2.0 / 3, 1, 2, 0.5, 1.5, 1]
        for width: CGFloat in [240, 600, 1100] {
            let rows = JustifiedAssetGridLayout.rows(aspectRatios: ratios, availableWidth: width, targetHeight: 180)
            #expect(rows.flatMap { Array($0.indices) } == Array(ratios.indices))
            for row in rows.dropLast() {
                let occupied = row.indices.reduce(CGFloat.zero) { $0 + ratios[$1] * row.height } + CGFloat(row.indices.count - 1)
                #expect(abs(occupied - width) < 0.001)
            }
            #expect(rows.last!.height <= 180)
        }
    }

    @Test func sparseAndEmptyLibrariesDoNotProduceOversizedRows() {
        #expect(JustifiedAssetGridLayout.rows(aspectRatios: [], availableWidth: 800, targetHeight: 180).isEmpty)
        let row = JustifiedAssetGridLayout.rows(aspectRatios: [1.5], availableWidth: 800, targetHeight: 180).first!
        #expect(row.height == 180)
        #expect(JustifiedAssetGridLayout.aspectRatio(nil) == 1.5)
    }
}
