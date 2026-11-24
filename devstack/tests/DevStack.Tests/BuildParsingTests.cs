using System.Diagnostics;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>Events, log polling, error parsing, capabilities, history and path rules - files in temp folders, no pwsh, no build.</summary>
public sealed class BuildParsingTests : IDisposable
{
    private readonly TestCheckout _checkout = new();

    public void Dispose() => _checkout.Dispose();

    // ---------- capabilities ----------

    [Fact]
    public void Capabilities_of_the_main_checkout_lack_the_new_parameters()
    {
        var caps = BuildCapabilities.Parse("noise\n" + PwshRunner.Marker + FakePwsh.MainParams + "\n");

        caps.Probed.Should().BeTrue();
        caps.BuildEvents.Should().BeFalse();
        caps.RangeFeedPath.Should().BeFalse();
        caps.RangeRepoPaths.Should().BeFalse();
        caps.AllSkipKill.Should().BeFalse();
        caps.KillDotnetLaneScoped.Should().BeFalse("a single parameter arrives as a string, not as an array");
        caps.RangeMsbuildProperties.Should().BeTrue();
        caps.AllDryRun.Should().BeTrue();
        caps.Missing().Should().Contain(m => m.Contains("-EventsFile")).And.Contain(m => m.Contains("packages=private"));
    }

    [Fact]
    public void Capabilities_of_the_worktree_have_all_parameters()
    {
        var caps = BuildCapabilities.Parse(PwshRunner.Marker + FakePwsh.EnvironmentParams);

        caps.Should().Be(new BuildCapabilities(true, true, true, true, true, true, true, true, true, true, true)
        {
            Environments = new EnvironmentCapabilities(true, true, true, true, true, true, false, "env", "repos", true, true, true, true, "env")
            {
                AddRepo = true, AddRepoPath = true, AddRepoInPlace = true, AddRepoRole = true, AddRepoAddAffected = true, Sync = true, Affected = true,
                AffectedTarget = true, Get = true
            }
        });
        caps.Missing().Should().BeEmpty();
    }

    [Fact]
    public void Capabilities_without_the_environment_cmdlets_name_them_as_missing()
    {
        var caps = BuildCapabilities.Parse(PwshRunner.Marker + FakePwsh.WorktreeParams);

        caps.Environments.Should().Be(EnvironmentCapabilities.None);
        caps.Environments.Build.Should().BeFalse();
        caps.Environments.Create.Should().BeFalse();
        caps.Missing().Should().HaveCount(2).And.Contain(m => m.Contains("Invoke-BuildEnvironment")).And.Contain(m => m.Contains("lane_create"));
    }

    [Fact]
    public void Environment_cmdlets_that_name_their_parameters_differently_are_mapped()
    {
        var caps = BuildCapabilities.Parse(PwshRunner.Marker +
                                           """{"Invoke-BuildEnvironment":"env","New-OctoEnvironment":["name","repo","Json"],"Remove-OctoEnvironment":["name","Json"]}""");

        caps.Environments.Build.Should().BeTrue("a single parameter arrives as a string");
        caps.Environments.BuildEvents.Should().BeFalse();
        caps.Environments.CreateNameParameter.Should().Be("name");
        caps.Environments.CreateReposParameter.Should().Be("repo");
        caps.Environments.RemoveNameParameter.Should().Be("name");
        caps.Environments.CreateBranchName.Should().BeFalse();
        caps.Missing().Should().Contain(m => m.Contains("Invoke-BuildEnvironment -EventsFile"));
    }

    [Fact]
    public void A_probe_without_result_is_reported_not_thrown()
    {
        var caps = BuildCapabilities.Parse("pwsh: command not found\n");

        caps.Probed.Should().BeFalse();
        caps.Error.Should().Contain("no result");
        BuildCapabilities.ProbeBody().Should().Contain("Get-Command").And.Contain(PwshRunner.Marker);
    }

