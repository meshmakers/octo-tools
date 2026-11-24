using System.Text.RegularExpressions;

namespace Meshmakers.Octo.DevStack.Builds;

public sealed record ParsedLog(IReadOnlyList<BuildError> Errors, int ErrorCount, int WarningCount);

/// <summary>
///     Errors of a dotnet build log (Invoke-Build.log): compiler diagnostics with file/line/col, MSBuild and NuGet errors
///     without a position. dotnet prints every diagnostic twice (while building and in the summary), so they are
///     deduplicated; the counts come from the summary when it has them.
/// </summary>
public static partial class BuildLogParser
{
    public const int MaxStoredPerRepo = 100;

    [GeneratedRegex(@"^(?<file>.+)\((?<line>\d+),(?<col>\d+)\): (?<sev>error|warning) (?<code>\w+): (?<msg>.*) \[(?<proj>.+)\]$")]
    private static partial Regex Positioned();

    // "/x/a.csproj : error NU1101: ... [/x/a.sln]", "MSBUILD : error MSB1009: ...", "error MSB4236: ..."
    [GeneratedRegex(@"^(?:(?<file>[^:(]+?|.*\.\w+proj|MSBUILD|CSC) ?: )?(?<sev>error|warning) (?<code>[A-Z]{2,}\d+): (?<msg>.*?)(?: \[(?<proj>[^\]]+)\])?$")]
    private static partial Regex Plain();

    [GeneratedRegex(@"^\s*(?<n>\d+) (?<kind>Warning|Error)\(s\)\s*$")]
    private static partial Regex ClassicSummary();

    [GeneratedRegex(@"\b(?:succeeded|failed) with (?:(?<e>\d+) error\(s\))?(?: and )?(?:(?<w>\d+) warning\(s\))?", RegexOptions.IgnoreCase)]
    private static partial Regex ModernSummary();

    public static ParsedLog Parse(string text, string repo, int max = MaxStoredPerRepo)
    {
        var errors = new List<BuildError>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var warnings = new HashSet<string>(StringComparer.Ordinal);
        var errorKeys = new HashSet<string>(StringComparer.Ordinal);
        int? summaryErrors = null;
        int? summaryWarnings = null;

        foreach (var raw in text.Replace("\r", "").Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0)
            {
                continue;
            }

            var classic = ClassicSummary().Match(line);
            if (classic.Success)
            {
                var n = int.Parse(classic.Groups["n"].Value);
                if (classic.Groups["kind"].Value == "Error")
                {
                    summaryErrors = n;
                }
                else
                {
                    summaryWarnings = n;
                }

                continue;
            }

            var modern = ModernSummary().Match(line);
            if (modern.Success && (modern.Groups["e"].Success || modern.Groups["w"].Success))
            {
                summaryErrors = modern.Groups["e"].Success ? int.Parse(modern.Groups["e"].Value) : 0;
                summaryWarnings = modern.Groups["w"].Success ? int.Parse(modern.Groups["w"].Value) : 0;
                continue;
            }

            BuildError? error;
            string severity;
            var m = Positioned().Match(line);
            if (m.Success)
            {
                severity = m.Groups["sev"].Value;
                error = new BuildError(repo, m.Groups["file"].Value, int.Parse(m.Groups["line"].Value), int.Parse(m.Groups["col"].Value),
                    m.Groups["code"].Value, m.Groups["msg"].Value.Trim(), m.Groups["proj"].Value);
            }
            else
            {
                m = Plain().Match(line);
                if (!m.Success)
                {
                    continue;
                }

                severity = m.Groups["sev"].Value;
                var file = m.Groups["file"].Success && m.Groups["file"].Value.Length > 0 ? m.Groups["file"].Value.Trim() : null;
                error = new BuildError(repo, file, null, null, m.Groups["code"].Value, m.Groups["msg"].Value.Trim(),
                    m.Groups["proj"].Success ? m.Groups["proj"].Value : null);
            }

            var key = $"{error.File}|{error.Line}|{error.Col}|{error.Code}|{error.Message}";
            if (severity == "warning")
            {
                warnings.Add(key);
                continue;
            }

            errorKeys.Add(key);
            if (errors.Count < max && seen.Add(key))
            {
                errors.Add(error);
            }
        }

        return new ParsedLog(errors, summaryErrors ?? errorKeys.Count, summaryWarnings ?? warnings.Count);
    }

    // Colour codes and the box frames npm scripts print around their messages (setup-license.js).
    [GeneratedRegex(@"\x1B\[[0-9;]*[A-Za-z]")]
    private static partial Regex Ansi();

    // "error" as a word (not "errors"), or npm's "ERR!" - followed by a space, where \b finds no boundary.
    [GeneratedRegex(@"(?:^|[\s\[(✘×])(?:error\b|err!)", RegexOptions.IgnoreCase)]
    private static partial Regex ErrorWord();

    private static readonly char[] Frame = ['║', '╔', '╗', '╚', '╝', '═', '╠', '╣', '│', '─', '┃', '━'];

    /// <summary>
    ///     Errors of a build that is not dotnet's (a build.ps1, npm, ng; AB#9464): the dotnet diagnostics when it ran dotnet,
    ///     else every line that names an error - colour codes and box frames removed, in order, once each. The first one is
    ///     usually the cause, e.g. a prebuild script's "ERROR: TELERIK_LICENSE environment variable is not set!".
    ///     <paramref name="code"/> stands for the missing diagnostic code (the build mode).
    /// </summary>
    public static ParsedLog ParseScriptOutput(string text, string repo, string code, int max = MaxStoredPerRepo)
    {
        // Colour codes go first, so that they reach neither the dotnet diagnostics nor the summary.
        var clean = Ansi().Replace(text, "");
        var dotnet = Parse(clean, repo, max);
        if (dotnet.Errors.Count > 0)
        {
            return dotnet;
        }

        var errors = new List<BuildError>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var raw in clean.Replace("\r", "").Split('\n'))
        {
            var line = raw.Trim().Trim(Frame).Trim();
            // The step's own -Json document is no error line, whatever its detail says.
            if (line.Length == 0 || line.StartsWith('{') || !ErrorWord().IsMatch(line) || IsBuildSummary(line) || !seen.Add(line))
            {
                continue;
            }

            if (errors.Count < max)
            {
                errors.Add(new BuildError(repo, null, null, null, code, line, null));
            }
        }

        // A dotnet summary that names a count without diagnostics ("Build failed with 2 error(s)") keeps its count.
        return new ParsedLog(errors, Math.Max(seen.Count, dotnet.ErrorCount), dotnet.WarningCount);
    }

    /// <summary>
    ///     A dotnet build summary ("    0 Error(s)", "Build succeeded with 0 error(s) and 1 warning(s)"): it counts errors, it
    ///     names none, so it is never the cause - unlike a message that only mentions a number of errors.
    /// </summary>
    private static bool IsBuildSummary(string line) =>
        ClassicSummary().IsMatch(line) || ModernSummary().Match(line) is { Success: true } m && (m.Groups["e"].Success || m.Groups["w"].Success);
}
