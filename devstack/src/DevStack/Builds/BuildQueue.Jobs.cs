using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Builds;

// The state of a job and its steps: in memory while the daemon runs, mirrored into the job file on every change.
public sealed partial class BuildQueue
{
    private sealed record JobSnapshot(
        string State,
        bool Success,
        DateTimeOffset? StartedAt,
        DateTimeOffset? FinishedAt,
        string? Phase,
        BuildOutcome? Outcome,
        List<string> Stopped,
        List<string> Notes,
        Dictionary<string, List<BuildError>> Errors,
        int ErrorCount,
        int WarningCount,
        Dictionary<string, string> PerRepoLogs,
        List<JsonObject> Results,
        string? OutputTail,
        Dictionary<string, RepoCounts> Counts,
        List<BuildTestProject>? Tests,
        List<BuildRepoEvidence> Evidence);

    private sealed class StepRun(StepSpec spec, string eventsFile, string exitFile)
    {
        private readonly Lock _sync = new();
        private (long Length, DateTime Written, StepEvents Events)? _cache;
        private StepEvents? _final;

        public StepSpec Spec { get; } = spec;
        public string EventsFile { get; } = eventsFile;

        /// <summary>Where the detached wrapper leaves the exit code.</summary>
        public string ExitFile { get; } = exitFile;

        public Action? Changed { get; set; }
        public DateTimeOffset? StartedAt { get; private set; }
        public int? Pid { get; private set; }
        public DateTimeOffset? ProcessStart { get; private set; }
        public long LogOffset { get; private set; }
        public bool Completed { get; private set; }
        public bool Success { get; private set; }
        public BuildOutcome? Outcome { get; private set; }

        /// <summary>Set when a daemon start finds the recorded process gone (or its pid reused): only its files are left to read.</summary>
        public bool ProcessGone { get; set; }

        public void Begin(long logOffset = 0)
        {
            lock (_sync)
            {
                StartedAt = DateTimeOffset.Now;
                LogOffset = logOffset;
                Pid = null;
                ProcessStart = null;
            }

            Changed?.Invoke();
        }

        public void SetProcess(int pid, DateTimeOffset? processStart)
        {
            lock (_sync)
            {
                Pid = pid;
                ProcessStart = processStart;
            }

            Changed?.Invoke();
        }

        public void Complete(StepEvents events, bool success, BuildOutcome outcome)
        {
            lock (_sync)
            {
                _final = events;
                Completed = true;
                Success = success;
                Outcome = outcome;
                Pid = null;
            }

            Changed?.Invoke();
        }

        /// <summary>The step's repos now: the final state, the parsed events file (cached by length and write time) or the log poll.</summary>
        public StepEvents Read(bool finished)
        {
            lock (_sync)
            {
                if (_final != null)
                {
                    return _final;
                }

                if (StartedAt == null)
                {
                    return BuildEventReader.Parse("", Spec.Repos);
                }

                if (!Spec.UsesEvents)
                {
                    // A build.ps1 or nothing-to-build step writes no Invoke-Build.log: polling it could only find an earlier
                    // build's log (AB#9464). Invoke-Build and Invoke-Publish write it, so their progress is polled.
                    return Spec.ResultCommand != BuildPlanner.RepoScriptCommand
                        ? BuildLogPoller.Poll(Spec.Repos, StartedAt.Value, finished)
                        : BuildEventReader.Parse("", Spec.Repos);
                }

                var info = new FileInfo(EventsFile);
                if (!info.Exists)
                {
                    return BuildEventReader.Parse("", Spec.Repos);
                }

                if (!finished && _cache is { } hit && hit.Length == info.Length && hit.Written == info.LastWriteTimeUtc)
                {
                    return hit.Events;
                }

                var parsed = BuildEventReader.Parse(BuildEventReader.ReadShared(EventsFile), Spec.Repos);
                _cache = (info.Length, info.LastWriteTimeUtc, parsed);
                return parsed;
            }
        }

        public StepRecord ToRecord()
        {
            lock (_sync)
            {
                return new StepRecord
                {
                    EventsFile = EventsFile, ExitFile = ExitFile, StartedAt = StartedAt, Pid = Pid, ProcessStart = ProcessStart, LogOffset = LogOffset,
                    Completed = Completed, Success = Success, Outcome = Outcome, Repos = _final?.Repos.ToList(), Done = _final?.Done
                };
            }
        }

