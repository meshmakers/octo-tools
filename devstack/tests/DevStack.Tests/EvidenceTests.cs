using System.Text.Json;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Microsoft.Extensions.Logging.Abstractions;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     The evidence of a job: per repository it covers the work tree, HEAD and whether it was clean, at the start and at the end.
///     Real git on temp repositories of a <see cref="TestCheckout"/>; the cmdlets are <see cref="FakePwsh"/>.
/// </summary>
public sealed class EvidenceTests : IDisposable
{
    private readonly TestCheckout _checkout = new();
    private readonly FakePwsh _fake = new() { Capabilities = FakePwsh.TestParams };

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    public void Dispose() => _checkout.Dispose();

    private BuildQueue Create()
    {
        var store = _checkout.WriteConfig("""
                                            sleeper:
                                              repo: octo-x
                                              workingDirectory: .
                                              command: pwsh
                                              args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                          """);
        var paths = new DevStackPaths(_checkout.StateDirectory);
        var state = new StateStore(paths);
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance);
        return new BuildQueue(store, supervisor, supervisor.Leases.Default, paths, NullLogger<BuildQueue>.Instance, _fake, state, null,
            new BuildQueueOptions { PollInterval = TimeSpan.FromMilliseconds(30) }, () => Task.FromResult(ExternalSnapshot.Empty));
    }

    private static async Task<BuildStatus> WaitAsync(BuildQueue queue, string id, Func<BuildStatus, bool>? until = null)
    {
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (true)
        {
            var status = queue.Get(id);
            if (until?.Invoke(status) ?? status.Times.FinishedAt != null)
            {
                return status;
            }

            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException($"job {id} stays {status.State}: {status.Outcome?.Summary}");
            }

            await Task.Delay(20, Ct);
        }
    }

    // ---------- git ----------

    [Fact]
    public void The_porcelain_v2_output_gives_head_branch_and_the_changed_and_untracked_entries()
    {
        var sha = new string('a', 40);
        var state = GitWorkTree.Parse(
            $"# branch.oid {sha}\n# branch.head feat/x\n# branch.upstream origin/feat/x\n# branch.ab +1 -0\n" +
            "1 .M N... 100644 100644 100644 1111 2222 src/a.cs\n? new.txt\nu UU N... 1 2 3 4 h1 h2 h3 conflict.cs\n");

        state.Should().Be(new BuildRepoState(sha, "feat/x", false, 3));
        GitWorkTree.Parse($"# branch.oid {sha.ToUpperInvariant()}\r\n# branch.head (detached)\r\n! ignored.log\r\n")
            .Should().Be(new BuildRepoState(sha, null, true), "ignored entries do not count, a detached HEAD has no branch");
        GitWorkTree.Parse("# branch.oid (initial)\n# branch.head main\n").Should().Be(new BuildRepoState(null, "main", true), "no commit yet");
    }

    [Fact]
    public async Task A_work_tree_is_clean_until_a_tracked_file_changes_or_an_untracked_one_appears_and_ignored_files_do_not_count()
    {
        var repo = _checkout.GitRepo("octo-a");
        File.WriteAllText(Path.Combine(repo, ".gitignore"), "bin/\n");
        _checkout.Git(repo, "add", ".gitignore");
        _checkout.Git(repo, "commit", "-q", "-m", "ignore bin");
        var head = _checkout.Git(repo, "rev-parse", "HEAD");
        Directory.CreateDirectory(Path.Combine(repo, "bin"));
        File.WriteAllText(Path.Combine(repo, "bin", "out.dll"), "x");

        (await GitWorkTree.ReadAsync(repo)).Should().Be(new BuildRepoState(head, "main", true), "bin/ is ignored");

        File.WriteAllText(Path.Combine(repo, "new.txt"), "x");
        var dirty = await GitWorkTree.ReadAsync(repo);
        (dirty with { Fingerprint = null }).Should().Be(new BuildRepoState(head, "main", false, 1), "an untracked file makes the work tree dirty");
        dirty.Fingerprint.Should().MatchRegex("^[0-9a-f]{16}$", "a dirty work tree has a fingerprint");

        File.Delete(Path.Combine(repo, "new.txt"));
        File.AppendAllText(Path.Combine(repo, "octo-a.sln"), "changed");
        ((await GitWorkTree.ReadAsync(repo)) with { Fingerprint = null }).Should().Be(new BuildRepoState(head, "main", false, 1));
    }

    [Fact]
    public async Task Only_the_root_of_a_work_tree_is_read()
    {
        var repo = _checkout.GitRepo("octo-a");
        var inside = Directory.CreateDirectory(Path.Combine(repo, "src")).FullName;

        (await GitWorkTree.ReadAsync(inside)).Error.Should().Contain("not the root of a git work tree", "a folder inside a repository is not that repository");
        (await GitWorkTree.ReadAsync(_checkout.Repo("octo-plain"))).Error.Should().Contain("no .git");
        (await GitWorkTree.ReadAsync(Path.Combine(_checkout.Lane, "missing"))).Should().Be(new BuildRepoState(null, null, null, null, "the folder does not exist"));
        // A .git file that points nowhere (a removed worktree): git itself says why.
        var broken = _checkout.Repo("wt-gone-octo-a");
        File.WriteAllText(Path.Combine(broken, ".git"), "gitdir: " + Path.Combine(_checkout.Root, "nowhere", ".git", "worktrees", "gone"));
        (await GitWorkTree.ReadAsync(broken)).Error.Should().StartWith("git status exited with");
    }

    // ---------- jobs ----------

    [Fact]
    public async Task A_repo_build_records_head_and_clean_state_at_start_and_end_and_is_unchanged()
    {
        var repo = _checkout.GitRepo("octo-a");
        var head = _checkout.Git(repo, "rev-parse", "HEAD");
        var queue = Create();

        var queued = await queue.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" }, Ct);
        queued.Evidence.Should().BeNull("a queued job has not read anything yet");
        var done = await WaitAsync(queue, queued.Id);

        var state = new BuildRepoState(head, "main", true);
        done.Evidence.Should().BeEquivalentTo(new BuildEvidence(true, [new BuildRepoEvidence("octo-a", repo, state, state)]));
        done.Evidence!.Repos.Single().Unchanged.Should().BeTrue();
        queue.Get(queued.Id, errorsOnly: true).Evidence.Should().BeNull("errorsOnly is state, outcome and diagnostics");
        // Compact: a repo's evidence is a few hundred characters.
        JsonSerializer.Serialize(done.Evidence, JsonSerializerOptions.Web).Length.Should().BeLessThan(400 + repo.Length);
    }

    [Fact]
    public async Task A_work_tree_that_changes_while_the_job_runs_makes_the_evidence_unstable()
    {
        var repo = _checkout.GitRepo("octo-a");
        var head = _checkout.Git(repo, "rev-parse", "HEAD");
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (body, _, _) =>
        {
            await release.Task;
            return FakePwsh.Ok(FakePwsh.Command(body), """{"success":true,"exitCode":0}""");
        };
        var queue = Create();
        var job = await queue.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" }, Ct);

        var running = await WaitAsync(queue, job.Id, s => s.Evidence != null);
        running.Evidence.Should().BeEquivalentTo(new BuildEvidence(null, [new BuildRepoEvidence("octo-a", repo, new BuildRepoState(head, "main", true), null)]),
            "while the job runs only the start is known");
        running.Evidence!.Repos.Single().Unchanged.Should().BeNull();

        File.AppendAllText(Path.Combine(repo, "octo-a.sln"), "edited during the build");
        _checkout.Git(repo, "commit", "-q", "-am", "edit");
        var moved = _checkout.Git(repo, "rev-parse", "HEAD");
        File.WriteAllText(Path.Combine(repo, "notes.txt"), "untracked");
        release.SetResult();
        var done = await WaitAsync(queue, job.Id);

        done.Evidence!.Unchanged.Should().BeFalse();
        done.Evidence.Repos.Single().Should().BeEquivalentTo(new
        {
            Start = new BuildRepoState(head, "main", true), End = new { Head = moved, Branch = "main", Clean = false, Changes = 1 }, Unchanged = (bool?)false
        });
    }

    [Fact]
    public async Task An_uncommitted_edit_made_before_the_job_leaves_it_unchanged_and_one_made_while_it_runs_does_not()
    {
        var repo = _checkout.GitRepo("octo-a");
        var head = _checkout.Git(repo, "rev-parse", "HEAD");
        File.AppendAllText(Path.Combine(repo, "octo-a.sln"), "the session's edit");
        File.WriteAllText(Path.Combine(repo, "New.cs"), "class New {}");
        Func<Task>? during = null;
        _fake.Build = async (body, _, _) =>
        {
            if (during != null)
            {
                await during();
            }

            return FakePwsh.Ok(FakePwsh.Command(body), """{"success":true,"exitCode":0}""");
        };
        var queue = Create();

        var plain = await WaitAsync(queue, (await queue.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" }, Ct)).Id);
        plain.Evidence!.Unchanged.Should().BeTrue("the normal flow: edit, then build - the job ran on what is there");
        var evidence = plain.Evidence.Repos.Single();
        evidence.Start.Should().Match<BuildRepoState>(s => s.Head == head && s.Clean == false && s.Changes == 2 && s.Fingerprint != null);
        evidence.End!.Fingerprint.Should().Be(evidence.Start!.Fingerprint);
        evidence.Unchanged.Should().BeTrue();

        // The same file edited again while the job runs: the same names, other content.
        during = () =>
        {
            File.AppendAllText(Path.Combine(repo, "octo-a.sln"), " and more");
            return Task.CompletedTask;
        };
        var edited = await WaitAsync(queue, (await queue.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" }, Ct)).Id);
        edited.Evidence!.Unchanged.Should().BeFalse("the job did not run on what is there now");
        edited.Evidence.Repos.Single().Start!.Changes.Should().Be(edited.Evidence.Repos.Single().End!.Changes, "the same files are changed");

        // A file of an untracked folder written while the job runs.
        Directory.CreateDirectory(Path.Combine(repo, "docs"));
        File.WriteAllText(Path.Combine(repo, "docs", "a.md"), "a");
        during = () =>
        {
            File.WriteAllText(Path.Combine(repo, "docs", "b.md"), "b");
            return Task.CompletedTask;
        };
        var untracked = await WaitAsync(queue, (await queue.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" }, Ct)).Id);
        untracked.Evidence!.Unchanged.Should().BeFalse("git lists the folder, its files make the difference");
    }

    [Fact]
    public void The_fingerprint_covers_the_entries_and_the_content_of_the_files_they_name()
    {
        var repo = _checkout.Repo("octo-f");
        File.WriteAllText(Path.Combine(repo, "a b.cs"), "one");
        const string output = "# branch.oid 0000000000000000000000000000000000000000\n1 .M N... 100644 100644 100644 1111 2222 a b.cs\n? gone.txt\n";

        var first = GitWorkTree.Fingerprint(repo, output);
        GitWorkTree.Fingerprint(repo, output).Should().Be(first, "the same entries and content");
        GitWorkTree.Fingerprint(repo, output.Replace("\n", "\r\n")).Should().Be(first);
        File.WriteAllText(Path.Combine(repo, "a b.cs"), "two");
        GitWorkTree.Fingerprint(repo, output).Should().NotBe(first, "the content of a changed file counts");
        GitWorkTree.Fingerprint(repo, output.Replace("1111 2222", "1111 3333")).Should().NotBe(GitWorkTree.Fingerprint(repo, output), "so does a staged change");

        GitWorkTree.EntryPath("1 .M N... 100644 100644 100644 1111 2222 a b.cs").Should().Be("a b.cs");
        GitWorkTree.EntryPath("2 R. N... 100644 100644 100644 1111 2222 R100 new name.cs\told.cs").Should().Be("new name.cs");
        GitWorkTree.EntryPath("u UU N... 1 2 3 4 h1 h2 h3 conflict.cs").Should().Be("conflict.cs");
        GitWorkTree.EntryPath("? docs/").Should().Be("docs/");
        GitWorkTree.EntryPath("? \"t\\303\\244st.txt\"").Should().BeNull("a quoted path cannot be read");
    }

    [Fact]
    public void A_fingerprint_that_would_not_cover_every_change_is_none_so_the_evidence_is_never_unchanged()
    {
        var repo = _checkout.Repo("octo-g");
        File.WriteAllText(Path.Combine(repo, "small.txt"), "x");
        GitWorkTree.Fingerprint(repo, "? small.txt\n").Should().NotBeNull();

        GitWorkTree.Fingerprint(repo, "? small.txt\n? \"a\\\"quote.txt\"\n").Should().BeNull("git still quotes a name with a quote: its content is not read");
        Directory.CreateDirectory(Path.Combine(repo, "nested"));
        GitWorkTree.Fingerprint(repo, "? nested/\n").Should().BeNull("a folder entry (an untracked nested repository) is not covered");
        using (var big = File.Create(Path.Combine(repo, "big.bin")))
        {
            big.SetLength(GitWorkTree.MaxHashedFileBytes + 1);
        }

        GitWorkTree.Fingerprint(repo, "? big.bin\n").Should().BeNull("a file over 16 MB is not hashed");
        GitWorkTree.Fingerprint(repo, string.Concat(Enumerable.Range(0, GitWorkTree.MaxEntries + 1).Select(i => $"? f{i}.txt\n"))).Should().BeNull();
    }

    [Fact]
    public async Task Every_untracked_file_is_an_entry_of_its_own_ignored_ones_are_not_and_a_non_ascii_name_is_read_by_content()
    {
        var repo = _checkout.GitRepo("octo-u");
        File.WriteAllText(Path.Combine(repo, ".gitignore"), "bin/\n");
        _checkout.Git(repo, "add", ".gitignore");
        _checkout.Git(repo, "commit", "-q", "-m", "ignore");
        Directory.CreateDirectory(Path.Combine(repo, "src", "New", "bin"));
        File.WriteAllText(Path.Combine(repo, "src", "New", "a.cs"), "a");
        File.WriteAllText(Path.Combine(repo, "src", "New", "bin", "out.dll"), "build output");
        File.WriteAllText(Path.Combine(repo, "täst.txt"), "one");

        var before = await GitWorkTree.ReadAsync(repo);
        before.Changes.Should().Be(2, "src/New/a.cs and the non-ASCII file, each on its own; bin/ is ignored");
        before.Fingerprint.Should().NotBeNull("core.quotePath=false: the non-ASCII name comes unquoted");

        File.WriteAllText(Path.Combine(repo, "src", "New", "bin", "out.dll"), "another build");
        (await GitWorkTree.ReadAsync(repo)).Fingerprint.Should().Be(before.Fingerprint, "a build's ignored output does not count");
        File.WriteAllText(Path.Combine(repo, "täst.txt"), "two");
        (await GitWorkTree.ReadAsync(repo)).Fingerprint.Should().NotBe(before.Fingerprint, "the content of the non-ASCII file counts");
    }

    [Fact]
    public async Task A_test_run_covers_the_tested_repository_and_a_folder_that_is_no_git_work_tree_says_why()
    {
        var repo = _checkout.GitRepo("octo-a");
        _checkout.Repo("octo-b");
        var head = _checkout.Git(repo, "rev-parse", "HEAD");
        _fake.Build = (body, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun",
            """{"success":true,"exitCode":0,"projects":[{"project":"A.Tests","state":"passed","success":true,"total":1,"passed":1,"failed":0,"skipped":0,"durationSeconds":1,"failedTests":[]}]}"""));
        var queue = Create();

        // The cmdlet takes the name without 'octo-' or a unique part: the evidence names the folder it resolves to.
        var tested = await WaitAsync(queue, (await queue.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Test, Repo = "a" }, Ct)).Id);
        var plain = await WaitAsync(queue, (await queue.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Test, Repo = "octo-b" }, Ct)).Id);

        tested.Evidence.Should().BeEquivalentTo(new BuildEvidence(true, [new BuildRepoEvidence("octo-a", repo, new BuildRepoState(head, "main", true), new BuildRepoState(head, "main", true))]));
        plain.Evidence!.Unchanged.Should().BeFalse("a repository git cannot read is no evidence");
        plain.Evidence.Repos.Single().End!.Error.Should().Contain("no .git");
    }

    [Fact]
    public async Task A_job_with_many_repositories_lists_only_the_ones_that_are_not_fine_and_counts_the_others()
    {
        var first = _checkout.GitRepo("octo-r00");
        var names = Enumerable.Range(0, 12).Select(i => $"octo-r{i:00}").ToList();
        foreach (var name in names.Skip(1))
        {
            CopyFolder(first, Path.Combine(_checkout.Lane, name)); // a copy of a repository is a repository with the same HEAD
        }

        File.WriteAllText(Path.Combine(_checkout.Lane, "octo-r03", "dirty.txt"), "an edit before the job is fine");
        _fake.RangePlan = JsonSerializer.Serialize(new
        {
            whatIf = true, lane = new { isolated = false }, packageCaches = Array.Empty<string>(),
            repositories = names.Select(n => new { repo = n, mode = "dotnet", path = Path.Combine(_checkout.Lane, n) })
        });
        _fake.Build = (body, _, _) =>
        {
            File.WriteAllText(Path.Combine(_checkout.Lane, "octo-r07", "dirty.txt"), "written while the job runs");
            return Task.FromResult(FakePwsh.Ok(FakePwsh.Command(body), """{"success":true,"exitCode":0,"repositories":[]}"""));
        };
        var queue = Create();

        var done = await WaitAsync(queue, (await queue.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-r00", To = "octo-r11", Publish = true }, Ct)).Id);

        done.Evidence!.Unchanged.Should().BeFalse();
        done.Evidence.Repos.Select(r => r.Repo).Should().Equal("octo-r07");
        done.Evidence.Omitted.Should().Be(11);
        queue.Get(done.Id, raw: true).Evidence!.Repos.Should().HaveCount(12, "the raw view lists every repository");
        queue.Get(done.Id, repo: "octo-r03").Evidence!.Repos.Single().Unchanged.Should().BeTrue();
    }

    private static void CopyFolder(string from, string to)
    {
        foreach (var dir in Directory.EnumerateDirectories(from, "*", SearchOption.AllDirectories))
        {
            Directory.CreateDirectory(Path.Combine(to, Path.GetRelativePath(from, dir)));
        }

        Directory.CreateDirectory(to);
        // The copy's index holds the original's stat data: git status compares the content again and finds it clean.
        foreach (var file in Directory.EnumerateFiles(from, "*", SearchOption.AllDirectories))
        {
            File.Copy(file, Path.Combine(to, Path.GetRelativePath(from, file)));
        }
    }
}
