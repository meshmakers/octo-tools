using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>The daemon's start/stop history and the rule that says whether it may be restarted.</summary>
public sealed class DaemonJournalTests : IDisposable
{
    private readonly TestCheckout _checkout = new();

    public void Dispose() => _checkout.Dispose();

    private DaemonJournal Journal(DateTimeOffset? startedAt = null) =>
        new(new DevStackPaths(_checkout.StateDirectory), "http://127.0.0.1:5999", _checkout.ConfigPath, development: true, startedAt);

    [Fact]
    public void A_stop_names_the_signal_and_the_next_start_follows_it()
    {
        var first = Journal();
        first.RecordStart().Select(e => e.Event).Should().Equal("start");
        first.NoteSignal("SIGTERM");
        first.NoteSignal("SIGINT");
        first.RecordStop("1 build(s) queued or running: b1 running (s1)")!.Trigger.Should().Be("signal SIGTERM", "the first signal ended the run");
        first.RecordStop().Should().BeNull("a shutdown is recorded once");

        var second = Journal();
        second.RecordStart().Select(e => e.Event).Should().Equal("start");

        second.Recent().Select(e => e.Event).Should().Equal("start", "stop", "start");
        second.Recent()[1].Detail.Should().Contain("b1 running");
        second.Daemon.Development.Should().BeTrue();
        second.Daemon.Pid.Should().Be(Environment.ProcessId);
    }

    [Fact]
    public void A_run_without_a_shutdown_record_is_reported_as_lost_by_the_next_start()
    {
        Journal(DateTimeOffset.Now.AddMinutes(-10)).RecordStart();

        var written = Journal().RecordStart();

        written.Select(e => e.Event).Should().Equal("lost", "start");
        written[0].Detail.Should().Contain("killed (SIGKILL), crashed");
    }

    [Fact]
    public void A_shutdown_without_a_signal_is_a_host_shutdown_and_a_broken_line_is_skipped()
    {
        var journal = Journal();
        journal.RecordStart();
        File.AppendAllText(Path.Combine(_checkout.StateDirectory, "daemon-history.jsonl"), "{\"at\":\"2026-11-1");

        journal.RecordStop()!.Trigger.Should().Be("host shutdown");
        journal.Recent().Select(e => e.Event).Should().Equal("stop", "start");
    }

    [Fact]
    public void The_version_carries_the_commit_the_binaries_were_built_from()
    {
        DaemonJournal.SplitVersion("1.0.0+8b45d869b9ba0f1e2d3c").Should().Be(("1.0.0", "8b45d869b9ba"));
        DaemonJournal.SplitVersion("1.0.0").Should().Be(("1.0.0", null));
    }

    [Fact]
    public void A_restart_is_safe_only_while_no_build_runs_or_waits_and_leases_only_warn()
    {
        var lease = new HeldLease("ab8797", "lane:ab8797", "feature work", DateTimeOffset.Now.AddHours(1));

        var idle = DaemonJournal.Check([], [lease]);
        idle.Safe.Should().BeTrue("a held lease survives the restart");
        idle.Warnings.Should().ContainSingle().Which.Should().Contain("lane:ab8797");

        var busy = DaemonJournal.Check([
            new ActiveBuild("b1-1", "s1", "running", "env", "ab8797", "ab8797", 4711, null, true),
            new ActiveBuild("b2-1", "s2", "running", "range", "main: a -> b", null, 4712, "stopping", false),
            new ActiveBuild("b3-1", "s3", "queued", "repo", "octo-a", null, null, null, true)
        ], []);
        busy.Safe.Should().BeFalse();
        busy.Blockers.Should().HaveCount(3);
        busy.Blockers[0].Should().Contain("b1-1 of s1").And.Contain("re-attached");
        busy.Blockers[1].Should().Contain("would NOT survive");
        busy.Blockers[2].Should().Contain("queued");
    }
}
