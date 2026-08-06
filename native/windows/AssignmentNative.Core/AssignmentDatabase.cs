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
    BeforeCommit
}

public sealed class AssignmentDatabaseOptions
{
    /// <summary>
    /// Optional deterministic test seam. Production callers should leave this null.
    /// Throwing from a checkpoint exercises rollback and backup restoration.
    /// </summary>
    public Action<MigrationCheckpoint>? OnMigrationCheckpoint { get; init; }
}

public sealed class AssignmentDatabase
{
    public const int CurrentSchemaVersion = 2;

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
            SELECT id, course_name, title, due_date, description, link, status,
                   priority, source_name, source_type, source_file, source_url,
                   created_at, updated_at
            FROM assignments
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
            SELECT id, course_name, title, due_date, description, link, status,
                   priority, source_name, source_type, source_file, source_url,
                   created_at, updated_at
            FROM assignments
            WHERE id = $id
            LIMIT 1
            """;
        command.Parameters.AddWithValue("$id", id);
        using var reader = command.ExecuteReader();
        return reader.Read() ? ReadAssignment(reader) : null;
    }

    public long Add(AssignmentDraft draft)
    {
        var value = NormalizeDraft(draft);
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO assignments (
                course_name, title, due_date, description, link, status, priority,
                source_name, source_type, source_file, source_url,
                created_at, updated_at
            ) VALUES (
                $course, $title, $due, $description, $link, $status, $priority,
                $sourceName, $sourceType, $sourceFile, $sourceUrl,
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            );
            SELECT last_insert_rowid();
            """;
        BindDraft(command, value);
        return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    public void Update(long id, AssignmentDraft draft)
    {
        var value = NormalizeDraft(draft);
        using var connection = Open();
        using var command = connection.CreateCommand();
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
                updated_at = CURRENT_TIMESTAMP
            WHERE id = $id
            """;
        BindDraft(command, value);
        command.Parameters.AddWithValue("$id", id);
        EnsureChanged(command.ExecuteNonQuery(), id);
    }

    public void UpdateStatus(long id, string status)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            UPDATE assignments
            SET status = $status, updated_at = CURRENT_TIMESTAMP
            WHERE id = $id
            """;
        command.Parameters.AddWithValue("$status", TaskStatuses.ToDatabaseStatus(status));
        command.Parameters.AddWithValue("$id", id);
        EnsureChanged(command.ExecuteNonQuery(), id);
    }

