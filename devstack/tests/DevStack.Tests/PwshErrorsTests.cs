using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>The meaningful line of a failed pwsh run: the first error record's message in each way pwsh 7 prints one.</summary>
public sealed class PwshErrorsTests
{
    private const string NotRecognized =
        "The term 'octo-cli' is not recognized as a name of a cmdlet, function, script file, or executable program. Check the spelling of the name, " +
        "or if a path was included, verify that the path is correct and try again.";

    [Fact]
    public void A_concise_error_with_a_position_box_gives_its_message_with_the_command()
    {
        const string output = "Registering local-e2e-uc-b ...\n" +
                              "Register-OctoCliContext: C:\\dev\\meshmakers\\octo-tools\\modules\\OctoCli.psm1:42\r\n" +
                              "Line |\n" +
                              "  42 |      & octo-cli -c AddContext @arguments\n" +
                              "     |        ~~~~~~~~\n" +
                              "     | The term 'octo-cli' is not recognized as a name of a cmdlet, function, script file, or executable program. Check the\n" +
                              "     | spelling of the name, or if a path was included, verify that the path is correct and try again.\n" +
                              "Exception: a second error\n";

        PwshErrors.FirstError(output).Should().Be("Register-OctoCliContext: " + NotRecognized, "the first record counts, not the last line");
    }

    [Fact]
    public void A_concise_error_without_a_position_and_a_normal_view_error_give_their_message()
    {
        PwshErrors.FirstError("noise: not an error\nRegister-OctoCliContext: The term 'octo-cli' is not recognized as a name of a cmdlet, function, script file, or\n" +
                              "executable program.\n\nlater output").Should()
            .Be("Register-OctoCliContext: The term 'octo-cli' is not recognized as a name of a cmdlet, function, script file, or executable program.");
        PwshErrors.FirstError("Exception: Remove-OctoEnvironment refused: the lane is in use").Should().Be("Exception: Remove-OctoEnvironment refused: the lane is in use");

        PwshErrors.FirstError("output\n\nocto-cli : The term 'octo-cli' is not recognized as the name of a cmdlet.\nAt line:3 char:5\n+ octo-cli -c AddContext\n" +
                              "+ ~~~~~~~~\n    + CategoryInfo          : ObjectNotFound: (octo-cli:String) [], CommandNotFoundException")
            .Should().Be("octo-cli : The term 'octo-cli' is not recognized as the name of a cmdlet.");
    }

    [Fact]
    public void Colours_are_ignored_and_output_without_an_error_record_falls_back_to_its_last_line()
    {
        PwshErrors.FirstError("\u001b[31;1mWrite-Error: \u001b[31;1mboom\u001b[0m").Should().Be("Write-Error: boom");

        PwshErrors.FirstError("{\n  \"schemaVersion\": 1\n}\n").Should().BeNull();
        PwshErrors.FirstError(null).Should().BeNull();
        PwshErrors.Summary("first\nlast line\n\n").Should().Be("last line");
        PwshErrors.Summary("   ").Should().Be("no output");
        PwshErrors.Summary("Get-Item: " + new string('x', 1000)).Should().HaveLength(400).And.EndWith("...");
    }
}
