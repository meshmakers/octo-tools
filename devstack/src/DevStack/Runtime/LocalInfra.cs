using System.Net.Http.Headers;
using System.Text;
using Meshmakers.Octo.DevStack.Configuration;
using MongoDB.Driver;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     Where the daemon reaches the kind infrastructure from the host, for stack_verify and the data drop of a removed lane
///     stack. MongoDB authenticates with the admin user and password of the devstack configuration (environment
///     OCTO_SYSTEM__ADMINUSER / OCTO_SYSTEM__ADMINUSERPASSWORD, never printed). RabbitMQ management and CrateDB HTTP are not
///     named by the configuration (the services use their built-in defaults), so they are the documented local defaults of
///     octo-tools' kind cluster: the management API on localhost:15672 with guest/guest (infrastructure/rabbitmq/definitions.json)
///     and CrateDB on the host port localhost:4301 (no authentication in the kind cluster).
/// </summary>
public static class LocalInfra
{
    public const string MongoUrl = "mongodb://localhost:27017/?directConnection=true";
    public const string RabbitManagementUrl = "http://localhost:15672/";
    public const string CrateSqlUrl = "http://localhost:4301/_sql";

    /// <summary>The local default user of the broker (octo-tools infrastructure/rabbitmq/definitions.json), not a secret.</summary>
    private const string RabbitUser = "guest";

    private const string RabbitPassword = "guest";

    /// <summary>
    ///     Straight to the host-local stores: no proxy (a configured HTTP proxy would see the broker's credential and could answer
    ///     in its place) and no redirects (a DELETE must not land anywhere else; a redirect is reported as the failed status it is).
    /// </summary>
    internal static readonly HttpClient Http = new(Handler()) { Timeout = TimeSpan.FromSeconds(10) };

    internal static SocketsHttpHandler Handler() => new() { UseProxy = false, AllowAutoRedirect = false };

    public static MongoClient Mongo(DevStackConfig config)
    {
        var user = config.Environment.GetValueOrDefault("OCTO_SYSTEM__ADMINUSER") ?? SlotCleanup.MongoAdminUser;
        var password = config.Environment.GetValueOrDefault("OCTO_SYSTEM__ADMINUSERPASSWORD");
        var settings = MongoClientSettings.FromConnectionString(MongoUrl);
        if (!string.IsNullOrEmpty(password))
        {
            settings.Credential = MongoCredential.CreateCredential("admin", user, password);
        }

        settings.ServerSelectionTimeout = TimeSpan.FromSeconds(5);
        return new MongoClient(settings);
    }

    /// <summary>A request to the RabbitMQ management API (<paramref name="path"/> relative to it, e.g. "api/queues").</summary>
    public static HttpRequestMessage RabbitRequest(HttpMethod method, string path)
    {
        var request = new HttpRequestMessage(method, RabbitManagementUrl + path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.ASCII.GetBytes($"{RabbitUser}:{RabbitPassword}")));
        return request;
    }
}
