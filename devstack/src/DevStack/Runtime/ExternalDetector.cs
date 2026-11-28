using System.Diagnostics;
using System.Text.RegularExpressions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>The Claude Code session a process was started from.</summary>
public sealed record ClaudeSessionInfo(int Pid, string? SessionId, string? Agent, string? WorkingDirectory);

/// <summary>Who started a group of external processes.</summary>
public sealed record ExternalOrigin(
    string Kind,
    string Description,
    int? LauncherPid,
    string? LauncherCommand,
    string? Branch,
    string? Configuration,
    bool NonInteractive,
    ClaudeSessionInfo? Session,
    string? StopHint);

/// <summary>A service process the daemon did not start (Start-Octo, npm run start, a leftover process).</summary>
public sealed record ExternalService(
    string Service,
    int Pid,
    IReadOnlyList<int> Ports,
    string Command,
    string? WorkingDirectory,
    [property: System.Text.Json.Serialization.JsonPropertyName("baseLane")] string? Checkout,
    string? RepoPath,
    string? Source,
    string? Configuration,
    DateTimeOffset? StartedAt,
    bool Healthy,
    string? HealthDetail,
    string? LogFile,
    string Group)
{
    /// <summary>The stack slot the ports point to: "default", a slot's name, or "offset +N" for a multiple of 100 no slot has.</summary>
    public string? SlotHint { get; init; }
}

public sealed record ExternalGroup(
    string Key,
    ExternalOrigin Origin,
    [property: System.Text.Json.Serialization.JsonPropertyName("baseLane")] string? Checkout,
    string? Configuration,
    IReadOnlyList<string> Services,
    DateTimeOffset? StartedAt,
    ProfileMatch? Profile = null);

public sealed record ExternalSnapshot(IReadOnlyList<ExternalService> Services, IReadOnlyList<ExternalGroup> Groups)
{
    public static readonly ExternalSnapshot Empty = new([], []);

    /// <summary>
    ///     Why the scan could not tell which processes run outside the daemon (an error while reading the OS): the services and
    ///     groups are then empty - unknown, not "none" - and the calling tool still answers (AB#9556). Null after a normal scan.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Warning { get; init; }

    /// <summary>
    ///     The processes the scan left out because their analysis failed (AB#9924); every other process is reported as usual,
    ///     so this is no <see cref="Warning"/>. Null when none was left out.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<ExternalSkipped>? Skipped { get; init; }
}

/// <summary>
///     A process the scan left out: its pid, the file name of its program (the image name the OS reports, else the first word
///     of its command line) and the type of the exception. Never its command
///     line, an argument, its location or the exception message (a message can quote its input).
/// </summary>
public sealed record ExternalSkipped(int Pid, string Executable, string ExceptionType);

/// <summary>
///     Finds the stack processes octo-devstack did not start and works out where they run from and who started them:
///     one ps and two lsof calls per scan (Windows: a Toolhelp snapshot, some command lines and the TCP listener table). Services are matched by the .dll in their command line, frontends (no .dll) by a
///     listening process whose working directory lies in the service's repository.
/// </summary>
public sealed partial class ExternalDetector(ConfigStore store)
{
    private static readonly TimeSpan CacheFor = TimeSpan.FromSeconds(2);
    private readonly Lock _lock = new();
    private (DateTime At, ExternalSnapshot Snapshot)? _cache;

    /// <param name="Image">The image (program file) name the OS reports with the process (Windows); null where unknown.</param>
    public sealed record PsRow(int Pid, int Ppid, TimeSpan Elapsed, string Command, string? Image = null);

    /// <summary>The known stack slots, to name the slot of an external process by its port offset (set by the supervisor).</summary>
    public Func<IReadOnlyList<SlotInfo>>? KnownSlots { get; set; }

    /// <summary>
    ///     The slot whose shifted ports an external process listens on: the offset that moves every configured port of its
    ///     service onto its ports. Null when its ports are unknown or fit no offset.
    /// </summary>
    internal static string? SlotHint(ServiceConfig service, IReadOnlyList<int> ports, IReadOnlyList<SlotInfo> slots)
    {
        if (ports.Count == 0 || service.Ports.Count == 0)
        {
            return null;
        }

        // Every listening port must be a configured port plus one common offset (Kestrel may listen on fewer ports).
        var offsets = ports.Select(p => service.Ports.Select(c => p - c).ToHashSet()).Aggregate((a, b) => a.Intersect(b).ToHashSet());
        var offset = offsets.Where(o => o >= 0).OrderBy(o => o).Cast<int?>().FirstOrDefault();
        if (offset == null)
        {
            return null;
        }

        // A known slot's offset names it; an unknown multiple of 100 (the default step) is shown as an offset; anything else is no slot.
        return slots.FirstOrDefault(s => s.PortOffset == offset)?.Name
               ?? (offset == 0 ? SlotInfo.DefaultName : offset % 100 == 0 ? $"offset +{offset}" : null);
    }

