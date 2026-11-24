using System.Text;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>
///     Windows command lines: splitting and quoting by the rules of CommandLineToArgvW (what the C runtime and .NET use),
///     and the cmd.exe wrapper that redirects a service's output into its log file. Pure string code, testable everywhere.
/// </summary>
public static class WindowsCommandLine
{
    /// <summary>The characters cmd.exe interprets outside quotes; every one of them is caret-escaped in <see cref="CmdEscape"/>.</summary>
    private const string CmdMetaCharacters = "()%!^\"<>&|";

    /// <summary>Splits a command line into arguments (CommandLineToArgvW rules for the arguments after the program name).</summary>
    public static List<string> Split(string commandLine)
    {
        var result = new List<string>();
        var current = new StringBuilder();
        var inQuotes = false;
        var hasToken = false;
        var i = 0;
        while (i < commandLine.Length)
        {
            var c = commandLine[i];
            if (c == '\\')
            {
                var start = i;
                while (i < commandLine.Length && commandLine[i] == '\\')
                {
                    i++;
                }

                var count = i - start;
                if (i < commandLine.Length && commandLine[i] == '"')
                {
                    // 2n backslashes + quote: n backslashes and a quote delimiter; 2n+1: n backslashes and a literal quote.
                    current.Append('\\', count / 2);
                    if (count % 2 == 1)
                    {
                        current.Append('"');
                        i++;
                    }
                }
                else
                {
                    current.Append('\\', count);
                }

                hasToken = true;
                continue;
            }

            if (c == '"')
            {
                if (inQuotes && i + 1 < commandLine.Length && commandLine[i + 1] == '"')
                {
                    // "" inside quotes is a literal quote (the msvcrt rule since 2008).
                    current.Append('"');
                    i += 2;
                    hasToken = true;
                    continue;
                }

                inQuotes = !inQuotes;
                hasToken = true;
                i++;
                continue;
            }

            if (!inQuotes && (c == ' ' || c == '\t'))
            {
                if (hasToken)
                {
                    result.Add(current.ToString());
                    current.Clear();
                    hasToken = false;
                }

                i++;
                continue;
            }

            current.Append(c);
            hasToken = true;
            i++;
        }

        if (hasToken)
        {
            result.Add(current.ToString());
        }

        return result;
    }

    /// <summary>One argument quoted so that <see cref="Split"/> (CommandLineToArgvW) gives it back unchanged.</summary>
    public static string Quote(string argument)
    {
        if (argument.Length > 0 && argument.IndexOfAny([' ', '\t', '\n', '\v', '"']) < 0)
        {
            return argument;
        }

        var sb = new StringBuilder("\"");
        for (var i = 0; i < argument.Length; i++)
        {
            var backslashes = 0;
            while (i < argument.Length && argument[i] == '\\')
            {
                backslashes++;
                i++;
            }

            if (i == argument.Length)
            {
                // Backslashes before the closing quote are doubled.
                sb.Append('\\', backslashes * 2);
                break;
            }

            if (argument[i] == '"')
            {
                sb.Append('\\', backslashes * 2 + 1).Append('"');
            }
            else
            {
                sb.Append('\\', backslashes).Append(argument[i]);
            }
        }

        return sb.Append('"').ToString();
    }

    /// <summary>Program and arguments as one command line.</summary>
    public static string Join(string program, IEnumerable<string> arguments) =>
        string.Join(' ', new[] { Quote(program) }.Concat(arguments.Select(Quote)));

    /// <summary>
    ///     Caret-escapes every cmd.exe metacharacter, quotes included: cmd then never enters its quote mode, so every caret
    ///     is consumed and the program receives exactly <paramref name="commandLine"/>. A percent sign becomes ^%, which
    ///     names no variable in command-line mode and is left alone by the expansion.
    /// </summary>
    public static string CmdEscape(string commandLine)
    {
        var sb = new StringBuilder(commandLine.Length * 2);
        foreach (var c in commandLine)
        {
            if (CmdMetaCharacters.Contains(c))
            {
                sb.Append('^');
            }

            sb.Append(c);
        }

        return sb.ToString();
    }

    /// <summary>
    ///     The arguments of cmd.exe that run the service with its output appended to <paramref name="logFile"/>:
    ///     <c>/d /v:off /s /c "&lt;escaped command line&gt; &lt;NUL &gt;&gt;"&lt;log&gt;" 2&gt;&amp;1"</c>. /d skips AutoRun
    ///     scripts, /v:off delayed expansion; /s strips the outer quotes and keeps the rest as it is. The log path stays in real
    ///     quotes (it may contain spaces; Windows paths cannot contain quotes). cmd.exe waits for the service and exits with
    ///     its exit code.
    /// </summary>
    public static string CmdWrapperArguments(string program, IReadOnlyList<string> arguments, string logFile)
    {
        if (logFile.Contains('"') || logFile.Contains('%'))
        {
            throw new InvalidOperationException($"The log file path '{logFile}' must not contain quotes or percent signs (cmd.exe redirection).");
        }

        return $"/d /v:off /s /c \"{CmdEscape(Join(program, arguments))} <NUL >>\"{logFile}\" 2>&1\"";
    }

    /// <summary>The program of a command line: its first argument, path and .exe removed (lower case).</summary>
    public static string ProgramName(string commandLine)
    {
        var first = Split(commandLine).FirstOrDefault() ?? "";
        var name = first[(first.LastIndexOfAny(['\\', '/']) + 1)..];
        return (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name[..^4] : name).ToLowerInvariant();
    }
}
