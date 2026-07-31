import CoreGraphics
import Testing
@testable import AutoBuff

struct WindowSelectorTests {
    @Test func discoveryIsNotLimitedToCurrentSpace() {
        #expect(
            !WindowSelector.discoveryOptions.contains(.optionOnScreenOnly)
        )
        #expect(
            WindowSelector.discoveryOptions.contains(.excludeDesktopElements)
        )
    }

    @Test func keepsUntitledMapleStoryWorldsWindow() {
        let title = WindowSelector.pickerTitle(
            rawTitle: "",
            ownerName: "MapleStory Worlds"
        )

        #expect(title == "MapleStory Worlds")
    }

    @Test func rejectsOtherUntitledWindows() {
        let title = WindowSelector.pickerTitle(
            rawTitle: "  ",
            ownerName: "Window Server"
        )

        #expect(title == nil)
    }

    @Test func preservesRegularWindowTitle() {
        let title = WindowSelector.pickerTitle(
            rawTitle: "  MapleStory Worlds-Artale  ",
            ownerName: "Unknown Owner"
        )

        #expect(title == "MapleStory Worlds-Artale")
    }
}
