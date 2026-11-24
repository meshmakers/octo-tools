using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Tests;

public class LeaseManagerTests
{
    private sealed class ManualTime : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = new(2026, 11, 9, 10, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }

    [Fact]
    public void First_changing_call_takes_the_lease_and_others_are_refused()
    {
        var lease = new LeaseManager();
        lease.Require("session-a", "stack").Owner.Should().Be("session-a");
        lease.Require("SESSION-A ").Owner.Should().Be("session-a", "owner comparison ignores case and blanks");

        var act = () => lease.Require("session-b");
        act.Should().Throw<LeaseHeldException>().WithMessage("*held by 'session-a'*");
    }

    [Fact]
    public void A_lease_keeps_the_session_of_the_call_next_to_the_owner()
    {
        var lease = new LeaseManager();
        using (LeaseSession.Use("meshmakers-07", "reimar/AB#1_x"))
        {
            lease.Require("reimar/AB#1_x").Session.Should().Be("meshmakers-07");
        }

        lease.Require("reimar/AB#1_x").Session.Should().Be("meshmakers-07", "a renewal without a session keeps the holder's");
        lease.Require("reimar/AB#1_x", session: "meshmakers-09").Session.Should().Be("meshmakers-09", "a call that names one replaces it");

        var other = () => lease.Require("someone-else");
        other.Should().Throw<LeaseHeldException>().WithMessage("*held by 'reimar/AB#1_x' (session meshmakers-09)*");
    }

    [Fact]
    public void The_session_of_a_call_applies_only_to_the_owners_the_call_names()
    {
        var lease = new LeaseManager();
        using (LeaseSession.Use("meshmakers-07", "a", "lane:ab1"))
        {
            // e.g. a queued build of another owner that starts during this call
            lease.Require("b").Session.Should().BeNull();
            lease.Release("b", force: false);
            lease.Require("lane:ab1").Session.Should().Be("meshmakers-07", "a lane's lease records the session acting for it");
        }

        LeaseSession.Of("a").Should().BeNull("the session ends with the call");
    }

    [Fact]
    public async Task Acquire_and_the_queue_name_the_session()
    {
        var lease = new LeaseManager();
        var ct = TestContext.Current.CancellationToken;
        (await lease.AcquireAsync("a", "x", TimeSpan.FromMinutes(5), TimeSpan.Zero, ct, session: "meshmakers-01"))!.Session.Should().Be("meshmakers-01");

        var waiting = lease.AcquireAsync("b", "y", TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(30), ct, session: "meshmakers-02");
        while (lease.Snapshot().Queue.Count == 0)
        {
            await Task.Delay(10, ct);
        }

        lease.Snapshot().Queue.Single().Session.Should().Be("meshmakers-02");
        lease.Release("a", force: false);
        (await waiting)!.Session.Should().Be("meshmakers-02");
    }

    [Fact]
    public async Task Changing_calls_keep_the_purpose_given_at_acquire()
    {
        var lease = new LeaseManager();
        await lease.AcquireAsync("a", "verify enum null handling", TimeSpan.FromMinutes(5), TimeSpan.Zero, TestContext.Current.CancellationToken);
        lease.Require("a").Purpose.Should().Be("verify enum null handling");
    }

    [Fact]
    public void Lease_expires_and_is_renewed_by_the_holder()
    {
        var time = new ManualTime();
        var lease = new LeaseManager(time);
        lease.Require("a", ttl: TimeSpan.FromMinutes(10));

        time.Now += TimeSpan.FromMinutes(8);
        lease.Require("a", ttl: TimeSpan.FromMinutes(10)).ExpiresAt.Should().Be(time.Now + TimeSpan.FromMinutes(10));

        time.Now += TimeSpan.FromMinutes(11);
        lease.Snapshot().Holder.Should().BeNull();
        lease.Require("b").Owner.Should().Be("b");
    }

    [Fact]
    public void Release_by_another_session_needs_force()
    {
        var lease = new LeaseManager();
        lease.Require("a");
        var act = () => lease.Release("b", force: false);
        act.Should().Throw<LeaseHeldException>();
        lease.Release("b", force: true).Former!.Owner.Should().Be("a");
        lease.Snapshot().Holder.Should().BeNull();
        lease.Release("b", force: true).Should().Be(new LeaseRelease(null, null), "nothing is held any more");
    }

