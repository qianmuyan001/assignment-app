using System.Globalization;
using System.Text.Json;
using AssignmentNative.Core;
using Microsoft.Data.Sqlite;

namespace AssignmentNative.Core.Tests;

internal static class Program
{
    private static readonly TimeZoneInfo TestTimeZone = TimeZoneInfo.CreateCustomTimeZone(
        "AssignmentTests+08",
        TimeSpan.FromHours(8),
        "Assignment tests UTC+08",
        "Assignment tests UTC+08");

    public static int Main()
    {
        var tests = new (string Name, Action Run)[]
        {
            ("add assignment", AddAssignment),
            ("edit assignment", EditAssignment),
            ("delete assignment", DeleteAssignment),
            ("change status with legacy database mapping", ChangeStatus),
            ("today calculation", TodayCalculation),
            ("natural week calculation", WeekCalculation),
            ("overdue calculation", OverdueCalculation),
            ("completed assignment is not overdue", CompletedIsNotOverdue),
            ("assignment without due date", NoDueDate),
            ("priority sorting", PrioritySorting),
            ("search title course and description", SearchFields),
            ("status course and priority filters", CombinedFilters),
            ("simple and professional mode preserve hidden data", ModeDoesNotLoseData),
            ("v1 database migration and backup", V1Migration),
            ("failed migration restores backup", MigrationFailureRecovery),
            ("unknown legacy status blocks migration", UnknownStatusBlocksMigration),
            ("offset-bearing database due date is rejected", OffsetDueDateIsRejected),
            ("manual backup and restore", ManualBackupRestore),
            ("Chinese and special characters", InternationalText),
            ("shared fixture follows Windows rules", SharedFixtureContract)
        };

        var failures = new List<string>();
        foreach (var test in tests)
        {
            try
            {
                test.Run();
                Console.WriteLine($"PASS  {test.Name}");
            }
            catch (Exception error)
            {
                failures.Add(test.Name);
                Console.Error.WriteLine($"FAIL  {test.Name}\n{error}");
            }
        }

        Console.WriteLine($"\n{tests.Length - failures.Count}/{tests.Length} tests passed.");
        if (failures.Count == 0)
        {
            return 0;
        }
        Console.Error.WriteLine($"Failed: {string.Join(", ", failures)}");
        return 1;
    }

    private static void AddAssignment()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var due = At(2026, 8, 6, 18, 30);
        var id = database.Add(Draft("Mathematics", "Problem set", due));

