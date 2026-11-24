using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     A detached build step with a script of several lines, through each OS's wrapper (AB#9377). On Windows the first real
///     environment build ended without a log or exit marker: the cmd.exe command line ended at the script's first line break.
///     There the default launcher now writes the script into &lt;id&gt;.&lt;step&gt;.ps1 and runs pwsh -File; the octo-tools profile it
///     dot-sources is a harmless fake here.
/// </summary>
public sealed class BuildLauncherTests : IDisposable
{
    private readonly TestCheckout _checkout = new();

    public void Dispose() => _checkout.Dispose();

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task A_step_script_of_several_lines_runs_whole_and_leaves_its_exit_code()
    {
        var tools = Path.Combine(_checkout.Root, "octo-tools");
        Directory.CreateDirectory(Path.Combine(tools, "modules"));
        File.WriteAllText(Path.Combine(tools, "modules", "profile.ps1"), "# fake octo-tools profile");
        var log = Path.Combine(_checkout.Root, "builds", "b9.log");
        var exit = Path.Combine(_checkout.Root, "builds", "b9.1.exit");
        // The default launcher - pwsh with the (fake) profile - on every OS: -Command behind /bin/sh, a .ps1 behind cmd.exe.
        var launcher = new DetachedBuildLauncher();
        var body = "Write-Output 'line one'\nWrite-Output 'line two'\nexit 4";

        var launched = launcher.Start(new BuildLaunch(tools, body, log, exit, new Dictionary<string, string?>()));
        await launched.Process!.WaitForExitAsync(Ct);
        await Task.Delay(300, Ct); // the wrapper moves the marker into place after the step

        BuildStepFiles.ReadExit(exit).Should().Be(4, "the last line ran and its exit code reached the marker");
        TestProcess.ReadLog(log).Should().Contain("line one").And.Contain("line two");
        File.Exists(DetachedBuildLauncher.ScriptFile(exit)).Should().Be(TestProcess.Windows, "only cmd.exe needs the script in a file");
        if (TestProcess.Windows)
        {
            File.ReadAllText(DetachedBuildLauncher.ScriptFile(exit)).Should().Contain("profile.ps1").And.Contain("Write-Output 'line two'");
        }
    }

    [Fact]
    public async Task Output_that_is_not_ASCII_reaches_the_job_log_as_written_also_from_a_child_process()
    {
        // AB#9464: on Windows the step's hidden console had the OEM code page, so the box frame of a failing npm script and
        // every umlaut came out as U+FFFD in the job log (read as UTF-8). A child process writes through the same console.
        var tools = Path.Combine(_checkout.Root, "octo-tools");
        Directory.CreateDirectory(Path.Combine(tools, "modules"));
        File.WriteAllText(Path.Combine(tools, "modules", "profile.ps1"), "# fake octo-tools profile");
        var log = Path.Combine(_checkout.Root, "builds", "b8.log");
        var exit = Path.Combine(_checkout.Root, "builds", "b8.1.exit");
        var body = "Write-Output 'own: Grüße ║ ✘'\n& pwsh -NoProfile -NonInteractive -Command \"Write-Output 'child: Größe ║'\"\nexit 0";

        var launched = new DetachedBuildLauncher().Start(new BuildLaunch(tools, body, log, exit, new Dictionary<string, string?>()));
        await launched.Process!.WaitForExitAsync(Ct);
        await Task.Delay(300, Ct);

        BuildStepFiles.ReadExit(exit).Should().Be(0);
        TestProcess.ReadLog(log).Should().Contain("own: Grüße ║ ✘").And.Contain("child: Größe ║").And.NotContain("�");
    }

    [Fact]
    public async Task A_pwsh_run_with_captured_output_reads_output_that_is_not_ASCII_as_written()
    {
        // The attached runs (plans, probes, env providers) share the daemon's console: what pwsh and its children write
        // there, beyond ASCII and beyond any OEM code page, is read back as written (a Polish user name in a path).
        var tools = Path.Combine(_checkout.Root, "octo-tools");
        Directory.CreateDirectory(Path.Combine(tools, "modules"));
        File.WriteAllText(Path.Combine(tools, "modules", "profile.ps1"), "# fake octo-tools profile");

        var result = await Common.PwshRunner.RunAsync(tools,
            "Write-Output 'own: Łódź Grüße ║ ✘'\n& pwsh -NoProfile -NonInteractive -Command \"Write-Output 'child: Łódź ║'\"", null, TimeSpan.FromMinutes(1), Ct);

        result.ExitCode.Should().Be(0);
        result.Output.Should().Contain("own: Łódź Grüße ║ ✘").And.Contain("child: Łódź ║").And.NotContain("�");
    }

    [Fact]
    public void The_Windows_script_file_sits_next_to_the_exit_marker()
    {
        DetachedBuildLauncher.ScriptFile(Path.Combine("state", "builds", "b3-104847.2.exit"))
            .Should().Be(Path.Combine("state", "builds", "b3-104847.2.ps1"), "it is removed with the job's other files (same id prefix)");
    }
}
