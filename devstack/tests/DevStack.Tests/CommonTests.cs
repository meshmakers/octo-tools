using System.Text;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Tests;

public class CommonTests
{
    [Fact]
    public void ExtractOctoJson_finds_the_last_document_in_mixed_output()
    {
        const string output = """
                              Restoring packages...
                                Determining projects to restore...
                              { "not": "it" }
                              {
                                "schemaVersion": 1,
                                "command": "Invoke-Build",
                                "data": { "success": false, "exitCode": 1, "logFile": "/x/Invoke-Build.log" }
                              }
                              trailing line printed after the document
                              """;
        var json = PwshRunner.ExtractOctoJson(output);
        json.Should().NotBeNull();
        json!["command"]!.GetValue<string>().Should().Be("Invoke-Build");
        json["data"]!["success"]!.GetValue<bool>().Should().BeFalse();
    }

    [Fact]
    public void ExtractOctoJson_returns_null_without_a_document()
    {
        PwshRunner.ExtractOctoJson("just\nsome { output\n").Should().BeNull();
    }

    [Fact]
    public void ExtractMarker_reads_the_provider_result()
    {
        var node = PwshRunner.ExtractMarker("noise\n" + PwshRunner.Marker + "{\"env\":{\"p\":{\"A\":\"1\"}},\"errors\":{}}\n");
        node!["env"]!["p"]!["A"]!.GetValue<string>().Should().Be("1");
    }

    [Fact]
    public void Secret_names_are_masked()
    {
        var masked = SecretMask.Mask(new Dictionary<string, string>
        {
            ["OCTO_SYSTEM__ADMINUSERPASSWORD"] = "x",
            ["OCTO_SECRETENCRYPTION__KEYS__k1"] = "x",
            ["ASPNETCORE_ENVIRONMENT"] = "Development"
        });
        masked["OCTO_SYSTEM__ADMINUSERPASSWORD"].Should().Be(SecretMask.Masked);
        masked["OCTO_SECRETENCRYPTION__KEYS__k1"].Should().Be(SecretMask.Masked);
        masked["ASPNETCORE_ENVIRONMENT"].Should().Be("Development");
    }

    [Fact]
    public void LogReader_tails_and_greps_across_chunk_boundaries()
    {
        var file = Path.GetTempFileName();
        try
        {
            var text = new StringBuilder();
            for (var i = 0; i < 20000; i++)
            {
                text.Append("line ").Append(i).Append(i % 1000 == 0 ? " ERROR here" : "").Append('\n');
            }

            File.WriteAllText(file, text.ToString());
            LogReader.TailLines(file, 3, null).Should().Equal("line 19997", "line 19998", "line 19999");
            var errors = LogReader.TailLines(file, 5, "error");
            errors.Should().Equal("line 15000 ERROR here", "line 16000 ERROR here", "line 17000 ERROR here", "line 18000 ERROR here",
                "line 19000 ERROR here");
            LogReader.TailLines(file, 5000, "^line 0 ").Should().Equal("line 0 ERROR here");
        }
        finally
        {
            File.Delete(file);
        }
    }

    [Fact]
    public void LogReader_handles_small_files_without_trailing_newline()
    {
        var file = Path.GetTempFileName();
        try
        {
            File.WriteAllText(file, "a\nb\nc");
            LogReader.TailLines(file, 10, null).Should().Equal("a", "b", "c");
        }
        finally
        {
            File.Delete(file);
        }
    }

