import Foundation
import KeepsAPI

enum JustifiedAssetGridLayout {
    struct Row {
        let indices: Range<Int>
        let height: CGFloat
    }

    static func aspectRatio(_ preview: KeepsPreview?) -> CGFloat {
        guard let preview, preview.width > 0, preview.height > 0 else { return 1.5 }
        return CGFloat(preview.width) / CGFloat(preview.height)
    }

    static func retainedAnchorIndex(oldIDs: [UUID], newIDs: [UUID], topIndex: Int) -> Int? {
        guard oldIDs.indices.contains(topIndex), !newIDs.isEmpty else { return nil }
        let positions = Dictionary(uniqueKeysWithValues: newIDs.enumerated().map { ($0.element, $0.offset) })
        // 被移走的首张照片以其后仍存在的照片接续；末尾整批移走时再向前寻找。
        for id in oldIDs[topIndex...] {
            if let index = positions[id] { return index }
        }
        for id in oldIDs[..<topIndex].reversed() {
            if let index = positions[id] { return index }
        }
        return nil
    }

    static func rows(aspectRatios: [CGFloat], availableWidth: CGFloat, targetHeight: CGFloat) -> [Row] {
        let width = max(1, availableWidth)
        var rows: [Row] = []
        var start = 0
        var ratioSum: CGFloat = 0
        for (index, ratio) in aspectRatios.enumerated() {
            ratioSum += ratio
            let gaps = CGFloat(index - start)
            if ratioSum * targetHeight + gaps >= width {
                rows.append(Row(indices: start..<(index + 1), height: max(1, width - gaps) / ratioSum))
                start = index + 1
                ratioSum = 0
            }
        }
        // 不把末行少量照片放大到超过用户选择的缩略图尺寸。
        if start < aspectRatios.count {
            let gaps = CGFloat(aspectRatios.count - start - 1)
            rows.append(Row(indices: start..<aspectRatios.count, height: min(targetHeight, max(1, width - gaps) / ratioSum)))
        }
        return rows
    }
}
