using System.Text.RegularExpressions;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>Masks values of secret-looking variables, arguments and URI credentials in everything a tool returns or a profile stores.</summary>
public static partial class SecretMask
{
    [GeneratedRegex("(PASSWORD|SECRET|KEY|TOKEN|CREDENTIAL|LICENSE|CONNECTIONSTRING|CONNSTR|PWD|PASSPHRASE|PRIVATE|CERT)", RegexOptions.IgnoreCase)]
    private static partial Regex SecretNameRegex();

    // scheme://user:password@host (also user@ only): the userinfo is masked.
    [GeneratedRegex(@"(?<scheme>[A-Za-z][A-Za-z0-9+.\-]*://)(?<userinfo>[^/@\s]+)@")]
    private static partial Regex UserInfoRegex();

    public const string Masked = "***";

    public static bool IsSecretName(string name) => SecretNameRegex().IsMatch(name);

    public static bool HasUriCredentials(string value) => UserInfoRegex().IsMatch(value);

    /// <summary>A value with the userinfo of URIs masked (mongodb://user:pw@host -> mongodb://***@host).</summary>
    public static string MaskValue(string value) => UserInfoRegex().Replace(value, m => m.Groups["scheme"].Value + Masked + "@");

    public static string? Mask(string key, string? value) => value == null ? null : IsSecretValue(key, value) ? Masked : MaskValue(value);

    /// <summary>
    ///     Whether the value of an environment variable is masked. The last key segment decides (OCTO_BOT__SECRETSWEEP__BACKUPSTORAGEPATH
    ///     is a path setting of the secret sweep, not a secret): a secret-looking last segment is always masked; a secret-looking word
    ///     only in an earlier segment is masked too unless the value is a plain path (safe-biased).
    /// </summary>
    public static bool IsSecretValue(string key, string value)
    {
        var separator = key.LastIndexOf("__", StringComparison.Ordinal);
        var last = separator < 0 ? key : key[(separator + 2)..];
        if (SecretNameRegex().IsMatch(last))
        {
            return true;
        }

        return SecretNameRegex().IsMatch(key) && !IsPlainPath(value);
    }

    private static bool IsPlainPath(string value) =>
        !value.Contains(' ') && (value.StartsWith('/') || value.StartsWith("~/", StringComparison.Ordinal) || value.StartsWith("./", StringComparison.Ordinal) ||
                                 (value.Length > 2 && char.IsLetter(value[0]) && value[1] == ':' && value[2] is '\\' or '/'));

    public static Dictionary<string, string> Mask(IEnumerable<KeyValuePair<string, string>> env) =>
        env.ToDictionary(kv => kv.Key, kv => Mask(kv.Key, kv.Value)!);

    public static Dictionary<string, string?> MaskNullable(IEnumerable<KeyValuePair<string, string?>> env) =>
        env.ToDictionary(kv => kv.Key, kv => Mask(kv.Key, kv.Value));

    /// <summary>
    ///     Arguments for display: the value of a secret-looking "--Key=value" or "--Key value" becomes ***, URI credentials are
    ///     masked. Same rules as <see cref="FilterArgs"/>, but the arguments stay in place.
    /// </summary>
    public static List<string> MaskArgs(IReadOnlyList<string> args)
    {
        var result = new List<string>(args.Count);
        for (var i = 0; i < args.Count; i++)
        {
            var arg = args[i];
            if (arg.StartsWith('-'))
            {
                var equals = arg.IndexOf('=');
                var name = (equals < 0 ? arg : arg[..equals]).TrimStart('-', '/');
                if (IsSecretName(name))
                {
                    if (equals >= 0)
                    {
                        result.Add(arg[..(equals + 1)] + Masked);
                        continue;
                    }

                    result.Add(arg);
                    if (i + 1 < args.Count && !args[i + 1].StartsWith('-'))
                    {
                        result.Add(Masked);
                        i++;
                    }

                    continue;
                }
            }

            result.Add(MaskValue(arg));
        }

        return result;
    }

    /// <summary>A command line (as ps prints it, split at blanks) with <see cref="MaskArgs"/> applied.</summary>
    public static string MaskCommandLine(string commandLine)
    {
        var tokens = commandLine.Split(' ');
        var masked = MaskArgs(tokens.Where(t => t.Length > 0).ToList());
        // Re-join over the original token positions so runs of blanks stay as they were.
        var result = new List<string>(tokens.Length);
        var next = 0;
        foreach (var token in tokens)
        {
            result.Add(token.Length == 0 ? token : masked[next++]);
        }

        return string.Join(' ', result);
    }

    /// <summary>
    ///     Command-line arguments without secret values: "--Key=value" and "--Key value" whose key looks secret, and any
    ///     argument holding URI credentials, are dropped; what was dropped is added to <paramref name="skipped"/> (key only).
    /// </summary>
    public static List<string> FilterArgs(IReadOnlyList<string> args, List<string> skipped)
    {
        var kept = new List<string>();
        for (var i = 0; i < args.Count; i++)
        {
            var arg = args[i];
            if (arg.StartsWith('-'))
            {
                var equals = arg.IndexOf('=');
                var name = (equals < 0 ? arg : arg[..equals]).TrimStart('-', '/');
                if (IsSecretName(name))
                {
                    skipped.Add($"argument {(equals < 0 ? arg : arg[..equals])}");
                    if (equals < 0 && i + 1 < args.Count && !args[i + 1].StartsWith('-'))
                    {
                        i++; // "--Key value": the value goes too
                    }

                    continue;
                }
            }

            if (HasUriCredentials(arg))
            {
                var equals = arg.IndexOf('=');
                skipped.Add(arg.StartsWith('-') && equals > 0 ? $"argument {arg[..equals]} (URI credentials)" : "an argument with URI credentials");
                continue;
            }

            kept.Add(arg);
        }

        return kept;
    }
}
