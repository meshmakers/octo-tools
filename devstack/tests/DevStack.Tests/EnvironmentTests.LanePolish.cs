using System.Text.Json;
using System.Text.Json.Nodes;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Runtime;
using Meshmakers.Octo.DevStack.Tools;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     AB#9808 lane polish: stale base-lane packages are named by lane_create, lane_add_repo and lane_build (and a check that
///     could not be made is said to have failed), lane_add_repo waits for the lane's jobs instead of refusing, and a repo added to
///     a running lane stack runs from the lane.
/// </summary>
public sealed partial class EnvironmentTests
{
    private const string StaleSnapshot = """
                                         {"checked":true,"errors":[],"rebuildInEnvironment":["octo-sdk"],
                                          "staleProducers":[{"repo":"octo-construction-kit-engine","behind":3,"upstream":"origin/main",
                                            "builtFrom":"0123abcd4567ef890123abcd4567ef8901234567","builtFromSource":"package","consumedBy":["octo-sdk"]}],"hints":[]}
                                         """;

    private const string FailedSnapshot = """
                                          {"checked":false,"errors":["octo-sdk: git rev-list against abc123 failed: bad revision"],
                                           "rebuildInEnvironment":[],"staleProducers":[],"hints":[]}
                                          """;

    [Fact]
    public void Feed_snapshot_notes_name_the_stale_producers_with_the_fix_and_a_failed_check_as_failed()
    {
        var stale = FeedSnapshot.Notes(JsonNode.Parse(StaleSnapshot), "ab1-one");
        stale.Should().ContainSingle().Which.Should()
            .Contain("Stale base-lane packages: octo-construction-kit-engine (built from 0123abcd, 3 commit(s) behind origin/main, consumed by octo-sdk)")
            .And.Contain("CS0246/CS1061")
            .And.Contain("lane_add_repo(owner, lane=\"ab1-one\", repo=\"octo-construction-kit-engine\", role=\"consumer\")")
            .And.Contain("lane_build(owner, lane=\"ab1-one\")");

        var failed = FeedSnapshot.Notes(JsonNode.Parse(FailedSnapshot), "ab1-one");
        failed.Should().ContainSingle().Which.Should().Contain("stale-package check failed: octo-sdk: git rev-list").And.Contain("not ruled out");

        FeedSnapshot.Notes(JsonNode.Parse("""{"checked":true,"errors":[],"rebuildInEnvironment":[],"staleProducers":[],"hints":[]}"""), "ab1-one")
            .Should().BeEmpty("nothing to say");
        FeedSnapshot.Notes(null, "ab1-one").Should().BeEmpty("an older octo-tools sends no feedSnapshot");
    }

    [Fact]
    public async Task Lane_create_and_lane_add_repo_name_stale_base_lane_packages_in_their_notes()
    {
        var (queue, supervisor, store) = CreateQueue();
        _fake.Build = (body, _, _) =>
        {
            if (FakePwsh.Command(body) == "New-OctoEnvironment")
            {
                Env("ab1-new", ["octo-a"]);
                return Task.FromResult(FakePwsh.Ok("New-OctoEnvironment", $$"""{"success":true,"exitCode":0,"feedSnapshot":{{StaleSnapshot}}}"""));
            }

            return Task.FromResult(FakePwsh.Ok("Add-OctoEnvironmentRepo", $$"""{"success":true,"exitCode":0,"feedSnapshot":{{FailedSnapshot}}}"""));
        };
        var manager = Manager(queue, supervisor, store);

        var created = await manager.CreateAsync("agent-1", "ab1-new", ["octo-a"], "AB#1", null, false, Ct);
        created.Success.Should().BeTrue();
        created.Notes.Should().Contain(n => n.Contains("Stale base-lane packages: octo-construction-kit-engine") &&
                                            n.Contains("lane_add_repo(owner, lane=\"ab1-new\", repo=\"octo-construction-kit-engine\", role=\"consumer\")"));

        var added = await manager.AddRepoAsync("agent-1", "ab1-new", "octo-b", null, "consumer", false, false, Ct);
        added.Success.Should().BeTrue();
        added.Notes.Should().Contain(n => n.Contains("stale-package check failed"), "a check that could not be made is not an empty list");
        added.Notes.Should().Contain(n => n.Contains("lane_build(owner, lane=\"ab1-new\")"));
    }