    [Fact]
    public async Task The_capability_probe_is_cached_per_octo_tools_path()
    {
        var fake = new FakePwsh();
        var cache = new BuildCapabilityCache(fake);

        await cache.GetAsync("/a", CancellationToken.None);
        await cache.GetAsync("/a", CancellationToken.None);
        await cache.GetAsync("/b", CancellationToken.None);

        fake.Calls.Should().HaveCount(2);
    }

    // ---------- events ----------

    [Fact]
    public void Events_give_repo_states_durations_and_the_result_and_tolerate_a_partial_line()
    {
        var text = """
                   {"schemaVersion":1,"ts":"2026-11-09T09:00:00Z","command":"Invoke-BuildRange","event":"plan","repos":[{"repo":"octo-a","mode":"dotnet"},{"repo":"octo-b","mode":"dotnet"},{"repo":"octo-c","mode":"none"}],"count":3}
                   {"schemaVersion":1,"ts":"2026-11-09T09:00:01Z","command":"Invoke-BuildRange","event":"repoStart","repo":"octo-a","index":1,"count":3}
                   {"schemaVersion":1,"ts":"2026-11-09T09:00:02Z","command":"Invoke-BuildRange","event":"phase","repo":"octo-a","phase":"packages"}
                   {"schemaVersion":1,"ts":"2026-11-09T09:01:00Z","command":"Invoke-BuildRange","event":"repoDone","repo":"octo-a","index":1,"count":3,"success":true,"seconds":59.5,"buildSeconds":50,"testSeconds":0,"packageSeconds":9.5,"copied":3,"purged":2,"logFile":"/x/octo-a/Invoke-Build.log"}
                   {"schemaVersion":1,"ts":"2026-11-09T09:01:01Z","command":"Invoke-BuildRange","event":"repoStart","repo":"octo-b","index":2,"count":3}
                   {"schemaVersion":1,"ts":"2026-11-09T09:01:02Z","command":"Invoke-BuildRange","event":"phase","repo":"octo-b","phase":"tests"}
                   {"schemaVersion":1,"ts":"2026-11-09T09:01:0
                   """;

        var events = BuildEventReader.Parse(text, [new PlanRepo("octo-a", "dotnet", "/x/octo-a")]);

        events.Repos.Select(r => r.Repo).Should().Equal("octo-a", "octo-b", "octo-c");
        var a = events.Repos[0];
        a.State.Should().Be("done");
        a.Seconds.Should().Be(59.5);
        a.Copied.Should().Be(3);
        a.Purged.Should().Be(2);
        events.Repos[1].State.Should().Be("building");
        events.Repos[1].Phase.Should().Be("tests");
        events.Repos[2].State.Should().Be("pending");
        events.Done.Should().BeNull();
        events.Lines.Should().Be(6);
    }

    [Fact]
    public void Done_and_null_counts_of_Invoke_BuildAll_are_read()
    {
        var text = """
                   {"schemaVersion":1,"ts":"2026-11-09T09:00:01Z","command":"Invoke-BuildAll","event":"repoDone","repo":"mm-x","index":1,"count":1,"success":false,"seconds":3,"buildSeconds":3,"testSeconds":0,"packageSeconds":0,"copied":null,"purged":null,"logFile":null}
                   {"schemaVersion":1,"ts":"2026-11-09T09:00:02Z","command":"Invoke-BuildAll","event":"done","success":false,"failedRepo":"mm-x","failedStep":"build","elapsedSeconds":4.2}
                   """;

        var events = BuildEventReader.Parse(text, []);

        events.Repos.Single().State.Should().Be("failed");
        events.Repos.Single().Copied.Should().BeNull();
        events.Done.Should().Be(new StepDone(false, "mm-x", "build", 4.2));
    }