        var item = Required(database.Get(id));
        Equal("Problem set", item.Title);
        Equal("Mathematics", item.CourseName);
        Equal(due.ToUniversalTime(), item.DueDate?.ToUniversalTime());
        Equal(TaskStatuses.Todo, item.Status);
        Equal(TaskPriorities.Medium, item.Priority);
        using var connection = RawOpen(workspace.DatabasePath);
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT due_date FROM assignments WHERE id = $id";
        command.Parameters.AddWithValue("$id", id);
        var expectedWallTime = TimeZoneInfo.ConvertTime(due, TimeZoneInfo.Local)
            .ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
        Equal(expectedWallTime, Convert.ToString(
            command.ExecuteScalar(),
            CultureInfo.InvariantCulture));
    }

    private static void EditAssignment()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var id = database.Add(Draft("Biology", "Lab notes", At(2026, 8, 6, 12, 0)));
        var edit = AssignmentDraft.From(Required(database.Get(id)));
        edit.Title = "Lab report";
        edit.Description = "Include microscopy images";
        edit.DueDate = null;
        edit.Priority = TaskPriorities.High;
        edit.Status = TaskStatuses.InProgress;
        database.Update(id, edit);

        var item = Required(database.Get(id));
        Equal("Lab report", item.Title);
        Equal("Include microscopy images", item.Description);
        Equal<DateTimeOffset?>(null, item.DueDate);
        Equal(TaskPriorities.High, item.Priority);
        Equal(TaskStatuses.InProgress, item.Status);
    }

    private static void DeleteAssignment()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var id = database.Add(Draft("English", "Essay"));
        database.Delete(id);
        Equal<AssignmentItem?>(null, database.Get(id));
    }

    private static void ChangeStatus()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var id = database.Add(Draft("Physics", "Quiz"));
        database.UpdateStatus(id, TaskStatuses.Done);
        Equal(TaskStatuses.Done, Required(database.Get(id)).Status);

        using var connection = RawOpen(workspace.DatabasePath);
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT status FROM assignments WHERE id = $id";
        command.Parameters.AddWithValue("$id", id);
        Equal("completed", Convert.ToString(command.ExecuteScalar(), CultureInfo.InvariantCulture));
    }

    private static void TodayCalculation()
    {
        var now = At(2026, 8, 5, 10, 0);
        var today = Item(1, "today", At(2026, 8, 5, 23, 30));
        var tomorrow = Item(2, "tomorrow", At(2026, 8, 6, 0, 0));
        True(TaskRules.IsDueToday(today, now, TestTimeZone));
        False(TaskRules.IsDueToday(tomorrow, now, TestTimeZone));
        EqualSequence(
            [1L],
            TaskRules.Apply(
                [today, tomorrow],
                Query(AssignmentView.Today, now)).Select(item => item.Id).ToArray());
    }

    private static void WeekCalculation()
    {
        var now = At(2026, 8, 5, 10, 0); // Wednesday; natural week starts Monday.
        var monday = Item(1, "monday", At(2026, 8, 3, 0, 0));
        var sunday = Item(2, "sunday", At(2026, 8, 9, 23, 59));
        var nextMonday = Item(3, "next monday", At(2026, 8, 10, 0, 0));
        True(TaskRules.IsDueThisWeek(monday, now, TestTimeZone));
        True(TaskRules.IsDueThisWeek(sunday, now, TestTimeZone));
        False(TaskRules.IsDueThisWeek(nextMonday, now, TestTimeZone));
        EqualSequence(
            [1L, 2L],
            TaskRules.Apply(
                [nextMonday, sunday, monday],
                Query(AssignmentView.ThisWeek, now)).Select(item => item.Id).ToArray());
    }

    private static void OverdueCalculation()
    {
        var now = At(2026, 8, 5, 10, 0);
        var overdue = Item(1, "late", At(2026, 8, 5, 9, 59));
        var future = Item(2, "future", At(2026, 8, 5, 10, 1));
        True(TaskRules.IsOverdue(overdue, now));
        False(TaskRules.IsOverdue(future, now));
        EqualSequence(
            [1L],
            TaskRules.Apply(
                [future, overdue],
                Query(AssignmentView.Overdue, now)).Select(item => item.Id).ToArray());
    }

    private static void CompletedIsNotOverdue()
    {
        var now = At(2026, 8, 5, 10, 0);
        var done = Item(
            1,
            "submitted",
            At(2026, 8, 1, 10, 0),
            status: TaskStatuses.Done);
        False(TaskRules.IsOverdue(done, now));
        Equal(0, TaskRules.Apply([done], Query(AssignmentView.Overdue, now)).Count);
    }

    private static void NoDueDate()
    {
        var now = At(2026, 8, 5, 10, 0);
        var item = Item(1, "someday", dueDate: null);
        False(TaskRules.IsDueToday(item, now, TestTimeZone));
        False(TaskRules.IsDueThisWeek(item, now, TestTimeZone));
        False(TaskRules.IsOverdue(item, now));
        Equal(1, TaskRules.Apply([item], Query(AssignmentView.All, now)).Count);
    }

    private static void PrioritySorting()
    {
        var items = new[]
        {
            Item(1, "low", At(2026, 8, 5, 9, 0), priority: TaskPriorities.Low),
            Item(2, "high", At(2026, 8, 6, 9, 0), priority: TaskPriorities.High),
            Item(3, "medium", At(2026, 8, 4, 9, 0), priority: TaskPriorities.Medium)
        };
        EqualSequence(
            [2L, 3L, 1L],
            TaskRules.Apply(
                items,
                new AssignmentQuery { Sort = AssignmentSort.PriorityDescending })
                .Select(item => item.Id)
                .ToArray());
    }

    private static void SearchFields()
    {
        var items = new[]
        {
            Item(1, "Quadratic worksheet", course: "Mathematics"),
            Item(2, "Reading", course: "History", description: "Silk Road chapter"),
            Item(3, "Experiment", course: "Chemistry")
        };
        EqualSequence([1L], Search(items, "quadratic"));
        EqualSequence([2L], Search(items, "history"));
        EqualSequence([2L], Search(items, "silk road"));
        Equal(0, Search(items, "manual").Length);
    }

    private static void CombinedFilters()
    {
        var items = new[]
        {
            Item(1, "A", course: "Math", priority: TaskPriorities.High),
            Item(2, "B", course: "Math", status: TaskStatuses.Done, priority: TaskPriorities.High),
            Item(3, "C", course: "Art", priority: TaskPriorities.High)
        };
        var query = new AssignmentQuery
        {
            Course = "math",
            Status = TaskStatuses.Todo,
            Priority = TaskPriorities.High
        };
        EqualSequence([1L], TaskRules.Apply(items, query).Select(item => item.Id).ToArray());
    }

    private static void ModeDoesNotLoseData()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var original = Draft("Computer Science", "Parser project");
        original.Description = "Keep <all> hidden fields & symbols";
        original.Link = "https://example.test/a?x=1&y=二";
        original.Priority = TaskPriorities.High;
        var id = database.Add(original);

        var settingsStore = new AppSettingsStore(workspace.SettingsPath);
        settingsStore.Save(new AppSettings
        {
            DetailMode = AssignmentDisplayMode.Professional,
            Theme = AppTheme.Dark
        });
        var settings = settingsStore.Load();
        Equal(AssignmentDisplayMode.Professional, settings.DetailMode);
        settings.DetailMode = AssignmentDisplayMode.Simple;
        settingsStore.Save(settings);

        var simpleEdit = AssignmentDraft.From(Required(database.Get(id)));
        simpleEdit.Title = "Parser project revised";
        database.Update(id, simpleEdit);
        var saved = Required(database.Get(id));
        Equal("Keep <all> hidden fields & symbols", saved.Description);
        Equal("https://example.test/a?x=1&y=二", saved.Link);
        Equal(TaskPriorities.High, saved.Priority);
        Equal(AssignmentDisplayMode.Simple, settingsStore.Load().DetailMode);
    }

    private static void V1Migration()
    {
        using var workspace = new TestWorkspace();
        CreateV1Database(workspace.DatabasePath);
        var database = workspace.Database();

        Equal(AssignmentDatabase.CurrentSchemaVersion, database.SchemaVersion);
        True(database.LastBackupPath is { } path && File.Exists(path));
        var migrated = Required(database.Get(7));
        Equal("Legacy homework", migrated.Title);
        Equal(TaskStatuses.Todo, migrated.Status);
        Equal(TaskPriorities.Medium, migrated.Priority);
        Equal<DateTimeOffset?>(null, migrated.DueDate);

        var id = database.Add(Draft("New course", "No due date", dueDate: null));
        True(id > 0);
    }

    private static void MigrationFailureRecovery()
    {
        using var workspace = new TestWorkspace();
        CreateV1Database(workspace.DatabasePath);
        var options = new AssignmentDatabaseOptions
        {
            OnMigrationCheckpoint = checkpoint =>
            {
                if (checkpoint == MigrationCheckpoint.BeforeCommit)
                {
                    throw new InvalidOperationException("Injected migration failure.");
                }
            }
        };

        DatabaseMigrationException error;
        try
        {
            _ = workspace.Database(options);
            throw new TestFailureException("Expected migration to fail.");
        }
        catch (DatabaseMigrationException caught)
        {
            error = caught;
        }

        True(error.BackupPath is { } backupPath && File.Exists(backupPath));
        using var connection = RawOpen(workspace.DatabasePath);
        using var row = connection.CreateCommand();
        row.CommandText = "SELECT title FROM assignments WHERE id = 7";
        Equal("Legacy homework", Convert.ToString(row.ExecuteScalar(), CultureInfo.InvariantCulture));
        using var columns = connection.CreateCommand();
        columns.CommandText =
            "SELECT 1 FROM pragma_table_info('assignments') WHERE name = 'priority'";
        Equal<object?>(null, columns.ExecuteScalar());
    }

    private static void UnknownStatusBlocksMigration()
    {
        using var workspace = new TestWorkspace();
        using (var connection = RawOpen(workspace.DatabasePath))
        using (var command = connection.CreateCommand())
        {
            command.CommandText =
                """
                CREATE TABLE assignments (
                    id INTEGER PRIMARY KEY,
                    course_name TEXT NOT NULL,
                    title TEXT NOT NULL,
                    due_date DATETIME,
                    description TEXT,
                    link TEXT,
                    status TEXT NOT NULL,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL
                );
                INSERT INTO assignments VALUES (
                    1, 'Test', 'Unknown', NULL, NULL, NULL, 'archived',
                    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
                );
                PRAGMA user_version = 1;
                """;
            command.ExecuteNonQuery();
        }

        try
        {
            _ = workspace.Database();
            throw new TestFailureException("Expected unknown status to block migration.");
        }
        catch (InvalidDataException error)
        {
            True(error.Message.Contains("archived", StringComparison.Ordinal));
        }
        Equal(0, Directory.EnumerateFiles(workspace.DirectoryPath, "*.bak").Count());
        using var verification = RawOpen(workspace.DatabasePath);
        using var status = verification.CreateCommand();
        status.CommandText = "SELECT status FROM assignments WHERE id = 1";
        Equal("archived", Convert.ToString(status.ExecuteScalar(), CultureInfo.InvariantCulture));
    }

    private static void ManualBackupRestore()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var id = database.Add(Draft("Music", "Practice"));
        var backup = database.CreateBackup();
        database.Delete(id);
        Equal<AssignmentItem?>(null, database.Get(id));
        database.RestoreBackup(backup);
        Equal("Practice", Required(database.Get(id)).Title);
    }

    private static void OffsetDueDateIsRejected()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var id = database.Add(Draft("Time zones", "Wall time only"));
        using (var connection = RawOpen(workspace.DatabasePath))
        using (var command = connection.CreateCommand())
        {
            command.CommandText =
                "UPDATE assignments SET due_date = '2026-08-05T12:00:00+08:00' WHERE id = $id";
            command.Parameters.AddWithValue("$id", id);
            command.ExecuteNonQuery();
        }
        try
        {
            _ = database.Get(id);
            throw new TestFailureException("Expected offset-bearing due_date to be rejected.");
        }
        catch (InvalidDataException error)
        {
            True(error.Message.Contains("local wall time", StringComparison.Ordinal));
        }
    }

    private static void InternationalText()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var draft = Draft("语文 / 日本語", "阅读《呐喊》— café ☕");
        draft.Description = "引号 “测试”、emoji 🧪、换行\nsecond line";
        draft.Link = "https://例子.测试/课程?q=特殊%20字符";
        var id = database.Add(draft);
        var item = Required(database.Get(id));
        Equal(draft.CourseName, item.CourseName);
        Equal(draft.Title, item.Title);
        Equal(draft.Description, item.Description);
        Equal(draft.Link, item.Link);
        EqualSequence([id], Search(database.FetchAssignments(), "呐喊"));
    }

    private static void SharedFixtureContract()
    {
        var fixturePath = FindSharedFixture();
        if (fixturePath is null)
        {
            Console.WriteLine("SKIP  shared fixture not present yet");
            return;
        }

        using var document = JsonDocument.Parse(File.ReadAllText(fixturePath));
        var root = document.RootElement;
        var assignments = root.ValueKind == JsonValueKind.Array
            ? root
            : root.TryGetProperty("tasks", out var property)
                ? property
                : root.TryGetProperty("assignments", out property)
                    ? property
                    : throw new TestFailureException("Shared fixture needs a tasks array.");
        var nowText = root.ValueKind == JsonValueKind.Object
            ? Text(root, "now")
            : null;
        var fixtureNow = nowText is null
            ? At(2026, 8, 5, 12, 0)
            : ParseWallTime(nowText, TestTimeZone);
        var items = new List<AssignmentItem>();
        var fallbackId = 1L;
        foreach (var value in assignments.EnumerateArray())
        {
            var dueText = Text(value, "due_at") ?? Text(value, "due_date");
            DateTimeOffset? dueDate = null;
            if (dueText is not null)
            {
                dueDate = ParseWallTime(dueText, TestTimeZone);
            }
            items.Add(new AssignmentItem
            {
                Id = Number(value, "id") ?? fallbackId,
                CourseName = Text(value, "course_name") ?? Text(value, "course") ?? "Fixture",
                Title = Text(value, "title") ?? "Untitled",
                Description = Text(value, "description"),
                DueDate = dueDate,
                Status = TaskStatuses.Normalize(Text(value, "status") ?? TaskStatuses.Todo),
                Priority = TaskPriorities.Normalize(
                    Text(value, "priority") ?? TaskPriorities.Medium)
            });
            fallbackId++;
        }

        foreach (var item in items)
        {
            True(TaskStatuses.IsValid(item.Status));
            True(TaskPriorities.IsValid(item.Priority));
        }
        if (root.ValueKind == JsonValueKind.Object &&
            root.TryGetProperty("expected_views", out var expectedViews))
        {
            var views = new Dictionary<string, AssignmentView>(StringComparer.OrdinalIgnoreCase)
            {
                ["all"] = AssignmentView.All,
                ["today"] = AssignmentView.Today,
                ["week"] = AssignmentView.ThisWeek,
                ["overdue"] = AssignmentView.Overdue,
                ["completed"] = AssignmentView.Completed
            };
            foreach (var expected in expectedViews.EnumerateObject())
            {
                if (!views.TryGetValue(expected.Name, out var view))
                {
                    continue;
                }
                var expectedIds = expected.Value.EnumerateArray()
                    .Select(id => id.GetInt64())
                    .OrderBy(id => id)
                    .ToArray();
                var actualIds = TaskRules.Apply(items, new AssignmentQuery
                    {
                        View = view,
                        Now = fixtureNow,
                        TimeZone = TestTimeZone
                    })
                    .Select(item => item.Id)
                    .OrderBy(id => id)
                    .ToArray();
                EqualSequence(expectedIds, actualIds);
            }
        }
        if (root.ValueKind == JsonValueKind.Object &&
            root.TryGetProperty("expected_sorts", out var expectedSorts))
        {
            AssertFixtureSort(expectedSorts, "due_date", AssignmentSort.DueDateAscending);
            AssertFixtureSort(expectedSorts, "priority", AssignmentSort.PriorityDescending);
        }

        void AssertFixtureSort(
            JsonElement expectedSortsValue,
            string name,
            AssignmentSort sort)
        {
            if (!expectedSortsValue.TryGetProperty(name, out var expected))
            {
                return;
            }
            var expectedIds = expected.EnumerateArray().Select(id => id.GetInt64()).ToArray();
            var actualIds = TaskRules.Apply(items, new AssignmentQuery
                {
                    Sort = sort,
                    Now = fixtureNow,
                    TimeZone = TestTimeZone
                })
                .Select(item => item.Id)
                .ToArray();
            EqualSequence(expectedIds, actualIds);
        }
    }

    private static AssignmentDraft Draft(
        string course,
        string title,
        DateTimeOffset? dueDate = null) => new()
    {
        CourseName = course,
        Title = title,
        DueDate = dueDate,
        Status = TaskStatuses.Todo,
        Priority = TaskPriorities.Medium
    };

    private static AssignmentItem Item(
        long id,
        string title,
        DateTimeOffset? dueDate = null,
        string course = "Course",
        string? description = null,
        string status = TaskStatuses.Todo,
        string priority = TaskPriorities.Medium) => new()
    {
        Id = id,
        CourseName = course,
        Title = title,
        DueDate = dueDate,
        Description = description,
        Status = status,
        Priority = priority
    };

    private static AssignmentQuery Query(AssignmentView view, DateTimeOffset now) => new()
    {
        View = view,
        Now = now,
        TimeZone = TestTimeZone
    };

    private static DateTimeOffset At(
        int year,
        int month,
        int day,
        int hour,
        int minute) => new(year, month, day, hour, minute, 0, TimeSpan.FromHours(8));

    private static long[] Search(IEnumerable<AssignmentItem> items, string search) =>
        TaskRules.Apply(items, new AssignmentQuery { Search = search })
            .Select(item => item.Id)
            .ToArray();

    private static void CreateV1Database(string path)
    {
        using var connection = RawOpen(path);
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            CREATE TABLE assignments (
                id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                course_name VARCHAR(120) NOT NULL,
                title VARCHAR(255) NOT NULL,
                due_date DATETIME NOT NULL,
                description TEXT,
                link VARCHAR(1000),
                status VARCHAR(20) NOT NULL DEFAULT 'not_started',
                source_name VARCHAR(255),
                source_type VARCHAR(80),
                source_file VARCHAR(1000),
                source_url VARCHAR(1000),
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
                CHECK (status IN ('not_started', 'in_progress', 'completed'))
            );
            INSERT INTO assignments (
                id, course_name, title, due_date, status
            ) VALUES (
                7, 'Legacy course', 'Legacy homework', '', 'not_started'
            );
            PRAGMA user_version = 1;
            """;
        command.ExecuteNonQuery();
    }

    private static DateTimeOffset ParseWallTime(string value, TimeZoneInfo timeZone)
    {
        var wallTime = DateTime.Parse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AllowWhiteSpaces);
        wallTime = DateTime.SpecifyKind(wallTime, DateTimeKind.Unspecified);
        return new DateTimeOffset(wallTime, timeZone.GetUtcOffset(wallTime));
    }

    private static SqliteConnection RawOpen(string path)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false
        }.ToString());
        connection.Open();
        return connection;
    }

    private static string? FindSharedFixture()
    {
        foreach (var start in new[] { AppContext.BaseDirectory, Directory.GetCurrentDirectory() })
        {
            var directory = new DirectoryInfo(start);
            for (var level = 0; level < 12 && directory is not null; level++)
            {
                var fixtureDirectory = Path.Combine(directory.FullName, "shared", "fixtures");
                if (Directory.Exists(fixtureDirectory))
                {
                    var preferred = Path.Combine(
                        fixtureDirectory,
                        "task-conformance-v2.json");
                    var fixture = File.Exists(preferred)
                        ? preferred
                        : Directory.EnumerateFiles(fixtureDirectory, "*.json")
                        .OrderBy(path => path, StringComparer.Ordinal)
                        .FirstOrDefault();
                    if (fixture is not null)
                    {
                        return fixture;
                    }
                }
                directory = directory.Parent;
            }
        }
        return null;
    }

    private static string? Text(JsonElement value, string propertyName) =>
        value.TryGetProperty(propertyName, out var property) &&
        property.ValueKind == JsonValueKind.String
            ? property.GetString()
            : null;

    private static long? Number(JsonElement value, string propertyName) =>
        value.TryGetProperty(propertyName, out var property) && property.TryGetInt64(out var number)
            ? number
            : null;

    private static T Required<T>(T? value) where T : class =>
        value ?? throw new TestFailureException("Expected a non-null value.");

    private static void True(bool value)
    {
        if (!value)
        {
            throw new TestFailureException("Expected true, got false.");
        }
    }

    private static void False(bool value) => True(!value);

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new TestFailureException($"Expected {expected}, got {actual}.");
        }
    }

    private static void EqualSequence<T>(IReadOnlyList<T> expected, IReadOnlyList<T> actual)
    {
        if (!expected.SequenceEqual(actual))
        {
            throw new TestFailureException(
                $"Expected [{string.Join(", ", expected)}], got [{string.Join(", ", actual)}].");
        }
    }

    private sealed class TestWorkspace : IDisposable
    {
        public string DirectoryPath { get; } = Path.Combine(
            Path.GetTempPath(),
            $"assignment-core-tests-{Guid.NewGuid():N}");
        public string DatabasePath => Path.Combine(DirectoryPath, "assignments.db");
        public string SettingsPath => Path.Combine(DirectoryPath, "settings.json");

        public TestWorkspace() => Directory.CreateDirectory(DirectoryPath);

        public AssignmentDatabase Database(AssignmentDatabaseOptions? options = null) =>
            new(DatabasePath, options);

        public void Dispose()
        {
            if (Directory.Exists(DirectoryPath))
            {
                Directory.Delete(DirectoryPath, recursive: true);
            }
        }
    }

    private sealed class TestFailureException(string message) : Exception(message);
}
