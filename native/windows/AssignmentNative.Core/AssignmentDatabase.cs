using System.Globalization;
using Microsoft.Data.Sqlite;

namespace AssignmentNative.Core;

public sealed record MigrationResult(
    int PreviousVersion,
    int CurrentVersion,
    bool Migrated,
    string? BackupPath);

public sealed class DatabaseMigrationException : Exception
{
    public string DatabasePath { get; }
    public string? BackupPath { get; }

    public DatabaseMigrationException(
        string message,
        string databasePath,
        string? backupPath,
        Exception innerException)
        : base(message, innerException)
    {
        DatabasePath = databasePath;
        BackupPath = backupPath;
    }
}

public enum MigrationCheckpoint
{
    BeforeSchemaChanges,
    BeforeCommit,
    AfterRollbackBeforeVerification,
    BeforeRollbackEvidenceCapture,
    AfterRecoveryFingerprintBeforeRestore
}

public sealed class AssignmentDatabaseOptions
{
    /// <summary>
    /// Optional deterministic test seam. Production callers should leave this null.
    /// Throwing from a checkpoint exercises rollback and backup restoration.
    /// </summary>
    public Action<MigrationCheckpoint>? OnMigrationCheckpoint { get; init; }
    public string? DatabaseInstanceUuid { get; init; }

    /// <summary>
    /// Test-only seam that commits the captured failed transaction so recovery
    /// can prove it restores only a state whose complete logical fingerprint
    /// was observed from this migration attempt. Never enable in production.
    /// </summary>
    public bool PreserveFailedMigrationStateForRecoveryTest { get; init; }
}

public sealed class AssignmentDatabase
{
    public const int CurrentSchemaVersion = 3;

    private readonly string _connectionString;
    private readonly AssignmentDatabaseOptions _options;

    public string DatabasePath { get; }
    public string? LastBackupPath { get; private set; }

    public int SchemaVersion
    {
        get
        {
            using var connection = Open();
            return ReadSchemaVersion(connection);
        }
    }