    [Fact]
    public void Without_events_the_logs_of_the_plan_repos_tell_the_progress()
    {
        var a = _checkout.Repo("octo-a");
        var b = _checkout.Repo("octo-b");
        var c = _checkout.Repo("octo-c");
        var start = DateTimeOffset.Now.AddMinutes(-5);
        File.WriteAllText(Path.Combine(a, "Invoke-Build.log"), "a");
        File.SetCreationTime(Path.Combine(a, "Invoke-Build.log"), start.AddMinutes(1).LocalDateTime);
        File.SetLastWriteTime(Path.Combine(a, "Invoke-Build.log"), start.AddMinutes(3).LocalDateTime);
        File.WriteAllText(Path.Combine(b, "Invoke-Build.log"), "b");
        File.WriteAllText(Path.Combine(c, "Invoke-Build.log"), "old");
        File.SetLastWriteTime(Path.Combine(c, "Invoke-Build.log"), start.AddDays(-1).LocalDateTime);
        PlanRepo[] plan = [new("octo-a", "dotnet", a), new("octo-b", "dotnet", b), new("octo-c", "dotnet", c)];

        var running = BuildLogPoller.Poll(plan, start, stepFinished: false);

        running.Repos[0].State.Should().Be("done");
        // With a creation time the build took 2 min; file systems without one (often Linux) count from the step start.
        var creationKept = Math.Abs((File.GetCreationTime(Path.Combine(a, "Invoke-Build.log")) - start.AddMinutes(1).LocalDateTime).TotalSeconds) < 2;
        running.Repos[0].Seconds.Should().BeApproximately(creationKept ? 120 : 180, 2);
        running.Repos[1].State.Should().Be("building");
        running.Repos[2].State.Should().Be("pending", "its log is from an earlier build");

        BuildLogPoller.Poll(plan, start, stepFinished: true).Repos[1].State.Should().Be("done");
    }

    // ---------- error parser ----------

    private const string FailedBuildLog = """
                                          Determining projects to restore...
                                          /lane/octo-a/src/A/Foo.cs(12,17): error CS0103: The name 'bar' does not exist in the current context [/lane/octo-a/src/A/A.csproj]
                                          /lane/octo-a/src/A/Foo.cs(20,5): warning CS8618: Non-nullable property 'X' must contain a non-null value. [/lane/octo-a/src/A/A.csproj]
                                          /lane/octo-a/src/B/B.csproj : error NU1101: Unable to find package Meshmakers.Octo.Sdk. No packages exist with this id in source(s): nuget [/lane/octo-a/octo-a.sln]

                                          Build FAILED.

                                          /lane/octo-a/src/A/Foo.cs(20,5): warning CS8618: Non-nullable property 'X' must contain a non-null value. [/lane/octo-a/src/A/A.csproj]
                                          /lane/octo-a/src/A/Foo.cs(12,17): error CS0103: The name 'bar' does not exist in the current context [/lane/octo-a/src/A/A.csproj]
                                          /lane/octo-a/src/B/B.csproj : error NU1101: Unable to find package Meshmakers.Octo.Sdk. No packages exist with this id in source(s): nuget [/lane/octo-a/octo-a.sln]
                                              1 Warning(s)
                                              2 Error(s)

                                          Time Elapsed 00:00:07.12
                                          """;

    [Fact]
    public void Compiler_and_NuGet_errors_are_parsed_once_with_the_summary_counts()
    {
        var parsed = BuildLogParser.Parse(FailedBuildLog, "octo-a");

        parsed.ErrorCount.Should().Be(2);
        parsed.WarningCount.Should().Be(1);
        parsed.Errors.Should().HaveCount(2);
        parsed.Errors[0].Should().Be(new BuildError("octo-a", "/lane/octo-a/src/A/Foo.cs", 12, 17, "CS0103",
            "The name 'bar' does not exist in the current context", "/lane/octo-a/src/A/A.csproj"));
        parsed.Errors[1].File.Should().Be("/lane/octo-a/src/B/B.csproj");
        parsed.Errors[1].Line.Should().BeNull();
        parsed.Errors[1].Code.Should().Be("NU1101");
        parsed.Errors[1].Project.Should().Be("/lane/octo-a/octo-a.sln");
    }