        public static StepRun Restore(StepSpec spec, StepRecord record)
        {
            var step = new StepRun(spec, record.EventsFile, record.ExitFile)
            {
                StartedAt = record.StartedAt, Pid = record.Pid, ProcessStart = record.ProcessStart, LogOffset = record.LogOffset,
                Completed = record.Completed, Success = record.Success, Outcome = record.Outcome
            };
            if (record.Completed)
            {
                var events = new StepEvents { Done = record.Done };
                events.Repos.AddRange(record.Repos ?? []);
                step._final = events;
            }

            return step;
        }
    }

    private sealed class BuildJob
    {
        private readonly string _directory;
        private readonly Dictionary<string, RepoCounts> _counts = new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, List<BuildError>> _errors = new(StringComparer.OrdinalIgnoreCase);
        private readonly List<BuildRepoEvidence> _evidence = [];
        private readonly List<string> _files = [];
        private readonly List<string> _notes = [];
        private readonly Dictionary<string, string> _perRepoLogs = new(StringComparer.OrdinalIgnoreCase);
        private readonly List<JsonObject> _results = [];
        private readonly List<string> _stopped = [];
        private readonly Lock _sync = new();
        private Action? _changed;
        private int _errorCount;
        private BuildOutcome? _outcome;
        private string? _outputTail;
        private string? _phase;
        private bool _success;
        private List<BuildTestProject>? _tests;
        private int _warningCount;

        public BuildJob(string id, long sequence, BuildRequest request, PlannedBuild planned, string logFile, string directory, string jobFile)
            : this(id, sequence, request, planned, logFile, directory, jobFile,
                planned.Steps.Select((s, i) => new StepRun(s, Path.Combine(directory, $"{id}.{i + 1}.events.jsonl"), Path.Combine(directory, $"{id}.{i + 1}.exit")))
                    .ToList())
        {
        }

        private BuildJob(string id, long sequence, BuildRequest request, PlannedBuild planned, string logFile, string directory, string jobFile, List<StepRun> steps)
        {
            Id = id;
            Sequence = sequence;
            Request = request;
            Planned = planned;
            LogFile = logFile;
            _directory = directory;
            Steps = steps;
            _files.Add(logFile);
            _files.Add(jobFile);
            _files.AddRange(Steps.Select(s => s.EventsFile));
            _files.AddRange(Steps.Select(s => s.ExitFile));
            // The script file of a step on Windows (written next to the marker); a missing file is no error when deleted.
            _files.AddRange(Steps.Select(s => DetachedBuildLauncher.ScriptFile(s.ExitFile)));
        }

        public string Id { get; }
        public long Sequence { get; }
        public bool LeaseRequired { get; init; }

        /// <summary>The own services the build is going to stop (from the plan); replaced by the real list once it stopped them.</summary>
        public IReadOnlyList<string> PlannedStops { get; init; } = [];

        /// <summary>The slots whose lease the job needs and pins while it runs.</summary>
        public IReadOnlyList<string> LeaseSlots { get; init; } = [];
        public BuildRequest Request { get; }
        public PlannedBuild Planned { get; }
        public string Kind => Request.Kind.ToString().ToLowerInvariant();
        public string LogFile { get; }
        public List<StepRun> Steps { get; }
        public DateTimeOffset QueuedAt { get; private init; } = DateTimeOffset.Now;
        public CancellationTokenSource Cancellation { get; } = new();
        public string State { get; private set; } = "queued";
        public DateTimeOffset? StartedAt { get; private set; }
        public DateTimeOffset? FinishedAt { get; private set; }
        public int? Pid { get; set; }

        /// <summary>The lease pins the job holds while it runs (taken when it becomes running, released when its run ends).</summary>
        public IReadOnlyList<IDisposable> Pins { get; set; } = [];

        /// <summary>
        ///     Pins of leases the job took only in its preflight (a test run that must stop services started while it was queued):
        ///     held until the services are back, released with <see cref="Pins"/>.
        /// </summary>
        public List<IDisposable> LatePins { get; } = [];

        /// <summary>A waiting test run: what the cmdlet's -WhatIf said about starting it next to its environment's build (AB#8832).</summary>
        public EarlyProbe? Early { get; set; }

        /// <summary>A test run started next to its environment's build: it runs with -build Never.</summary>
        public bool NoBuild { get; set; }

        public StoppedForBuild Stopped { get; private set; } = StoppedForBuild.None;
        public IReadOnlyList<BuildConflict> Conflicts { get; private set; } = [];
        public string? FailedStepFallback => _phase == "stopping" ? "preflight" : null;

        /// <summary>How often a daemon start took the job over while it ran.</summary>
        public int Reattached { get; private set; }

