using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     One daemon per state folder (AB#9377): a second daemon - launchd's KeepAlive restart racing Start-OctoDevStackDaemon on
///     macOS - must stop before it adopts services or writes a start record.
/// </summary>
public sealed class DaemonLockTests : IDisposable
{
    private readonly TestCheckout _checkout = new();

    public void Dispose() => _checkout.Dispose();

    [Fact]
    public void A_second_daemon_on_the_same_state_folder_does_not_get_the_lock()
    {
        using var first = DaemonLock.TryAcquire(_checkout.StateDirectory);
        first.Should().NotBeNull();

        DaemonLock.TryAcquire(_checkout.StateDirectory).Should().BeNull("the first daemon still holds it");
    }

    [Fact]
    public void The_lock_is_free_again_when_its_holder_ends()
    {
        DaemonLock.TryAcquire(_checkout.StateDirectory)!.Dispose();

        using var next = DaemonLock.TryAcquire(_checkout.StateDirectory);
        next.Should().NotBeNull("the next daemon starts after the previous one ended");
    }

    [Fact]
    public async Task A_daemon_that_waits_takes_the_lock_when_its_holder_ends()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var first = DaemonLock.TryAcquire(_checkout.StateDirectory)!;
        var waiting = DaemonLock.WaitAsync(_checkout.StateDirectory, TimeSpan.FromMilliseconds(20), cancellationToken);

        await Task.Delay(200, cancellationToken);
        waiting.IsCompleted.Should().BeFalse("the first daemon still holds the lock");

        first.Dispose();
        using var taken = await waiting.WaitAsync(TimeSpan.FromSeconds(10), cancellationToken);
        taken.Should().NotBeNull();
        DaemonLock.TryAcquire(_checkout.StateDirectory).Should().BeNull("the waiting daemon holds it now");
    }

    [Fact]
    public async Task Waiting_for_the_lock_ends_when_it_is_canceled()
    {
        using var first = DaemonLock.TryAcquire(_checkout.StateDirectory);
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));

        var act = () => DaemonLock.WaitAsync(_checkout.StateDirectory, TimeSpan.FromMilliseconds(20), cancel.Token);

        await act.Should().ThrowAsync<OperationCanceledException>();
    }

    [Theory]
    [InlineData("launchd", true)]
    [InlineData("systemd", false)]
    [InlineData(null, false)]
    [InlineData("", false)]
    public void Only_a_daemon_launchd_runs_waits_for_a_held_lock(string? serviceManager, bool waits)
    {
        // launchd's KeepAlive starts every daemon that exits again; systemd counts the exit code as a success and stops.
        DaemonLock.WaitsForTheLock(serviceManager).Should().Be(waits);
        DaemonLock.HeldExitCode.Should().Be(75);
    }

    [Theory]
    [InlineData(0x1u, true)]   // FILE_TYPE_DISK: daemon.log of Start-Process
    [InlineData(0x3u, true)]   // FILE_TYPE_PIPE
    [InlineData(0x2u, false)]  // FILE_TYPE_CHAR: a console stays as it is
    [InlineData(0x0u, false)]  // FILE_TYPE_UNKNOWN
    public void Windows_keeps_a_log_file_or_pipe_of_the_daemon_from_its_children(uint fileType, bool kept)
    {
        StdHandles.KeptFromChildren(fileType).Should().Be(kept);
    }

    [Fact]
    public void A_lock_file_this_user_cannot_write_is_an_error_not_another_daemon()
    {
        var lockFile = DaemonLock.PathIn(_checkout.StateDirectory);
        Directory.CreateDirectory(_checkout.StateDirectory);
        File.WriteAllText(lockFile, "");
        if (OperatingSystem.IsWindows())
        {
            File.SetAttributes(lockFile, FileAttributes.ReadOnly);
        }
        else
        {
            File.SetUnixFileMode(lockFile, UnixFileMode.UserRead);
        }

        try
        {
            using var taken = DaemonLock.TryAcquire(_checkout.StateDirectory);
            taken.Should().NotBeNull("only a user who may write it anyway (root) opens it, and then no other daemon holds it either");
        }
        catch (UnauthorizedAccessException)
        {
            // expected: reported as what it is - never null, which would mean "another daemon runs"
        }
        finally
        {
            if (OperatingSystem.IsWindows())
            {
                File.SetAttributes(lockFile, FileAttributes.Normal);
            }
            else
            {
                File.SetUnixFileMode(lockFile, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
        }
    }

    [Fact]
    public void Only_a_refused_lock_counts_as_another_daemon_other_file_errors_do_not()
    {
        // The real refusal of this OS is what the first test produces; here the errors around it, as .NET reports them.
        if (OperatingSystem.IsWindows())
        {
            DaemonLock.IsHeldByAnother(new IOException("sharing violation", unchecked((int)0x80070020))).Should().BeTrue();
            DaemonLock.IsHeldByAnother(new IOException("lock violation", unchecked((int)0x80070021))).Should().BeTrue();
            DaemonLock.IsHeldByAnother(new IOException("disk full", unchecked((int)0x80070070))).Should().BeFalse();
        }
        else
        {
            DaemonLock.IsHeldByAnother(new IOException("flock refused", DaemonLock.WouldBlockErrno)).Should().BeTrue();
            DaemonLock.IsHeldByAnother(new IOException("read-only file system", 30)).Should().BeFalse();
            DaemonLock.IsHeldByAnother(new IOException("no space left", 28)).Should().BeFalse();
            DaemonLock.IsHeldByAnother(new IOException("I/O error", 5)).Should().BeFalse();
        }

        DaemonLock.IsHeldByAnother(new DirectoryNotFoundException()).Should().BeFalse();
    }

    [Fact]
    public void Daemons_of_different_state_folders_do_not_block_each_other()
    {
        using var shared = DaemonLock.TryAcquire(_checkout.StateDirectory);
        using var development = DaemonLock.TryAcquire(Path.Combine(_checkout.Root, ".state-dev"));

        shared.Should().NotBeNull();
        development.Should().NotBeNull("the development daemon has its own state folder");
    }
}
