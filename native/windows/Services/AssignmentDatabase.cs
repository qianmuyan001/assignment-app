using Microsoft.Data.Sqlite;

namespace AssignmentNative.Services;

public sealed class AssignmentDatabase
{
    public string DatabasePath { get; }
    private readonly string _connectionString;

    public AssignmentDatabase(string? path = null)
    {
        DatabasePath = path ?? FindDatabasePath();
        Directory.CreateDirectory(Path.GetDirectoryName(DatabasePath)!);
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared
        }.ToString();
        CreateSchema();
    }

    public IReadOnlyList<AssignmentItem> FetchAssignments()
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT id, course_name, title, due_date, description, link, status,
                   source_name, source_url
            FROM assignments
            ORDER BY due_date IS NULL, due_date ASC, created_at DESC
            """;
        using var reader = command.ExecuteReader();
        var result = new List<AssignmentItem>();
        while (reader.Read())
        {
            result.Add(new AssignmentItem
            {
                Id = reader.GetInt64(0),
                CourseName = reader.GetString(1),
                Title = reader.GetString(2),
                DueDate = ParseDatabaseDate(reader.IsDBNull(3) ? null : reader.GetString(3)),
                Description = reader.IsDBNull(4) ? null : reader.GetString(4),
                Link = reader.IsDBNull(5) ? null : reader.GetString(5),
                Status = reader.GetString(6),
                SourceName = reader.IsDBNull(7) ? null : reader.GetString(7),
                SourceUrl = reader.IsDBNull(8) ? null : reader.GetString(8)
            });
        }
        return result;
    }

    public int InsertCandidates(
        IEnumerable<AssignmentCandidate> candidates,
        string fallbackCourse,
        string sourceName,
        string sourceUrl)
    {
        using var connection = Open();
        using var transaction = connection.BeginTransaction();
        var inserted = 0;
        foreach (var candidate in candidates.Take(200))
        {
            var title = Clean(candidate.Title) ?? "Untitled";
            var course = Clean(candidate.CourseName)
                ?? Clean(fallbackCourse)
                ?? "Imported";
            var dueDate = DatabaseDueDate(candidate.DueDate, candidate.DueTime);
            var resolvedSource = Clean(candidate.SourceName) ?? Clean(sourceName);
            var resolvedUrl = Clean(candidate.SourceUrl) ?? Clean(sourceUrl);

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
                    course_name, title, due_date, description, link, status,
                    source_name, source_type, source_file, source_url,
                    created_at, updated_at
                ) VALUES (
                    $course, $title, $due, $description, $url, 'not_started',
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
            insert.Parameters.AddWithValue(
                "$source",
                (object?)resolvedSource ?? DBNull.Value);
            insert.ExecuteNonQuery();
            inserted++;
        }
        transaction.Commit();
        return inserted;
    }

    public void UpdateStatus(long id, string status)
    {
        if (status is not ("not_started" or "in_progress" or "completed"))
        {
            throw new ArgumentOutOfRangeException(nameof(status));
        }
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText =
            "UPDATE assignments SET status = $status, updated_at = CURRENT_TIMESTAMP WHERE id = $id";
        command.Parameters.AddWithValue("$status", status);
        command.Parameters.AddWithValue("$id", id);
        command.ExecuteNonQuery();
    }

    public void Delete(long id)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM assignments WHERE id = $id";
        command.Parameters.AddWithValue("$id", id);
        command.ExecuteNonQuery();
    }

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection(_connectionString);
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText =
            "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;";
        command.ExecuteNonQuery();
        return connection;
    }

    private void CreateSchema()
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            CREATE TABLE IF NOT EXISTS assignments (
                id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                course_name VARCHAR(120) NOT NULL,
                title VARCHAR(255) NOT NULL,
                due_date DATETIME,
                description TEXT,
                link VARCHAR(1000),
                status VARCHAR(20) NOT NULL DEFAULT 'not_started',
                source_name VARCHAR(255),
                source_type VARCHAR(80),
                source_file VARCHAR(1000),
                source_url VARCHAR(1000),
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                CONSTRAINT assignment_status_check
                    CHECK (status IN ('not_started', 'in_progress', 'completed'))
            );
            CREATE INDEX IF NOT EXISTS ix_assignments_due_date ON assignments (due_date);
            CREATE INDEX IF NOT EXISTS ix_assignments_status ON assignments (status);
            """;
        command.ExecuteNonQuery();
    }

    private static string FindDatabasePath()
    {
        var overridePath = Environment.GetEnvironmentVariable("ASSIGNMENT_DB_PATH");
        if (!string.IsNullOrWhiteSpace(overridePath))
        {
            return Path.GetFullPath(overridePath);
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

    private static DateTimeOffset? ParseDatabaseDate(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }
        return DateTimeOffset.TryParse(value, out var date) ? date : null;
    }

    private static string? DatabaseDueDate(string? date, string? time)
    {
        var cleanDate = Clean(date);
        return cleanDate is null ? null : $"{cleanDate} {Clean(time) ?? "23:59"}";
    }

    private static string? Clean(string? value)
    {
        var clean = value?.Trim();
        return string.IsNullOrEmpty(clean) ? null : clean;
    }
}
