using System.Security.Cryptography;

namespace AssignmentNative.Core;

public sealed record AttachmentReconciliationResult(
    int RemovedOrphanCount,
    IReadOnlyList<string> MissingPayloadNames);

public sealed class AttachmentFileStore
{
    private readonly string _attachmentsRoot;
    private readonly string _stagingRoot;

    public AttachmentFileStore(string databasePath)
    {
        var dataRoot = Path.GetDirectoryName(Path.GetFullPath(databasePath))
            ?? throw new ArgumentException("Database path has no parent directory.");
        _attachmentsRoot = Path.Combine(dataRoot, "attachments");
        _stagingRoot = Path.Combine(dataRoot, ".attachment-staging");
    }

    public AttachmentMetadataItem Import(
        string sourcePath,
        long assignmentId,
        string? mimeType,
        ITaskOrganizationRepository repository)
    {
        PrepareDirectories();
        var source = Path.GetFullPath(sourcePath);
        if (!File.Exists(source) || IsReparsePoint(source))
            throw new IOException("Attachment source must be a regular local file.");

        var fileName = Path.GetFileName(source);
        var uuid = SchemaV3Contract.NewUuid();
        var destination = PayloadPath(uuid);
        var staged = Path.Combine(_stagingRoot, $"{Guid.NewGuid():D}.partial");
        try
        {
            File.Copy(source, staged, overwrite: false);
            var info = new FileInfo(staged);
            var byteSize = info.Length;
            using var input = File.OpenRead(staged);
            var digest = Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant();
            File.Move(staged, destination);
            try
            {
                var metadata = repository.CreateAttachment(new AttachmentMetadataDraft(
                    assignmentId, fileName, mimeType, byteSize, digest, uuid));
                if (metadata.Uuid != uuid || metadata.RelativePath != $"attachments/{uuid}")
                    throw new IOException("Attachment payload and metadata identity do not match.");
                return metadata;
            }
            catch
            {
                File.Delete(destination);
                throw;
            }
        }
        catch
        {
            File.Delete(staged);
            throw;
        }
    }

    public string PayloadPath(AttachmentMetadataItem attachment)
    {
        var expected = $"attachments/{attachment.Uuid}";
        if (!string.Equals(attachment.RelativePath, expected, StringComparison.Ordinal))
            throw new IOException("Attachment storage path is invalid.");
        var path = PayloadPath(attachment.Uuid);
        if (!File.Exists(path))
            throw new FileNotFoundException(
                $"The file for '{attachment.FileName}' is missing from local storage.", path);
        if (IsReparsePoint(path))
            throw new IOException("Attachment payload must not be a symbolic link.");
        return path;
    }

    public void Delete(
        AttachmentMetadataItem attachment,
        ITaskOrganizationRepository repository)
    {
        PrepareDirectories();
        var source = PayloadPath(attachment.Uuid);
        var staged = Path.Combine(_stagingRoot, $"{attachment.Uuid}.deleted");
        var hadPayload = File.Exists(source);
        if (hadPayload)
        {
            if (IsReparsePoint(source))
                throw new IOException("Attachment payload must not be a symbolic link.");
            File.Delete(staged);
            File.Move(source, staged);
        }
        try
        {
            repository.DeleteAttachment(attachment.Id);
        }
        catch
        {
            if (hadPayload && File.Exists(staged)) File.Move(staged, source);
            throw;
        }
        if (hadPayload)
        {
            try { File.Delete(staged); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    public AttachmentReconciliationResult Reconcile(
        IReadOnlyList<AttachmentMetadataItem> activeAttachments)
    {
        PrepareDirectories();
        var active = activeAttachments.Select(item => item.Uuid)
            .ToHashSet(StringComparer.Ordinal);
        ReconcileStaging(active);
        var missing = activeAttachments
            .Where(item => !IsPayloadAvailable(item))
            .Select(item => item.FileName)
            .OrderBy(value => value, StringComparer.CurrentCulture)
            .ToList();
        var removed = 0;
        foreach (var path in Directory.EnumerateFiles(_attachmentsRoot))
        {
            var name = Path.GetFileName(path);
            if (!Guid.TryParseExact(name, "D", out _) || active.Contains(name) || IsReparsePoint(path))
                continue;
            File.Delete(path);
            removed++;
        }
        return new AttachmentReconciliationResult(removed, missing);
    }

    private bool IsPayloadAvailable(AttachmentMetadataItem attachment)
    {
        try
        {
            _ = PayloadPath(attachment);
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private void ReconcileStaging(IReadOnlySet<string> active)
    {
        foreach (var path in Directory.EnumerateFileSystemEntries(_stagingRoot))
        {
            var name = Path.GetFileName(path);
            if (name.EndsWith(".partial", StringComparison.Ordinal))
            {
                var attributes = File.GetAttributes(path);
                if (!attributes.HasFlag(FileAttributes.Directory)) File.Delete(path);
                continue;
            }
            if (!name.EndsWith(".deleted", StringComparison.Ordinal)) continue;
            var uuid = name[..^".deleted".Length];
            if (!Guid.TryParseExact(uuid, "D", out _)) continue;
            var tombstoneAttributes = File.GetAttributes(path);
            if (tombstoneAttributes.HasFlag(FileAttributes.Directory)) continue;
            if (tombstoneAttributes.HasFlag(FileAttributes.ReparsePoint))
            {
                File.Delete(path);
                continue;
            }
            var destination = PayloadPath(uuid);
            if (active.Contains(uuid) && !File.Exists(destination))
                File.Move(path, destination);
            else
                File.Delete(path);
        }
    }

    private string PayloadPath(string uuid)
    {
        _ = SchemaV3Contract.AttachmentRelativePath(uuid);
        var candidate = Path.GetFullPath(Path.Combine(_attachmentsRoot, uuid));
        if (!string.Equals(
                Path.GetDirectoryName(candidate),
                Path.GetFullPath(_attachmentsRoot),
                StringComparison.OrdinalIgnoreCase))
            throw new IOException("Attachment path escapes its storage root.");
        return candidate;
    }

    private void PrepareDirectories()
    {
        Directory.CreateDirectory(_attachmentsRoot);
        Directory.CreateDirectory(_stagingRoot);
        if (IsReparsePoint(_attachmentsRoot) || IsReparsePoint(_stagingRoot))
            throw new IOException("Attachment storage root is unsafe.");
    }

    private static bool IsReparsePoint(string path) =>
        (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
}
