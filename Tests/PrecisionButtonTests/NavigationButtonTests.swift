import Testing
@testable import PrecisionButton

@Test func onlyFinderGetsKeyboardNavigation() {
    #expect(ActionPerformer.ignoresNavigationButtons("com.apple.finder"))
    #expect(!ActionPerformer.ignoresNavigationButtons("com.apple.Safari"))
    #expect(!ActionPerformer.ignoresNavigationButtons("com.microsoft.VSCode"))
    #expect(!ActionPerformer.ignoresNavigationButtons(nil))
}
