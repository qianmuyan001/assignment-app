using System.Diagnostics;

namespace AssignmentNative.Core;

internal sealed class DatabaseMigrationLock : IDisposable
{
    private readonly FileStream _stream;

    private DatabaseMigrationLock(FileStream stream)
    {
        _stream = stream;
    }

    public static DatabaseMigrationLock Acquire(
        string databasePath,
        TimeSpan? timeout = null)
    {
        var lockPath = Path.GetFullPath(databasePath) + ".migration.lock";
        var deadline = Stopwatch.StartNew();
        var maximumWait = timeout ?? TimeSpan.FromSeconds(15);
        Exception? lastError = null;

        while (deadline.Elapsed < maximumWait)
        {
            try
            {
                var stream = new FileStream(
                    lockPath,
                    FileMode.OpenOrCreate,
                    FileAccess.ReadWrite,
                    FileShare.None,
                    bufferSize: 1,
                    FileOptions.WriteThrough);
                return new DatabaseMigrationLock(stream);
            }
            catch (IOException error)
            {
                lastError = error;
                Thread.Sleep(40);
            }
            catch (UnauthorizedAccessException error)
            {
                lastError = error;
                Thread.Sleep(40);
            }
        }

        throw new TimeoutException(
            $"Timed out waiting for the database migration lock: {lockPath}",
            lastError);
    }

    public void Dispose() => _stream.Dispose();
}
