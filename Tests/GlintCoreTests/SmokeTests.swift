import Testing
@testable import GlintCore

@Suite("Smoke")
struct SmokeTests {
    @Test func info() {
        #expect(GlintInfo.name == "Glint")
        #expect(GlintInfo.urlScheme == "glint")
    }
}
