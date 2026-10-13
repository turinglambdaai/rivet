import Testing
@testable import RivetSystem

@Test func fileDialogFiltersNormalizeExtensionsAndRejectPatterns() {
    let filter = RivetFileDialogFilter(
        label: "Images",
        extensions: ["PNG", ".jpg", " *.gif", "folder/png", "", "."]
    )
    #expect(filter.label == "Images")
    #expect(filter.extensions == ["png", "jpg"])
}
