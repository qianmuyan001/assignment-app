using Windows.Security.Credentials;

namespace AssignmentNative.Services;

public sealed class CredentialVaultService
{
    private const string ResourcePrefix = "AssignmentNative:";
    private readonly PasswordVault _vault = new();

    public void Save(Uri pageUri, string username, string password)
    {
        var origin = ExactSecureOrigin(pageUri);
        Remove(pageUri);
        _vault.Add(new PasswordCredential(
            ResourcePrefix + origin,
            username,
            password));
    }

    public StoredCredential? Retrieve(Uri pageUri)
    {
        var origin = ExactSecureOrigin(pageUri);
        PasswordCredential? match = null;
        try
        {
            match = _vault
                .FindAllByResource(ResourcePrefix + origin)
                .FirstOrDefault();
        }
        catch
        {
            return null;
        }
        if (match is null)
        {
            return null;
        }
        match.RetrievePassword();
        return new StoredCredential(origin, match.UserName, match.Password);
    }

    public void Remove(Uri pageUri)
    {
        var origin = ExactSecureOrigin(pageUri);
        IReadOnlyList<PasswordCredential> existing;
        try
        {
            existing = _vault.FindAllByResource(ResourcePrefix + origin);
        }
        catch
        {
            return;
        }
        foreach (var credential in existing)
        {
            _vault.Remove(credential);
        }
    }

    public static string ExactSecureOrigin(Uri uri)
    {
        if (!uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "Saved credentials can only be used on an HTTPS page.");
        }
        var host = uri.IdnHost.ToLowerInvariant();
        if (uri.HostNameType == UriHostNameType.IPv6)
        {
            host = $"[{host}]";
        }
        var port = uri.IsDefaultPort ? "" : $":{uri.Port}";
        return $"https://{host}{port}";
    }
}
