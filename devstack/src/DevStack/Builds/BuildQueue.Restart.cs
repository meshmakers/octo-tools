using System.Diagnostics;
using System.Text.RegularExpressions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>What a detached (or attached) build step left when it ended. ExitCode is null when the process left no exit marker.</summary>
internal sealed record StepResult(int? ExitCode, string Output, bool TimedOut, bool Canceled, bool IdleTimedOut)
{
    public static StepResult From(PwshResult result) => new(result.ExitCode, result.Output, result.TimedOut, result.Canceled, result.IdleTimedOut);
}

/// <summary>A queued or running build as the restart check sees it.</summary>
public sealed record ActiveBuild(string Id, string Owner, string State, string Kind, string Target,
    [property: System.Text.Json.Serialization.JsonPropertyName("lane")] string? Environment, int? Pid, string? Phase,
    bool SurvivesRestart);

// Job files, what a daemon start restores from them, and watching a detached build step.
public sealed partial class BuildQueue
{
    /// <summary>Characters kept of the build log of a repo that did not fail (a failed repo's log is kept completely).</summary>
    private const int KeptLogChars = 200_000;

    // ---------- job files ----------

    /// <summary>From now on every change of the job goes into its job file.</summary>
    private void Track(BuildJob job)
    {
        job.Changed = () => Save(job);
        Save(job);
    }

    /// <summary>
    ///     Lets go of every job without touching it, as if the daemon process had ended: after one last write of the job
    ///     files nothing is watched, started or written any more, the build processes go on. For tests that restart the
    ///     queue on the same state folder.
    /// </summary>
    internal void Abandon()
    {
        // The files hold what the jobs are right now (a change is written after it happened; a test must not race that write).
        foreach (var job in _jobs.Values)
        {
            Save(job);
        }

        _abandoned.Cancel();
    }

