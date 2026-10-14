import Foundation
import Testing
@testable import PhotoAssetManager

struct PhotoTagSuggestionsTests {
    @Test func suggestionsPreserveExistingTagsAndDeduplicate() throws {
        let tags = try PhotoTagSuggestions.decode(Data(#"{"tags":[" 山川 ","山川","RAW"]}"#.utf8))
        #expect(PhotoTagSuggestions.merging(["家庭", "raw"], tags) == ["家庭", "raw", "山川"])
    }

    @Test func invalidModelOutputCannotBecomePhotoTags() {
        for tags in [[""], ["\n"], ["两行\n标签"], [String(repeating: "字", count: 65)], Array(repeating: "标签", count: 13)] {
            let data = try! JSONSerialization.data(withJSONObject: ["tags": tags])
            #expect(throws: (any Error).self) { try PhotoTagSuggestions.decode(data) }
        }
    }

}
