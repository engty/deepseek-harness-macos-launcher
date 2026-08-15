import Testing
@testable import HarnessLauncher

struct PluginCommandParserTests {
    @Test
    func parsesOfficialPastedInstallCommand() throws {
        let result = try PluginCommandParser.parseInstallCommand(
            "dsh plugin --profile web add dsh-llm-codex"
        )
        #expect(result == ["add", "dsh-llm-codex"])
    }

    @Test
    func parsesQuotedSpecAndHelperCommand() throws {
        let result = try PluginCommandParser.parseInstallCommand(
            "\"/Applications/DeepSeek Harness.app/Contents/Resources/bin/deepseek-harness-plugin\" add \"file:/tmp/my plugin\""
        )
        #expect(result == ["add", "file:/tmp/my plugin"])
    }

    @Test
    func normalizesPublicGitHubShorthandForFinderLaunchedApps() throws {
        let result = try PluginCommandParser.parseInstallCommand(
            "dsh plugin --profile web add github:mishibeikejie/zat-dsh-engine#main"
        )
        #expect(result == [
            "add",
            "https://github.com/mishibeikejie/zat-dsh-engine.git#main"
        ])
    }

    @Test
    func rejectsNonInstallOrShellCommands() {
        #expect(throws: PluginCommandParserError.unsupportedCommand) {
            try PluginCommandParser.parseInstallCommand("dsh plugin --profile web remove dsh-llm-codex")
        }
        #expect(throws: PluginCommandParserError.unsupportedCommand) {
            try PluginCommandParser.parseInstallCommand("echo plugin --profile web add dsh-llm-codex")
        }
        #expect(throws: PluginCommandParserError.unsupportedCommand) {
            try PluginCommandParser.parseInstallCommand("dsh plugin --profile web add foo; rm -rf /")
        }
        #expect(throws: PluginCommandParserError.optionNotAllowed("--config")) {
            try PluginCommandParser.parseInstallCommand("dsh plugin --profile web add --config foo")
        }
    }
}