    [Fact]
    public void MSBuild_errors_without_a_file_and_the_modern_summary_are_parsed()
    {
        var log = """
                  MSBUILD : error MSB1009: Project file does not exist.
                  error MSB4236: The SDK 'Microsoft.NET.Sdk' specified could not be found.
                  Build failed with 2 error(s) and 3 warning(s) in 1.2s
                  """;

        var parsed = BuildLogParser.Parse(log, "r");

        parsed.Errors.Select(e => e.Code).Should().Equal("MSB1009", "MSB4236");
        parsed.Errors[0].File.Should().Be("MSBUILD");
        parsed.Errors[1].File.Should().BeNull();
        parsed.ErrorCount.Should().Be(2);
        parsed.WarningCount.Should().Be(3);
    }

    [Fact]
    public void Errors_are_capped_per_repo_but_counted()
    {
        var log = string.Join('\n', Enumerable.Range(1, 130).Select(i => $"/f.cs({i},1): error CS1002: ; expected [/p.csproj]"));

        var parsed = BuildLogParser.Parse(log, "r");

        parsed.Errors.Should().HaveCount(BuildLogParser.MaxStoredPerRepo);
        parsed.ErrorCount.Should().Be(130);
    }

    [Fact]
    public void The_errors_of_a_script_build_are_its_lines_that_name_an_error_without_colours_and_frames()
    {
        const string output = "Building octo-frontend-libraries\n" +
                              "\u001b[31m║  ERROR: TELERIK_LICENSE environment variable is not set!   ║\u001b[0m\n" +
                              "✘ [ERROR] Could not resolve \"@meshmakers/octo-ui\"\n" +
                              "Error: Command failed: npm run build\n" +
                              "Error: Command failed: npm run build\n" +
                              "npm ERR! code ELIFECYCLE\n" +
                              "Error: Expected 0 errors, received 1\n" +
                              "    0 Error(s)\n" +
                              "Build succeeded with 0 error(s)\n" +
                              "Build at: 2026-11-19 - 0 errors in other projects\n" +
                              "Write-Output 'mirror'\n" +
                              """{"schemaVersion":1,"command":"octo-devstack-repo-build","data":{"success":false,"detail":"error in build.ps1"}}""";

        var parsed = BuildLogParser.ParseScriptOutput(output, "octo-frontend-refinery-studio", "script");

        parsed.Errors.Select(e => e.Message).Should().Equal("ERROR: TELERIK_LICENSE environment variable is not set!",
            "✘ [ERROR] Could not resolve \"@meshmakers/octo-ui\"", "Error: Command failed: npm run build", "npm ERR! code ELIFECYCLE",
            "Error: Expected 0 errors, received 1");
        parsed.ErrorCount.Should().Be(5, "each line once; 'errors', a dotnet build summary and the -Json document are no error lines");
        parsed.Errors.Should().OnlyContain(e => e.Code == "script" && e.File == null);

        // A build.ps1 that ran dotnet: its diagnostics, as for Invoke-Build.
        BuildLogParser.ParseScriptOutput("/x/a.cs(3,9): error CS0246: Foo [/x/a.csproj]\nError: build failed", "r", "script")
            .Errors.Should().ContainSingle().Which.Code.Should().Be("CS0246");
        // A dotnet summary without diagnostics: no error line, but its count stays.
        var summaryOnly = BuildLogParser.ParseScriptOutput("Build failed with 2 error(s) in 3.1s\n", "r", "script");
        summaryOnly.Errors.Should().BeEmpty("a summary names no error");
        summaryOnly.ErrorCount.Should().Be(2);

        // ... without the colour codes a script put around them.
        BuildLogParser.ParseScriptOutput("MSBUILD : error MSB1009: \u001b[31mProject file does not exist.\u001b[0m", "r", "script")
            .Errors.Should().ContainSingle().Which.Should().Match<BuildError>(e => e.Code == "MSB1009" && !e.Message.Contains('\u001b'));
    }