        /// <summary>A build of a daemon version without job files, taken over from the state file.</summary>
        public bool Legacy { get; private init; }

        /// <summary>Serializes the writes of the job file; <see cref="Deleted"/> is set under it.</summary>
        public Lock SaveLock { get; } = new();

        public bool Deleted { get; private set; }

        /// <summary>Called after every change of the job or one of its steps (the queue writes the job file).</summary>
        public Action? Changed
        {
            get => _changed;
            set
            {
                _changed = value;
                foreach (var step in Steps)
                {
                    step.Changed = value;
                }
            }
        }

        public string? Phase
        {
            get
            {
                lock (_sync)
                {
                    return _phase;
                }
            }
        }

        public bool HasErrors
        {
            get
            {
                lock (_sync)
                {
                    return _errors.Count > 0;
                }
            }
        }

        public string? FirstErrorRepo
        {
            get
            {
                lock (_sync)
                {
                    return _errors.Keys.FirstOrDefault();
                }
            }
        }

        public StepEvents ReadEvents(StepRun step, bool finished) => step.Read(finished);

        public string? CurrentRepo()
        {
            foreach (var step in Steps)
            {
                if (step.Read(false).Repos.FirstOrDefault(r => r.State == "building") is { } run)
                {
                    return run.Repo;
                }
            }

            return null;
        }

        public bool TryStart()
        {
            lock (_sync)
            {
                if (State != "queued")
                {
                    return false;
                }

                State = "running";
                StartedAt = DateTimeOffset.Now;
            }

            _changed?.Invoke();
            return true;
        }

        public bool TryCancelQueued()
        {
            lock (_sync)
            {
                if (State != "queued")
                {
                    return false;
                }

                State = "canceled";
                _outcome = new BuildOutcome(null, null, "canceled while queued", null);
                FinishedAt = DateTimeOffset.Now;
            }

            _changed?.Invoke();
            return true;
        }

        public void Finish(string state, bool success, BuildOutcome outcome)
        {
            lock (_sync)
            {
                State = state;
                _success = success;
                _outcome = outcome;
                _phase = null;
                FinishedAt = DateTimeOffset.Now;
            }

            _changed?.Invoke();
        }

        public void SetPhase(string? phase)
        {
            lock (_sync)
            {
                _phase = phase;
            }

            _changed?.Invoke();
        }

        public void SetStopped(StoppedForBuild stopped)
        {
            lock (_sync)
            {
                Stopped = stopped;
                _stopped.AddRange(stopped.Names.Where(n => !_stopped.Contains(n)).ToList()); // called again with the growing set, slot by slot
            }

            _changed?.Invoke();
        }

        public void SetConflicts(IReadOnlyList<BuildConflict> conflicts)
        {
            lock (_sync)
            {
                Conflicts = conflicts;
            }
        }

        public void AddNote(string note)
        {
            lock (_sync)
            {
                _notes.Add(note);
            }

            _changed?.Invoke();
        }

        /// <summary>A daemon start took the running job over.</summary>
        public void MarkReattached(string note)
        {
            lock (_sync)
            {
                Reattached++;
                _phase = null;
                _notes.Add(note);
            }

            _changed?.Invoke();
        }

        public void AddResult(JsonObject json)
        {
            lock (_sync)
            {
                _results.Add(json);
            }

            _changed?.Invoke();
        }

        /// <summary>The test projects of a finished test run, with their failed tests.</summary>
        public void SetTests(List<BuildTestProject> tests)
        {
            lock (_sync)
            {
                _tests = tests;
            }

            _changed?.Invoke();
        }

        /// <summary>Whether the work trees were read when the job started (a job taken over after a daemon restart has them).</summary>
        public bool HasEvidence
        {
            get
            {
                lock (_sync)
                {
                    return _evidence.Count > 0;
                }
            }
        }

        /// <summary>The work trees when the job started, one row per repository it covers.</summary>
        public void SetEvidenceStart(IReadOnlyList<(string Repo, string Path, BuildRepoState State)> rows)
        {
            lock (_sync)
            {
                _evidence.Clear();
                _evidence.AddRange(rows.Select(r => new BuildRepoEvidence(r.Repo, r.Path, r.State, null)));
            }

            _changed?.Invoke();
        }

