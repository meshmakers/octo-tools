using FluentAssertions;
using Meshmakers.Octo.DevStack.Leasing;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>Claims are written into a temp lane only.</summary>
public sealed class LaneClaimsTests : IDisposable
{
    private readonly TestCheckout _checkout = new();

    private sealed class FakeTimeProvider(DateTimeOffset start) : TimeProvider
    {
        private DateTimeOffset _now = start;
        public override DateTimeOffset GetUtcNow() => _now.ToUniversalTime();
        public void Advance(TimeSpan by) => _now += by;
    }

    public void Dispose() => _checkout.Dispose();

    private static LeaseInfo Lease(string owner, DateTimeOffset now, string? purpose = "verify X") => new(owner, purpose, now, now.AddHours(2));

    [Fact]
    public void Claim_writes_a_readable_file_and_release_removes_it()
    {
        var time = new FakeTimeProvider(DateTimeOffset.Now);
        var claims = new LaneClaims(time);
        var now = time.GetLocalNow();

        claims.Claim(_checkout.Lane, Lease("reimar/AB#1_x", now));

        var file = LaneClaims.PathOf(_checkout.Lane);
        file.Should().Be(Path.Combine(_checkout.Lane, ".octo", "claims", "local-stack.md"));
        File.ReadAllText(file).Should().Contain("- Session: reimar/AB#1_x").And.Contain("- Purpose: verify X").And.Contain("- Expires: ");
        var claim = claims.Read(_checkout.Lane)!;
        claim.Session.Should().Be("reimar/AB#1_x");
        claim.ManagedByDevStack.Should().BeTrue();
        claim.Expires!.Value.Should().BeCloseTo(now.AddHours(2), TimeSpan.FromSeconds(1));

        claims.OnLeaseChanged(null);
        File.Exists(file).Should().BeFalse();
        claims.Lanes.Should().BeEmpty();
    }

    [Fact]
    public void A_claim_names_the_session_to_message_and_belongs_to_the_owner()
    {
        var time = new FakeTimeProvider(DateTimeOffset.Now);
        var claims = new LaneClaims(time);
        var now = time.GetLocalNow();

        claims.Claim(_checkout.Lane, Lease("reimar/AB#1_x", now) with { Session = "meshmakers-07" });

        File.ReadAllText(LaneClaims.PathOf(_checkout.Lane)).Should().Contain("- Session: meshmakers-07").And.Contain("- Owner: reimar/AB#1_x");
        var claim = claims.Read(_checkout.Lane)!;
        claim.Session.Should().Be("meshmakers-07");
        claim.Owner.Should().Be("reimar/AB#1_x");
        claims.EnsureCanClaim(_checkout.Lane, "reimar/AB#1_x");
        var other = () => claims.EnsureCanClaim(_checkout.Lane, "meshmakers-07");
        other.Should().Throw<LaneClaimedException>("the claim belongs to the owner, the session is who to message")
            .WithMessage("*claimed by 'reimar/AB#1_x' (session 'meshmakers-07') (verify X)*");
    }

    [Fact]
    public void A_claim_of_a_lane_written_before_the_lane_vocabulary_still_belongs_to_the_lane()
    {
        var file = LaneClaims.PathOf(_checkout.Lane, "local-stack-ab1");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, "# Claim\n\n- Session: env:ab1\n- Expires: 2999-01-01T00:00:00+00:00\n- Managed by: octo-devstack lease\n");
        var claims = new LaneClaims();