    [Fact]
    public async Task A_release_hands_the_lease_to_the_first_waiter_at_once_and_says_so()
    {
        var lease = new LeaseManager();
        var ct = TestContext.Current.CancellationToken;
        lease.Require("a", session: "meshmakers-01");
        var waiting = lease.AcquireAsync("b", "verify", TimeSpan.FromMinutes(7), TimeSpan.FromSeconds(30), ct, session: "meshmakers-02");
        var third = lease.AcquireAsync("c", null, TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(30), ct);
        while (lease.Snapshot().Queue.Count < 2)
        {
            await Task.Delay(10, ct);
        }

        var events = new List<LeaseInfo?>();
        lease.Changed += events.Add;
        var release = lease.Release("a", force: false);

        release.Former!.Session.Should().Be("meshmakers-01");
        release.Next!.Owner.Should().Be("b", "the lease is handed over in the release, not when the waiter wakes up");
        release.Next.Session.Should().Be("meshmakers-02");
        release.Next.Purpose.Should().Be("verify");
        release.Next.TtlMinutes.Should().Be(7, "the waiter's own idle timeout");
        lease.Snapshot().Holder!.Owner.Should().Be("b");
        lease.Snapshot().Queue.Select(w => w.Owner).Should().Equal("c");
        events.Should().ContainSingle().Which!.Owner.Should().Be("b", "one announcement: the new holder");
        (await waiting)!.Owner.Should().Be("b");
        events.Should().ContainSingle("the waiter does not announce it again");

        lease.Release("b", force: false).Next!.Owner.Should().Be("c");
        (await third)!.Owner.Should().Be("c");
    }

    [Fact]
    public async Task Lease_release_answers_whether_it_released_whose_lease_and_who_holds_it_now()
    {
        var lease = new LeaseManager();
        var ct = TestContext.Current.CancellationToken;
        var tools = new Tools.LeaseTools(new LeaseRegistry(lease), new ConfigStore(Path.Combine(Path.GetTempPath(), "never-read.yaml")));

        var free = tools.Release("reimar/AB#1_x", session: "meshmakers-01");
        free.Released.Should().BeFalse();
        free.FormerHolder.Should().BeNull();
        free.Note.Should().Be("Nothing released: the lease of the shared stack was not held (free, or it expired).");

        lease.Require("reimar/AB#1_x", session: "meshmakers-01");
        var waiting = lease.AcquireAsync("reimar/AB#2_y", null, TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(30), ct, session: "meshmakers-02");
        SpinWait.SpinUntil(() => lease.Snapshot().Queue.Count == 1, 2000).Should().BeTrue();
        var handed = tools.Release("reimar/AB#1_x", session: "meshmakers-01");
        handed.Released.Should().BeTrue();
        handed.FormerHolder!.Owner.Should().Be("reimar/AB#1_x");
        handed.FormerHolder.Session.Should().Be("meshmakers-01");
        handed.Holder!.Owner.Should().Be("reimar/AB#2_y");
        handed.Holder.Session.Should().Be("meshmakers-02");
        handed.Queue.Should().BeEmpty();
        handed.Note.Should().Be("Released the lease of the shared stack held by 'reimar/AB#1_x' (session meshmakers-01); the first waiting session, " +
                                "'reimar/AB#2_y' (session meshmakers-02), holds it now.");
        await waiting;

        var json = System.Text.Json.JsonSerializer.SerializeToNode(tools.Release("reimar/AB#2_y"), ModelContextProtocol.McpJsonUtilities.DefaultOptions)!.AsObject();
        json["released"]!.GetValue<bool>().Should().BeTrue();
        json["formerHolder"]!["owner"]!.GetValue<string>().Should().Be("reimar/AB#2_y");
        json["holder"].Should().BeNull();
        json["note"]!.GetValue<string>().Should().EndWith("it is free now.");
    }

    [Fact]
    public async Task Waiter_gets_the_lease_when_it_is_released_and_blocks_others()
    {
        var lease = new LeaseManager();
        lease.Require("a");

        var waiting = lease.AcquireAsync("b", "tests", TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(10), CancellationToken.None);
        await Task.Delay(200, TestContext.Current.CancellationToken);
        lease.Snapshot().Queue.Should().ContainSingle(w => w.Owner == "b");

        lease.Release("a", force: false);
        // A third session must not jump the queue while b is being served.
        var granted = await waiting;
        granted!.Owner.Should().Be("b");
        lease.Snapshot().Queue.Should().BeEmpty();
        var act = () => lease.Require("c");
        act.Should().Throw<LeaseHeldException>();
    }

