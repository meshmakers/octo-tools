using System.Diagnostics;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>AB#9808: no sleep on macOS while a job runs - caffeinate -i -w &lt;job pid&gt;, a no-op elsewhere.</summary>
public sealed class KeepAwakeTests
{
    [Fact]
    public void Caffeinate_prevents_idle_sleep_until_the_job_process_ends()
    {
        KeepAwake.Arguments(4711).Should().Equal("-i", "-w", "4711");
    }

    [Fact]
    public void Outside_macOS_nothing_is_started()
    {
        KeepAwake.While(Environment.ProcessId, isMacOs: false).Should().BeNull();
        KeepAwake.While(Environment.ProcessId, isMacOs: true, program: "/no/such/caffeinate").Should().BeNull("a missing caffeinate never fails a job");
    }

    [Fact]
    public async Task On_macOS_caffeinate_runs_while_the_job_process_runs_and_ends_with_it()
    {
        if (!OperatingSystem.IsMacOS())
        {
            KeepAwake.While(Environment.ProcessId).Should().BeNull("only macOS has caffeinate");
            return;
        }

        using var job = Process.Start(new ProcessStartInfo("/bin/sleep", "2") { UseShellExecute = false })!;
        using var caffeinate = KeepAwake.While(job.Id);

        caffeinate.Should().NotBeNull();
        caffeinate!.HasExited.Should().BeFalse("it holds the assertion while the job runs");
        await job.WaitForExitAsync(TestContext.Current.CancellationToken);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(15));
        await caffeinate.WaitForExitAsync(deadline.Token);
        caffeinate.HasExited.Should().BeTrue("caffeinate -w ends with the job's process");
    }
}