    public AssignmentDatabase(
        string? path = null,
        AssignmentDatabaseOptions? options = null)
    {
        DatabasePath = Path.GetFullPath(path ?? FindDatabasePath());
        var directory = Path.GetDirectoryName(DatabasePath)
            ?? throw new InvalidOperationException("Database path has no parent directory.");
        Directory.CreateDirectory(directory);
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared,
            Pooling = false
        }.ToString();
        _options = options ?? new AssignmentDatabaseOptions();
        MigrateToLatest();
    }

    public IReadOnlyList<AssignmentItem> FetchAssignments(AssignmentQuery? query = null)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT id, uuid, course_name, title, due_date, description, link, status,
                   priority, source_name, source_type, source_file, source_url,
                   created_at, updated_at, course_id, project_id, completed_at,
                   progress_percent, all_day, timezone_id, deleted_at
            FROM assignments
            WHERE deleted_at IS NULL
            """;
        using var reader = command.ExecuteReader();
        var result = new List<AssignmentItem>();
        while (reader.Read())
        {
            result.Add(ReadAssignment(reader));
        }

        return TaskRules.Apply(result, query);
    }

    public AssignmentItem? Get(long id)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT id, uuid, course_name, title, due_date, description, link, status,
                   priority, source_name, source_type, source_file, source_url,
                   created_at, updated_at, course_id, project_id, completed_at,
                   progress_percent, all_day, timezone_id, deleted_at
            FROM assignments
            WHERE id = $id AND deleted_at IS NULL
            LIMIT 1
            """;
        command.Parameters.AddWithValue("$id", id);
        using var reader = command.ExecuteReader();
        return reader.Read() ? ReadAssignment(reader) : null;
    }

    public long Add(AssignmentDraft draft)
    {
        var value = NormalizeDraft(draft);
        using var migrationGate = DatabaseMigrationLock.Acquire(DatabasePath);
        using var connection = Open();
        using var transaction = connection.BeginTransaction(deferred: false);
        var courseId = ResolveCourseId(connection, transaction, value.CourseName, value.CourseId);
        ValidateProject(connection, transaction, value.ProjectId, courseId);
        var timestamp = SchemaV3Contract.CanonicalUtcNow();
        var state = InitialState(value.Status, value.ProgressPercent, timestamp);
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO assignments (
                uuid, course_name, title, due_date, description, link, status, priority,
                source_name, source_type, source_file, source_url,
                created_at, updated_at, course_id, project_id, completed_at,
                progress_percent, all_day, timezone_id, deleted_at
            ) VALUES (
                $uuid, $course, $title, $due, $description, $link, $status, $priority,
                $sourceName, $sourceType, $sourceFile, $sourceUrl,
                $created, $updated, $courseId, $projectId, $completed,
                $progress, $allDay, $timezone, NULL
            );
            SELECT last_insert_rowid();
            """;
        BindDraft(command, value);
        command.Parameters.AddWithValue("$uuid", SchemaV3Contract.NewUuid());
        command.Parameters.AddWithValue("$created", timestamp);
        command.Parameters.AddWithValue("$updated", timestamp);
        command.Parameters.AddWithValue("$courseId", (object?)courseId ?? DBNull.Value);
        command.Parameters.AddWithValue("$projectId", (object?)value.ProjectId ?? DBNull.Value);
        command.Parameters.AddWithValue("$completed", (object?)state.CompletedAt ?? DBNull.Value);
        command.Parameters.AddWithValue("$progress", state.Progress);
        command.Parameters.AddWithValue("$allDay", value.AllDay ? 1 : 0);
        command.Parameters.AddWithValue("$timezone", (object?)value.TimezoneId ?? DBNull.Value);
        var id = Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
        transaction.Commit();
        return id;
    }

    public void Update(long id, AssignmentDraft draft)
    {
        var value = NormalizeDraft(draft);
        using var migrationGate = DatabaseMigrationLock.Acquire(DatabasePath);
        using var connection = Open();
        using var transaction = connection.BeginTransaction(deferred: false);
        var currentRelationship = ReadCurrentRelationship(connection, transaction, id);
        var preservesCourse = value.CourseId == currentRelationship.CourseId &&
            string.Equals(
                value.CourseName,
                currentRelationship.CourseName,
                StringComparison.Ordinal);
        long? courseId = preservesCourse
            ? currentRelationship.CourseId
            : ResolveCourseId(connection, transaction, value.CourseName, value.CourseId);
        var preservesProject = value.ProjectId == currentRelationship.ProjectId &&
            preservesCourse;
        if (!preservesProject)
            ValidateProject(connection, transaction, value.ProjectId, courseId);
        var timestamp = SchemaV3Contract.CanonicalUtcNow();
        var state = TaskStatePersistence.UpdateParent(
            connection,
            transaction,
            id,
            value.Status,
            value.ProgressPercent,
            timestamp);
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            UPDATE assignments
            SET course_name = $course,
                title = $title,
                due_date = $due,
                description = $description,
                link = $link,
                status = $status,
                priority = $priority,
                source_name = $sourceName,
                source_type = $sourceType,
                source_file = $sourceFile,
                source_url = $sourceUrl,
                updated_at = $updated,
                course_id = $courseId,
                project_id = $projectId,
                completed_at = $completed,
                progress_percent = $progress,
                all_day = $allDay,
                timezone_id = $timezone
            WHERE id = $id AND deleted_at IS NULL
            """;
        BindDraft(command, value);
        command.Parameters.AddWithValue("$updated", timestamp);
        command.Parameters.AddWithValue("$courseId", (object?)courseId ?? DBNull.Value);
        command.Parameters.AddWithValue("$projectId", (object?)value.ProjectId ?? DBNull.Value);
        command.Parameters.AddWithValue("$completed", (object?)state.CompletedAt ?? DBNull.Value);
        command.Parameters.AddWithValue("$progress", state.Progress);
        command.Parameters.AddWithValue("$allDay", value.AllDay ? 1 : 0);
        command.Parameters.AddWithValue("$timezone", (object?)value.TimezoneId ?? DBNull.Value);
        command.Parameters.AddWithValue("$id", id);
        EnsureChanged(command.ExecuteNonQuery(), id);
        transaction.Commit();
    }

    public void UpdateStatus(long id, string status)
    {
        using var migrationGate = DatabaseMigrationLock.Acquire(DatabasePath);
        using var connection = Open();
        using var transaction = connection.BeginTransaction(deferred: false);
        var timestamp = SchemaV3Contract.CanonicalUtcNow();
        var state = TaskStatePersistence.UpdateParent(
            connection,
            transaction,
            id,
            TaskStatuses.ToDatabaseStatus(status),
            requestedProgress: null,
            timestamp);
        TaskStatePersistence.WriteParent(connection, transaction, id, state, timestamp);
        transaction.Commit();
    }

    public void UpdateProgress(long id, int progressPercent)
    {
        if (progressPercent is < 0 or > 100)
            throw new ArgumentOutOfRangeException(nameof(progressPercent));
        using var migrationGate = DatabaseMigrationLock.Acquire(DatabasePath);
        using var connection = Open();
        using var transaction = connection.BeginTransaction(deferred: false);
        var timestamp = SchemaV3Contract.CanonicalUtcNow();
        var inferredStatus = progressPercent switch
        {
            100 => "completed",
            > 0 => "in_progress",
            _ => "not_started"
        };
        var state = TaskStatePersistence.UpdateParent(
            connection,
            transaction,
            id,
            inferredStatus,
            progressPercent,
            timestamp);
        TaskStatePersistence.WriteParent(connection, transaction, id, state, timestamp);
        transaction.Commit();
    }

    public void Delete(long id)
    {
        using var migrationGate = DatabaseMigrationLock.Acquire(DatabasePath);
        using var connection = Open();
        using var transaction = connection.BeginTransaction(deferred: false);
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        var timestamp = SchemaV3Contract.CanonicalUtcNow();
        command.CommandText = "UPDATE assignments SET deleted_at=$now, updated_at=$now WHERE id=$id AND deleted_at IS NULL";
        command.Parameters.AddWithValue("$now", timestamp);
        command.Parameters.AddWithValue("$id", id);
        EnsureChanged(command.ExecuteNonQuery(), id);
        using var reminders = connection.CreateCommand();
        reminders.Transaction = transaction;
        reminders.CommandText = "UPDATE reminders SET is_enabled=0, updated_at=$now WHERE assignment_id=$id AND deleted_at IS NULL";
        reminders.Parameters.AddWithValue("$now", timestamp);
        reminders.Parameters.AddWithValue("$id", id);
        reminders.ExecuteNonQuery();
        transaction.Commit();
    }

    public AssignmentItem Restore(long id)
    {
        using var migrationGate = DatabaseMigrationLock.Acquire(DatabasePath);
        using var connection = Open();
        using var transaction = connection.BeginTransaction(deferred: false);
        var timestamp = SchemaV3Contract.CanonicalUtcNow();
        using (var command = connection.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandText = "UPDATE assignments SET deleted_at=NULL, updated_at=$now WHERE id=$id AND deleted_at IS NOT NULL";
            command.Parameters.AddWithValue("$now", timestamp);
            command.Parameters.AddWithValue("$id", id);
            EnsureChanged(command.ExecuteNonQuery(), id);
        }
        TaskStatePersistence.RecalculateParent(connection, transaction, id, timestamp, resetWhenEmpty: false);
        transaction.Commit();
        return Get(id) ?? throw new KeyNotFoundException($"Assignment {id} was not found.");
    }

    public int InsertCandidates(
        IEnumerable<AssignmentCandidate> candidates,
        string fallbackCourse,
        string sourceName,
        string sourceUrl)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        using var migrationGate = DatabaseMigrationLock.Acquire(DatabasePath);
        using var connection = Open();
        using var transaction = connection.BeginTransaction(deferred: false);
        var inserted = 0;
        foreach (var candidate in candidates.Take(200))
        {
            var title = Clean(candidate.Title) ?? "Untitled";
            var course = Clean(candidate.CourseName) ?? Clean(fallbackCourse) ?? "Imported";
            var dueDate = CandidateDueDate(candidate.DueDate, candidate.DueTime);
            var resolvedSource = Clean(candidate.SourceName) ?? Clean(sourceName);
            var resolvedUrl = Clean(candidate.SourceUrl) ?? Clean(sourceUrl);
            var priority = Clean(candidate.Priority) is { } candidatePriority
                ? TaskPriorities.Normalize(candidatePriority)
                : TaskPriorities.Medium;

            using var duplicate = connection.CreateCommand();
            duplicate.Transaction = transaction;
            duplicate.CommandText =
                """
                SELECT 1 FROM assignments
                WHERE lower(course_name) = lower($course)
                  AND lower(title) = lower($title)
                  AND ifnull(due_date, '') = ifnull($due, '')
                  AND ifnull(source_url, '') = ifnull($url, '')
                LIMIT 1
                """;
            duplicate.Parameters.AddWithValue("$course", course);
            duplicate.Parameters.AddWithValue("$title", title);
            duplicate.Parameters.AddWithValue("$due", (object?)dueDate ?? DBNull.Value);
            duplicate.Parameters.AddWithValue("$url", (object?)resolvedUrl ?? DBNull.Value);
            if (duplicate.ExecuteScalar() is not null)
            {
                continue;
            }

            using var insert = connection.CreateCommand();
            insert.Transaction = transaction;
            var courseId = ResolveCourseId(connection, transaction, course, preferredId: null);
            var timestamp = SchemaV3Contract.CanonicalUtcNow();
            insert.CommandText =
                """
                INSERT INTO assignments (
                    uuid, course_name, title, due_date, description, link, status, priority,
                    source_name, source_type, source_file, source_url,
                    created_at, updated_at, course_id, project_id, completed_at,
                    progress_percent, all_day, timezone_id, deleted_at
                ) VALUES (
                    $uuid, $course, $title, $due, $description, $url, 'not_started', $priority,
                    $source, 'secure_web', NULL, $url,
                    $now, $now, $courseId, NULL, NULL, 0, 0, NULL, NULL
                )
                """;
            insert.Parameters.AddWithValue("$uuid", SchemaV3Contract.NewUuid());
            insert.Parameters.AddWithValue("$course", course);
            insert.Parameters.AddWithValue("$title", title);
            insert.Parameters.AddWithValue("$due", (object?)dueDate ?? DBNull.Value);
            insert.Parameters.AddWithValue(
                "$description",
                (object?)Clean(candidate.Description) ?? DBNull.Value);
            insert.Parameters.AddWithValue("$url", (object?)resolvedUrl ?? DBNull.Value);
            insert.Parameters.AddWithValue("$priority", priority);
            insert.Parameters.AddWithValue("$source", (object?)resolvedSource ?? DBNull.Value);
            insert.Parameters.AddWithValue("$now", timestamp);
            insert.Parameters.AddWithValue("$courseId", courseId);
            insert.ExecuteNonQuery();
            inserted++;
        }
        transaction.Commit();
        return inserted;
    }

    public string CreateBackup(string? destinationPath = null)
    {
        using var migrationGate = DatabaseMigrationLock.Acquire(DatabasePath);
        return CreateBackupLocked(destinationPath);
    }

    private string CreateBackupLocked(string? destinationPath = null)
    {
        if (!File.Exists(DatabasePath))
        {
            throw new FileNotFoundException("The database does not exist.", DatabasePath);
        }

        var backupPath = Path.GetFullPath(destinationPath ?? DefaultBackupPath());
        if (string.Equals(backupPath, DatabasePath, StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("Backup path must differ from the database path.");
        }

        Directory.CreateDirectory(
            Path.GetDirectoryName(backupPath)
                ?? throw new InvalidOperationException("Backup path has no parent directory."));

        if (File.Exists(backupPath))
        {
            throw new IOException($"Refusing to overwrite an existing backup: {backupPath}");
        }

        var partialPath = backupPath + $".partial-{Guid.NewGuid():N}";
        var destinationConnectionString = new SqliteConnectionStringBuilder
        {
            DataSource = partialPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false
        }.ToString();
        try
        {
            using var source = OpenReadOnly();
            using (var destination = new SqliteConnection(destinationConnectionString))
            {
                destination.Open();
                source.BackupDatabase(destination);
                using var validate = destination.CreateCommand();
                validate.CommandText = "PRAGMA quick_check";
                if (!string.Equals(
                        Convert.ToString(validate.ExecuteScalar(), CultureInfo.InvariantCulture),
                        "ok",
                        StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("The online backup failed quick_check.");
                }
            }
            File.Move(partialPath, backupPath);
            LastBackupPath = backupPath;
            return backupPath;
        }
        finally
        {
            if (File.Exists(partialPath)) File.Delete(partialPath);
        }
    }

    public void RestoreBackup(string backupPath)
    {
        using var migrationGate = DatabaseMigrationLock.Acquire(DatabasePath);
        RestoreBackupLocked(backupPath);
    }

    private void RestoreBackupLocked(
        string backupPath,
        string? expectedDestinationFingerprint = null)
    {
        var resolvedBackup = Path.GetFullPath(backupPath);
        if (!File.Exists(resolvedBackup))
        {
            throw new FileNotFoundException("The database backup does not exist.", resolvedBackup);
        }
        if (string.Equals(resolvedBackup, DatabasePath, StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("Backup path must differ from the database path.");
        }

        SqliteConnection.ClearAllPools();
        var backupConnectionString = new SqliteConnectionStringBuilder
        {
            DataSource = resolvedBackup,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false
        }.ToString();
        using var backup = new SqliteConnection(backupConnectionString);
        using var destination = new SqliteConnection(_connectionString);
        backup.Open();
        destination.Open();
        using (var checkpoint = destination.CreateCommand())
        {
            checkpoint.CommandText = "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;";
            checkpoint.ExecuteNonQuery();
        }
        if (expectedDestinationFingerprint is not null)
        {
            using (var locking = destination.CreateCommand())
            {
                locking.CommandText = "PRAGMA locking_mode=EXCLUSIVE";
                var mode = Convert.ToString(
                    locking.ExecuteScalar(),
                    CultureInfo.InvariantCulture);
                if (!string.Equals(mode, "exclusive", StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException(
                        "SQLite did not grant exclusive recovery locking; " +
                        "refusing to restore the migration backup.");
                }
            }
            using (var begin = destination.CreateCommand())
            {
                begin.CommandText = "BEGIN EXCLUSIVE";
                begin.ExecuteNonQuery();
            }
            try
            {
                if (DatabaseLogicalFingerprint.Compute(destination) !=
                    expectedDestinationFingerprint)
                {
                    throw new InvalidDataException(
                        "The live database changed while recovery was preparing; " +
                        "refusing to overwrite it with the migration backup.");
                }
                using var commit = destination.CreateCommand();
                commit.CommandText = "COMMIT";
                commit.ExecuteNonQuery();

                // SQLite EXCLUSIVE locking mode deliberately retains the
                // exclusive file lock after COMMIT until this connection
                // closes. The Online Backup below therefore cannot race an
                // external writer between evidence validation and overwrite.
                using var verifyLock = destination.CreateCommand();
                verifyLock.CommandText = "PRAGMA locking_mode";
                var retainedMode = Convert.ToString(
                    verifyLock.ExecuteScalar(),
                    CultureInfo.InvariantCulture);
                if (!string.Equals(
                        retainedMode,
                        "exclusive",
                        StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException(
                        "SQLite did not retain the exclusive recovery lock; " +
                        "refusing to restore the migration backup.");
                }
                _options.OnMigrationCheckpoint?.Invoke(
                    MigrationCheckpoint.AfterRecoveryFingerprintBeforeRestore);
            }
            catch
            {
                try
                {
                    using var rollback = destination.CreateCommand();
                    rollback.CommandText = "ROLLBACK";
                    rollback.ExecuteNonQuery();
                }
                catch { }
                throw;
            }
        }
        backup.BackupDatabase(destination);
        using var command = destination.CreateCommand();
        command.CommandText = "PRAGMA quick_check";
        var result = Convert.ToString(command.ExecuteScalar(), CultureInfo.InvariantCulture);
        if (!string.Equals(result, "ok", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException($"Restored database failed quick_check: {result}");
        }
    }

    public MigrationResult MigrateToLatest()
    {
        using var migrationLock = DatabaseMigrationLock.Acquire(DatabasePath);
        return MigrateToLatestLocked();
    }

    private MigrationResult MigrateToLatestLocked()
    {
        int previousVersion = 0;
        bool tableExists = false;
        long originalRowCount = 0;
        IReadOnlyList<long> originalIds = [];
        string originalFingerprint = "";
        string? backupPath = null;
        Exception? migrationError = null;
        string? failedMigrationFingerprint = null;

        using (var connection = Open())
        using (var transaction = connection.BeginTransaction(deferred: false))
        {
            previousVersion = ReadSchemaVersion(connection, transaction);
            if (previousVersion > CurrentSchemaVersion)
            {
                throw new NotSupportedException(
                    $"Database schema v{previousVersion} is newer than supported v{CurrentSchemaVersion}.");
            }
            tableExists = TableExists(connection, "assignments", transaction);
            if (tableExists)
            {
                ValidateKnownStatuses(connection, transaction);
                ValidateKnownPriorities(connection, transaction);
                ValidateDueDates(connection, transaction);
            }
            originalRowCount = tableExists ? CountRows(connection, transaction) : 0;
            originalIds = tableExists
                ? ReadAssignmentIds(
                    connection,
                    transaction,
                    useRowId: !ReadColumns(connection, transaction).ContainsKey("id"))
                : [];
            originalFingerprint = DatabaseLogicalFingerprint.Compute(connection, transaction);
            if (previousVersion == CurrentSchemaVersion)
            {
                SchemaV3Contract.Validate(connection, transaction);
                transaction.Commit();
                return new MigrationResult(
                    previousVersion,
                    CurrentSchemaVersion,
                    Migrated: false,
                    BackupPath: null);
            }
            if (tableExists) backupPath = CreateBackupLocked();

            try
            {
                ApplyMigration(
                    connection,
                    transaction,
                    tableExists,
                    originalRowCount,
                    originalIds);
                transaction.Commit();
                return new MigrationResult(
                    previousVersion,
                    CurrentSchemaVersion,
                    Migrated: true,
                    BackupPath: backupPath);
            }
            catch (Exception error)
            {
                migrationError = error;
                try
                {
                    failedMigrationFingerprint = DatabaseLogicalFingerprint.Compute(
                        connection,
                        transaction);
                }
                catch { }
                try
                {
                    if (_options.PreserveFailedMigrationStateForRecoveryTest &&
                        failedMigrationFingerprint is not null)
                    {
                        transaction.Commit();
                    }
                    else
                    {
                        transaction.Rollback();
                    }
                }
                catch { }
            }
        }

        _options.OnMigrationCheckpoint?.Invoke(MigrationCheckpoint.AfterRollbackBeforeVerification);
        Exception recoveryError = migrationError!;
        var recovered = false;
        var concurrentChangePreserved = false;
        var knownFailedMigrationState = false;
        string? rollbackFingerprint = null;
        var rollbackEvidenceCaptured = false;
        try
        {
            _options.OnMigrationCheckpoint?.Invoke(
                MigrationCheckpoint.BeforeRollbackEvidenceCapture);
            using var rollbackCheck = Open();
            using var rollbackTransaction = rollbackCheck.BeginTransaction(deferred: false);
            rollbackFingerprint = DatabaseLogicalFingerprint.Compute(
                rollbackCheck,
                rollbackTransaction);
            recovered = rollbackFingerprint == originalFingerprint;
            var rollbackIsHealthy = IsHealthyDatabase(
                rollbackCheck,
                rollbackTransaction);
            knownFailedMigrationState = !recovered &&
                failedMigrationFingerprint is not null &&
                rollbackFingerprint == failedMigrationFingerprint;
            concurrentChangePreserved = !recovered &&
                !knownFailedMigrationState &&
                rollbackIsHealthy;
            rollbackTransaction.Commit();
            rollbackEvidenceCaptured = true;
        }
        catch (Exception evidenceError)
        {
            recovered = false;
            concurrentChangePreserved = false;
            recoveryError = new AggregateException(migrationError!, evidenceError);
        }

        if (!recovered &&
            knownFailedMigrationState &&
            rollbackEvidenceCaptured &&
            rollbackFingerprint is not null &&
            backupPath is not null)
        {
            try
            {
                RestoreBackupLocked(backupPath, rollbackFingerprint);
                using var restoreCheck = Open();
                recovered = DatabaseLogicalFingerprint.Compute(restoreCheck) == originalFingerprint;
            }
            catch (Exception restoreError)
            {
                recoveryError = new AggregateException(migrationError!, restoreError);
            }
        }

        throw new DatabaseMigrationException(
            recovered
                ? "Database migration failed; the original database was preserved or restored."
                : concurrentChangePreserved ||
                  (rollbackEvidenceCaptured && !knownFailedMigrationState)
                    ? "Database migration failed; a concurrent or otherwise unattributed " +
                      "live database state was preserved; " +
                      "backup restoration was not attempted."
                : "Database migration failed and the original database could not be verified.",
            DatabasePath,
            backupPath,
            recoveryError);
    }

    private static bool IsHealthyDatabase(
        SqliteConnection connection,
        SqliteTransaction transaction)
    {
        using (var integrity = connection.CreateCommand())
        {
            integrity.Transaction = transaction;
            integrity.CommandText = "PRAGMA quick_check";
            if (!string.Equals(
                    Convert.ToString(integrity.ExecuteScalar(), CultureInfo.InvariantCulture),
                    "ok",
                    StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
        }
        using var foreignKeys = connection.CreateCommand();
        foreignKeys.Transaction = transaction;
        foreignKeys.CommandText = "PRAGMA foreign_key_check";
        using var violations = foreignKeys.ExecuteReader();
        return !violations.Read();
    }

    private void ApplyMigration(
        SqliteConnection connection,
        SqliteTransaction transaction,
        bool tableExists,
        long originalRowCount,
        IReadOnlyList<long> originalIds)
    {
        _options.OnMigrationCheckpoint?.Invoke(MigrationCheckpoint.BeforeSchemaChanges);
        if (!tableExists)
        {
            CreateAssignmentsTable(connection, transaction);
        }
        else
        {
            var columns = ReadColumns(connection, transaction);
            var requiresRebuild = AssignmentDueDateIsRequired(columns) ||
                HasCanonicalStatuses(connection, transaction) ||
                RequiredBaseColumns.Any(column => !columns.ContainsKey(column));
            if (requiresRebuild)
            {
                RebuildAssignmentsTable(connection, transaction, columns);
            }
            else
            {
                AddColumnIfMissing(connection, transaction, columns, "source_name", "VARCHAR(255)");
                AddColumnIfMissing(connection, transaction, columns, "source_type", "VARCHAR(80)");
                AddColumnIfMissing(connection, transaction, columns, "source_file", "VARCHAR(1000)");
                AddColumnIfMissing(connection, transaction, columns, "source_url", "VARCHAR(1000)");
                AddColumnIfMissing(
                    connection,
                    transaction,
                    columns,
                    "priority",
                    "VARCHAR(20) NOT NULL DEFAULT 'medium' " +
                    "CHECK (priority IN ('low', 'medium', 'high'))");
            }

        }

        CreateIndexes(connection, transaction);
        using var version = connection.CreateCommand();
        version.Transaction = transaction;
        version.CommandText = "PRAGMA user_version = 2";
        version.ExecuteNonQuery();
        SchemaV3Contract.MigrateV2ToV3(connection, transaction, _options.DatabaseInstanceUuid);
        ValidateMigration(connection, transaction, originalRowCount, originalIds);
        _options.OnMigrationCheckpoint?.Invoke(MigrationCheckpoint.BeforeCommit);
    }

    private static void RebuildAssignmentsTable(
        SqliteConnection connection,
        SqliteTransaction transaction,
        IReadOnlyDictionary<string, ColumnInfo> columns)
    {
        if (TableExists(connection, "assignments_v1_migration", transaction))
        {
            throw new InvalidOperationException(
                "Cannot migrate while assignments_v1_migration already exists.");
        }

        Execute(connection, transaction, "ALTER TABLE assignments RENAME TO assignments_v1_migration");
        CreateAssignmentsTable(connection, transaction);

        string ColumnOr(string name, string fallback) =>
            columns.ContainsKey(name) ? $"\"{name}\"" : fallback;
        var id = columns.ContainsKey("id") ? "\"id\"" : "rowid";
        var status = columns.ContainsKey("status")
            ? "CASE lower(trim(ifnull(\"status\", 'not_started'))) " +
              "WHEN 'todo' THEN 'not_started' WHEN 'done' THEN 'completed' " +
              "WHEN 'in_progress' THEN 'in_progress' WHEN 'completed' THEN 'completed' " +
              "ELSE 'not_started' END"
            : "'not_started'";
        var priority = columns.ContainsKey("priority")
            ? "CASE lower(trim(ifnull(\"priority\", 'medium'))) " +
              "WHEN 'low' THEN 'low' WHEN 'high' THEN 'high' ELSE 'medium' END"
            : "'medium'";

        Execute(
            connection,
            transaction,
            $"""
            INSERT INTO assignments (
                id, course_name, title, due_date, description, link, status, priority,
                source_name, source_type, source_file, source_url, created_at, updated_at
            )
            SELECT
                {id},
                coalesce({ColumnOr("course_name", "NULL")}, 'Uncategorized'),
                coalesce({ColumnOr("title", "NULL")}, 'Untitled'),
                {ColumnOr("due_date", "NULL")},
                {ColumnOr("description", "NULL")},
                {ColumnOr("link", "NULL")},
                {status},
                {priority},
                {ColumnOr("source_name", "NULL")},
                {ColumnOr("source_type", "NULL")},
                {ColumnOr("source_file", "NULL")},
                {ColumnOr("source_url", "NULL")},
                coalesce({ColumnOr("created_at", "NULL")}, CURRENT_TIMESTAMP),
                coalesce({ColumnOr("updated_at", "NULL")}, CURRENT_TIMESTAMP)
            FROM assignments_v1_migration
            """);
        Execute(connection, transaction, "DROP TABLE assignments_v1_migration");
    }

    private static void CreateAssignmentsTable(
        SqliteConnection connection,
        SqliteTransaction transaction) => Execute(
        connection,
        transaction,
        """
        CREATE TABLE assignments (
            id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            course_name VARCHAR(120) NOT NULL,
            title VARCHAR(255) NOT NULL,
            due_date DATETIME,
            description TEXT,
            link VARCHAR(1000),
            status VARCHAR(20) NOT NULL DEFAULT 'not_started',
            priority VARCHAR(20) NOT NULL DEFAULT 'medium',
            source_name VARCHAR(255),
            source_type VARCHAR(80),
            source_file VARCHAR(1000),
            source_url VARCHAR(1000),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
            CONSTRAINT assignment_status_check
                CHECK (status IN ('not_started', 'in_progress', 'completed')),
            CONSTRAINT assignment_priority_check
                CHECK (priority IN ('low', 'medium', 'high'))
        )
        """);

    private static void CreateIndexes(
        SqliteConnection connection,
        SqliteTransaction transaction)
    {
        Execute(
            connection,
            transaction,
            "CREATE INDEX IF NOT EXISTS ix_assignments_due_date ON assignments (due_date)");
        Execute(
            connection,
            transaction,
            "CREATE INDEX IF NOT EXISTS ix_assignments_status ON assignments (status)");
        Execute(
            connection,
            transaction,
            "CREATE INDEX IF NOT EXISTS ix_assignments_priority ON assignments (priority)");
        Execute(
            connection,
            transaction,
            "CREATE INDEX IF NOT EXISTS ix_assignments_course_name ON assignments (course_name)");
    }

    private static void AddColumnIfMissing(
        SqliteConnection connection,
        SqliteTransaction transaction,
        IDictionary<string, ColumnInfo> columns,
        string name,
        string definition)
    {
        if (columns.ContainsKey(name))
        {
            return;
        }
        Execute(connection, transaction, $"ALTER TABLE assignments ADD COLUMN {name} {definition}");
        columns[name] = new ColumnInfo(name, NotNull: definition.Contains("NOT NULL"));
    }

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection(_connectionString);
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;";
        command.ExecuteNonQuery();
        return connection;
    }

    private SqliteConnection OpenReadOnly()
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadOnly,
            Cache = SqliteCacheMode.Private,
            Pooling = false
        }.ToString());
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA busy_timeout=10000; PRAGMA query_only=ON;";
        command.ExecuteNonQuery();
        return connection;
    }

    private static AssignmentItem ReadAssignment(SqliteDataReader reader)
    {
        var timezoneId = reader.IsDBNull(20) ? null : reader.GetString(20);
        var timeZone = LocalWallTime.ResolveTimeZone(timezoneId);
        var rawDueDate = reader.IsDBNull(4) ? null : reader.GetString(4);
        var parsedDueDate = LocalWallTime.ParseLegacy(rawDueDate, timeZone);
        return new AssignmentItem
        {
            Id = reader.GetInt64(0),
            Uuid = reader.GetString(1),
            CourseName = reader.GetString(2),
            Title = reader.GetString(3),
            DueDate = parsedDueDate,
            Description = reader.IsDBNull(5) ? null : reader.GetString(5),
            Link = reader.IsDBNull(6) ? null : reader.GetString(6),
            Status = TaskStatuses.FromDatabaseStatus(reader.GetString(7)),
            Priority = TaskPriorities.Normalize(reader.GetString(8)),
            SourceName = reader.IsDBNull(9) ? null : reader.GetString(9),
            SourceType = reader.IsDBNull(10) ? null : reader.GetString(10),
            SourceFile = reader.IsDBNull(11) ? null : reader.GetString(11),
            SourceUrl = reader.IsDBNull(12) ? null : reader.GetString(12),
            CreatedAt = ParseTimestamp(reader.IsDBNull(13) ? null : reader.GetString(13))
            ?? DateTimeOffset.MinValue,
            UpdatedAt = ParseTimestamp(reader.IsDBNull(14) ? null : reader.GetString(14))
            ?? DateTimeOffset.MinValue,
            CourseId = reader.IsDBNull(15) ? null : reader.GetInt64(15),
            ProjectId = reader.IsDBNull(16) ? null : reader.GetInt64(16),
            CompletedAt = ParseTimestamp(reader.IsDBNull(17) ? null : reader.GetString(17)),
            ProgressPercent = reader.GetInt32(18),
            AllDay = reader.GetInt32(19) == 1,
            TimezoneId = timezoneId,
            DeletedAt = ParseTimestamp(reader.IsDBNull(21) ? null : reader.GetString(21)),
            StoredDueDateText = rawDueDate,
            StoredDueDateValue = parsedDueDate
        };
    }

    private static NormalizedDraft NormalizeDraft(AssignmentDraft draft)
    {
        ArgumentNullException.ThrowIfNull(draft);
        var title = Clean(draft.Title)
            ?? throw new ArgumentException("Title is required.", nameof(draft));
        var course = Clean(draft.CourseName)
            ?? throw new ArgumentException("Course is required.", nameof(draft));
        if (draft.AllDay && draft.DueDate is null)
            throw new ArgumentException("An all-day task requires a due date.", nameof(draft));
        var timezone = Clean(draft.TimezoneId);
        var resolvedTimeZone = LocalWallTime.ResolveTimeZone(timezone);
        return new NormalizedDraft(
            course,
            title,
            LocalWallTime.StoredText(
                draft.DueDate,
                draft.StoredDueDateText,
                draft.StoredDueDateValue,
                resolvedTimeZone),
            draft.Description,
            draft.Link,
            TaskStatuses.ToDatabaseStatus(draft.Status),
            TaskPriorities.Normalize(draft.Priority),
            draft.SourceName,
            draft.SourceType,
            draft.SourceFile,
            draft.SourceUrl,
            draft.CourseId,
            draft.ProjectId,
            draft.ProgressPercent,
            draft.AllDay,
            timezone);
    }

    private static void BindDraft(SqliteCommand command, NormalizedDraft draft)
    {
        command.Parameters.AddWithValue("$course", draft.CourseName);
        command.Parameters.AddWithValue("$title", draft.Title);
        command.Parameters.AddWithValue("$due", (object?)draft.DueDate ?? DBNull.Value);
        command.Parameters.AddWithValue("$description", (object?)draft.Description ?? DBNull.Value);
        command.Parameters.AddWithValue("$link", (object?)draft.Link ?? DBNull.Value);
        command.Parameters.AddWithValue("$status", draft.Status);
        command.Parameters.AddWithValue("$priority", draft.Priority);
        command.Parameters.AddWithValue("$sourceName", (object?)draft.SourceName ?? DBNull.Value);
        command.Parameters.AddWithValue("$sourceType", (object?)draft.SourceType ?? DBNull.Value);
        command.Parameters.AddWithValue("$sourceFile", (object?)draft.SourceFile ?? DBNull.Value);
        command.Parameters.AddWithValue("$sourceUrl", (object?)draft.SourceUrl ?? DBNull.Value);
    }

    private static PersistedTaskState InitialState(string status, int? progress, string timestamp)
    {
        var defaultProgress = status == "completed" ? 100 : 0;
        var value = progress ?? defaultProgress;
        if (value is < 0 or > 100)
            throw new ArgumentOutOfRangeException(nameof(progress));
        if (status == "completed" && value != 100)
            throw new TaskStateConflictException("Done status requires progress 100.");
        if (status == "not_started" && value != 0)
            throw new TaskStateConflictException("Todo status requires progress 0.");
        if (status != "completed" && value == 100)
            throw new TaskStateConflictException("Progress 100 requires done status.");
        return new PersistedTaskState(status, value, status == "completed" ? timestamp : null);
    }

    private static long ResolveCourseId(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string courseName,
        long? preferredId)
    {
        if (preferredId is not null)
        {
            using var preferred = connection.CreateCommand();
            preferred.Transaction = transaction;
            preferred.CommandText = "SELECT name FROM courses WHERE id=$id AND deleted_at IS NULL";
            preferred.Parameters.AddWithValue("$id", preferredId.Value);
            var storedName = preferred.ExecuteScalar() as string;
            if (storedName is null)
                throw new ArgumentException("A task can only reference an active course.");
            if (!string.Equals(storedName, courseName, StringComparison.Ordinal))
                throw new ArgumentException("Task course_name must match the referenced course exactly.");
            return preferredId.Value;
        }

        using (var existing = connection.CreateCommand())
        {
            existing.Transaction = transaction;
            existing.CommandText = "SELECT id FROM courses WHERE name=$name AND deleted_at IS NULL ORDER BY id LIMIT 1";
            existing.Parameters.AddWithValue("$name", courseName);
            if (existing.ExecuteScalar() is { } id)
                return Convert.ToInt64(id, CultureInfo.InvariantCulture);
        }

        var timestamp = SchemaV3Contract.CanonicalUtcNow();
        using var insert = connection.CreateCommand();
        insert.Transaction = transaction;
        insert.CommandText =
            "INSERT INTO courses(uuid,name,normalized_name,created_at,updated_at) " +
            "VALUES($uuid,$name,$normalized,$created,$updated); SELECT last_insert_rowid();";
        insert.Parameters.AddWithValue("$uuid", SchemaV3Contract.NewUuid());
        insert.Parameters.AddWithValue("$name", courseName);
        insert.Parameters.AddWithValue("$normalized", SchemaV3Contract.CanonicalName(courseName));
        insert.Parameters.AddWithValue("$created", timestamp);
        insert.Parameters.AddWithValue("$updated", timestamp);
        return Convert.ToInt64(insert.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private static void ValidateProject(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long? projectId,
        long? courseId)
    {
        if (projectId is null) return;
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT course_id FROM projects WHERE id=$id AND deleted_at IS NULL";
        command.Parameters.AddWithValue("$id", projectId.Value);
        using var reader = command.ExecuteReader();
        if (!reader.Read()) throw new ArgumentException("A task can only reference an active project.");
        if (!reader.IsDBNull(0) && reader.GetInt64(0) != courseId)
            throw new ArgumentException("Task and project courses must match.");
    }

    private static CurrentRelationship ReadCurrentRelationship(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long assignmentId)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "SELECT course_name,course_id,project_id FROM assignments " +
            "WHERE id=$id AND deleted_at IS NULL";
        command.Parameters.AddWithValue("$id", assignmentId);
        using var reader = command.ExecuteReader();
        if (!reader.Read())
            throw new KeyNotFoundException($"Assignment {assignmentId} was not found.");
        return new CurrentRelationship(
            reader.GetString(0),
            reader.IsDBNull(1) ? null : reader.GetInt64(1),
            reader.IsDBNull(2) ? null : reader.GetInt64(2));
    }

    private static void EnsureChanged(int changedRows, long id)
    {
        if (changedRows == 0)
        {
            throw new KeyNotFoundException($"Assignment {id} was not found.");
        }
    }

    private static int ReadSchemaVersion(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA user_version";
        return Convert.ToInt32(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private static int ReadSchemaVersion(
        SqliteConnection connection,
        SqliteTransaction transaction)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "PRAGMA user_version";
        return Convert.ToInt32(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private static bool HasCurrentColumns(
        SqliteConnection connection,
        SqliteTransaction? transaction = null)
    {
        var columns = ReadColumns(connection, transaction);
        return CurrentColumns.All(columns.ContainsKey);
    }

    private static Dictionary<string, ColumnInfo> ReadColumns(
        SqliteConnection connection,
        SqliteTransaction? transaction = null)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "PRAGMA table_info(assignments)";
        using var reader = command.ExecuteReader();
        var columns = new Dictionary<string, ColumnInfo>(StringComparer.OrdinalIgnoreCase);
        while (reader.Read())
        {
            var name = reader.GetString(1);
            columns[name] = new ColumnInfo(name, reader.GetInt64(3) == 1);
        }
        return columns;
    }

    private static bool AssignmentDueDateIsRequired(SqliteConnection connection) =>
        AssignmentDueDateIsRequired(ReadColumns(connection));

    private static bool AssignmentDueDateIsRequired(
        IReadOnlyDictionary<string, ColumnInfo> columns) =>
        columns.TryGetValue("due_date", out var dueDate) && dueDate.NotNull;

    private static bool HasCanonicalStatuses(SqliteConnection connection) =>
        HasCanonicalStatuses(connection, transaction: null);

    private static bool HasCanonicalStatuses(
        SqliteConnection connection,
        SqliteTransaction? transaction)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT 1 FROM assignments
            WHERE lower(status) IN ('todo', 'done')
            LIMIT 1
            """;
        return command.ExecuteScalar() is not null;
    }

    private static void ValidateKnownStatuses(
        SqliteConnection connection,
        SqliteTransaction? transaction = null)
    {
        var columns = ReadColumns(connection, transaction);
        if (!columns.ContainsKey("status"))
        {
            return;
        }
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT coalesce(status, '<null>') FROM assignments
            WHERE status IS NULL OR lower(status) NOT IN (
                'not_started', 'in_progress', 'completed', 'todo', 'done'
            )
            LIMIT 1
            """;
        if (command.ExecuteScalar() is { } invalid)
        {
            throw new InvalidDataException(
                $"Database contains unsupported assignment status '{invalid}'. No migration was attempted.");
        }
    }

    private static void ValidateKnownPriorities(
        SqliteConnection connection,
        SqliteTransaction? transaction = null)
    {
        var columns = ReadColumns(connection, transaction);
        if (!columns.ContainsKey("priority"))
        {
            return;
        }
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT coalesce(priority, '<null>') FROM assignments
            WHERE priority IS NULL OR lower(priority) NOT IN ('low', 'medium', 'high')
            LIMIT 1
            """;
        if (command.ExecuteScalar() is { } invalid)
        {
            throw new InvalidDataException(
                $"Database contains unsupported assignment priority '{invalid}'. No migration was attempted.");
        }
    }

    private static void ValidateDueDates(
        SqliteConnection connection,
        SqliteTransaction? transaction = null)
    {
        var columns = ReadColumns(connection, transaction);
        if (!columns.ContainsKey("due_date"))
        {
            return;
        }
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        var hasTimeZone = columns.ContainsKey("timezone_id");
        command.CommandText = hasTimeZone
            ? "SELECT due_date,timezone_id FROM assignments WHERE due_date IS NOT NULL"
            : "SELECT due_date,NULL FROM assignments WHERE due_date IS NOT NULL";
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            var timeZone = LocalWallTime.ResolveTimeZone(
                reader.IsDBNull(1) ? null : reader.GetString(1));
            _ = LocalWallTime.ParseLegacy(reader.GetString(0), timeZone);
        }
    }

    private static long CountRows(
        SqliteConnection connection,
        SqliteTransaction? transaction = null)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT count(*) FROM assignments";
        return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private static IReadOnlyList<long> ReadAssignmentIds(
        SqliteConnection connection,
        SqliteTransaction? transaction = null,
        bool useRowId = false)
    {
        var identityColumn = useRowId ? "rowid" : "id";
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            $"SELECT {identityColumn} FROM assignments ORDER BY {identityColumn}";
        using var reader = command.ExecuteReader();
        var ids = new List<long>();
        while (reader.Read())
        {
            ids.Add(reader.GetInt64(0));
        }
        return ids;
    }

    private static void ValidateMigration(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long expectedRowCount,
        IReadOnlyList<long> expectedIds)
    {
        var columns = ReadColumns(connection, transaction);
        var missing = CurrentColumns.Where(column => !columns.ContainsKey(column)).ToArray();
        if (missing.Length > 0)
        {
            throw new InvalidDataException(
                $"Migrated database is missing columns: {string.Join(", ", missing)}.");
        }
        if (AssignmentDueDateIsRequired(columns))
        {
            throw new InvalidDataException("Migrated due_date column must allow null values.");
        }
        var actualRowCount = CountRows(connection, transaction);
        if (actualRowCount != expectedRowCount)
        {
            throw new InvalidDataException(
                $"Migration row-count mismatch: expected {expectedRowCount}, got {actualRowCount}.");
        }
        var actualIds = ReadAssignmentIds(connection, transaction);
        if (!actualIds.SequenceEqual(expectedIds))
        {
            throw new InvalidDataException(
                "Migration assignment-ID validation failed; the transaction will be rolled back.");
        }

        using (var statuses = connection.CreateCommand())
        {
            statuses.Transaction = transaction;
            statuses.CommandText =
                """
                SELECT coalesce(status, '<null>') FROM assignments
                WHERE status IS NULL OR status NOT IN ('not_started', 'in_progress', 'completed')
                LIMIT 1
                """;
            if (statuses.ExecuteScalar() is { } invalid)
            {
                throw new InvalidDataException(
                    $"Migrated database contains unsupported status '{invalid}'.");
            }
        }
        using (var priorities = connection.CreateCommand())
        {
            priorities.Transaction = transaction;
            priorities.CommandText =
                """
                SELECT coalesce(priority, '<null>') FROM assignments
                WHERE priority IS NULL OR priority NOT IN ('low', 'medium', 'high')
                LIMIT 1
                """;
            if (priorities.ExecuteScalar() is { } invalid)
            {
                throw new InvalidDataException(
                    $"Migrated database contains unsupported priority '{invalid}'.");
            }
        }
        using (var integrity = connection.CreateCommand())
        {
            integrity.Transaction = transaction;
            integrity.CommandText = "PRAGMA quick_check";
            var result = Convert.ToString(
                integrity.ExecuteScalar(),
                CultureInfo.InvariantCulture);
            if (!string.Equals(result, "ok", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException($"Migrated database failed quick_check: {result}");
            }
        }
        if (ReadSchemaVersion(connection, transaction) != CurrentSchemaVersion)
        {
            throw new InvalidDataException("Migrated database version was not committed correctly.");
        }
    }

    private static bool TableExists(
        SqliteConnection connection,
        string tableName,
        SqliteTransaction? transaction = null)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = $name LIMIT 1";
        command.Parameters.AddWithValue("$name", tableName);
        return command.ExecuteScalar() is not null;
    }

    private static void Execute(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string sql)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private string DefaultBackupPath()
    {
        var directory = Path.GetDirectoryName(DatabasePath)!;
        var fileName = Path.GetFileName(DatabasePath);
        return Path.Combine(
            directory,
            $"{fileName}.pre-v3-{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.bak");
    }

    private static string FindDatabasePath()
    {
        var overridePath = Environment.GetEnvironmentVariable("ASSIGNMENT_DB_PATH");
        if (!string.IsNullOrWhiteSpace(overridePath))
        {
            return overridePath;
        }

        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        for (var index = 0; index < 10 && directory is not null; index++)
        {
            var candidate = Path.Combine(directory.FullName, "backend", "assignments.db");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            directory = directory.Parent;
        }

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AssignmentNative",
            "assignments.db");
    }

    private static DateTimeOffset? ParseTimestamp(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }
        if (DateTimeOffset.TryParse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeUniversal |
                DateTimeStyles.AdjustToUniversal,
            out var timestamp))
        {
            return timestamp;
        }
        return null;
    }

    private static string? CandidateDueDate(string? date, string? time)
    {
        var cleanDate = Clean(date);
        if (cleanDate is null)
        {
            return null;
        }

        if (HasExplicitOffset(cleanDate))
        {
            return null;
        }

        if (!DateOnly.TryParse(
                cleanDate,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AllowWhiteSpaces,
                out var localDate))
        {
            return null;
        }
        var localTime = TimeOnly.TryParse(
            Clean(time) ?? "23:59",
            CultureInfo.InvariantCulture,
            DateTimeStyles.AllowWhiteSpaces,
            out var parsedTime)
            ? parsedTime
            : new TimeOnly(23, 59);
        var localDateTime = DateTime.SpecifyKind(
            localDate.ToDateTime(localTime),
            DateTimeKind.Unspecified);
        return localDateTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
    }

    private static bool HasOffset(string value)
    {
        var timeSeparator = Math.Max(value.IndexOf('T'), value.IndexOf(' '));
        if (timeSeparator < 0)
        {
            return false;
        }
        return value.IndexOf('+', timeSeparator) >= 0 ||
            value.IndexOf('-', timeSeparator + 1) >= 0;
    }

    private static bool HasExplicitOffset(string value) =>
        value.EndsWith("Z", StringComparison.OrdinalIgnoreCase) || HasOffset(value);

    private static string? Clean(string? value)
    {
        var clean = value?.Trim();
        return string.IsNullOrEmpty(clean) ? null : clean;
    }

    private static readonly string[] RequiredBaseColumns =
    [
        "id", "course_name", "title", "due_date", "description", "link", "status",
        "created_at", "updated_at"
    ];

    private static readonly string[] CurrentColumns =
    [
        .. RequiredBaseColumns,
        "priority", "source_name", "source_type", "source_file", "source_url"
    ];

    private sealed record ColumnInfo(string Name, bool NotNull);

    private sealed record NormalizedDraft(
        string CourseName,
        string Title,
        string? DueDate,
        string? Description,
        string? Link,
        string Status,
        string Priority,
        string? SourceName,
        string? SourceType,
        string? SourceFile,
        string? SourceUrl,
        long? CourseId,
        long? ProjectId,
        int? ProgressPercent,
        bool AllDay,
        string? TimezoneId);

    private sealed record CurrentRelationship(
        string CourseName,
        long? CourseId,
        long? ProjectId);
}
