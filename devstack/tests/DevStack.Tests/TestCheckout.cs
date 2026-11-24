using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>A throw-away rootPath with a lane (branches/main) and a config file in a temp folder.</summary>
internal sealed class TestCheckout : IDisposable
{
    public TestCheckout()
    {
        Root = Path.Combine(Path.GetTempPath(), "devstack-tests", Guid.NewGuid().ToString("N")[..12]);
        Lane = Path.Combine(Root, "branches", "main");
        Directory.CreateDirectory(Lane);
        File.WriteAllText(Path.Combine(Lane, "Octo.User.props"), "<Project />");
        StateDirectory = Path.Combine(Root, ".state");
        ConfigPath = Path.Combine(Root, "devstack.yaml");
    }

    public string Root { get; }
    public string Lane { get; }
    public string StateDirectory { get; }
    public string ConfigPath { get; }

    public string Repo(string name)
    {
        var path = Path.Combine(Lane, name);
        Directory.CreateDirectory(path);
        // A .NET repo has a solution in its root; without one kind=repo builds nothing (mode none, AB#9417).
        File.WriteAllText(Path.Combine(path, name + ".sln"), "");
        return path;
    }

    /// <summary>
    ///     A repo of the lane that is a real git repository with one commit (the solution file); returns its folder. git runs
    ///     with an empty global and no system config, so the developer's settings (signing, hooks, templates) never apply.
    /// </summary>
    public string GitRepo(string name)
    {
        var path = Repo(name);
        Git(path, "init", "-q", "-b", "main");
        Git(path, "add", "-A");
        Git(path, "commit", "-q", "-m", "init");
        return path;
    }

    /// <summary>Runs git in <paramref name="folder"/> (isolated from the machine's git config) and returns its trimmed output.</summary>
    public string Git(string folder, params string[] arguments)
    {
        var globalConfig = Path.Combine(Root, ".gitconfig-empty");
        if (!File.Exists(globalConfig))
        {
            Directory.CreateDirectory(Root);
            File.WriteAllText(globalConfig, "");
        }

        var start = new System.Diagnostics.ProcessStartInfo("git")
        {
            RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = folder
        };
        foreach (var argument in new[] { "-c", "user.name=devstack-tests", "-c", "user.email=devstack-tests@example.invalid", "-c", "commit.gpgsign=false" }.Concat(arguments))
        {
            start.ArgumentList.Add(argument);
        }

        start.Environment["GIT_CONFIG_NOSYSTEM"] = "1";
        start.Environment["GIT_CONFIG_GLOBAL"] = globalConfig;
        // Tests run from a git hook inherit what points git at another repository (or its index): the fixture must never touch it.
        foreach (var variable in new[] { "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE" })
        {
            start.Environment.Remove(variable);
        }
        using var process = System.Diagnostics.Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        process.WaitForExit();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"git {string.Join(' ', arguments)} exited with {process.ExitCode}: {error.Result}");
        }

        return output.Result.Trim();
    }

    public ConfigStore WriteConfig(string servicesYaml, string extra = "")
    {
        File.WriteAllText(ConfigPath, $"""
                                       rootPath: {Root}
                                       octoToolsPath: {Root}/octo-tools
                                       defaultCheckout: branches/main
                                       configuration: DebugL
                                       stopTimeoutSeconds: 3
                                       {extra}
                                       services:
                                       {servicesYaml}
                                       """);
        return new ConfigStore(ConfigPath);
    }

    /// <summary>
    ///     A devstack.yaml as the daemon writes it since AB#9377 - no rootPath, octoToolsPath or defaultCheckout - with the
    ///     folders from the workspace octo-tools describes (here: the lanes layout of this checkout), as in production.
    /// </summary>
    public ConfigStore WriteWorkspaceConfig(string servicesYaml, string extra = "")
    {
        File.WriteAllText(ConfigPath, $"""
                                       configuration: DebugL
                                       stopTimeoutSeconds: 3
                                       {extra}
                                       services:
                                       {servicesYaml}
                                       """);
        Directory.CreateDirectory(Path.Combine(Root, "octo-tools"));
        return new ConfigStore(ConfigPath) { WorkspaceInfo = Workspace() };
    }

    /// <summary>The workspace octo-tools would describe for this checkout (lanes layout, default lane branches/main).</summary>
    public WorkspaceInfo Workspace() => new("octo-tools", Root, Path.Combine(Root, "octo-tools"), "lanes", "branches/main", Lane, "lanes",
        Path.Combine(Root, "cfg"), true, []);

    /// <remarks>
    ///     A build queue or supervisor of the test may still write a state or job file at this moment (they are not disposed).
    ///     On Windows a file that ReplaceFile is swapping in (its "~RF....TMP" partner) or that another handle still has
    ///     open refuses the delete with UnauthorizedAccessException, an open directory with IOException: the delete is
    ///     tried again for a moment, and a temp folder that stays is left behind - cleaning up never fails a test that passed.
    /// </remarks>
    public void Dispose()
    {
        for (var attempt = 1; attempt <= 10; attempt++)
        {
            try
            {
                Directory.Delete(Root, recursive: true);
                return;
            }
            catch (DirectoryNotFoundException)
            {
                return;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                ClearReadOnly(); // git keeps its object files read-only, which Windows refuses to delete
                Thread.Sleep(50 * attempt);
            }
        }
    }

    private void ClearReadOnly()
    {
        try
        {
            foreach (var file in Directory.EnumerateFiles(Root, "*", SearchOption.AllDirectories))
            {
                var attributes = File.GetAttributes(file);
                if (attributes.HasFlag(FileAttributes.ReadOnly))
                {
                    File.SetAttributes(file, attributes & ~FileAttributes.ReadOnly);
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Tried again with the next attempt.
        }
    }
}
