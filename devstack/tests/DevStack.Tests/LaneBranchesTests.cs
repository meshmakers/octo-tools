using FluentAssertions;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>The feature branches lane_remove deletes or keeps (temp repositories, git as a process).</summary>
public sealed class LaneBranchesTests : IDisposable
{
    private readonly TestCheckout _checkout = new();

    public void Dispose() => _checkout.Dispose();

    [Fact]
    public void A_command_for_the_developer_puts_its_values_in_single_quotes_and_offers_none_for_a_value_with_a_quote()
    {
        LaneBranches.Quote("reimar/AB#1_$(rm -rf x)`y`").Should().Be("'reimar/AB#1_$(rm -rf x)`y`'", "nothing expands inside single quotes");
        LaneBranches.Quote("it's").Should().BeNull();
        LaneBranches.Quote("a\nb").Should().BeNull();
    }

    [Fact]
    public async Task A_branch_whose_worktree_repository_git_cannot_name_is_reported_and_never_deleted()
    {
        var repo = _checkout.GitRepo("octo-a");
        var head = _checkout.Git(repo, "rev-parse", "HEAD");
        _checkout.Git(repo, "branch", "reimar/AB#1_x");
        _checkout.Git(repo, "branch", "keep-a-ref"); // the commit is on another branch too: it would be deleted if the owner were known

        var target = new LaneBranches.Target("octo-a", "reimar/AB#1_x", head, "main", repo) { OwnerUnknown = "git rev-parse --git-common-dir failed" };
        var result = (await LaneBranches.CleanAsync([target], keepAll: false)).Single();

        result.Deleted.Should().BeFalse();
        result.Delete.Should().BeNull();
        result.Reason.Should().Contain("could not be read").And.Contain("deletes no branch in another repository");
        _checkout.Git(repo, "branch", "--list", "reimar/*").Should().Contain("reimar/AB#1_x");

        var known = (await LaneBranches.CleanAsync([target with { OwnerUnknown = null }], keepAll: false)).Single();
        known.Deleted.Should().BeTrue("the same branch with its repository known holds nothing");
        _checkout.Git(repo, "branch", "--list", "reimar/*").Should().BeEmpty();
    }
}