        /// <summary>The work trees when the job ended: next to the start of the same folder (a row without a start when it had none).</summary>
        public void SetEvidenceEnd(IReadOnlyList<(string Repo, string Path, BuildRepoState State)> rows)
        {
            lock (_sync)
            {
                foreach (var row in rows)
                {
                    var index = _evidence.FindIndex(e => PathScope.SamePath(e.Path, row.Path));
                    if (index < 0)
                    {
                        _evidence.Add(new BuildRepoEvidence(row.Repo, row.Path, null, row.State));
                    }
                    else
                    {
                        _evidence[index] = _evidence[index] with { End = row.State };
                    }
                }
            }

            _changed?.Invoke();
        }

        public void SetOutputTail(string tail)
        {
            lock (_sync)
            {
                _outputTail = tail;
            }

            _changed?.Invoke();
        }

        /// <summary>
        ///     Keeps a repo's build log in the state folder (the next build of the repo deletes <c>Invoke-Build.log</c>) and its
        ///     error and warning counts: a failed repo's log completely, with its parsed errors; another one's last
        ///     <see cref="KeptLogChars"/> characters.
        /// </summary>
        public void SnapshotLog(string repo, string log, bool failed)
        {
            var text = BuildEventReader.ReadShared(log);
            Keep(repo, text, BuildLogParser.Parse(text, repo), failed, log);
        }

        /// <summary>
        ///     A failed repo whose step writes no log of its own (a build.ps1, Invoke-Publish; AB#9464): the step's output in
        ///     the job log is kept as the repo's log, with the error lines it names.
        /// </summary>
        public void SnapshotOutput(string repo, string output, string mode) =>
            Keep(repo, output, BuildLogParser.ParseScriptOutput(output, repo, mode), true, LogFile);

        /// <summary>The first error kept for a repo, if any.</summary>
        public BuildError? FirstErrorOf(string repo)
        {
            lock (_sync)
            {
                return _errors.TryGetValue(repo, out var errors) ? errors.FirstOrDefault() : null;
            }
        }

        private void Keep(string repo, string text, ParsedLog parsed, bool failed, string fallback)
        {
            var copy = Path.Combine(_directory, $"{Id}.{PathScope.Slug(repo)}.log");
            try
            {
                File.WriteAllText(copy, failed || text.Length <= KeptLogChars ? text : "[... earlier output left out ...]\n" + text[^KeptLogChars..]);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                copy = fallback;
            }

            lock (_sync)
            {
                if (copy != fallback && !_files.Contains(copy))
                {
                    _files.Add(copy);
                }

                _perRepoLogs[repo] = copy;
                _counts[repo] = new RepoCounts(parsed.ErrorCount, parsed.WarningCount);
                if (failed)
                {
                    _errors[repo] = parsed.Errors.ToList();
                    _errorCount += parsed.ErrorCount;
                    _warningCount += parsed.WarningCount;
                }
            }

            _changed?.Invoke();
        }

        public JobSnapshot Snapshot()
        {
            lock (_sync)
            {
                return new JobSnapshot(State, _success, StartedAt, FinishedAt, _phase, _outcome, _stopped.ToList(), _notes.ToList(),
                    _errors.Where(e => e.Value.Count > 0).ToDictionary(e => e.Key, e => e.Value.ToList()), _errorCount, _warningCount,
                    new Dictionary<string, string>(_perRepoLogs, StringComparer.OrdinalIgnoreCase), _results.ToList(), _outputTail,
                    new Dictionary<string, RepoCounts>(_counts, StringComparer.OrdinalIgnoreCase), _tests?.ToList(), _evidence.ToList());
            }
        }

        public JobRecord ToRecord()
        {
            lock (_sync)
            {
                return new JobRecord
                {
                    Id = Id, Sequence = Sequence, Request = Request, Plan = Planned, State = State, Success = _success, QueuedAt = QueuedAt,
                    StartedAt = StartedAt, FinishedAt = FinishedAt, Phase = _phase, Outcome = _outcome, LeaseRequired = LeaseRequired,
                    LeaseSlots = LeaseSlots.ToList(), PlannedStops = PlannedStops.ToList(), StoppedNames = Stopped.Names.ToList(),
                    StoppedOverrides = Stopped.Overrides.ToDictionary(o => o.Key, o => o.Value), Notes = _notes.ToList(),
                    Errors = _errors.ToDictionary(e => e.Key, e => e.Value.ToList()), Counts = new Dictionary<string, RepoCounts>(_counts),
                    ErrorCount = _errorCount, WarningCount = _warningCount, PerRepoLogs = new Dictionary<string, string>(_perRepoLogs),
                    Results = _results.Select(r => (JsonObject)r.DeepClone()).ToList(), OutputTail = _outputTail, Files = _files.ToList(),
                    Steps = Steps.Select(s => s.ToRecord()).ToList(), Reattached = Reattached, Legacy = Legacy, Tests = _tests?.ToList(),
                    Evidence = _evidence.Count > 0 ? _evidence.ToList() : null
                };
            }
        }

