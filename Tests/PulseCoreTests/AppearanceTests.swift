import Testing
@testable import PulseCore

@Suite("Codex 外观配置") struct AppearanceTests {
    private let fixture = """
    unrelated = "ignored"
    [desktop]
    appearanceTheme = "dark"
    [desktop.appearanceLightChromeTheme]
    surface = "#FAFAFA"
    ink = '#121212'
    accent = "#123456" # comment
    [desktop.appearanceLightChromeTheme.fonts]
    ui = "system"
    [desktop.appearanceDarkChromeTheme]
    surface = "#121212"
    ink = "#FAFAFA"
    accent = "#ABCDEF"
    """
    @Test func onlyAllowlistedColorsAndModeAreRead() throws {
        let appearance = try #require(CodexAppearance.parse(fixture))
        #expect(appearance.mode == "dark")
        #expect(appearance.light?.surface == 0xFAFAFA)
        #expect(appearance.dark?.ink == 0xFAFAFA)
        #expect(appearance.dark?.accent == 0xABCDEF)
        #expect(CodexAppearance.parse(fixture.replacingOccurrences(of: "appearanceTheme = \"dark\"", with: "appearanceTheme = \"system\""))?.mode == "system")
        #expect(CodexAppearance.parse(fixture.replacingOccurrences(of: "appearanceTheme = \"dark\"", with: "appearanceTheme = \"invalid\"")) == nil)
    }
    @Test func malformedUnknownAndMultilineCannotInventTheme() {
        #expect(CodexAppearance.parse("[desktop]\nappearanceTheme = \"dark\"") == nil)
        #expect(CodexAppearance.parse("unrelated = \"#123456\"") == nil)
        #expect(CodexAppearance.parse(fixture.replacingOccurrences(of: "#ABCDEF", with: "#GGGGGG"))?.dark == nil)
        #expect(CodexAppearance.parse("instructions = \"\"\"\n" + fixture + "\n\"\"\"") == nil)
        #expect(CodexAppearance.parse(fixture.replacingOccurrences(of: "[desktop.appearanceDarkChromeTheme]", with: "[other.appearanceDarkChromeTheme]"))?.dark == nil)
    }
}