    // ---------- history ----------

    [Fact]
    public void History_keeps_five_durations_and_estimates_unknown_repos_with_the_median()
    {
        var paths = new DevStackPaths(_checkout.StateDirectory);
        var history = new BuildHistory(paths);
        foreach (var s in new[] { 100.0, 100, 100, 100, 100, 400 })
        {
            history.Record(_checkout.Lane, "octo-a", "DebugL", s);
        }

        history.Record(_checkout.Lane, "octo-b", "DebugL", 50);

        var reloaded = new BuildHistory(paths);
        reloaded.Estimate(_checkout.Lane, "octo-a", "DebugL").Should().Be(160, "the oldest of six values is dropped");
        reloaded.Estimate(_checkout.Lane, "octo-a", "Release").Should().BeNull();
        // pending: octo-b (50) and unknown octo-x (median of 50,160 -> 160); current octo-a at 60 s of 160.
        reloaded.Eta("DebugL", [(_checkout.Lane, "octo-b"), (_checkout.Lane, "octo-x")], (_checkout.Lane, "octo-a"), 60).Should().Be(50 + 160 + 100);
        reloaded.Eta("DebugL", [(_checkout.Lane, "octo-y")], null, 0).Should().BeNull("nothing known for Release/unknown");
    }

    // ---------- paths ----------

    [Fact]
    public void Nested_worktrees_are_not_part_of_the_lane_repo()
    {
        var repo = _checkout.Repo("octo-mesh-adapter");
        Directory.CreateDirectory(Path.Combine(repo, ".git"));
        var claudeWorktree = Path.Combine(repo, ".claude", "worktrees", "agent-1");
        Directory.CreateDirectory(claudeWorktree);
        var nested = Path.Combine(repo, "wt-nested");
        Directory.CreateDirectory(nested);
        File.WriteAllText(Path.Combine(nested, ".git"), "gitdir: /x");

        PathScope.IsInRepo(repo, repo).Should().BeTrue();
        PathScope.IsInRepo(Path.Combine(repo, "src", "Service"), repo).Should().BeTrue();
        PathScope.IsInRepo(claudeWorktree, repo).Should().BeFalse();
        PathScope.IsInRepo(nested, repo).Should().BeFalse();
        PathScope.IsInRepo(_checkout.Repo("octo-mesh-adapter-2"), repo).Should().BeFalse("a sibling with the same prefix is another repo");
        PathScope.LaneOf(Path.Combine(repo, "src")).Should().Be(_checkout.Lane);
        PathScope.IsWorktree(nested).Should().BeTrue();
    }

    // ---------- process runner ----------

    [Fact]
    public async Task The_idle_timeout_terminates_a_silent_process()
    {
        var psi = TestProcess.SleepStartInfo(30);
        var pid = 0;
        var watch = Stopwatch.StartNew();

        var result = await PwshRunner.RunProcessAsync(psi, new PwshRunOptions
        {
            Timeout = TimeSpan.FromSeconds(20),
            IdleTimeout = TimeSpan.FromMilliseconds(400),
            OnStarted = p => pid = p
        }, CancellationToken.None);

        result.IdleTimedOut.Should().BeTrue();
        result.TimedOut.Should().BeFalse();
        watch.Elapsed.Should().BeLessThan(TimeSpan.FromSeconds(10));
        ProcessTree.IsAlive(pid).Should().BeFalse();
    }