        /// <summary>The job of a job file. A step the file does not describe (an older plan shape) starts as not run.</summary>
        public static BuildJob Restore(JobRecord record, string directory, string jobFile)
        {
            var plan = record.Plan ?? throw new InvalidOperationException($"The job file of {record.Id} holds no plan.");
            var steps = plan.Steps.Select((spec, i) => i < record.Steps.Count
                ? StepRun.Restore(spec, record.Steps[i])
                : new StepRun(spec, Path.Combine(directory, $"{record.Id}.{i + 1}.events.jsonl"), Path.Combine(directory, $"{record.Id}.{i + 1}.exit"))).ToList();
            var job = new BuildJob(record.Id, record.Sequence, record.Request, plan, Path.Combine(directory, record.Id + ".log"), directory, jobFile, steps)
            {
                LeaseRequired = record.LeaseRequired, LeaseSlots = record.LeaseSlots, PlannedStops = record.PlannedStops, QueuedAt = record.QueuedAt,
                Legacy = record.Legacy,
                State = record.State, StartedAt = record.StartedAt, FinishedAt = record.FinishedAt, Reattached = record.Reattached,
                Stopped = record.StoppedNames.Count > 0 ? new StoppedForBuild(record.StoppedNames, record.StoppedOverrides) : StoppedForBuild.None,
                _success = record.Success, _outcome = record.Outcome, _phase = record.Phase, _outputTail = record.OutputTail,
                _errorCount = record.ErrorCount, _warningCount = record.WarningCount, _tests = record.Tests
            };
            job._stopped.AddRange(record.StoppedNames);
            job._notes.AddRange(record.Notes);
            job._evidence.AddRange(record.Evidence ?? []);
            job._results.AddRange(record.Results);
            foreach (var (repo, errors) in record.Errors)
            {
                job._errors[repo] = errors;
            }

            foreach (var (repo, counts) in record.Counts)
            {
                job._counts[repo] = counts;
            }

            foreach (var (repo, log) in record.PerRepoLogs)
            {
                job._perRepoLogs[repo] = log;
            }

            foreach (var file in record.Files.Where(f => !job._files.Contains(f)))
            {
                job._files.Add(file);
            }

            return job;
        }

        /// <summary>
        ///     A build the state file of a daemon version without job files names: one step whose process is
        ///     <paramref name="build"/>'s pid, no plan (the repos come from its events file), no exit marker.
        /// </summary>
        public static BuildJob Adopt(PersistedBuild build, long sequence, string directory, string jobFile)
        {
            var kind = Enum.TryParse<BuildKind>(build.Kind, ignoreCase: true, out var parsed) ? parsed : BuildKind.Repo;
            var events = Path.Combine(directory, $"{build.Id}.1.events.jsonl");
            var request = new BuildRequest { Owner = build.Owner, Kind = kind, Environment = kind == BuildKind.Env ? build.Target : null };
            var spec = new StepSpec
            {
                Kind = kind, Target = build.Target, Script = "", Repos = [], HistoryLane = "", UsesEvents = File.Exists(events),
                Timeout = TimeSpan.FromHours(3)
            };
            var plan = new PlannedBuild
            {
                Request = request, Target = build.Target, Configuration = "", Steps = [spec], Warnings = [], Capabilities = BuildCapabilities.None
            };
            var step = StepRun.Restore(spec, new StepRecord
            {
                EventsFile = events, ExitFile = Path.Combine(directory, $"{build.Id}.1.exit"), StartedAt = build.StartedAt, Pid = build.Pid,
                LogOffset = 0
            });
            var log = string.IsNullOrEmpty(build.LogFile) ? Path.Combine(directory, build.Id + ".log") : build.LogFile;
            return new BuildJob(build.Id, sequence, request, plan, log, directory, jobFile, [step])
            {
                QueuedAt = build.StartedAt, StartedAt = build.StartedAt, State = "running", Legacy = true
            };
        }

        public void DeleteFiles()
        {
            List<string> files;
            lock (SaveLock)
            {
                Deleted = true;
            }

            lock (_sync)
            {
                files = _files.ToList();
            }

            foreach (var file in files)
            {
                try
                {
                    File.Delete(file);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    // Cleaned up with the 14-day sweep of the next daemon start.
                }
            }
        }
    }
}
