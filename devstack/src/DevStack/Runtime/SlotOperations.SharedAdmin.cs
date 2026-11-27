using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     The developer's admin of the lane stacks (AB#9865): email (optional) and password from the shared credentials file.
///     Its <see cref="ToString"/> never names the password, so the value cannot reach a log or a message by formatting.
/// </summary>
internal sealed class SharedAdminCredentials(string file, string? email, string password)
{
    public string File { get; } = file;
    public string? Email { get; } = email;
    public string Password { get; } = password;

    public override string ToString() => $"shared admin credentials {File} ({Email ?? "no email"}, password not shown)";
}

/// <summary>Reading the shared admin file: the credentials, or the warning that says why it was not used (never its content).</summary>
internal sealed record SharedAdminRead(SharedAdminCredentials? Credentials, string? Warning);

public sealed partial class SlotOperations
{
    /// <summary>A shared credentials file larger than this is not read (a lane file has a few hundred bytes).</summary>
    internal const int SharedAdminFileMaxBytes = 64 * 1024;

    /// <summary>The identity's minimum password length (ASP.NET Identity's default; octo-identity-services sets no other).</summary>
    internal const int IdentityPasswordMinimumLength = 6;

    /// <summary>
    ///     The shared admin credentials file of the lane stacks: <c>&lt;base lane&gt;/.octo/admin-credentials.json</c> (the base
    ///     lane is <c>defaultCheckout</c>, in the usual layout <c>&lt;rootPath&gt;/branches/main</c>) - the same path the shared
    ///     stack keeps its own admin in. Null when the base lane is unknown.
    /// </summary>
    internal static string? SharedAdminFile(DevStackConfig config)
    {
        var root = ServicePlanner.RootPath(config);
        if (root.Length == 0 || config.DefaultCheckout.Length == 0)
        {
            return null;
        }

        try
        {
            return Path.Combine(ServicePlanner.ResolveFolder(config.DefaultCheckout, root, null, "base lane"), ".octo", CredentialsFileName);
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

    /// <summary>
    ///     The shared admin for the admin step of <paramref name="target"/>, or null (with a warning when the file is there
    ///     but not usable). Only a lane stack reads it; a target whose own files folder is the shared file's folder (the shared
    ///     stack) never does. A password that breaks the identity rules throws: the step fails, there is no fallback.
    /// </summary>
    private SharedAdminCredentials? SharedAdminFor(SlotTarget target, DevStackConfig config, List<string> warnings)
    {
        if (target.Environment == null || SharedAdminFile(config) is not { } file ||
            Common.PathScope.SamePath(Path.GetDirectoryName(file)!, target.FilesFolder))
        {
            return null;
        }

        var read = ReadSharedAdmin(file, sharedFileProtection ?? OwnerOnlyProblem);
        if (read.Warning != null)
        {
            warnings.Add(read.Warning);
            return null;
        }

        if (read.Credentials is { } credentials && PasswordRuleBroken(credentials.Password) is { } rule)
        {
            throw new InvalidOperationException(
                $"The password in the shared admin credentials file {file} breaks the identity password rule: {rule}. The admin was not created; " +
                "correct the password in that file (or remove the file for a generated one) and repeat the step.");
        }

        return read.Credentials;
    }

    /// <summary>
    ///     Reads the shared admin file. Missing file: no credentials, no warning (today's behaviour). Every other problem -
    ///     a link, not owner-only, too large, unreadable, not JSON, no password - is a warning that names the file and the
    ///     problem, never a value from it.
    /// </summary>
    internal static SharedAdminRead ReadSharedAdmin(string file, Func<string, string?> protection)
    {
        SharedAdminRead Warn(string problem) =>
            new(null, $"The shared admin credentials file {file} {problem}; the lane admin gets a generated password instead (README \"Setup of a lane stack\").");

        FileInfo info;
        try
        {
            info = new FileInfo(file);
            if (info.LinkTarget != null)
            {
                return Warn("is a symbolic link (only a regular file is used)");
            }

            if (!info.Exists)
            {
                return new SharedAdminRead(null, null);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return Warn("cannot be read");
        }

        if (protection(file) is { } unprotected)
        {
            return Warn(unprotected);
        }

        if (info.Length > SharedAdminFileMaxBytes)
        {
            return Warn($"is larger than {SharedAdminFileMaxBytes / 1024} KB");
        }

        JsonNode? root;
        try
        {
            root = JsonNode.Parse(System.IO.File.ReadAllText(file));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return Warn("cannot be read");
        }
        catch (JsonException)
        {
            // The parser's message is not passed on: it may quote the text around the error.
            return Warn("is not valid JSON");
        }

        if (root is not JsonObject json)
        {
            return Warn("is not a JSON object");
        }

        if (json["password"] is not JsonValue passwordValue || !passwordValue.TryGetValue<string>(out var password) || string.IsNullOrWhiteSpace(password))
        {
            return Warn("has no password (a non-empty string \"password\" is needed)");
        }

        string? email = null;
        switch (json["email"])
        {
            case null:
                break;
            case JsonValue emailValue when emailValue.TryGetValue<string>(out var text):
                email = string.IsNullOrWhiteSpace(text) ? null : text.Trim();
                break;
            default:
                return Warn("has an \"email\" that is not a string");
        }

        return new SharedAdminRead(new SharedAdminCredentials(file, email, password), null);
    }

    /// <summary>
    ///     Null when only the owner can use the file, else the problem. macOS/Linux: the mode has no group or other bits.
    ///     Windows: the file's owner is the current user (<see cref="WriteOwnerOnly"/> sets no ACL there).
    /// </summary>
    internal static string? OwnerOnlyProblem(string file)
    {
        try
        {
            if (OperatingSystem.IsWindows())
            {
                var owner = new FileInfo(file).GetAccessControl(AccessControlSections.Owner).GetOwner(typeof(SecurityIdentifier));
                var user = WindowsIdentity.GetCurrent().User;
                return owner != null && user != null && owner.Equals(user) ? null : "is not owned by the current user";
            }

            const UnixFileMode groupOrOther = UnixFileMode.GroupRead | UnixFileMode.GroupWrite | UnixFileMode.GroupExecute |
                                              UnixFileMode.OtherRead | UnixFileMode.OtherWrite | UnixFileMode.OtherExecute;
            var mode = System.IO.File.GetUnixFileMode(file);
            return (mode & groupOrOther) == 0 ? null : $"is not owner-only (mode {Convert.ToString((int)mode, 8)}; chmod 600 it)";
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException or PlatformNotSupportedException or IdentityNotMappedException)
        {
            return "cannot be checked for owner-only access";
        }
    }

    /// <summary>
    ///     The first identity password rule <paramref name="password"/> breaks, or null: the rules <see cref="GeneratePassword"/>
    ///     encodes (upper, lower, digit, symbol) and the identity's minimum length, checked as ASP.NET Identity checks them.
    ///     The answer names the rule only, never the password.
    /// </summary>
    internal static string? PasswordRuleBroken(string password)
    {
        static bool Upper(char c) => c is >= 'A' and <= 'Z';
        static bool Lower(char c) => c is >= 'a' and <= 'z';
        static bool Digit(char c) => c is >= '0' and <= '9';

        if (password.Length < IdentityPasswordMinimumLength)
        {
            return $"at least {IdentityPasswordMinimumLength} characters";
        }

        if (!password.Any(Upper))
        {
            return "at least one uppercase letter (A-Z)";
        }

        if (!password.Any(Lower))
        {
            return "at least one lowercase letter (a-z)";
        }

        if (!password.Any(Digit))
        {
            return "at least one digit (0-9)";
        }

        return password.Any(c => !Upper(c) && !Lower(c) && !Digit(c)) ? null : "at least one symbol (a character that is not a letter or digit)";
    }
}