    [Fact]
    public async Task A_long_idle_timeout_does_not_delay_the_result_of_a_finished_process()
    {
        var watch = Stopwatch.StartNew();

        var result = await PwshRunner.RunProcessAsync(TestProcess.SleepStartInfo(0),
            new PwshRunOptions { Timeout = TimeSpan.FromMinutes(5), IdleTimeout = TimeSpan.FromMinutes(20) }, CancellationToken.None);

        result.ExitCode.Should().Be(0);
        watch.Elapsed.Should().BeLessThan(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task Activity_outside_stdout_keeps_a_process_alive_and_the_environment_reaches_it()
    {
        var psi = TestProcess.Script("Start-Sleep 1; Write-Output \"value=$env:DEVSTACK_TEST\"");

        var result = await PwshRunner.RunProcessAsync(psi, new PwshRunOptions
        {
            Timeout = TimeSpan.FromSeconds(20),
            IdleTimeout = TimeSpan.FromMilliseconds(400),
            LastActivity = _ => DateTimeOffset.Now,
            Environment = new Dictionary<string, string?> { ["DEVSTACK_TEST"] = "42" }
        }, CancellationToken.None);

        result.IdleTimedOut.Should().BeFalse();
        result.ExitCode.Should().Be(0);
        result.Output.Should().Contain("value=42");
    }

    [Fact]
    public async Task A_cached_activity_that_would_end_a_process_is_read_again_before_the_idle_watchdog_terminates_it()
    {
        // The cached value is old; only a fresh read (argument true, AB#9417) sees the current activity.
        var started = DateTimeOffset.Now;
        var fresh = 0;
        var psi = TestProcess.Script("Start-Sleep 1");

        var result = await PwshRunner.RunProcessAsync(psi, new PwshRunOptions
        {
            Timeout = TimeSpan.FromSeconds(20),
            IdleTimeout = TimeSpan.FromMilliseconds(400),
            LastActivity = force =>
            {
                if (!force)
                {
                    return started;
                }

                Interlocked.Increment(ref fresh);
                return DateTimeOffset.Now;
            }
        }, CancellationToken.None);

        result.IdleTimedOut.Should().BeFalse("the fresh read shows activity");
        result.ExitCode.Should().Be(0);
        fresh.Should().BePositive("the watchdog reads again only when the cached value would terminate the process");
    }

    [Fact]
    public async Task Output_that_arrives_while_the_fresh_activity_read_runs_keeps_the_process_alive()
    {
        // Handshake instead of timing (AB#9417): the process stays silent until the first fresh read opens the gate, and
        // that read returns nothing only after the process's line is in the log (OnLine updates the output time before it
        // writes the log line). Only the output read after the fresh read can keep the process alive then.
        var gate = Path.Combine(_checkout.Root, "output-gate");
        var log = Path.Combine(_checkout.Root, "output.log");
        var psi = TestProcess.Script(
            "$i = 0; while (-not (Test-Path $env:DEVSTACK_GATE) -and $i -lt 400) { Start-Sleep -Milliseconds 50; $i++ }; Write-Output line; Start-Sleep -Milliseconds 300");
        var freshReads = 0;
        var released = false;

        var result = await PwshRunner.RunProcessAsync(psi, new PwshRunOptions
        {
            Timeout = TimeSpan.FromSeconds(30),
            IdleTimeout = TimeSpan.FromMilliseconds(400),
            LogFile = log,
            Environment = new Dictionary<string, string?> { ["DEVSTACK_GATE"] = gate },
            LastActivity = force =>
            {
                if (Volatile.Read(ref released))
                {
                    return DateTimeOffset.Now; // after the handshake: the process is active until it ends by itself
                }

                if (!force)
                {
                    return null;
                }

                Interlocked.Increment(ref freshReads);
                File.WriteAllText(gate, "");
                var deadline = DateTime.UtcNow.AddSeconds(20);
                while (!(File.Exists(log) && TestProcess.ReadLog(log).Contains("line", StringComparison.Ordinal)) && DateTime.UtcNow < deadline)
                {
                    Thread.Sleep(10);
                }

                Volatile.Write(ref released, true);
                return null;
            }
        }, CancellationToken.None);

        freshReads.Should().Be(1, "the first fresh read is the handshake");
        result.IdleTimedOut.Should().BeFalse("the process printed while the fresh read ran");
        result.Output.Should().Contain("line");
    }
}
