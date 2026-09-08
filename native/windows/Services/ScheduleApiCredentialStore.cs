using Windows.Security.Credentials;

namespace AssignmentNative.Services;

public sealed class ScheduleApiCredentialStore
{
    private const string Resource = "AssignmentNative:ScheduleParsingApi";
    private const string UserName = "api-key";
    private readonly PasswordVault _vault = new();

    public void Save(string apiKey)
    {
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            throw new ArgumentException("The API key cannot be empty.", nameof(apiKey));
        }
        Remove();
        _vault.Add(new PasswordCredential(Resource, UserName, apiKey.Trim()));
    }

    public string? Retrieve()
    {
        PasswordCredential? credential;
        try
        {
            credential = _vault.FindAllByResource(Resource).FirstOrDefault();
        }
        catch
        {
            return null;
        }
        if (credential is null)
        {
            return null;
        }
        credential.RetrievePassword();
        return string.IsNullOrWhiteSpace(credential.Password)
            ? null
            : credential.Password;
    }

    public void Remove()
    {
        IReadOnlyList<PasswordCredential> existing;
        try
        {
            existing = _vault.FindAllByResource(Resource);
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
}