    [Fact]
    public async Task A_canceled_call_of_an_owner_leaves_another_waiting_call_of_the_same_owner_its_place_and_its_lease()
    {
        var lease = new LeaseManager();
        lease.Require("a");
        var ct = TestContext.Current.CancellationToken;
        using var gone = new CancellationTokenSource();
        var staying = lease.AcquireAsync("b", null, TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(20), CancellationToken.None);
        var canceled = lease.AcquireAsync("b", null, TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(20), gone.Token);
        SpinWait.SpinUntil(() => lease.Snapshot().Queue.Count == 1, 2000).Should().BeTrue();

        await gone.CancelAsync();
        await FluentActions.Awaiting(() => canceled).Should().ThrowAsync<OperationCanceledException>();
        lease.Snapshot().Queue.Should().ContainSingle(w => w.Owner == "b", "the other call of b still waits on the entry");

        lease.Release("a", force: false);
        (await staying.WaitAsync(TimeSpan.FromSeconds(5), ct))!.Owner.Should().Be("b");
        lease.Current()!.Owner.Should().Be("b");
    }

    [Fact]
    public async Task A_call_canceled_right_after_the_handover_does_not_take_back_the_lease_another_call_of_the_owner_returns()
    {
        var ct = TestContext.Current.CancellationToken;
        for (var round = 0; round < 20; round++)
        {
            var lease = new LeaseManager();
            lease.Require("a");
            lease.AcquireAsync("c", null, TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(20), CancellationToken.None).IsCompleted.Should().BeFalse();
            using var gone = new CancellationTokenSource();
            SpinWait.SpinUntil(() => lease.Snapshot().Queue.Count == 1, 2000);
            var staying = lease.AcquireAsync("b", null, TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(20), CancellationToken.None);
            var canceled = lease.AcquireAsync("b", null, TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(20), gone.Token);
            SpinWait.SpinUntil(() => lease.Snapshot().Queue.Count == 2, 2000).Should().BeTrue();
            lease.Release("a", force: false); // c first
            lease.Release("c", force: false); // hands it to b

            await gone.CancelAsync(); // races with the two calls of b waking up
            (await staying.WaitAsync(TimeSpan.FromSeconds(5), ct))!.Owner.Should().Be("b");
            try
            {
                await canceled;
            }
            catch (OperationCanceledException)
            {
                // either outcome: it returned the lease too, or it was canceled - but it never gives the lease away
            }

            lease.Current()!.Owner.Should().Be("b", $"round {round}: a call of b returned the lease, so b holds it");
        }
    }

    [Fact]
    public async Task Waiting_times_out_and_leaves_the_queue()
    {
        var lease = new LeaseManager();
        lease.Require("a");
        (await lease.AcquireAsync("b", null, TimeSpan.FromMinutes(5), TimeSpan.FromMilliseconds(300), CancellationToken.None)).Should().BeNull();
        lease.Snapshot().Queue.Should().BeEmpty();
        (await lease.AcquireAsync("b", null, TimeSpan.FromMinutes(5), TimeSpan.Zero, CancellationToken.None)).Should().BeNull();
    }

    [Fact]
    public void Free_lease_with_a_waiter_goes_to_the_waiter_first()
    {
        var lease = new LeaseManager();
        lease.Require("a");
        _ = lease.AcquireAsync("b", null, TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(30), CancellationToken.None);
        SpinWait.SpinUntil(() => lease.Snapshot().Queue.Count == 1, 2000);

        // Free it without notifying the waiter loop yet: a newcomer must still be refused.
        lease.Release("a", force: false);
        var act = () => lease.Require("c");
        act.Should().Throw<LeaseHeldException>();
    }

    [Fact]
    public void Changed_event_reports_grants_and_releases()
    {
        var lease = new LeaseManager();
        var events = new List<LeaseInfo?>();
        lease.Changed += events.Add;
        lease.Require("a");
        lease.Release("a", false);
        events.Should().HaveCount(2);
        events[0]!.Owner.Should().Be("a");
        events[1].Should().BeNull();
    }

    [Fact]
    public void A_pinned_lease_does_not_expire_and_unpinning_renews_it()
    {
        var time = new ManualTime();
        var lease = new LeaseManager(time);
        var changes = new List<LeaseInfo?>();
        lease.Changed += changes.Add;
        lease.Require("a", ttl: TimeSpan.FromMinutes(10));

        var pin = lease.Pin("a");
        time.Now += TimeSpan.FromHours(3);
        lease.Snapshot().Holder!.Owner.Should().Be("a", "a running build pins the lease");
        var other = () => lease.Require("b");
        other.Should().Throw<LeaseHeldException>();

        pin.Dispose();
        lease.IsPinned("a").Should().BeFalse();
        lease.Snapshot().Holder!.ExpiresAt.Should().BeAfter(time.Now, "the end of the pin renews the lease");
        changes.Last()!.Owner.Should().Be("a");
        pin.Dispose(); // idempotent
    }