    [Fact]
    public async Task Lane_build_warns_about_stale_base_lane_packages_from_the_dry_run()
    {
        var (queue, _, _) = CreateQueue();
        var env = Env("ab1-ok", ["octo-a"]);
        _fake.EnvPlan = $$"""
                          {"dryRun":true,"repositories":[{"repo":"octo-a","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(env, "octo-a"))}}}],
                           "feedSnapshot":{{StaleSnapshot}}}
                          """;

        var plan = await queue.Plan(new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-ok" });

        plan.Warnings.Should().Contain(w => w.Contains("Stale base-lane packages: octo-construction-kit-engine") &&
                                            w.Contains("lane_add_repo(owner, lane=\"ab1-ok\", repo=\"octo-construction-kit-engine\", role=\"consumer\")"));
    }

    [Fact]
    public async Task Lane_add_repo_waits_for_a_running_job_of_the_lane_and_then_adds_the_repo()
    {
        var (queue, supervisor, store) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        var release = new TaskCompletionSource();
        _fake.Build = async (body, _, _) =>
        {
            var command = FakePwsh.Command(body);
            if (command == "Invoke-BuildEnvironment")
            {
                await release.Task;
                return FakePwsh.Ok(command, """{"success":true,"exitCode":0,"repositories":[]}""");
            }

            return FakePwsh.Ok(command, """{"success":true,"exitCode":0}""");
        };
        var manager = Manager(queue, supervisor, store);
        manager.JobPollInterval = TimeSpan.FromMilliseconds(20);

        var job = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-one" });
        await WaitAsync(queue, job.Id, s => s.State == "running");
        var add = manager.AddRepoAsync("agent-1", "ab1-one", "octo-b", null, "consumer", false, false, Ct);
        await Task.Delay(300, Ct);
        add.IsCompleted.Should().BeFalse("it waits for the lane's build instead of being refused");
        _fake.BuildCalls.Should().NotContain(c => c.StartsWith("Add-OctoEnvironmentRepo", StringComparison.Ordinal));

        release.SetResult();
        var added = await add;

        added.Success.Should().BeTrue();
        added.Notes.Should().Contain(n => n.StartsWith("Waited ", StringComparison.Ordinal) && n.Contains(job.Id));
        _fake.BuildCalls.Should().Contain("Add-OctoEnvironmentRepo -env 'ab1-one' -repo 'octo-b' -role 'consumer' -Json");
    }

    [Fact]
    public async Task Lane_add_repo_answers_with_the_job_to_wait_for_when_the_lanes_job_does_not_end_within_the_wait()
    {
        var (queue, supervisor, store) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        var release = new TaskCompletionSource();
        _fake.Build = async (body, _, _) =>
        {
            await release.Task;
            return FakePwsh.Ok(FakePwsh.Command(body), """{"success":true,"exitCode":0,"repositories":[]}""");
        };
        var manager = Manager(queue, supervisor, store);
        manager.JobPollInterval = TimeSpan.FromMilliseconds(20);
        manager.AddRepoJobWait = TimeSpan.FromMilliseconds(200);

        var job = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-one" });
        try
        {
            var answer = await manager.AddRepoAsync("agent-1", "ab1-one", "octo-b", null, "consumer", false, false, Ct);
            answer.Success.Should().BeFalse("nothing was added");
            answer.RetryAfterJob.Should().Be(job.Id);
            answer.Notes.Should().ContainSingle().Which.Should().Contain("Nothing was added yet").And.Contain($"job_status(\"{job.Id}\", waitSeconds)");
            Manager(queue, supervisor, store).AddRepoJobWait.Should().BeLessThan(TimeSpan.FromSeconds(60), "below the MCP call timeout of an agent");
            _fake.BuildCalls.Should().NotContain(c => c.StartsWith("Add-OctoEnvironmentRepo", StringComparison.Ordinal));
        }
        finally
        {
            release.SetResult();
            await WaitAsync(queue, job.Id);
        }
    }

    [Fact]
    public async Task A_repo_added_to_a_running_lane_stack_starts_from_the_lane_not_from_the_base_lane()
    {
        var (supervisor, store, _) = CreateSupervisor();
        var env = Env("ab1-ok", ["octo-a"]);
        var tools = new StackTools(supervisor, store);
        var started = await tools.Start("agent-1", lane: "ab1-ok", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        started.Status.Services.Single(s => s.Name == "alpha").RepoPath.Should().Be(Path.Combine(env, "octo-a"));

        // lane_add_repo octo-b while the lane stack runs: the manifest lists it now
        Env("ab1-ok", ["octo-a", "octo-b"]);
        var beta = await tools.ServiceStart("agent-1", ["beta"], waitForHealthy: false, timeoutSeconds: 1, lane: "ab1-ok", cancellationToken: Ct);

        beta.Status.Services.Single(s => s.Name == "beta").RepoPath.Should().Be(Path.Combine(env, "octo-b"), "octo-b is in the lane now");
        await tools.Stop("agent-1", lane: "ab1-ok", cancellationToken: Ct);
    }
}
