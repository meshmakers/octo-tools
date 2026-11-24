using FluentAssertions;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Tests;

public sealed class DockerVmTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 11, 12, 0, 0, TimeSpan.Zero);

    private static Func<string, (int, string)> Docker(string info, string images, int exit = 0) =>
        arguments => arguments.StartsWith("info", StringComparison.Ordinal) ? (exit, info) : (0, images);

    [Fact]
    public void A_small_vm_next_to_kind_gets_a_warning_that_names_what_is_small()
    {
        var info = DockerVm.Probe(Docker("""{"NCPU":4,"MemTotal":8327528448,"OperatingSystem":"Docker Desktop"}""", "kindest/node:v1.33.1\nseaweedfs:latest\n"), 12, 6, Now);

        info.Available.Should().BeTrue();
        info.MemoryGb.Should().Be(7.8);
        info.Cpus.Should().Be(4);
        info.Kind.Should().BeTrue();
        info.OperatingSystem.Should().Be("Docker Desktop");
        info.Warning.Should().Contain("7.8 GiB memory (below 12)").And.Contain("4 CPUs (below 6)").And.Contain("kind cluster runs in it");
    }

    [Fact]
    public void No_warning_without_kind_or_with_a_large_vm()
    {
        DockerVm.Probe(Docker("""{"NCPU":4,"MemTotal":8327528448}""", "postgres:16\n"), 12, 6, Now).Warning.Should().BeNull("kind does not run");
        var large = DockerVm.Probe(Docker("""{"NCPU":16,"MemTotal":16745033728}""", "kindest/node:v1.33.1\n"), 12, 6, Now);
        large.Warning.Should().BeNull();
        large.MemoryGb.Should().Be(15.6);
        DockerVm.WarningOf(15.6, 4, true, 12, 6).Should().Contain("4 CPUs (below 6)").And.NotContain("GiB memory");
    }

    [Fact]
    public void Docker_that_does_not_answer_is_reported_as_unavailable_without_a_warning()
    {
        DockerVm.Probe(Docker("Cannot connect to the Docker daemon", "", exit: 1), 12, 6, Now).Should()
            .BeEquivalentTo(new { Available = false, Kind = false, Warning = (string?)null });
        DockerVm.Probe(Docker("""{"NCPU":0,"MemTotal":0,"ServerErrors":["Cannot connect"]}""", ""), 12, 6, Now).Available.Should().BeFalse("only the client answered");
        DockerVm.Probe(_ => throw new System.ComponentModel.Win32Exception("no docker"), 12, 6, Now).Available.Should().BeFalse("docker is not installed");
    }
}