    [Fact]
    public void The_default_lease_is_an_idle_timeout_of_30_minutes_and_shows_the_last_activity()
    {
        var time = new ManualTime();
        var lease = new LeaseManager(time);
        var start = time.GetLocalNow();
        lease.Require("a", "verify").ExpiresAt.Should().Be(start + TimeSpan.FromMinutes(30));

        time.Now += TimeSpan.FromMinutes(12.5);
        var holder = lease.Snapshot().Holder!;
        holder.LastActivityAt.Should().Be(start);
        holder.IdleMinutes.Should().Be(12, "whole minutes since the last changing call");
        holder.LastActivityAt!.Value.Offset.Should().Be(time.GetLocalNow().Offset, "times shown to the developer are local");

        var renewed = lease.Require("a");
        renewed.LastActivityAt.Should().Be(time.GetLocalNow(), "every changing call is activity");
        renewed.ExpiresAt.Should().Be(time.GetLocalNow() + TimeSpan.FromMinutes(30));
        lease.Snapshot().Holder!.IdleMinutes.Should().Be(0);

        time.Now += TimeSpan.FromMinutes(29);
        var refused = () => lease.Require("b");
        refused.Should().Throw<LeaseHeldException>().WithMessage($"*last active {time.GetLocalNow().AddMinutes(-29):HH:mm}*");

        time.Now += TimeSpan.FromMinutes(2);
        lease.Snapshot().Holder.Should().BeNull("30 idle minutes end the lease");
        lease.Require("b").Owner.Should().Be("b");
    }

    [Fact]
    public void The_last_activity_survives_a_daemon_restart_and_idle_minutes_are_not_persisted()
    {
        using var checkout = new TestCheckout();
        var paths = new DevStackPaths(checkout.StateDirectory);
        var time = new ManualTime();
        var store = new StateStore(paths);
        var lease = new LeaseManager(time);
        lease.Changed += store.SaveLease;
        lease.Require("a", "verify");
        var active = time.GetLocalNow();
        time.Now += TimeSpan.FromMinutes(7);
        lease.Snapshot(); // a lease_status call writes nothing

        File.ReadAllText(paths.StateFile).Should().Contain("LastActivityAt").And.NotContain("IdleMinutes");
        var restored = new LeaseManager(time, new StateStore(paths).Load().LeasesBySlot()["default"]);
        var holder = restored.Snapshot().Holder!;
        holder.Owner.Should().Be("a");
        holder.LastActivityAt.Should().Be(active);
        holder.IdleMinutes.Should().Be(7);
        holder.ExpiresAt.Should().Be(active + TimeSpan.FromMinutes(30));
    }

    [Fact]
    public void A_lease_of_an_older_state_file_derives_its_last_activity_from_the_expiry()
    {
        var time = new ManualTime();
        var acquired = time.GetLocalNow() - TimeSpan.FromMinutes(50);
        var renewed = time.GetLocalNow() - TimeSpan.FromMinutes(20);
        // An older daemon kept no last activity: every renewal set the expiry to its time plus the TTL.
        var lease = new LeaseManager(time, new LeaseInfo("a", null, acquired, renewed + TimeSpan.FromMinutes(120)) { TtlMinutes = 120 });

        var holder = lease.Snapshot().Holder!;
        holder.LastActivityAt.Should().Be(renewed);
        holder.IdleMinutes.Should().Be(20);
        new LeaseInfo("a", null, acquired, acquired + TimeSpan.FromHours(1)).LastActivity().Should().Be(acquired, "without a recorded TTL: the grant");
    }

    [Fact]
    public void An_expiry_found_by_any_call_raises_Changed_once()
    {
        var time = new ManualTime();
        var lease = new LeaseManager(time);
        var events = new List<LeaseInfo?>();
        lease.Require("a", ttl: TimeSpan.FromMinutes(10));
        lease.Changed += events.Add;

        time.Now += TimeSpan.FromMinutes(11);
        lease.Current().Should().BeNull();
        events.Should().BeEmpty("Current() is for event handlers and raises nothing");
        lease.Snapshot();
        lease.Snapshot();

        events.Should().Equal(new LeaseInfo?[] { null });
    }
}
