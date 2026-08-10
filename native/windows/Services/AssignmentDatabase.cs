using AssignmentNative.Core;
using CoreCandidate = AssignmentNative.Core.AssignmentCandidate;
using CoreDatabase = AssignmentNative.Core.AssignmentDatabase;
using CoreItem = AssignmentNative.Core.AssignmentItem;

namespace AssignmentNative.Services;

/// <summary>
/// Compatibility facade for the original WinUI namespace. New non-UI code should
/// reference AssignmentNative.Core.AssignmentDatabase directly.
/// </summary>
public sealed class AssignmentDatabase
{
    private readonly CoreDatabase _database;

    public string DatabasePath => _database.DatabasePath;
    public string? LastBackupPath => _database.LastBackupPath;
    public int SchemaVersion => _database.SchemaVersion;
    public CoreDatabase Core => _database;

    public AssignmentDatabase(
        string? path = null,
        AssignmentDatabaseOptions? options = null)
    {
        _database = new CoreDatabase(path, options);
    }

    public IReadOnlyList<AssignmentItem> FetchAssignments() =>
        Map(_database.FetchAssignments());

    public IReadOnlyList<AssignmentItem> FetchAssignments(AssignmentQuery query) =>
        Map(_database.FetchAssignments(query));

    public IReadOnlyList<CoreItem> FetchCoreAssignments(AssignmentQuery? query = null) =>
        _database.FetchAssignments(query);

    public AssignmentItem? Get(long id) => _database.Get(id) is { } item
        ? AssignmentItem.FromCore(item)
        : null;

    public long Add(AssignmentDraft draft) => _database.Add(draft);

    public void Update(long id, AssignmentDraft draft) => _database.Update(id, draft);

    public void UpdateStatus(long id, string status) => _database.UpdateStatus(id, status);

    public void Delete(long id) => _database.Delete(id);

    public int InsertCandidates(
        IEnumerable<AssignmentCandidate> candidates,
        string fallbackCourse,
        string sourceName,
        string sourceUrl) => _database.InsertCandidates(
            candidates,
            fallbackCourse,
            sourceName,
            sourceUrl);

    public int InsertCandidates(
        IEnumerable<CoreCandidate> candidates,
        string fallbackCourse,
        string sourceName,
        string sourceUrl) => _database.InsertCandidates(
            candidates,
            fallbackCourse,
            sourceName,
            sourceUrl);

    public string CreateBackup(string? destinationPath = null) =>
        _database.CreateBackup(destinationPath);

    public void RestoreBackup(string backupPath) => _database.RestoreBackup(backupPath);

    public MigrationResult MigrateToLatest() => _database.MigrateToLatest();

    private static IReadOnlyList<AssignmentItem> Map(IEnumerable<CoreItem> items) =>
        items.Select(AssignmentItem.FromCore).ToList();
}