        claims.Read(_checkout.Lane, "local-stack-ab1")!.Owner.Should().Be("env:ab1", "a claim without an Owner line names its owner as Session");
        claims.EnsureCanClaim(_checkout.Lane, "lane:ab1", "local-stack-ab1");
        var other = () => claims.EnsureCanClaim(_checkout.Lane, "lane:ab2", "local-stack-ab1");
        other.Should().Throw<LaneClaimedException>();
    }

    [Fact]
    public void A_live_claim_of_another_session_blocks_and_an_expired_one_does_not()
    {
        var time = new FakeTimeProvider(DateTimeOffset.Now);
        var claims = new LaneClaims(time);
        claims.Claim(_checkout.Lane, Lease("session-a", time.GetLocalNow()));

        claims.EnsureCanClaim(_checkout.Lane, "session-a");
        var act = () => claims.EnsureCanClaim(_checkout.Lane, "session-b");
        act.Should().Throw<LaneClaimedException>().WithMessage("*claimed by 'session-a' (verify X) until*local-stack.md*");

        time.Advance(TimeSpan.FromHours(3));
        claims.EnsureCanClaim(_checkout.Lane, "session-b");
    }

    [Fact]
    public void A_hand_written_claim_without_expiry_blocks_and_is_never_removed_by_the_daemon()
    {
        var file = LaneClaims.PathOf(_checkout.Lane);
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, "# Claim: local stack\n\n- Session: daidalos-integrate\n- Since: 2026-11-09\n");
        var claims = new LaneClaims();

        var act = () => claims.EnsureCanClaim(_checkout.Lane, "someone");
        act.Should().Throw<LaneClaimedException>().WithMessage("*'daidalos-integrate'*without expiry*");

        claims.Track(_checkout.Lane);
        claims.Lanes.Should().BeEmpty("only claims octo-devstack wrote are kept in step");
        claims.OnLeaseChanged(null);
        File.Exists(file).Should().BeTrue();
    }

    [Fact]
    public void Lease_changes_rewrite_owner_and_expiry_and_a_new_lane_moves_the_claim()
    {
        var time = new FakeTimeProvider(DateTimeOffset.Now);
        var claims = new LaneClaims(time);
        var now = time.GetLocalNow();
        claims.Claim(_checkout.Lane, Lease("a", now));

        claims.OnLeaseChanged(new LeaseInfo("b", "other work", now, now.AddMinutes(30)));
        var claim = claims.Read(_checkout.Lane)!;
        claim.Session.Should().Be("b");
        claim.Purpose.Should().Be("other work");

        var otherLane = Path.Combine(_checkout.Root, "branches", "dev");
        Directory.CreateDirectory(otherLane);
        claims.Claim(otherLane, Lease("b", now));
        File.Exists(LaneClaims.PathOf(_checkout.Lane)).Should().BeFalse();
        File.Exists(LaneClaims.PathOf(otherLane)).Should().BeTrue();
        claims.Lanes.Should().Equal(otherLane);
    }

    [Fact]
    public void The_lease_manager_drives_the_claim()
    {
        var claims = new LaneClaims();
        var lease = new LeaseManager();
        lease.Changed += claims.OnLeaseChanged;
        var info = lease.Require("a", "purpose");
        claims.Claim(_checkout.Lane, info);

        lease.Require("a", "renewed purpose");
        claims.Read(_checkout.Lane)!.Purpose.Should().Be("renewed purpose");

        lease.Release("a", false);
        File.Exists(LaneClaims.PathOf(_checkout.Lane)).Should().BeFalse();
    }

    [Fact]
    public void An_expired_lease_removes_the_claim_and_claims_follow_the_current_holder()
    {
        var time = new FakeTimeProvider(DateTimeOffset.Now);
        var lease = new LeaseManager(time);
        var claims = new LaneClaims(time) { CurrentLease = lease.Current };
        var events = new List<LeaseInfo?>();
        lease.Changed += claims.OnLeaseChanged;
        lease.Changed += events.Add;

        var a = lease.Require("session-a", ttl: TimeSpan.FromMinutes(10));
        claims.Claim(_checkout.Lane, a);
        lease.Release("session-a", false);
        var b = lease.Require("session-b", ttl: TimeSpan.FromMinutes(10));
        claims.Claim(_checkout.Lane, b);

        // A late event of the earlier holder must not put it back on disk.
        claims.OnLeaseChanged(a);
        claims.Read(_checkout.Lane)!.Session.Should().Be("session-b");

        time.Advance(TimeSpan.FromMinutes(11));
        lease.Snapshot().Holder.Should().BeNull();
        events.Last().Should().BeNull("the expiry is announced");
        File.Exists(LaneClaims.PathOf(_checkout.Lane)).Should().BeFalse();
    }

    [Fact]
    public void An_unwritable_claim_folder_does_not_fail_the_lease_change()
    {
        var time = new FakeTimeProvider(DateTimeOffset.Now);
        var claims = new LaneClaims(time);
        claims.Claim(_checkout.Lane, Lease("session-a", time.GetLocalNow()));
        var file = LaneClaims.PathOf(_checkout.Lane);
        var folder = Path.GetDirectoryName(file)!;
        // Unwritable: a folder without write permission; on Windows (no Unix modes) a read-only claim file, which the
        // replacing move cannot overwrite.
        if (OperatingSystem.IsWindows())
        {
            File.SetAttributes(file, FileAttributes.ReadOnly);
        }
        else
        {
            File.SetUnixFileMode(folder, UnixFileMode.UserRead | UnixFileMode.UserExecute);
        }

        try
        {
            var act = () => claims.OnLeaseChanged(Lease("session-b", time.GetLocalNow()));
            act.Should().NotThrow();
            claims.Lanes.Should().Contain(_checkout.Lane, "the lane stays tracked");
        }
        finally
        {
            if (OperatingSystem.IsWindows())
            {
                File.SetAttributes(file, FileAttributes.Normal);
            }
            else
            {
                File.SetUnixFileMode(folder, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }
        }
    }
}
