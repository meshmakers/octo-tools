using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Meshmakers.Octo.DevStack.Tools;
using Microsoft.Extensions.Logging.Abstractions;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>Command lines leave the daemon masked (stack_status, start/stop results, /api/overview); internally they stay raw.</summary>
public sealed class StatusMaskTests : IDisposable
{
    private readonly TestCheckout _checkout = new();

    public void Dispose() => _checkout.Dispose();

    [Fact]
    public void Arguments_and_command_lines_keep_their_shape_with_secret_values_masked()
    {
        SecretMask.MaskArgs(["App.dll", "--ApiKey=abc", "--ClientSecret", "xyz", "--urls", "http://0.0.0.0:5020", "--Broker=amqp://u:p@host", "--Flag"])
            .Should().Equal("App.dll", "--ApiKey=***", "--ClientSecret", "***", "--urls", "http://0.0.0.0:5020", "--Broker=amqp://***@host", "--Flag");
        SecretMask.MaskCommandLine("dotnet  App.dll --Octo:Token tok --Mongo=mongodb://a:b@h:27017 --Level=Debug")
            .Should().Be("dotnet  App.dll --Octo:Token *** --Mongo=mongodb://***@h:27017 --Level=Debug");
    }

    [Fact]
    public void Status_masks_service_args_external_commands_and_launcher_commands()
    {
        var origin = new ExternalOrigin("start-octo", "Start-Octo", 1, "pwsh -c Start-Octo -LicenseKey L1C", "main", "DebugL", true, null, "Stop-Octo");
        var external = new ExternalService("web", 42, [], "dotnet Web.dll --Password=pw", null, null, null, null, null, null, false, null, null, "g1");
        var service = new ServiceStatus("web", "healthy", true, null, 7, null, "/r", "/r", "dotnet", ["Web.dll", "--Token", "t0k"], "/l", [],
            DateTimeOffset.Now, null, null, false, null);
        var status = new StackStatus(true, "/c", "DebugL", null, null, new LeaseSnapshot(null, []), [service], [],
            new ExternalSnapshot([external], [new ExternalGroup("g1", origin, null, null, ["web"], null)]));

        var masked = status.Masked();

        masked.Services[0].Args.Should().Equal("Web.dll", "--Token", "***");
        masked.External.Services[0].Command.Should().Be("dotnet Web.dll --Password=***");
        masked.External.Groups[0].Origin.LauncherCommand.Should().Be("pwsh -c Start-Octo -LicenseKey ***");
        status.Services[0].Args.Should().Contain("t0k", "the raw status is left alone");
    }

    [Fact]
    public async Task Stack_status_tool_masks_while_the_supervisor_keeps_the_raw_args()
    {
        _checkout.Repo("tools");
        var store = _checkout.WriteConfig("""
                                            web:
                                              repo: tools
                                              workingDirectory: .
                                              command: pwsh
                                              args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30 #", "--Octo:ApiKey=s3cret"]
                                          """);
        var supervisor = new StackSupervisor(store, new LeaseManager(), new StateStore(new DevStackPaths(_checkout.StateDirectory)),
            NullLogger<StackSupervisor>.Instance);
        var tools = new StackTools(supervisor, store);

        var started = await tools.Start("a", cancellationToken: TestContext.Current.CancellationToken, waitForHealthy: false);
        started.Status.Services.Single().Args.Should().Contain("--Octo:ApiKey=***");
        (await tools.Status()).Services.Single().Args.Should().NotContain(a => a.Contains("s3cret"));
        (await supervisor.StatusAsync(false)).Services.Single().Args.Should().Contain("--Octo:ApiKey=s3cret");
        (await tools.Stop("a", cancellationToken: TestContext.Current.CancellationToken)).Status.Services.Should().BeEmpty();
    }
}