    public void Delete(long id)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM assignments WHERE id = $id";
        command.Parameters.AddWithValue("$id", id);
        EnsureChanged(command.ExecuteNonQuery(), id);
    }

    public int InsertCandidates(
        IEnumerable<AssignmentCandidate> candidates,
        string fallbackCourse,
        string sourceName,
        string sourceUrl)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        using var connection = Open();
        using var transaction = connection.BeginTransaction();
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
            insert.CommandText =
                """
                INSERT INTO assignments (
                    course_name, title, due_date, description, link, status, priority,
                    source_name, source_type, source_file, source_url,
                    created_at, updated_at
                ) VALUES (
                    $course, $title, $due, $description, $url, 'not_started', $priority,
                    $source, 'secure_web', NULL, $url,
                    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
                )
                """;
            insert.Parameters.AddWithValue("$course", course);
            insert.Parameters.AddWithValue("$title", title);
            insert.Parameters.AddWithValue("$due", (object?)dueDate ?? DBNull.Value);
            insert.Parameters.AddWithValue(
                "$description",
                (object?)Clean(candidate.Description) ?? DBNull.Value);
            insert.Parameters.AddWithValue("$url", (object?)resolvedUrl ?? DBNull.Value);
            insert.Parameters.AddWithValue("$priority", priority);
            insert.Parameters.AddWithValue("$source", (object?)resolvedSource ?? DBNull.Value);
            insert.ExecuteNonQuery();
            inserted++;
        }
        transaction.Commit();
        return inserted;
    }

    public string CreateBackup(string? destinationPath = null)
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

        var destinationConnectionString = new SqliteConnectionStringBuilder
        {
            DataSource = backupPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false
        }.ToString();
        using var source = Open();
        using (var checkpoint = source.CreateCommand())
        {
            checkpoint.CommandText = "PRAGMA wal_checkpoint(FULL)";
            checkpoint.ExecuteNonQuery();
        }
        using var destination = new SqliteConnection(destinationConnectionString);
        destination.Open();
        source.BackupDatabase(destination);
        LastBackupPath = backupPath;
        return backupPath;
    }

    public void RestoreBackup(string backupPath)
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
        DeleteSidecarFiles();
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
        int previousVersion;
        bool tableExists;
        bool requiresMigration;
        long originalRowCount;
        IReadOnlyList<long> originalIds;
        using (var inspection = Open())
        {
            previousVersion = ReadSchemaVersion(inspection);
            if (previousVersion > CurrentSchemaVersion)
            {
                throw new NotSupportedException(
                    $"Database schema v{previousVersion} is newer than supported v{CurrentSchemaVersion}.");
            }
            tableExists = TableExists(inspection, "assignments");
            if (tableExists)
            {
                ValidateKnownStatuses(inspection);
                ValidateKnownPriorities(inspection);
                ValidateDueDates(inspection);
            }
            originalRowCount = tableExists ? CountRows(inspection) : 0;
            originalIds = tableExists
                ? ReadAssignmentIds(
                    inspection,
                    useRowId: !ReadColumns(inspection).ContainsKey("id"))
                : [];
            requiresMigration = !tableExists ||
                previousVersion < CurrentSchemaVersion ||
                !HasCurrentColumns(inspection) ||
                AssignmentDueDateIsRequired(inspection) ||
                HasCanonicalStatuses(inspection);
        }

        if (!requiresMigration)
        {
            return new MigrationResult(
                previousVersion,
                CurrentSchemaVersion,
                Migrated: false,
                BackupPath: null);
        }

        string? backupPath = null;
        if (tableExists)
        {
            backupPath = CreateBackup();
        }

        try
        {
            ApplyMigration(tableExists, originalRowCount, originalIds);
            return new MigrationResult(
                previousVersion,
                CurrentSchemaVersion,
                Migrated: true,
                BackupPath: backupPath);
        }
        catch (Exception migrationError)
        {
            Exception error = migrationError;
            var restored = backupPath is null;
            if (backupPath is not null)
            {
                try
                {
                    RestoreBackup(backupPath);
                    restored = true;
                }
                catch (Exception restoreError)
                {
                    error = new AggregateException(migrationError, restoreError);
                }
            }

            throw new DatabaseMigrationException(
                restored
                    ? "Database migration failed; the pre-migration backup was restored."
                    : "Database migration and automatic backup restoration both failed.",
                DatabasePath,
                backupPath,
                error);
        }
    }

    private void ApplyMigration(
        bool tableExists,
        long originalRowCount,
        IReadOnlyList<long> originalIds)
    {
        using var connection = Open();
        using var transaction = connection.BeginTransaction();
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
        version.CommandText = $"PRAGMA user_version = {CurrentSchemaVersion}";
        version.ExecuteNonQuery();
        ValidateMigration(connection, transaction, originalRowCount, originalIds);
        _options.OnMigrationCheckpoint?.Invoke(MigrationCheckpoint.BeforeCommit);
        transaction.Commit();
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

    private static AssignmentItem ReadAssignment(SqliteDataReader reader) => new()
    {
        Id = reader.GetInt64(0),
        CourseName = reader.GetString(1),
        Title = reader.GetString(2),
        DueDate = ParseDueDate(reader.IsDBNull(3) ? null : reader.GetString(3)),
        Description = reader.IsDBNull(4) ? null : reader.GetString(4),
        Link = reader.IsDBNull(5) ? null : reader.GetString(5),
        Status = TaskStatuses.FromDatabaseStatus(reader.GetString(6)),
        Priority = TaskPriorities.Normalize(reader.GetString(7)),
        SourceName = reader.IsDBNull(8) ? null : reader.GetString(8),
        SourceType = reader.IsDBNull(9) ? null : reader.GetString(9),
        SourceFile = reader.IsDBNull(10) ? null : reader.GetString(10),
        SourceUrl = reader.IsDBNull(11) ? null : reader.GetString(11),
        CreatedAt = ParseTimestamp(reader.IsDBNull(12) ? null : reader.GetString(12))
            ?? DateTimeOffset.MinValue,
        UpdatedAt = ParseTimestamp(reader.IsDBNull(13) ? null : reader.GetString(13))
            ?? DateTimeOffset.MinValue
    };

    private static NormalizedDraft NormalizeDraft(AssignmentDraft draft)
    {
        ArgumentNullException.ThrowIfNull(draft);
        var title = Clean(draft.Title)
            ?? throw new ArgumentException("Title is required.", nameof(draft));
        var course = Clean(draft.CourseName)
            ?? throw new ArgumentException("Course is required.", nameof(draft));
        return new NormalizedDraft(
            course,
            title,
            DatabaseDate(draft.DueDate),
            Clean(draft.Description),
            Clean(draft.Link),
            TaskStatuses.ToDatabaseStatus(draft.Status),
            TaskPriorities.Normalize(draft.Priority),
            Clean(draft.SourceName),
            Clean(draft.SourceType) ?? "manual",
            Clean(draft.SourceFile),
            Clean(draft.SourceUrl));
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

    private static bool HasCurrentColumns(SqliteConnection connection)
    {
        var columns = ReadColumns(connection);
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

    private static void ValidateKnownStatuses(SqliteConnection connection)
    {
        var columns = ReadColumns(connection);
        if (!columns.ContainsKey("status"))
        {
            return;
        }
        using var command = connection.CreateCommand();
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

    private static void ValidateKnownPriorities(SqliteConnection connection)
    {
        var columns = ReadColumns(connection);
        if (!columns.ContainsKey("priority"))
        {
            return;
        }
        using var command = connection.CreateCommand();
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

    private static void ValidateDueDates(SqliteConnection connection)
    {
        var columns = ReadColumns(connection);
        if (!columns.ContainsKey("due_date"))
        {
            return;
        }
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT due_date FROM assignments WHERE due_date IS NOT NULL";
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            _ = ParseDueDate(reader.GetString(0));
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
            $"{fileName}.pre-v2-{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.bak");
    }

    private void DeleteSidecarFiles()
    {
        foreach (var suffix in new[] { "-wal", "-shm", "-journal" })
        {
            var sidecar = DatabasePath + suffix;
            if (File.Exists(sidecar))
            {
                File.Delete(sidecar);
            }
        }
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

    private static DateTimeOffset? ParseDueDate(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        if (HasExplicitOffset(value))
        {
            throw new InvalidDataException(
                $"due_date '{value}' contains a UTC marker or offset; schema v2 requires local wall time (yyyy-MM-dd HH:mm:ss)."
            );
        }
        if (!DateTime.TryParse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AllowWhiteSpaces,
            out var localDate))
        {
            return null;
        }
        localDate = DateTime.SpecifyKind(localDate, DateTimeKind.Unspecified);
        return new DateTimeOffset(localDate, TimeZoneInfo.Local.GetUtcOffset(localDate));
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

    private static string? DatabaseDate(DateTimeOffset? value) => value is { } dueDate
        ? TimeZoneInfo.ConvertTime(dueDate, TimeZoneInfo.Local)
            .ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)
        : null;

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
        string? SourceUrl);
}
