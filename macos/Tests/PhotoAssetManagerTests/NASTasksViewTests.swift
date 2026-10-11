import Testing
@testable import PhotoAssetManager

struct NASTasksViewTests {
    @Test @MainActor func taskBarHidesInactiveTasksAndKeepsFailuresVisible() {
        #expect(!NASTasksView.isVisible("idle"))
        #expect(!NASTasksView.isVisible("completed"))
        #expect(NASTasksView.isVisible("pending"))
        #expect(NASTasksView.isVisible("running"))
        #expect(NASTasksView.isVisible("failed"))
    }

    @Test @MainActor func labelsDescribePhotoWorkWithoutCallingEverythingAScan() {
        #expect(NASTasksView.statusLabel("running") == "处理中")
        #expect(NASTasksView.statusLabel("pending") == "等待中")
        #expect(NASTasksView.statusLabel("idle") == "空闲")
        #expect(NASTasksView.statusLabel("failed") == "失败")
        #expect(NASTasksView.statusLabel("completed") == "已完成")
        #expect(NASTasksView.kindLabel("manual") == "手动一次性作业")
        #expect(NASTasksView.kindLabel("maintenance") == "自动维护")
        #expect(NASTasksView.kindLabel("reconcile") == "全库补漏")
    }
}
