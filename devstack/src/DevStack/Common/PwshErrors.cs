using System.Text.RegularExpressions;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>
///     The meaningful line of a failed pwsh run: the message of its first error record, not the last line of the output
///     (pwsh wraps a message, so its last line is a fragment such as "spelling of the name, or if a path was included, ...").
///     Pure; reads the three ways pwsh 7 prints an error record: ConciseView with a position box ("Line |", the code,
///     "~~~", then "| message"), ConciseView without one ("Command: message") and NormalView ("message", "At file:line char:n").
/// </summary>
public static partial class PwshErrors
{
    private const int MaxChars = 400;

    [GeneratedRegex(@"\x1b\[[0-9;?]*[ -/]*[@-~]")]
    private static partial Regex Ansi();

    [GeneratedRegex(@"^\s*Line \|\s*$")]
    private static partial Regex BoxStart();

    [GeneratedRegex(@"^\s*\|\s*~+\s*$")]
    private static partial Regex BoxMarker();

    [GeneratedRegex(@"^\s*\| ?(?<text>.*)$")]
    private static partial Regex BoxLine();

    /// <summary>
    ///     "Verb-Noun: message" (a cmdlet or function), "SomethingException: message", "Exception: message" or a category
    ///     reason - the first line of a ConciseView error record without a position.
    /// </summary>
    [GeneratedRegex(@"^(?<who>[A-Z][A-Za-z0-9]*-[A-Za-z0-9]+|(?:[A-Za-z][A-Za-z0-9.]*)?Exception|InvalidOperation|ParserError|WriteError|NotSpecified|ObjectNotFound|InvalidArgument|PermissionDenied|ResourceUnavailable|OperationStopped): (?<message>\S.*)$")]
    private static partial Regex Concise();

    [GeneratedRegex(@"^At (line:\d+|.+:\d+) char:\d+\s*$")]
    private static partial Regex NormalAt();

    /// <summary>The message of the first error record in <paramref name="output"/> (wrapped lines joined), or null when it has none.</summary>
    public static string? FirstError(string? output)
    {
        if (string.IsNullOrWhiteSpace(output))
        {
            return null;
        }

        var lines = Ansi().Replace(output, "").Replace("\r", "").Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            if (BoxStart().IsMatch(lines[i]))
            {
                if (Box(lines, i) is { } boxed)
                {
                    return boxed;
                }

                continue;
            }

            var concise = Concise().Match(lines[i].TrimEnd());
            if (concise.Success)
            {
                if (i + 1 < lines.Length && BoxStart().IsMatch(lines[i + 1]))
                {
                    continue; // the header of a position box ("Command: file:line"), read at the next line
                }

                var parts = new List<string> { concise.Groups["message"].Value.Trim() };
                for (var j = i + 1; j < lines.Length && j <= i + 3; j++)
                {
                    var next = lines[j].Trim();
                    if (next.Length == 0 || BoxStart().IsMatch(lines[j]) || Concise().IsMatch(next) || NormalAt().IsMatch(next))
                    {
                        break;
                    }

                    parts.Add(next);
                }

                return Compose(concise.Groups["who"].Value, parts);
            }

            if (NormalAt().IsMatch(lines[i].Trim()) && i > 0)
            {
                var parts = new List<string>();
                for (var k = i - 1; k >= 0 && k >= i - 3 && lines[k].Trim().Length > 0; k--)
                {
                    parts.Insert(0, lines[k].Trim());
                }

                if (parts.Count > 0)
                {
                    return Compose(null, parts);
                }
            }
        }

        return null;
    }

    /// <summary>
    ///     The line a failure summary shows: the first error record's message, else the last non-empty line, else "no output".
    /// </summary>
    public static string Summary(string? output)
    {
        if (FirstError(output) is { } error)
        {
            return error;
        }

        var last = (output ?? "").Replace("\r", "").Split('\n').LastOrDefault(l => l.Trim().Length > 0)?.Trim();
        return last is { Length: > 0 } ? Cap(Ansi().Replace(last, "")) : "no output";
    }

    /// <summary>A position box: the header line before "Line |" names the command; the message follows the "~~~" line.</summary>
    private static string? Box(string[] lines, int start)
    {
        var header = start > 0 ? lines[start - 1].Trim() : "";
        var who = Concise().Match(header) is { Success: true } m ? m.Groups["who"].Value : null;
        var marker = -1;
        for (var j = start + 1; j < lines.Length && j <= start + 8; j++)
        {
            if (BoxMarker().IsMatch(lines[j]))
            {
                marker = j;
                break;
            }
        }

        if (marker < 0)
        {
            return null;
        }

        var parts = new List<string>();
        for (var j = marker + 1; j < lines.Length && parts.Count < 6; j++)
        {
            var line = BoxLine().Match(lines[j]);
            if (!line.Success || line.Groups["text"].Value.Trim().Length == 0)
            {
                break;
            }

            parts.Add(line.Groups["text"].Value.Trim());
        }

        return parts.Count == 0 ? null : Compose(who, parts);
    }

    private static string Compose(string? who, IReadOnlyList<string> parts)
    {
        var message = string.Join(' ', parts);
        return Cap(who is { Length: > 0 } ? $"{who}: {message}" : message);
    }

    private static string Cap(string text) => text.Length <= MaxChars ? text : text[..(MaxChars - 3)] + "...";
}
