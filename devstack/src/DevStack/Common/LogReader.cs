using System.Text;
using System.Text.RegularExpressions;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>Reads the end of (possibly large) log files.</summary>
public static class LogReader
{
    private const int ChunkBytes = 64 * 1024;
    private const int MaxScanBytes = 32 * 1024 * 1024;

    /// <summary>The last <paramref name="lines"/> lines, or null if the file does not exist.</summary>
    public static string? Tail(string file, int lines) => File.Exists(file) ? string.Join('\n', TailLines(file, lines, null)) : null;

    /// <summary>
    ///     The last <paramref name="lines"/> lines matching <paramref name="pattern"/> (regex, case-insensitive), scanning at
    ///     most the last 32 MB of the file.
    /// </summary>
    public static List<string> TailLines(string file, int lines, string? pattern)
    {
        lines = Math.Clamp(lines, 1, 5000);
        var regex = string.IsNullOrEmpty(pattern) ? null : new Regex(pattern, RegexOptions.IgnoreCase, TimeSpan.FromSeconds(2));
        using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var result = new List<string>();
        var position = stream.Length;
        var scanned = 0L;
        var carry = Array.Empty<byte>();

        while (position > 0 && result.Count < lines && scanned < MaxScanBytes)
        {
            var size = (int)Math.Min(ChunkBytes, position);
            position -= size;
            scanned += size;
            var buffer = new byte[size + carry.Length];
            stream.Position = position;
            stream.ReadExactly(buffer, 0, size);
            carry.CopyTo(buffer, size);

            // Keep the (possibly incomplete) first line for the next chunk unless we are at the file start.
            var firstNewline = position > 0 ? Array.IndexOf(buffer, (byte)'\n') : -1;
            var start = firstNewline >= 0 ? firstNewline + 1 : 0;
            carry = position > 0 ? (firstNewline >= 0 ? buffer[..start] : buffer) : [];
            if (position > 0 && firstNewline < 0)
            {
                continue;
            }

            var text = Encoding.UTF8.GetString(buffer, start, buffer.Length - start);
            var chunkLines = text.Replace("\r", "").Split('\n');
            if (chunkLines.Length > 0 && chunkLines[^1].Length == 0)
            {
                chunkLines = chunkLines[..^1];
            }

            for (var i = chunkLines.Length - 1; i >= 0 && result.Count < lines; i--)
            {
                if (regex == null || regex.IsMatch(chunkLines[i]))
                {
                    result.Add(chunkLines[i]);
                }
            }
        }

        result.Reverse();
        return result;
    }
}