    public async Task<ExternalSnapshot> ScanAsync(IReadOnlySet<int> ownPids)
    {
        lock (_lock)
        {
            if (_cache is { } c && DateTime.UtcNow - c.At < CacheFor)
            {
                return c.Snapshot;
            }
        }

        var slots = KnownSlots?.Invoke() ?? [SlotInfo.Default];
        ExternalSnapshot snapshot;
        try
        {
            snapshot = await Task.Run(() => (ScanOverride ?? Scan)(store.Load(), ownPids, slots));
            snapshot = snapshot with { Services = await ProbeAsync(snapshot.Services) };
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            // AB#9556: a failure while reading the OS (a duplicate pid, an unreadable process) must not fail stack_start,
            // build_start or test_run: the external processes are unknown then, and the answer says so.
            snapshot = ExternalSnapshot.Empty with
            {
                Warning = $"Processes outside octo-devstack are unknown: the scan failed ({e.GetType().Name}: {SecretMask.MaskValue(e.Message.Split('\n')[0])})."
            };
        }

        lock (_lock)
        {
            _cache = (DateTime.UtcNow, snapshot);
        }

        return snapshot;
    }

    /// <summary>
    ///     What a scan reads from the OS: the processes, the listening ports by pid, and - asked only for the candidates and
    ///     the sessions - where processes run (cwd) and where their stdout goes.
    /// </summary>
    internal sealed record Observation(
        List<PsRow> Processes,
        Dictionary<int, List<int>> Listening,
        Func<IReadOnlyCollection<int>, Dictionary<int, (string? Cwd, string? Stdout)>> Files);

    /// <summary>Replaces the OS scan (tests: a scan that throws).</summary>
    internal Func<DevStackConfig, IReadOnlySet<int>, IReadOnlyList<SlotInfo>, ExternalSnapshot>? ScanOverride { get; set; }

    private static ExternalSnapshot Scan(DevStackConfig config, IReadOnlySet<int> ownPids, IReadOnlyList<SlotInfo> slots) =>
        Analyse(config, OperatingSystem.IsWindows() ? ObserveWindows() : ObserveUnix(), ownPids, slots);

    /// <summary>macOS/Linux: one ps and two lsof calls; Linux without lsof reads /proc instead (<see cref="LinuxProc"/>).</summary>
    private static Observation ObserveUnix() => LinuxProc.UseProc
        ? new Observation(ParsePs(Run("ps", "-A -o pid=,ppid=,etime=,command=")), LinuxProc.ListeningPortsByPid(), pids => LinuxProc.Files(pids))
        : new Observation(
            ParsePs(Run("ps", "-A -o pid=,ppid=,etime=,command=")),
            ParseLsofListen(Run("lsof", "-nP -iTCP -sTCP:LISTEN -Fpn")),
            pids => ParseLsofFiles(Run("lsof", $"-a -d cwd,1 -p {string.Join(',', pids)} -Fpfn")));