    [Fact]
    public void Worktree_git_file_resolves_repo_and_branch()
    {
        using var checkout = new TestCheckout();
        var repo = checkout.Repo("octo-mesh-adapter");
        var gitDir = Path.Combine(repo, ".git", "worktrees", "wt-8625");
        Directory.CreateDirectory(gitDir);
        File.WriteAllText(Path.Combine(gitDir, "HEAD"), "ref: refs/heads/reimar/AB#8625_x\n");
        var worktree = checkout.Repo("wt-8625-octo-mesh-adapter");
        Directory.CreateDirectory(Path.Combine(worktree, "bin", "DebugL"));
        File.WriteAllText(Path.Combine(worktree, ".git"), $"gitdir: {gitDir}\n");

        CheckoutDiscovery.ReadWorktree(Path.Combine(worktree, ".git")).Should().Be(("octo-mesh-adapter", "reimar/AB#8625_x"));

        var store = checkout.WriteConfig("""
                                           meshAdapter: { repo: octo-mesh-adapter, args: [x] }
                                         """);
        var lanes = CheckoutDiscovery.Discover(store.Load());
        var lane = lanes.Should().ContainSingle(l => l.Path == checkout.Lane).Subject;
        lane.IsDefault.Should().BeTrue();
        var wt = lane.Worktrees.Should().ContainSingle().Subject;
        wt.RelativeToBaseLane.Should().Be("wt-8625-octo-mesh-adapter");
        wt.Services.Should().Equal("meshAdapter");
        wt.BuiltConfigurations.Should().Equal("DebugL");
    }

    [Fact]
    public void Env_provider_body_runs_each_provider_guarded()
    {
        var config = Configuration.ConfigStore.Parse("""
                                                     services:
                                                       bot: { repo: r, args: [x] }
                                                     envProviders:
                                                       always: { script: "@{ A = '1' }" }
                                                       onlyBot: { script: "@{ B = '2' }", whenServices: [bot] }
                                                       off: { enabled: false, script: "@{ C = '3' }" }
                                                     """);
        EnvProviderRunner.Applicable(config, ["other"]).Should().Equal("always");
        EnvProviderRunner.Applicable(config, ["bot"]).Should().Equal("always", "onlyBot");
        var body = EnvProviderRunner.BuildBody(config, ["always", "onlyBot"]);
        body.Should().Contain("$__result['always']").And.Contain("catch").And.Contain(PwshRunner.Marker);
    }

    [Fact]
    public async Task A_shared_file_is_replaced_while_the_daemon_reads_it_and_while_a_foreign_reader_holds_it_briefly()
    {
        using var checkout = new TestCheckout();
        var file = Path.Combine(checkout.Root, "state.json");
        File.WriteAllText(file, "one");

        // The daemon's own reads share delete: a replace goes through while one is open (Windows refused it before).
        using (new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            File.WriteAllText(file + ".tmp", "two");
            SharedFile.Replace(file + ".tmp", file);
        }

        SharedFile.ReadAllText(file).Should().Be("two");

        // A foreign reader without FILE_SHARE_DELETE (a scanner) blocks the move on Windows until it lets go: retried.
        var foreign = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
        var release = Task.Run(async () =>
        {
            await Task.Delay(150, TestContext.Current.CancellationToken);
            await foreign.DisposeAsync();
        }, TestContext.Current.CancellationToken);
        File.WriteAllText(file + ".tmp", "three");
        SharedFile.Replace(file + ".tmp", file);
        await release;

        SharedFile.ReadAllLines(file).Should().Equal("three");
        File.Exists(file + ".tmp").Should().BeFalse();
        SharedFile.IsTransient(new FileNotFoundException()).Should().BeFalse("a missing file does not come back by waiting");
        SharedFile.IsTransient(new UnauthorizedAccessException()).Should().BeTrue();
    }