    private void Save(BuildJob job)
    {
        try
        {
            lock (job.SaveLock)
            {
                if (!job.Deleted && !_abandoned.IsCancellationRequested)
                {
                    _jobStore.Save(job.ToRecord());
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _logger.LogWarning(e, "Could not write the job file of build {Id}; a daemon restart would not know its last state", job.Id);
        }
    }

    // ---------- restore ----------

    /// <summary>
    ///     Reads the jobs of earlier daemon runs: finished ones are history, queued ones wait again in their order, running
    ///     ones are returned to be run on (their step's process is re-attached when it still is the recorded one, else its
    ///     result is read from what it left). Builds of a daemon version without job files come from the state file.
    /// </summary>
    private List<BuildJob> RestoreJobs()
    {
        foreach (var record in _jobStore.LoadAll((file, e) => _logger.LogWarning(e, "Unreadable job file {File} was set aside", file)))
        {
            try
            {
                var job = BuildJob.Restore(record, _paths.BuildLogDirectory, _jobStore.PathOf(record.Id));
                _jobs[job.Id] = job;
                _sequence = Math.Max(_sequence, job.Sequence);
            }
            catch (Exception e) when (e is InvalidOperationException or ArgumentException)
            {
                _logger.LogWarning(e, "Job {Id} of an earlier daemon run could not be restored", record.Id);
            }
        }

        foreach (var build in _state?.Load().RunningBuilds() ?? [])
        {
            if (_jobs.ContainsKey(build.Id))
            {
                continue;
            }

            var sequence = LegacySequence().Match(build.Id) is { Success: true } m && long.TryParse(m.Groups[1].Value, out var n) ? n : _sequence + 1;
            _jobs[build.Id] = BuildJob.Adopt(build, sequence, _paths.BuildLogDirectory, _jobStore.PathOf(build.Id));
            _sequence = Math.Max(_sequence, sequence);
        }

        var resume = new List<BuildJob>();
        foreach (var job in _jobs.Values.OrderBy(j => j.Sequence))
        {
            Track(job);
            switch (job.State)
            {
                case "queued":
                    _waiting.Add(job);
                    _logger.LogInformation("Build {Id} of {Owner} ({Kind} {Target}) waits again after the daemon restart", job.Id, job.Request.Owner, job.Kind,
                        job.Planned.Target);
                    break;
                case "running":
                    Reattach(job);
                    job.Pins = PinLeases(job);
                    // The leases its preflight took for the services it stopped (late pins) are kept again until they are back.
                    var pinned = job.LeaseRequired ? job.LeaseSlots.DefaultIfEmpty(Configuration.SlotInfo.DefaultName).ToHashSet() : [];
                    foreach (var slot in job.Stopped.Names.Select(n => StackSupervisor.Unqualify(n).Slot).Distinct().Where(s => !pinned.Contains(s)))
                    {
                        job.LatePins.Add(LeaseOf(slot).Pin(job.Request.LeaseOwnerFor(slot)));
                    }

                    _running.Add(job);
                    resume.Add(job);
                    break;
            }
        }

        if (resume.Count > 0 || _state?.Load().RunningBuilds().Count > 0)
        {
            PersistRunning();
        }

        return resume;
    }

    /// <summary>Looks at the process of the step a running job was in and says in a note what the restart found.</summary>
    private void Reattach(BuildJob job)
    {
        var now = DateTimeOffset.Now;
        var step = job.Steps.FirstOrDefault(s => s is { StartedAt: not null, Completed: false, Pid: not null });
        if (step == null)
        {
            job.MarkReattached($"the daemon restarted at {now:HH:mm:ss} while the build was {job.Phase ?? "between two steps"}; it goes on from there");
            _logger.LogInformation("Build {Id} of {Owner} goes on after the daemon restart (no build process ran)", job.Id, job.Request.Owner);
            return;
        }

        var pid = step.Pid!.Value;
        var same = job.Legacy ? IsLegacyBuild(pid, step) : IsOwnBuild(pid, step);
        if (same)
        {
            if (step.ProcessStart == null)
            {
                step.SetProcess(pid, ProcessTree.StartTime(pid));
            }

            job.Pid = pid;
            job.MarkReattached($"re-attached after the daemon restart at {now:HH:mm:ss}: the build process (pid {pid}) still runs" +
                               (job.Legacy ? "; it was started by a daemon version without exit markers, so its result comes from its build events" : ""));
            _logger.LogWarning("Build {Id} of {Owner} ({Kind} {Target}, pid {Pid}) still runs from before the daemon restart: re-attached", job.Id,
                job.Request.Owner, job.Kind, job.Planned.Target, pid);
        }
        else
        {
            step.ProcessGone = true;
            job.MarkReattached($"the daemon restarted at {now:HH:mm:ss}; the build process (pid {pid}) had ended meanwhile, its result is read from what it left");
            _logger.LogWarning("Build {Id} of {Owner} ({Kind} {Target}) ended while the daemon was down: its result is recovered", job.Id, job.Request.Owner,
                job.Kind, job.Planned.Target);
        }
    }

    /// <summary>
    ///     The recorded pid still is the step's wrapper: alive, started when recorded, and its command line names the step's
    ///     exit marker. A command line that cannot be read (ps failed, e.g. under load) is asked for again; when it stays
    ///     unreadable the recorded start time decides - a running build must never be taken for gone.
    /// </summary>
    private static bool IsOwnBuild(int pid, StepRun step)
    {
        if (!ProcessTree.IsAlive(pid, step.ProcessStart))
        {
            return false;
        }

        for (var attempt = 0; attempt < 3; attempt++)
        {
            var commandLine = ProcessTree.CommandLine(pid);
            if (commandLine.Length > 0)
            {
                return commandLine.Contains(Path.GetFileName(step.ExitFile), StringComparison.Ordinal);
            }

            Thread.Sleep(200);
        }

        return step.ProcessStart != null && ProcessTree.IsAlive(pid, step.ProcessStart);
    }

    /// <summary>
    ///     The pid of a state file without job files still is that build's pwsh: alive, a pwsh, and - when the build wrote an
    ///     events file - its command line names that file (it carries the job id).
    /// </summary>
    private bool IsLegacyBuild(int pid, StepRun step)
    {
        if (_options.IsBuildProcess != null)
        {
            return _options.IsBuildProcess(pid);
        }

        if (!ProcessTree.IsAlive(pid))
        {
            return false;
        }

        var commandLine = ProcessTree.CommandLine(pid);
        return commandLine.Contains("pwsh", StringComparison.OrdinalIgnoreCase) &&
               (!step.Spec.UsesEvents || commandLine.Contains(Path.GetFileName(step.EventsFile), StringComparison.Ordinal));
    }

    [GeneratedRegex(@"^b(\d+)-")]
    private static partial Regex LegacySequence();

    // ---------- watching a detached step ----------

    /// <summary>
    ///     Waits for a detached step: until its exit marker appears or its process is gone, the job is canceled, or the
    ///     step's overall or idle timeout passes (then the process tree is terminated). Works the same for a step this
    ///     daemon run started (<paramref name="process"/>) and for one taken over after a restart (pid and start time).
    /// </summary>
    private async Task<StepResult> WatchAsync(BuildJob job, StepRun step, Process? process, CancellationToken token)
    {
        var pid = step.Pid!.Value;
        var started = step.StartedAt ?? DateTimeOffset.Now;
        // A step taken over from a daemon without exit markers no longer writes the job log (its pipe went with that
        // daemon), so only its events count as activity - and without events nothing does.
        var watchIdle = !job.Legacy || step.Spec.UsesEvents;
        var attachedAt = DateTimeOffset.Now;
        var testLogs = step.Spec.Kind == BuildKind.Test ? new TestLogActivity(() => TestResultsFolder(job, step), started, _options.TestLogScanInterval) : null;

        bool Alive() => !step.ProcessGone && (process != null ? !process.HasExited : ProcessTree.IsAlive(pid, step.ProcessStart));

        StepResult Ended(bool timedOut = false, bool canceled = false, bool idle = false) =>
            new(canceled || timedOut || idle ? -1 : BuildStepFiles.ReadExit(step.ExitFile), BuildStepFiles.ReadFrom(job.LogFile, step.LogOffset), timedOut,
                canceled, idle);

        async Task TerminateAsync()
        {
            // Only the process this daemon (or the one before it) started: the pid is checked again right before the signal.
            if (Alive())
            {
                await ProcessTree.TerminateAsync(pid, TimeSpan.FromSeconds(10), CancellationToken.None);
            }
        }

        while (true)
        {
            _abandoned.Token.ThrowIfCancellationRequested();
            if (BuildStepFiles.ReadExit(step.ExitFile) != null)
            {
                return Ended();
            }

            if (!Alive())
            {
                // The wrapper writes the marker right before it exits: look once more, then the step ended without one.
                await Task.Delay(TimeSpan.FromMilliseconds(100), CancellationToken.None);
                return Ended();
            }

            if (token.IsCancellationRequested)
            {
                await TerminateAsync();
                return Ended(canceled: true);
            }

            var now = DateTimeOffset.Now;
            if (now - started > step.Spec.Timeout)
            {
                await TerminateAsync();
                return Ended(timedOut: true);
            }

            // A test run that waits for the machine-wide test lock is silent on purpose; the cmdlet has its own lock timeout.
            if (watchIdle && !(step.Spec.Kind == BuildKind.Test && step.Read(false).LockWait != null))
            {
                DateTimeOffset Output() => new[] { started, attachedAt, BuildStepFiles.LastWrite(job.LogFile) ?? started, BuildStepFiles.LastWrite(step.EventsFile) ?? started }.Max();
                var last = Output();
                if (now - last > _options.IdleTimeout && testLogs?.Last() is { } written && written > last)
                {
                    // dotnet test and ng write only into the per-project test logs (AB#9417).
                    last = written;
                }

                // The throttled scan can be up to TestLogScanInterval old: before that value terminates the run, scan again.
                // Output and events written while the scan ran count as well.
                if (now - last > _options.IdleTimeout && testLogs != null)
                {
                    var fresh = testLogs.Last(force: true);
                    last = new[] { last, fresh ?? last, Output() }.Max();
                }

                if (now - last > _options.IdleTimeout)
                {
                    await TerminateAsync();
                    return Ended(idle: true);
                }
            }

            try
            {
                await Task.Delay(_options.PollInterval, token);
            }
            catch (OperationCanceledException)
            {
                // Handled at the top of the loop.
            }
        }
    }

    // ---------- output ----------

    /// <summary>
    ///     The output of a build for the status page: the repos (those with errors first) and the last
    ///     <paramref name="lines"/> lines of one log - a repo's (kept in the state folder when its build ended, else its
    ///     live Invoke-Build.log) or the job's own.
    /// </summary>
    public BuildOutput Output(string id, string? repo = null, int lines = 400)
    {
        if (!_jobs.TryGetValue(id, out var job))
        {
            throw new InvalidOperationException(UnknownJob(id));
        }

        var snapshot = job.Snapshot();
        var rows = Rows(job);
        var repos = rows.Select((r, index) =>
            {
                var counts = snapshot.Counts.GetValueOrDefault(r.Run.Repo);
                var errors = (snapshot.Errors.GetValueOrDefault(r.Run.Repo) ?? []).Take(BuildLogParser.MaxStoredPerRepo)
                    .Select(e => e with { Message = SecretMask.MaskValue(e.Message) }).ToList();
                var state = ShownState(r.Run, snapshot);
                var output = new BuildRepoOutput(r.Run.Repo, state, state == "building" ? r.Run.Phase : null, Round(r.Run.Seconds), Round(r.Run.BuildSeconds),
                    Round(r.Run.TestSeconds), Round(r.Run.PackageSeconds), counts?.Errors ?? errors.Count, counts?.Warnings ?? 0, errors,
                    RepoLog(job, snapshot, r.Step, r.Run) != null);
                return (Output: output, Index: index);
            })
            // Errors first: failed repos, then the one that builds, then the rest in build order.
            .OrderBy(x => x.Output.State == "failed" || x.Output.ErrorCount > 0 ? 0 : x.Output.State == "building" ? 1 : 2).ThenBy(x => x.Index)
            .Select(x => x.Output).ToList();

        return new BuildOutput(job.Id, snapshot.State, repos, LogOf(job, snapshot, rows, repo, lines));
    }

    /// <summary>
    ///     The last <paramref name="lines"/> lines of one log of a job: of <paramref name="repo"/> when given; else, while
    ///     the job runs, of the repo (or test project) that builds right now - the cmdlets print nothing into the job log
    ///     while they work (-Json), dotnet writes into the repo's Invoke-Build.log or the test project's log; else the job log.
    /// </summary>
    private static BuildLogText LogOf(BuildJob job, JobSnapshot snapshot, List<(StepRun Step, RepoRun Run)> rows, string? repo, int lines)
    {
        lines = Math.Clamp(lines, 1, 5000);
        (StepRun Step, RepoRun Run)? row = repo == null
            ? null
            : rows.Where(r => string.Equals(r.Run.Repo, repo, StringComparison.OrdinalIgnoreCase)).Select(r => ((StepRun, RepoRun)?)r).FirstOrDefault();
        if (repo == null && snapshot.FinishedAt == null)
        {
            // Nothing asked for: what happens now. The repo that started last is the one a reader watches.
            row = rows.Where(r => r.Run.State == "building" && RepoLog(job, snapshot, r.Step, r.Run) != null)
                .OrderByDescending(r => r.Run.StartedAt).Select(r => ((StepRun, RepoRun)?)r).FirstOrDefault();
        }

        string? path = job.LogFile;
        var source = "job";
        string? selected = null;
        if (row is { } found)
        {
            selected = found.Run.Repo;
            var log = RepoLog(job, snapshot, found.Step, found.Run);
            path = log?.Path;
            source = log?.Source ?? "none";
        }

        var text = path != null && File.Exists(path) ? LogReader.TailLines(path, lines + 1, null) : [];
        var truncated = text.Count > lines;
        return new BuildLogText(selected, text.Count == 0 && source != "job" ? "none" : source, path, text.Skip(truncated ? 1 : 0).Select(SecretMask.MaskValue).ToList(),
            truncated);
    }

    /// <summary>A repo's log: the copy kept when its build ended, else its Invoke-Build.log while this build writes it.</summary>
    private static (string Path, string Source)? RepoLog(BuildJob job, JobSnapshot snapshot, StepRun step, RepoRun run)
    {
        if (snapshot.PerRepoLogs.TryGetValue(run.Repo, out var kept) && File.Exists(kept))
        {
            return (kept, kept.StartsWith(Path.GetDirectoryName(job.LogFile)!, StringComparison.OrdinalIgnoreCase) ? "kept" : "live");
        }

        if (snapshot.FinishedAt != null || step.StartedAt == null || run.State == "pending")
        {
            return null;
        }

        var plan = step.Spec.Repos.FirstOrDefault(p => string.Equals(p.Name, run.Repo, StringComparison.OrdinalIgnoreCase));
        var live = run.LogFile ?? (plan == null ? null : Path.Combine(plan.Path, "Invoke-Build.log"));
        if (live == null && step.Spec.Kind == BuildKind.Test && run.State == "building")
        {
            live = LiveTestLog(job, step, run);
        }

        return live != null && File.Exists(live) && File.GetLastWriteTime(live) >= step.StartedAt.Value.LocalDateTime.AddSeconds(-2) ? (live, "live") : null;
    }

    /// <summary>
    ///     The log a running test project writes: Invoke-OctoTestRun names it only when the project is done, but it lies in
    ///     &lt;lane&gt;/logFiles/test-results/&lt;repo&gt;/&lt;project&gt;/&lt;run&gt;/ - the newest run folder since the step started.
    /// </summary>
    private static string? LiveTestLog(BuildJob job, StepRun step, RepoRun run)
    {
        var repo = step.Read(false).TestRepo;
        if (job.Planned.Lane == null || repo == null || step.StartedAt == null)
        {
            return null;
        }

        try
        {
            var project = Path.Combine(job.Planned.Lane, "logFiles", "test-results", repo, run.Repo);
            if (!Directory.Exists(project))
            {
                return null;
            }

            return Directory.EnumerateDirectories(project)
                .SelectMany(d => Directory.EnumerateFiles(d, "*-test.log"))
                .Where(f => File.GetLastWriteTime(f) >= step.StartedAt.Value.LocalDateTime.AddSeconds(-2))
                .OrderByDescending(File.GetLastWriteTime).FirstOrDefault();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>
    ///     The folder a test run's per-project logs go to: &lt;lane&gt;/logFiles/test-results/&lt;repo&gt; (Invoke-OctoTestRun writes
    ///     the dotnet test and ng output only there, not to the job log). Null for other steps or before the repo is known.
    /// </summary>
    private static string? TestResultsFolder(BuildJob job, StepRun step)
    {
        if (step.Spec.Kind != BuildKind.Test || job.Planned.Lane == null)
        {
            return null;
        }

        var repo = step.Read(false).TestRepo ?? job.Request.Repo;
        return repo == null ? null : Path.Combine(job.Planned.Lane, "logFiles", "test-results", repo);
    }

    /// <summary>
    ///     The idle watchdog's look at a test run's own logs (AB#9417): the newest write of a file in a run folder of
    ///     <paramref name="folder"/> (&lt;project&gt;/&lt;run&gt;/*) since <paramref name="since"/>. Run folders older than the step
    ///     are skipped without opening them. Null when nothing was written since then.
    /// </summary>
    internal static DateTimeOffset? LastTestLogWrite(string? folder, DateTimeOffset since)
    {
        if (folder == null || !Directory.Exists(folder))
        {
            return null;
        }

        try
        {
            var floor = since.LocalDateTime.AddSeconds(-2);
            DateTime? newest = null;
            foreach (var run in Directory.EnumerateDirectories(folder).SelectMany(Directory.EnumerateDirectories))
            {
                if (Directory.GetLastWriteTime(run) < floor && Directory.GetCreationTime(run) < floor)
                {
                    continue;
                }

                foreach (var file in Directory.EnumerateFiles(run, "*", SearchOption.AllDirectories))
                {
                    var written = File.GetLastWriteTime(file);
                    if (written >= floor && (newest == null || written > newest))
                    {
                        newest = written;
                    }
                }
            }

            return newest == null ? null : new DateTimeOffset(newest.Value);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>
    ///     <see cref="LastTestLogWrite"/> of a step, looked at again at most every <paramref name="interval"/>
    ///     (<see cref="BuildQueueOptions.TestLogScanInterval"/>; the watchdog polls every second, a test run may leave many files).
    /// </summary>
    internal sealed class TestLogActivity(Func<string?> folder, DateTimeOffset since, TimeSpan interval)
    {
        private readonly Lock _sync = new();
        private DateTimeOffset _scannedAt = DateTimeOffset.MinValue;
        private DateTimeOffset? _last;

        /// <summary>The newest test-log write; <paramref name="force"/> scans now, ignoring the interval (the idle decision).</summary>
        public DateTimeOffset? Last(bool force = false)
        {
            lock (_sync)
            {
                var now = DateTimeOffset.Now;
                if (force || now - _scannedAt >= interval)
                {
                    _scannedAt = now;
                    _last = LastTestLogWrite(folder(), since) ?? _last;
                }

                return _last;
            }
        }
    }

    /// <summary>What the idle watchdog watched, for the outcome of a step it terminated.</summary>
    private string IdleSummary(BuildJob job, StepRun step)
    {
        var minutes = _options.IdleTimeout.TotalMinutes.ToString("0", System.Globalization.CultureInfo.InvariantCulture);
        if (step.Spec.Kind != BuildKind.Test)
        {
            return $"no output and no build event for {minutes} min; the build was terminated";
        }

        var folder = TestResultsFolder(job, step) ?? "<lane>/logFiles/test-results/<repo>";
        return $"no output, no test event and no write to the test logs under {folder} for {minutes} min; the test run was terminated";
    }

    // ---------- test lock ----------

    /// <summary>The machine-wide docker test lock as Get-OctoTestLock -Json reports it (its data object).</summary>
    public async Task<System.Text.Json.Nodes.JsonNode> TestLockAsync(CancellationToken cancellationToken = default)
    {
        var config = _store.Load();
        var octoTools = Configuration.ServicePlanner.OctoToolsPath(config);
        var caps = await _capabilities.GetAsync(octoTools, cancellationToken);
        if (!caps.Tests.Lock)
        {
            throw new InvalidOperationException(TestCapabilities.Unavailable(caps, octoTools).Replace("Invoke-OctoTestRun", "Get-OctoTestLock"));
        }

        var result = await _pwsh.RunAsync(octoTools, BuildPlanner.RootPrelude(Configuration.ServicePlanner.RootPath(config)) + "Get-OctoTestLock -Json",
            new PwshRunOptions { Timeout = TimeSpan.FromMinutes(1) }, cancellationToken);
        var data = PwshRunner.ExtractOctoJson(result.Output, "Get-OctoTestLock")?["data"]?.DeepClone()
                   ?? throw new InvalidOperationException($"Get-OctoTestLock -Json printed no result (exit code {result.ExitCode}): {PwshErrors.Summary(result.Output)}");
        return InLaneWords(data);
    }

    /// <summary>
    ///     The lock's owner in the agents' words: octo-tools' lane (the folder of the run, the base lane) is baseLane, its
    ///     environment (the feature environment) is lane.
    /// </summary>
    internal static System.Text.Json.Nodes.JsonNode InLaneWords(System.Text.Json.Nodes.JsonNode data)
    {
        if (data["owner"] is System.Text.Json.Nodes.JsonObject owner)
        {
            var renamed = new System.Text.Json.Nodes.JsonObject();
            foreach (var (key, value) in owner.ToList())
            {
                owner.Remove(key);
                renamed[key switch { "lane" => "baseLane", "environment" => "lane", _ => key }] = value;
            }

            data["owner"] = renamed;
        }

        return data;
    }

    // ---------- restart check ----------

    /// <summary>
    ///     The queued and running builds, for the restart check. A queued job is restored by the next start; a running one
    ///     survives when its step runs detached and it is not stopping or restarting services right now.
    /// </summary>
    public List<ActiveBuild> Active() =>
        _jobs.Values.Where(j => j.State is "queued" or "running").OrderBy(j => j.Sequence).Select(job =>
        {
            var phase = job.State == "running" ? job.Phase : null;
            var survives = job.State == "queued" || ((_launcher != null || job.Legacy) && phase is not ("stopping" or "restarting"));
            return new ActiveBuild(job.Id, job.Request.Owner, job.State, BuildStatus.ShownKind(job.Kind), job.Planned.Target, job.Request.Environment, job.Pid, phase, survives);
        }).ToList();

    /// <summary>Why a queued job has not started (the first reason in queue order); null when it is about to.</summary>
    private string? WaitReason(BuildJob job)
    {
        List<BuildJob> running;
        List<BuildJob> ahead;
        lock (_scheduleLock)
        {
            running = _running.ToList();
            ahead = _waiting.TakeWhile(j => j != job).Where(j => j.State == "queued").ToList();
        }

        static string Name(BuildJob j) => $"{j.Id} ({BuildStatus.ShownKind(j.Kind)} {j.Planned.Target}, {j.Request.Owner})";

        // The words of the agent-facing tools: a lane job is a base lane build, an environment is a lane.
        var env = ClassOf(job);
        var per = job.Request.Environment != null ? "one build or test run per lane"
            : IsWorktreeBuild(job) ? "one build per worktree"
            : $"one test run of {job.Planned.Branch ?? job.Planned.Lane} at a time"; // a test run of the base lane (or another checkout)
        if (ahead.FirstOrDefault(j => ClassOf(j) == null) is { } laneAhead)
        {
            return $"queued behind the base lane build {Name(laneAhead)}; nothing overtakes a waiting base lane build";
        }

        if (env == null)
        {
            return running.Count > 0 ? $"a base lane build runs alone; waiting for {string.Join(", ", running.Select(Name))}" : null;
        }

        if (running.FirstOrDefault(j => ClassOf(j) == null) is { } lane)
        {
            return $"waiting for the base lane build {Name(lane)}";
        }

        if (running.FirstOrDefault(j => ClassOf(j) == env) is { } same)
        {
            return $"{per}; waiting for {Name(same)}" + (job.Early is { Ok: false, Reason: { } why } ? $" - it cannot start next to that build: {why}" : "");
        }

        if (ahead.FirstOrDefault(j => ClassOf(j) == env) is { } sameAhead)
        {
            return $"{per}; queued behind {Name(sameAhead)}";
        }

        if (running.FirstOrDefault(j => Overlaps(j, job)) is { } overlapping)
        {
            return $"{Name(overlapping)} builds or tests a folder of this job ({string.Join(", ", job.Planned.ConflictPaths)}); two jobs never work on one folder at once";
        }

        if (IsTest(job))
        {
            return null;
        }

        if (IsWorktreeBuild(job))
        {
            var worktrees = running.Where(IsWorktreeBuild).ToList();
            return worktrees.Count >= MaxParallelWorktreeBuilds
                ? $"at most {MaxParallelWorktreeBuilds} worktree builds run at once; waiting for {string.Join(", ", worktrees.Select(Name))}"
                : null;
        }

        var environments = running.Where(IsEnvironmentBuild).ToList();
        return environments.Count >= MaxParallelEnvironmentBuilds
            ? $"at most {MaxParallelEnvironmentBuilds} lane builds run at once; waiting for {string.Join(", ", environments.Select(Name))}"
            : null;
    }

    // ---------- trimming ----------

    private void Trim()
    {
        foreach (var old in _jobs.Values.Where(j => j.FinishedAt != null).OrderByDescending(j => j.FinishedAt).Skip(KeepFinishedJobs).ToList())
        {
            Forget(old);
        }
    }

    private void Forget(BuildJob job)
    {
        if (_jobs.TryRemove(job.Id, out _))
        {
            job.DeleteFiles();
        }
    }

    /// <summary>Finished jobs are kept for 14 days (at most <see cref="KeepFinishedJobs"/>); files no job owns go after the same time.</summary>
    private void CleanOldFiles()
    {
        foreach (var old in _jobs.Values.Where(j => j.FinishedAt != null && DateTimeOffset.Now - j.FinishedAt > KeepFilesFor).ToList())
        {
            Forget(old);
        }

        try
        {
            var ids = _jobs.Keys.ToList();
            foreach (var file in Directory.EnumerateFiles(_paths.BuildLogDirectory))
            {
                var name = Path.GetFileName(file);
                if (DateTime.Now - File.GetLastWriteTime(file) > KeepFilesFor && !ids.Any(id => name.StartsWith(id + ".", StringComparison.Ordinal)))
                {
                    File.Delete(file);
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _logger.LogDebug(e, "Could not clean old build files");
        }
    }
}