    /// <summary>
    ///     Windows: a Toolhelp snapshot for pids, parents and creation times, the command lines of the processes the scan
    ///     looks at (NUL characters read as blanks, <see cref="CommandLines"/>), GetExtendedTcpTable for the listeners. A working directory and the stdout target are not readable there; the location of a process is taken
    ///     from its command line or its loaded modules instead (<see cref="LocationFromCommandLine"/>). A parent created after
    ///     its child is a reused pid: the child gets no parent (an orphan). A session's working directory stays unknown.
    /// </summary>
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static Observation ObserveWindows()
    {
        var rows = WindowsProcesses.Snapshot();
        var byPid = rows.GroupBy(r => r.Pid).ToDictionary(g => g.Key, g => g.First());
        var listening = TcpListenerTable.ListeningPortsByPid();
        int ParentOf(WindowsProcessRow r) => ProcessTree.IsRealParent(r, byPid.GetValueOrDefault(r.ParentPid)) ? r.ParentPid : 0;

        // Command lines only where the scan looks: dotnet and node processes, listeners, and their ancestors (Start-Octo,
        // Claude Code sessions). Every other row carries its exe name.
        var wanted = new HashSet<int>();
        foreach (var r in rows.Where(r => listening.ContainsKey(r.Pid) || r.Name.Equals("dotnet.exe", StringComparison.OrdinalIgnoreCase) ||
                                          r.Name.Equals("node.exe", StringComparison.OrdinalIgnoreCase)))
        {
            for (var current = r; current != null && wanted.Add(current.Pid); current = byPid.GetValueOrDefault(ParentOf(current)))
            {
            }
        }

        var commandLines = CommandLines(wanted, WindowsProcesses.CommandLine);
        var now = DateTimeOffset.Now;
        var processes = rows.Select(r => new PsRow(
            r.Pid,
            ParentOf(r),
            r.CreatedAt is { } created && created <= now ? now - created : TimeSpan.Zero,
            commandLines.GetValueOrDefault(r.Pid) ?? r.Name,
            r.Name)).ToList(); // AB#9924: the image name names a process the scan leaves out, never parsed from its command line
        // Distinct: a pid asked for twice (a candidate that is also a session's ancestor, AB#9556) is observed once.
        return new Observation(processes, listening, pids => pids.Distinct()
            .Select(pid => (Pid: pid, Location: commandLines.GetValueOrDefault(pid) is { } commandLine && !IsClaude(commandLine)
                ? LocationFromCommandLine(commandLine, file => ModulePath(pid, file))
                : null))
            .ToDictionary(x => x.Pid, x => (x.Location, (string?)null)));
    }

    /// <summary>
    ///     Where a process runs from when its working directory is unknown (Windows): the folder of an absolute .dll
    ///     argument, the folder of the loaded module of a relative .dll argument, an absolute path among the arguments (a
    ///     node script inside the repo, or its folder; the value of --x=path counts), or the folder of the program itself.
    /// </summary>
    internal static string? LocationFromCommandLine(string commandLine, Func<string, string?> modulePath)
    {
        var args = WindowsCommandLine.Split(commandLine);
        var rest = args.Skip(1).ToList();
        var dll = rest.FirstOrDefault(a => a.EndsWith(".dll", StringComparison.OrdinalIgnoreCase));
        if (dll != null && Path.IsPathFullyQualified(dll))
        {
            return Path.GetDirectoryName(dll);
        }

        if (dll != null && modulePath(Path.GetFileName(dll)) is { } module)
        {
            return Path.GetDirectoryName(module);
        }

        var rooted = rest.Select(a => a.StartsWith('-') && a.Contains('=') ? a[(a.IndexOf('=') + 1)..] : a).FirstOrDefault(Path.IsPathFullyQualified);
        if (rooted != null)
        {
            // A folder, like a working directory: the argument itself when it is one, else the folder of the file it names.
            return Directory.Exists(rooted) ? rooted : Path.GetDirectoryName(rooted);
        }

        var program = args.FirstOrDefault();
        return program != null && Path.IsPathFullyQualified(program) ? Path.GetDirectoryName(program) : null;
    }

    /// <summary>
    ///     A Windows command line as the scan reads it (AB#9924): a program that splits its own command line in place leaves NUL
    ///     characters where the blanks were, so they are read as blanks - the arguments are separate again for the secret masks
    ///     and for <see cref="LocationFromCommandLine"/>.
    /// </summary>
    internal static string? NulsAsBlanks(string? commandLine) => commandLine?.Replace('\0', ' ');

    /// <summary>
    ///     The command lines of <paramref name="pids"/> as the Windows scan reads them: through <paramref name="read"/>
    ///     (<see cref="WindowsProcesses.CommandLine"/>), NUL characters as blanks (<see cref="NulsAsBlanks"/>); null where unreadable.
    /// </summary>
    internal static Dictionary<int, string?> CommandLines(IEnumerable<int> pids, Func<int, string?> read) =>
        pids.ToDictionary(pid => pid, pid => NulsAsBlanks(read(pid)));