    [Fact]
    public async Task A_reader_never_finds_a_shared_file_missing_while_it_is_replaced()
    {
        // Windows ReplaceFile renamed the old file away before the new one came in: a reader that came in between found no
        // state, job or config file (a rare test failure "job file does not exist"). Every OS: the name never goes away.
        using var checkout = new TestCheckout();
        var file = Path.Combine(checkout.Root, "job.json");
        File.WriteAllText(file, "0");
        using var stop = new CancellationTokenSource();
        var reading = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var missing = 0;
        var reads = 0;
        var reader = Task.Run(() =>
        {
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    SharedFile.ReadAllText(file);
                    reads++;
                    reading.TrySetResult();
                }
                catch (FileNotFoundException)
                {
                    missing++;
                }
            }
        }, TestContext.Current.CancellationToken);

        try
        {
            // The reader runs before the first replace, so the replaces really overlap with reads.
            await reading.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
            for (var i = 1; i <= 500; i++)
            {
                File.WriteAllText(file + ".tmp", i.ToString(System.Globalization.CultureInfo.InvariantCulture));
                SharedFile.Replace(file + ".tmp", file);
            }
        }
        finally
        {
            await stop.CancelAsync();
            await reader;
        }

        reads.Should().BeGreaterThan(1);
        missing.Should().Be(0);
        SharedFile.ReadAllText(file).Should().Be("500");
    }

    [Fact]
    public void The_replace_without_POSIX_rename_keeps_the_old_file_when_it_fails_half_way()
    {
        // Windows on FAT or a network share: ReplaceFile with a backup name. Run directly (every OS), the volume is not marked.
        using var checkout = new TestCheckout();
        var file = Path.Combine(checkout.Root, "state.json");
        File.WriteAllText(file, "old");

        // A daemon read is open during the replace; the backup goes once the replace is done.
        using (new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            File.WriteAllText(file + ".tmp", "new");
            SharedFile.ReplaceKeepingTheOld(file + ".tmp", file);
        }

        SharedFile.ReadAllText(file).Should().Be("new");
        File.Exists(file + ".tmp").Should().BeFalse();
        File.Exists(file + ".replaced").Should().BeFalse("the backup is deleted after a replace that worked");

        // ReplaceFile moved the old file to the backup name, then could not move the new one in (ERROR_UNABLE_TO_MOVE_REPLACEMENT_2).
        File.WriteAllText(file + ".tmp", "newer");
        var halfWay = () => SharedFile.ReplaceKeepingTheOld(file + ".tmp", file, (_, path, backup) =>
        {
            File.Move(path, backup);
            throw new IOException("Unable to move the replacement file to the file to be replaced.");
        });

        halfWay.Should().Throw<IOException>("the caller retries or reports it");
        SharedFile.ReadAllText(file).Should().Be("new", "the last good file is back under its name");
        File.Exists(file + ".replaced").Should().BeFalse();
        File.ReadAllText(file + ".tmp").Should().Be("newer", "the new content is not lost either");

        // No old file yet: the new one is moved.
        var fresh = Path.Combine(checkout.Root, "job.json");
        File.WriteAllText(fresh + ".tmp", "first");
        SharedFile.ReplaceKeepingTheOld(fresh + ".tmp", fresh);
        SharedFile.ReadAllText(fresh).Should().Be("first");
    }

    [Theory]
    [InlineData(8, 16, 20)]
    [InlineData(4, 8, 12)]
    public void The_Windows_rename_buffer_has_the_layout_of_FILE_RENAME_INFO(int pointerSize, int lengthOffset, int nameOffset)
    {
        const string target = @"C:\state\state.json";
        var buffer = WindowsFileRename.RenameInfo(target, WindowsFileRename.ReplaceIfExists | WindowsFileRename.PosixSemantics, pointerSize);

        BitConverter.ToUInt32(buffer, 0).Should().Be(3u, "replace if it exists, POSIX semantics");
        buffer.AsSpan(4, lengthOffset - 4).ToArray().Should().OnlyContain(b => b == 0, "padding and a null RootDirectory");
        BitConverter.ToUInt32(buffer, lengthOffset).Should().Be((uint)(target.Length * 2), "the length is in bytes, without the terminator");
        Encoding.Unicode.GetString(buffer, nameOffset, target.Length * 2).Should().Be(target);
        buffer.Length.Should().Be(nameOffset + target.Length * 2 + 2, "a terminating zero character");
        buffer[^1].Should().Be(0);
        buffer[^2].Should().Be(0);
    }
}
