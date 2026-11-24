using System.Text.RegularExpressions;

namespace Meshmakers.Octo.DevStack.Configuration;

/// <summary>Expands ${name} and ${env:NAME} placeholders; an unknown name is an error, not an empty string.</summary>
public static partial class TemplateExpander
{
    [GeneratedRegex(@"\$\{([A-Za-z0-9_.:\-]+)\}")]
    private static partial Regex PlaceholderRegex();

    public static string Expand(string template, IReadOnlyDictionary<string, string> variables, Func<string, string?>? environment = null)
    {
        environment ??= System.Environment.GetEnvironmentVariable;
        return PlaceholderRegex().Replace(template, match =>
        {
            var name = match.Groups[1].Value;
            if (name.StartsWith("env:", StringComparison.Ordinal))
            {
                return environment(name[4..]) ?? "";
            }

            if (variables.TryGetValue(name, out var value))
            {
                return value;
            }

            throw new InvalidOperationException(
                $"Unknown placeholder '${{{name}}}' in '{template}'. Known: {string.Join(", ", variables.Keys.Order())}, env:<NAME>.");
        });
    }

    /// <summary>Expands a leading ~ to the home folder and returns a full path.</summary>
    public static string ExpandPath(string path)
    {
        if (path == "~" || path.StartsWith("~/", StringComparison.Ordinal))
        {
            path = System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile) + path[1..];
        }

        return Path.GetFullPath(path);
    }
}