    /// <summary>The path of a loaded module of a process (an IL assembly appears there when the loader mapped it), null if not readable.</summary>
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static string? ModulePath(int pid, string fileName)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            foreach (ProcessModule module in process.Modules)
            {
                using (module)
                {
                    if (string.Equals(module.ModuleName, fileName, StringComparison.OrdinalIgnoreCase))
                    {
                        return module.FileName;
                    }
                }
            }
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException)
        {
        }

        return null;
    }

    /// <summary>The scan itself, on what <paramref name="observation"/> read (testable with canned rows).</summary>
    internal static ExternalSnapshot Analyse(DevStackConfig config, Observation observation, IReadOnlySet<int> ownPids, IReadOnlyList<SlotInfo> slots)
    {
        var ps = observation.Processes;
        var byPid = ps.GroupBy(r => r.Pid).ToDictionary(g => g.Key, g => g.First()); // a pid listed twice (a snapshot race) counts once
        var listening = observation.Listening;
        var excluded = new HashSet<int>(ownPids);
        foreach (var pid in ownPids)
        {
            foreach (var row in ps.Where(r => IsDescendant(r.Pid, pid, byPid)))
            {
                excluded.Add(row.Pid);
            }
        }

        excluded.Add(Environment.ProcessId);
        var root = ServicePlanner.RootPath(config);

        // Candidates: processes running a configured .dll, and every listening process (frontends).
        var dllServices = config.Services
            .Select(s => (Name: s.Key, Service: s.Value, Dll: s.Value.Args.FirstOrDefault(a => a.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))))
            .Where(x => x.Dll != null).ToList();
        var candidates = new Dictionary<int, string?>();
        foreach (var row in ps.Where(r => !excluded.Contains(r.Pid)))
        {
            var match = dllServices.FirstOrDefault(d => ContainsToken(row.Command, d.Dll!));
            if (match.Name != null)
            {
                candidates[row.Pid] = match.Name;
            }
            else if (listening.ContainsKey(row.Pid))
            {
                candidates[row.Pid] = null;
            }
        }

        var sessionPids = new HashSet<int>();
        foreach (var pid in candidates.Keys)
        {
            foreach (var ancestor in Ancestors(pid, byPid))
            {
                if (IsClaude(ancestor.Command))
                {
                    sessionPids.Add(ancestor.Pid);
                    break;
                }
            }
        }

        var skipped = new List<ExternalSkipped>();
        var files = candidates.Count == 0
            ? new Dictionary<int, (string? Cwd, string? Stdout)>()
            : ObserveFiles(observation, candidates, sessionPids, byPid, skipped);

        var services = new List<ExternalService>();
        var groups = new Dictionary<string, (ExternalOrigin Origin, List<ExternalService> Members)>();
        foreach (var (pid, dllService) in candidates)
        {
            (ExternalService Service, ExternalOrigin Origin)? found;
            try
            {
                found = AnalyseCandidate(pid, dllService);
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                // AB#9924: one process that cannot be analysed is left out; the others are reported.
                skipped.Add(Skip(byPid[pid], e));
                continue;
            }

            if (found is not { } result)
            {
                continue; // a listening process that is no stack service (IDE, other tools)
            }

            var (service, origin) = result;
            services.Add(service);
            if (!groups.TryGetValue(service.Group, out var group))
            {
                groups[service.Group] = group = (origin, []);
            }

            group.Members.Add(service);
        }

        var groupList = groups.Select(g => new ExternalGroup(
            g.Key,
            g.Value.Origin,
            g.Value.Members.Select(s => s.Checkout).FirstOrDefault(c => c != null),
            g.Value.Members.Select(s => s.Configuration).FirstOrDefault(c => c != null),
            g.Value.Members.Select(s => s.Service).Distinct().ToList(),
            g.Value.Members.Min(s => s.StartedAt))).OrderByDescending(g => g.Services.Count).ToList();

        return new ExternalSnapshot(services.OrderBy(s => s.Service).ToList(), groupList)
        {
            Skipped = skipped.Count == 0 ? null : skipped.OrderBy(s => s.Pid).ToList()
        };

        (ExternalService Service, ExternalOrigin Origin)? AnalyseCandidate(int pid, string? dllService)
        {
            var row = byPid[pid];
            var cwd = files.GetValueOrDefault(pid).Cwd;
            string? name = dllService;
            string? repoPath = null;
            if (cwd != null)
            {
                // A process without a service dll is matched by the configured port it holds first (several services may
                // share a repo), then by the repo it runs in.
                var held = listening.GetValueOrDefault(pid) ?? [];
                var nonDll = config.Services.Where(s => !dllServices.Any(d => d.Name == s.Key)).ToList();
                var candidatesByPort = nonDll.Where(s => s.Value.Ports.Any(held.Contains)).Concat(nonDll).Distinct();
                repoPath = dllService != null
                    ? RepoFolderOrUnknown(cwd, config.Services[dllService].Repo, root)
                    : candidatesByPort
                        .Select(s => (s.Key, Repo: FindRepoFolder(cwd, s.Value.Repo, root)))
                        .Where(x => x.Repo != null)
                        .Select(x =>
                        {
                            name = x.Key;
                            return x.Repo;
                        })
                        .FirstOrDefault();
            }

            if (name == null || (dllService == null && repoPath == null))
            {
                return null;
            }

            var origin = DescribeOrigin(pid, byPid, files);
            var key = origin.Kind switch
            {
                "start-octo" => $"start-octo:{origin.LauncherPid}",
                "session" => $"session:{origin.Session!.Pid}",
                "orphan" => $"orphan:{pid}",
                _ => $"process:{origin.LauncherPid ?? pid}"
            };

            var (checkout, source) = repoPath == null ? (null, null) : CheckoutOf(repoPath);
            var configuration = cwd == null ? null : ConfigurationRegex().Match(cwd) is { Success: true } m ? m.Groups[1].Value : null;
            configuration ??= origin.Configuration;
            var serviceConfig = config.Services[name];
            var logFile = LogFileOf(files.GetValueOrDefault(pid).Stdout, origin, checkout, config, serviceConfig, name);

            var ports = listening.GetValueOrDefault(pid) ?? [];
            var service = new ExternalService(name, pid, ports, row.Command, cwd, checkout, repoPath, source,
                configuration, DateTimeOffset.Now - row.Elapsed, false, null, logFile, key)
            {
                SlotHint = SlotHint(serviceConfig, ports, slots)
            };
            return (service, origin);
        }
    }

    /// <summary>
    ///     The repository folder of a process that runs a service .dll, null when it cannot be determined (AB#9924): a failing
    ///     lookup (a worktree's .git or HEAD file being rewritten, an unreadable folder) makes its location unknown, it never
    ///     drops the service - it is reported without a repository path.
    /// </summary>
    private static string? RepoFolderOrUnknown(string cwd, string repo, string root)
    {
        try
        {
            return FindRepoFolder(cwd, repo, root);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            return null;
        }
    }

    /// <summary>
    ///     Where the candidates and the sessions run (<see cref="Observation.Files"/>). When reading them all at once fails,
    ///     each pid is read on its own (AB#9924): a listener without a service .dll whose read fails is left out and named in
    ///     <paramref name="skipped"/>; a service .dll whose read fails stays a candidate with an unknown location; a session
    ///     whose read fails keeps an unknown working directory. A failing read never fails the scan.
    /// </summary>
    private static Dictionary<int, (string? Cwd, string? Stdout)> ObserveFiles(Observation observation, Dictionary<int, string?> candidates,
        IReadOnlySet<int> sessionPids, IReadOnlyDictionary<int, PsRow> byPid, List<ExternalSkipped> skipped)
    {
        var pids = candidates.Keys.Concat(sessionPids).Distinct().ToList(); // a candidate may be a session's ancestor too (AB#9556)
        try
        {
            return observation.Files(pids);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            var files = new Dictionary<int, (string? Cwd, string? Stdout)>();
            foreach (var pid in pids)
            {
                try
                {
                    foreach (var (key, value) in observation.Files([pid]))
                    {
                        files[key] = value;
                    }
                }
                catch (Exception one) when (one is not OperationCanceledException)
                {
                    if (candidates.TryGetValue(pid, out var dllService) && dllService == null)
                    {
                        candidates.Remove(pid);
                        skipped.Add(Skip(byPid[pid], one));
                    }
                }
            }

            return files;
        }
    }

    /// <summary>
    ///     The note for a process left out: pid, the file name of its program and the exception type - nothing of its arguments.
    ///     The program is the image name the OS reported (Windows), else read from the command line (<see cref="ExecutableOf"/>).
    /// </summary>
    internal static ExternalSkipped Skip(PsRow row, Exception e) =>
        new(row.Pid, row.Image is { Length: > 0 } image ? FileNameOf(image) : ExecutableOf(row.Command), e.GetType().Name);

    /// <summary>
    ///     The sentence that names the processes a scan left out (a job plan's warning, a capture's note): pid, executable and
    ///     exception type of each, nothing else of the process.
    /// </summary>
    internal static string LeftOut(IEnumerable<ExternalSkipped> skipped) =>
        $"The scan of processes outside octo-devstack left out {string.Join(", ", skipped.Select(s => $"pid {s.Pid} ({s.Executable}, {s.ExceptionType})"))}.";

    /// <summary>
    ///     The program of a command line without the OS's image name: one leading quote off, up to the first whitespace, quote
    ///     or control character (a NUL can join the program and an argument), its file name. Never a part of an argument, also
    ///     for an unclosed quote or a quote closed without a blank; a program path with a blank gives its first word.
    /// </summary>
    internal static string ExecutableOf(string command)
    {
        var rest = command.StartsWith('"') ? command[1..] : command;
        var end = rest.AsSpan().IndexOfAny(ProgramEnd);
        return FileNameOf(end < 0 ? rest : rest[..end]);
    }

    /// <summary>Where the program of a command line ends: a blank, a quote or any control character (tab, CR, LF and NUL among them).</summary>
    private static readonly System.Buffers.SearchValues<char> ProgramEnd =
        System.Buffers.SearchValues.Create(" \"" + new string(Enumerable.Range(0, 0x20).Select(c => (char)c).ToArray()));

    /// <summary>The part after the last / or \, cut at the first control character (a NUL can join a program and an argument).</summary>
    private static string FileNameOf(string path)
    {
        var name = path[(path.LastIndexOfAny(['\\', '/']) + 1)..];
        var control = name.AsSpan().IndexOfAnyInRange('\0', '\u001f');
        return control < 0 ? name : name[..control];
    }

    private static async Task<IReadOnlyList<ExternalService>> ProbeAsync(IReadOnlyList<ExternalService> services) =>
        await Task.WhenAll(services.Select(async s =>
        {
            var (healthy, detail) = await Probes.CheckAsync(null, s.Ports, ProfileMatcher.ArgsOf(s.Command));
            return s with { Healthy = healthy, HealthDetail = detail };
        }));

    // ---------- origin ----------

    internal static ExternalOrigin DescribeOrigin(int pid, IReadOnlyDictionary<int, PsRow> byPid, IReadOnlyDictionary<int, (string? Cwd, string? Stdout)> files)
    {
        var chain = Ancestors(pid, byPid).ToList();
        var startOcto = chain.FirstOrDefault(r => r.Command.Contains("Start-Octo", StringComparison.Ordinal));
        var claude = chain.FirstOrDefault(r => IsClaude(r.Command));
        var session = claude == null ? null : ParseClaude(claude, files.GetValueOrDefault(claude.Pid).Cwd);
        var details = new List<string>();
        if (session?.Agent != null)
        {
            details.Add($"agent {session.Agent}");
        }

        if (session?.SessionId != null)
        {
            details.Add($"session {session.SessionId[..Math.Min(8, session.SessionId.Length)]}");
        }

        var by = session == null
            ? "from a terminal"
            : "by a Claude Code session" + (details.Count > 0 ? $" ({string.Join(", ", details)})" : "");

        if (startOcto != null)
        {
            var branch = Arg(startOcto.Command, "-branch");
            var configuration = Arg(startOcto.Command, "-configuration");
            var nonInteractive = Regex.IsMatch(startOcto.Command, @"-nonInteractive\s+\$?true", RegexOptions.IgnoreCase);
            var stop = nonInteractive
                ? $"Stop-Octo{(branch != null ? $" -branch {branch}" : "")}"
                : "press a key in the terminal that runs Start-Octo";
            return new ExternalOrigin("start-octo", $"Start-Octo, started {by}", startOcto.Pid, Shorten(StartOctoCall(startOcto.Command)), branch,
                configuration, nonInteractive, session, stop);
        }

        // Unix re-parents an orphan to pid 1; on Windows its parent is gone (0).
        if (byPid.TryGetValue(pid, out var self) && self.Ppid <= 1)
        {
            return new ExternalOrigin("orphan", "Its parent process is gone; it runs until it is stopped", null, null, null, null, false, null,
                ProcessTree.KillHint(pid));
        }

        // The topmost ancestor below the session's shell wrapper (zsh -c ...) or below the terminal shell.
        var below = chain.TakeWhile(r => !IsClaude(r.Command) && !IsShell(r.Command)).ToList();
        var launcher = below.Count > 1 ? below[^1] : below.FirstOrDefault();
        if (session != null)
        {
            return new ExternalOrigin("session", $"Started {by}", launcher?.Pid, launcher == null ? null : Shorten(launcher.Command), null, null, false,
                session, launcher == null ? null : ProcessTree.KillHint(launcher.Pid));
        }

        return new ExternalOrigin("process", "Started from a terminal or another tool", launcher?.Pid, launcher == null ? null : Shorten(launcher.Command),
            null, null, false, null, launcher == null ? null : ProcessTree.KillHint(launcher.Pid));
    }

    internal static ClaudeSessionInfo ParseClaude(PsRow row, string? cwd) =>
        new(row.Pid, Arg(row.Command, "--resume") ?? Arg(row.Command, "--session-id") ?? Arg(row.Command, "-r"), Arg(row.Command, "--agent"), cwd);

    private static string StartOctoCall(string command)
    {
        var index = command.IndexOf("Start-Octo", StringComparison.Ordinal);
        return index < 0 ? command : command[index..];
    }

    /// <summary>Value after a command-line switch, quotes removed.</summary>
    internal static string? Arg(string command, string name)
    {
        var match = Regex.Match(command, $@"(?:^|\s){Regex.Escape(name)}(?:\s+|=)(""[^""]*""|'[^']*'|\S+)");
        // A value in an escaped Windows command line arrives as \"value\".
        return match.Success ? match.Groups[1].Value.Trim('"', '\'', '\\') : null;
    }

    /// <summary>A Claude Code process: claude (claude.exe on Windows, also quoted), or node running the npm package's cli.js.</summary>
    internal static bool IsClaude(string command)
    {
        var exe = command.Split(' ', 2)[0];
        return Path.GetFileName(exe) == "claude" || WindowsCommandLine.ProgramName(command) == "claude" ||
               (WindowsCommandLine.ProgramName(command) == "node" && command.Contains("claude-code", StringComparison.OrdinalIgnoreCase) &&
                command.Contains("cli.js", StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>A shell the launcher search stops at (also Git Bash, cmd.exe and Windows PowerShell on Windows).</summary>
    internal static bool IsShell(string command)
    {
        var exe = Path.GetFileName(command.Split(' ', 2)[0]).TrimStart('-');
        return exe is "zsh" or "bash" or "sh" or "fish" or "login" ||
               WindowsCommandLine.ProgramName(command).TrimStart('-') is "bash" or "sh" or "cmd" or "powershell";
    }

    // ---------- paths ----------

    /// <summary>The folder of <paramref name="repo"/> that contains <paramref name="cwd"/>: the repo itself or a worktree of it.</summary>
    internal static string? FindRepoFolder(string cwd, string repo, string root)
    {
        DirectoryInfo? dir;
        try
        {
            dir = new DirectoryInfo(cwd);
        }
        catch (ArgumentException)
        {
            // AB#9924: no valid path (a NUL character from a command line, an empty string) lies in no repository.
            return null;
        }

        while (dir != null && dir.FullName.Length >= root.Length)
        {
            if (dir.Name == repo && Directory.Exists(Path.Combine(dir.FullName, ".git")))
            {
                return dir.FullName;
            }

            var gitFile = Path.Combine(dir.FullName, ".git");
            if (File.Exists(gitFile))
            {
                return CheckoutDiscovery.ReadWorktree(gitFile).Repo == repo ? dir.FullName : null;
            }

            if (Directory.Exists(gitFile))
            {
                return dir.Name == repo ? dir.FullName : null;
            }

            dir = dir.Parent;
        }

        return null;
    }

    /// <summary>Lane and (for a worktree) the worktree folder of a repository folder.</summary>
    private static (string? Checkout, string? Source) CheckoutOf(string repoPath)
    {
        var isWorktree = File.Exists(Path.Combine(repoPath, ".git"));
        var parent = Path.GetDirectoryName(repoPath);
        if (isWorktree && parent != null && Path.GetFileName(parent) == "worktrees" && Path.GetFileName(Path.GetDirectoryName(parent)) == ".claude")
        {
            // <lane>/<repo>/.claude/worktrees/<name>
            parent = Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(parent)));
        }

        return (parent, isWorktree ? repoPath : null);
    }

    private static string? LogFileOf(string? stdout, ExternalOrigin origin, string? checkout, DevStackConfig config, ServiceConfig service, string name)
    {
        if (stdout != null && File.Exists(stdout))
        {
            return stdout;
        }

        if (origin.Kind == "start-octo" && checkout != null)
        {
            var file = Path.Combine(checkout, config.LogDirectory, (service.LogName ?? name) + ".log");
            return File.Exists(file) ? file : null;
        }

        return null;
    }

    [GeneratedRegex(@"[/\\]bin[/\\](Debug|Release|DebugL)[/\\]")]
    private static partial Regex ConfigurationRegex();

    // ---------- parsing ----------

    internal static List<PsRow> ParsePs(string output)
    {
        var rows = new List<PsRow>();
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = line.Trim().Split(' ', 4, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 4 && int.TryParse(parts[0], out var pid) && int.TryParse(parts[1], out var ppid))
            {
                rows.Add(new PsRow(pid, ppid, ParseElapsed(parts[2]), parts[3].Trim()));
            }
        }

        return rows;
    }

    /// <summary>ps etime: [[dd-]hh:]mm:ss.</summary>
    internal static TimeSpan ParseElapsed(string etime)
    {
        var days = 0;
        var dash = etime.IndexOf('-');
        if (dash > 0)
        {
            int.TryParse(etime[..dash], out days);
            etime = etime[(dash + 1)..];
        }

        var parts = etime.Split(':').Select(p => int.TryParse(p, out var v) ? v : 0).Reverse().ToArray();
        return new TimeSpan(days, parts.Length > 2 ? parts[2] : 0, parts.Length > 1 ? parts[1] : 0, parts.Length > 0 ? parts[0] : 0);
    }

    /// <summary>lsof -Fpn of listening sockets: p&lt;pid&gt; then n*:5003 / n127.0.0.1:5003 / n[::1]:5003.</summary>
    internal static Dictionary<int, List<int>> ParseLsofListen(string output)
    {
        var result = new Dictionary<int, List<int>>();
        var pid = 0;
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            if (line[0] == 'p')
            {
                int.TryParse(line[1..], out pid);
            }
            else if (line[0] == 'n' && pid > 0)
            {
                var colon = line.LastIndexOf(':');
                if (colon > 0 && int.TryParse(line[(colon + 1)..], out var port))
                {
                    if (!result.TryGetValue(pid, out var ports))
                    {
                        result[pid] = ports = [];
                    }

                    if (!ports.Contains(port))
                    {
                        ports.Add(port);
                    }
                }
            }
        }

        foreach (var ports in result.Values)
        {
            ports.Sort();
        }

        return result;
    }

    /// <summary>lsof -Fpfn for the cwd and fd 1 of processes.</summary>
    internal static Dictionary<int, (string? Cwd, string? Stdout)> ParseLsofFiles(string output)
    {
        var result = new Dictionary<int, (string? Cwd, string? Stdout)>();
        var pid = 0;
        string? fd = null;
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            switch (line[0])
            {
                case 'p':
                    int.TryParse(line[1..], out pid);
                    fd = null;
                    break;
                case 'f':
                    fd = line[1..];
                    break;
                case 'n' when pid > 0:
                    var current = result.GetValueOrDefault(pid);
                    if (fd == "cwd")
                    {
                        result[pid] = current with { Cwd = line[1..] };
                    }
                    else if (fd == "1" && line.Length > 1 && line[1] == '/') // lsof prints a bare "n" for an unnamed fd
                    {
                        result[pid] = current with { Stdout = line[1..] };
                    }

                    break;
            }
        }

        return result;
    }

    private static IEnumerable<PsRow> Ancestors(int pid, IReadOnlyDictionary<int, PsRow> byPid)
    {
        var seen = new HashSet<int>();
        var current = byPid.GetValueOrDefault(pid);
        while (current != null && current.Ppid > 1 && seen.Add(current.Pid) && byPid.TryGetValue(current.Ppid, out var parent))
        {
            yield return parent;
            current = parent;
        }
    }

    private static bool IsDescendant(int pid, int ancestor, IReadOnlyDictionary<int, PsRow> byPid) =>
        pid == ancestor || Ancestors(pid, byPid).Any(a => a.Pid == ancestor);

    /// <summary>The token as a whole word, also after a path (/ or \) and in quotes.</summary>
    internal static bool ContainsToken(string command, string token) =>
        Regex.IsMatch(command, $@"(^|[\s/\\""]){Regex.Escape(token)}(""|\s|$)");

    private static string Shorten(string text) => text.Length <= 200 ? text : text[..197] + "...";

    private static string Run(string file, string arguments)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(file, arguments)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            });
            if (process == null)
            {
                return "";
            }

            var output = process.StandardOutput.ReadToEndAsync();
            process.StandardError.ReadToEndAsync();
            process.WaitForExit(10000);
            return output.Result;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return "";
        }
    }
}
