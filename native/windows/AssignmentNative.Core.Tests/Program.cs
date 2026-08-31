using System.Globalization;
using System.Diagnostics;
using System.Runtime.InteropServices;
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

    public static int Main(string[] args)
    {
        if (args.Length > 0)
        {
            if (args.Length == 2 &&
                string.Equals(args[0], "--verify-database", StringComparison.Ordinal))
                return VerifyDatabase(args[1]);
            if (args.Length == 2 &&
                string.Equals(args[0], "--create-contract-database", StringComparison.Ordinal))
                return CreateContractDatabase(args[1]);
            return PrintUsage();
        }

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
            ("navigation pane mode persists with existing settings", NavigationPaneModePersists),
            ("settings path override isolates desktop acceptance", SettingsPathOverrideIsolates),
            ("WinUI editor projection preserves v3 fields and derives status", EditorProjectionPreservesV3Fields),
            ("unchanged due controls preserve seconds and raw value", DueControlBaselinePreservesPrecision),
            ("v1 database migration and backup", V1Migration),
            ("failed migration restores backup", MigrationFailureRecovery),
            ("failed migration automatically restores in place", AutomaticMigrationRestoreInPlace),
            ("failed migration preserves healthy concurrent write", ConcurrentRollbackWriteIsPreserved),
            ("failed migration preserves concurrent valid v3", ConcurrentValidV3IsPreserved),
            ("failed migration preserves healthy newer schema", HealthyNewerSchemaIsPreserved),
            ("missing rollback evidence fails closed", MissingRollbackEvidenceFailsClosed),
            ("unknown legacy status blocks migration", UnknownStatusBlocksMigration),
            ("offset-bearing database due date is rejected", OffsetDueDateIsRejected),
            ("raw due date and task timezone survive unrelated edits", RawDueDateAndTimeZone),
            ("due display uses task timezone", DueDisplayUsesTaskTimeZone),
            ("invalid due date and unknown IANA zone are rejected", InvalidDueDateAndTimeZone),
            ("manual backup and restore", ManualBackupRestore),
            ("Chinese and special characters", InternationalText),
            ("shared fixture follows Windows rules", SharedFixtureContract),
            ("schema v3 migration preserves shared organization fixture", SchemaV3MigrationFixture),
            ("schema v3 normalization and UUID vectors", SchemaV3IdentityVectors),
            ("migrated course can be renamed and reopened", MigratedCourseRenameReopens),
            ("course project and tag CRUD", OrganizationCrud),
            ("task tags detach and restore", TaskTagLifecycle),
            ("subtasks derive parent progress", SubtaskDerivedProgress),
            ("attachment metadata is safe and contains no payload", AttachmentMetadataContract),
            ("attachment payload lifecycle is atomic and reconciled", AttachmentPayloadLifecycle),
            ("reminders require UTC and canonical recurrence", ReminderContract),
            ("soft deleted tasks restore without losing fields", TaskSoftDeleteRestore),
            ("task edit preserves soft deleted organization links", DeletedOrganizationLinksSurviveTaskEdit),
            ("legacy hidden link survives simple editor", LegacyHiddenLinkSurvivesSimpleEditor),
            ("database identity is immutable", DatabaseIdentityImmutable),
            ("forged v3 organization rows are rejected", ForgedOrganizationRowsAreRejected),
            ("forged nullable v3 scalar is rejected", ForgedNullableScalarIsRejected),
            ("concurrent initializers serialize migration", ConcurrentMigration),
            ("ordinary writer waits for migration lock", OrdinaryWriterWaitsForMigration),
            ("v2 additive extension column survives migration", V2ExtensionSurvivesMigration)
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

    private static int PrintUsage()
    {
        Console.Error.WriteLine(
            "Usage: AssignmentNative.Core.Tests " +
            "[--verify-database|--create-contract-database <absolute-path>]");
        return 2;
    }

    private static int CreateContractDatabase(string databasePath)
    {
        try
        {
            var fullPath = Path.GetFullPath(databasePath);
            if (File.Exists(fullPath))
                throw new IOException($"Refusing to overwrite an existing database: {fullPath}");
            Directory.CreateDirectory(Path.GetDirectoryName(fullPath)
                ?? throw new InvalidOperationException("Database path has no parent directory."));
            var database = new AssignmentDatabase(fullPath);
            var repository = new TaskOrganizationRepository(database);
            var course = repository.CreateCourse(
                new CourseDraft("跨平台 Contract 🧪", "#3366AA", "Teacher", "2026 Fall"));
            var project = repository.CreateProject(
                new ProjectDraft("Phase 1", course.Id, "Shared schema v3", ProjectStatuses.Active));
            var draft = Draft(course.Name, "Windows-generated fixture");
            draft.CourseId = course.Id;
            draft.ProjectId = project.Id;
            draft.Description = "Unicode + timezone + organization metadata";
            draft.TimezoneId = "America/Los_Angeles";
            draft.DueDate = LocalWallTime.FromLocalDateTime(
                new DateTime(2026, 11, 2, 14, 5, 0),
                LocalWallTime.ResolveTimeZone(draft.TimezoneId));
            var task = database.Add(draft);
            var tag = repository.CreateTag(new TagDraft("Cross-platform", "#AA3366"));
            repository.AttachTag(task, tag.Id);
            repository.CreateSubtask(
                new SubtaskDraft(task, "Contract child", TaskStatuses.InProgress, 0));
            repository.CreateReminder(new ReminderDraft(
                task,
                new DateTimeOffset(2026, 11, 2, 21, 0, 0, TimeSpan.Zero),
                15,
                "FREQ=WEEKLY;BYDAY=MO"));
            Console.WriteLine($"PASS  created Windows Core schema v3 contract database: {fullPath}");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"FAIL  create contract database\n{error}");
            return 1;
        }
    }

    private static int VerifyDatabase(string databasePath)
    {
        try
        {
            var fullPath = Path.GetFullPath(databasePath);
            if (!File.Exists(fullPath))
            {
                throw new TestFailureException(
                    $"Smoke database was not created at {fullPath}.");
            }

            using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = fullPath,
                Mode = SqliteOpenMode.ReadOnly,
                Pooling = false
            }.ToString());
            connection.Open();

            using var version = connection.CreateCommand();
            version.CommandText = "PRAGMA user_version";
            Equal(
                AssignmentDatabase.CurrentSchemaVersion,
                Convert.ToInt32(version.ExecuteScalar(), CultureInfo.InvariantCulture));

            using var integrity = connection.CreateCommand();
            integrity.CommandText = "PRAGMA quick_check";
            Equal(
                "ok",
                Convert.ToString(integrity.ExecuteScalar(), CultureInfo.InvariantCulture));
            using var foreignKeys = connection.CreateCommand();
            foreignKeys.CommandText = "PRAGMA foreign_keys=ON";
            foreignKeys.ExecuteNonQuery();
            SchemaV3Contract.Validate(connection);

            Console.WriteLine(
                $"PASS  launch smoke database (schema v{AssignmentDatabase.CurrentSchemaVersion}, " +
                "quick_check ok, complete v3 contract)");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"FAIL  launch smoke database\n{error}");
            return 1;
        }
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

    private static void NavigationPaneModePersists()
    {
        using var workspace = new TestWorkspace();
        var settingsStore = new AppSettingsStore(workspace.SettingsPath);
        settingsStore.Save(new AppSettings
        {
            DetailMode = AssignmentDisplayMode.Professional,
            Theme = AppTheme.Dark,
            NavigationPaneMode = NavigationPaneMode.Compact
        });

        var restored = settingsStore.Load();
        Equal(AssignmentDisplayMode.Professional, restored.DetailMode);
        Equal(AppTheme.Dark, restored.Theme);
        Equal(NavigationPaneMode.Compact, restored.NavigationPaneMode);
    }

    private static void SettingsPathOverrideIsolates()
    {
        using var workspace = new TestWorkspace();
        var previous = Environment.GetEnvironmentVariable("ASSIGNMENT_SETTINGS_PATH");
        try
        {
            Environment.SetEnvironmentVariable("ASSIGNMENT_SETTINGS_PATH", workspace.SettingsPath);
            var store = new AppSettingsStore();
            Equal(Path.GetFullPath(workspace.SettingsPath), store.SettingsPath);
            store.Save(new AppSettings { NavigationPaneMode = NavigationPaneMode.Compact });
            Equal(NavigationPaneMode.Compact, store.Load().NavigationPaneMode);
        }
        finally
        {
            Environment.SetEnvironmentVariable("ASSIGNMENT_SETTINGS_PATH", previous);
        }
    }

    private static void EditorProjectionPreservesV3Fields()
    {
        var storedDue = new DateTimeOffset(2026, 3, 8, 3, 30, 0, TimeSpan.FromHours(-7));
        var existing = new AssignmentItem
        {
            Id = 41,
            Uuid = Guid.NewGuid().ToString("D"),
            CourseName = "Physics",
            Title = "Lab",
            DueDate = storedDue,
            Status = TaskStatuses.Todo,
            Priority = TaskPriorities.High,
            SourceName = "Imported",
            SourceType = "file",
            SourceFile = "lab.md",
            SourceUrl = "https://example.test/lab",
            CourseId = 7,
            ProjectId = 9,
            ProgressPercent = 0,
            AllDay = true,
            TimezoneId = "America/Los_Angeles",
            StoredDueDateText = "2026-03-08 02:30:00.123456",
            StoredDueDateValue = storedDue
        };
        var unchanged = TaskEditorDraftProjection.Apply(
            existing,
            existing.CourseName,
            "Lab revised",
            existing.DueDate,
            existing.Status,
            "hidden description",
            existing.Priority,
            "https://example.test/lab");
        Equal(7L, unchanged.CourseId);
        Equal(9L, unchanged.ProjectId);
        Equal(0, unchanged.ProgressPercent);
        True(unchanged.AllDay);
        Equal("America/Los_Angeles", unchanged.TimezoneId);
        Equal(existing.StoredDueDateText, unchanged.StoredDueDateText);
        Equal("file", unchanged.SourceType);

        var completed = TaskEditorDraftProjection.Apply(
            existing,
            existing.CourseName,
            existing.Title,
            existing.DueDate,
            TaskStatuses.Done,
            existing.Description,
            existing.Priority,
            existing.Link);
        Equal<int?>(null, completed.ProgressPercent);

        var moved = TaskEditorDraftProjection.Apply(
            existing,
            "Chemistry",
            existing.Title,
            existing.DueDate,
            existing.Status,
            existing.Description,
            existing.Priority,
            existing.Link);
        Equal<long?>(null, moved.CourseId);
        Equal<long?>(null, moved.ProjectId);

        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var stored = Draft("Physics", "Move me");
        var id = database.Add(stored);
        var movedStored = TaskEditorDraftProjection.Apply(
            Required(database.Get(id)),
            "Chemistry",
            "Move me",
            null,
            TaskStatuses.Todo,
            null,
            TaskPriorities.Medium,
            null);
        database.Update(id, movedStored);
        Equal("Chemistry", Required(database.Get(id)).CourseName);
    }

    private static void DueControlBaselinePreservesPrecision()
    {
        var zone = LocalWallTime.ResolveTimeZone("America/Los_Angeles");
        const string raw = "2026-11-02 14:05:37.123456";
        var exact = LocalWallTime.ParseLegacy(raw, zone)!.Value;
        var existing = new AssignmentItem
        {
            Id = 2,
            DueDate = exact,
            TimezoneId = "America/Los_Angeles",
            StoredDueDateText = raw,
            StoredDueDateValue = exact
        };
        // This is the minute-granularity value exposed by the WinUI TimePicker,
        // not the seconds/fractional precision loaded from SQLite.
        var loaded = new TaskDueControlState(
            true,
            new DateOnly(2026, 11, 2),
            new TimeSpan(14, 5, 0));
        var unchanged = TaskDueEditorProjection.Resolve(
            existing,
            loaded,
            loaded,
            zone);
        Equal(exact, unchanged);
        var draft = AssignmentDraft.From(existing);
        draft.DueDate = unchanged;
        Equal(raw, LocalWallTime.StoredText(
            draft.DueDate,
            draft.StoredDueDateText,
            draft.StoredDueDateValue,
            zone));

        var changedControls = loaded with { Time = new TimeSpan(14, 6, 0) };
        var changed = TaskDueEditorProjection.Resolve(
            existing,
            loaded,
            changedControls,
            zone);
        Equal("2026-11-02 14:06:00", LocalWallTime.Format(changed!.Value, zone));
        Equal<DateTimeOffset?>(null, TaskDueEditorProjection.Resolve(
            existing,
            loaded,
            loaded with { HasDueDate = false },
            zone));
        Throws<ArgumentException>(() => TaskDueEditorProjection.Resolve(
            existing: null,
            new TaskDueControlState(false, null, default),
            new TaskDueControlState(true, null, new TimeSpan(14, 5, 0)),
            zone));

        var emptyRaw = new AssignmentItem
        {
            DueDate = null,
            StoredDueDateText = "",
            StoredDueDateValue = null
        };
        Equal("", LocalWallTime.StoredText(
            TaskDueEditorProjection.Resolve(
                emptyRaw,
                new TaskDueControlState(false, null, default),
                new TaskDueControlState(false, null, default),
                zone),
            emptyRaw.StoredDueDateText,
            emptyRaw.StoredDueDateValue,
            zone));
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

    private static void AutomaticMigrationRestoreInPlace()
    {
        using var workspace = new TestWorkspace();
        CreateV1Database(workspace.DatabasePath);
        var originalIdentity = FileIdentity(workspace.DatabasePath);
        using var writerStarted = new ManualResetEventSlim();
        Task? externalWriter = null;
        var options = new AssignmentDatabaseOptions
        {
            PreserveFailedMigrationStateForRecoveryTest = true,
            OnMigrationCheckpoint = checkpoint =>
            {
                if (checkpoint == MigrationCheckpoint.BeforeCommit)
                    throw new InvalidOperationException("Injected migration failure.");
                if (checkpoint == MigrationCheckpoint.AfterRecoveryFingerprintBeforeRestore)
                {
                    externalWriter = Task.Run(() =>
                    {
                        using var connection = RawOpen(workspace.DatabasePath);
                        using var write = connection.CreateCommand();
                        write.CommandText =
                            "PRAGMA busy_timeout=10000; " +
                            "UPDATE assignments SET title='External post-restore edit' WHERE id=7";
                        writerStarted.Set();
                        write.ExecuteNonQuery();
                    });
                    True(writerStarted.Wait(TimeSpan.FromSeconds(10)));
                    False(externalWriter.Wait(TimeSpan.FromMilliseconds(150)));
                }
            }
        };

        var error = ThrowsResult<DatabaseMigrationException>(() => workspace.Database(options));
        True(error.Message.Contains("preserved or restored", StringComparison.Ordinal));
        var completedWriter = externalWriter
            ?? throw new TestFailureException("The restore checkpoint did not start its writer.");
        True(completedWriter.Wait(TimeSpan.FromSeconds(10)));
        if (completedWriter.IsFaulted)
            throw completedWriter.Exception!.InnerException ?? completedWriter.Exception;
        Equal(originalIdentity, FileIdentity(workspace.DatabasePath));
        using var verification = RawOpen(workspace.DatabasePath);
        using var title = verification.CreateCommand();
        title.CommandText = "SELECT title FROM assignments WHERE id=7";
        Equal(
            "External post-restore edit",
            Convert.ToString(title.ExecuteScalar(), CultureInfo.InvariantCulture));
        using var version = verification.CreateCommand();
        version.CommandText = "PRAGMA user_version";
        Equal(1L, Convert.ToInt64(version.ExecuteScalar(), CultureInfo.InvariantCulture));
        using var priority = verification.CreateCommand();
        priority.CommandText =
            "SELECT 1 FROM pragma_table_info('assignments') WHERE name='priority'";
        Equal<object?>(null, priority.ExecuteScalar());
    }

    private static void ConcurrentRollbackWriteIsPreserved()
    {
        using var workspace = new TestWorkspace();
        CreateV1Database(workspace.DatabasePath);
        var options = new AssignmentDatabaseOptions
        {
            OnMigrationCheckpoint = checkpoint =>
            {
                if (checkpoint == MigrationCheckpoint.BeforeCommit)
                    throw new InvalidOperationException("Injected migration failure.");
                if (checkpoint == MigrationCheckpoint.AfterRollbackBeforeVerification)
                {
                    using var connection = RawOpen(workspace.DatabasePath);
                    using var externalWrite = connection.CreateCommand();
                    externalWrite.CommandText =
                        "UPDATE assignments SET title='Concurrent committed edit' WHERE id=7";
                    externalWrite.ExecuteNonQuery();
                }
            }
        };

        var error = ThrowsResult<DatabaseMigrationException>(() => workspace.Database(options));
        True(error.Message.Contains("live database state was preserved", StringComparison.Ordinal));
        using var verification = RawOpen(workspace.DatabasePath);
        using var title = verification.CreateCommand();
        title.CommandText = "SELECT title FROM assignments WHERE id=7";
        Equal(
            "Concurrent committed edit",
            Convert.ToString(title.ExecuteScalar(), CultureInfo.InvariantCulture));
        using var version = verification.CreateCommand();
        version.CommandText = "PRAGMA user_version";
        Equal(1L, Convert.ToInt64(version.ExecuteScalar(), CultureInfo.InvariantCulture));
    }

    private static void ConcurrentValidV3IsPreserved()
    {
        using var workspace = new TestWorkspace();
        var concurrentPath = Path.Combine(workspace.DirectoryPath, "concurrent-v3.db");
        var concurrent = new AssignmentDatabase(concurrentPath);
        var concurrentId = concurrent.Add(Draft("Concurrent", "Valid v3 committed elsewhere"));
        CreateV1Database(workspace.DatabasePath);
        var options = new AssignmentDatabaseOptions
        {
            OnMigrationCheckpoint = checkpoint =>
            {
                if (checkpoint == MigrationCheckpoint.BeforeCommit)
                    throw new InvalidOperationException("Injected migration failure.");
                if (checkpoint == MigrationCheckpoint.AfterRollbackBeforeVerification)
                    CopyDatabase(concurrentPath, workspace.DatabasePath);
            }
        };
        var error = ThrowsResult<DatabaseMigrationException>(() => workspace.Database(options));
        True(error.Message.Contains("live database state was preserved", StringComparison.Ordinal));
        var reopened = workspace.Database();
        Equal(3, reopened.SchemaVersion);
        Equal("Valid v3 committed elsewhere", Required(reopened.Get(concurrentId)).Title);
    }

    private static void HealthyNewerSchemaIsPreserved()
    {
        using var workspace = new TestWorkspace();
        CreateV1Database(workspace.DatabasePath);
        var options = new AssignmentDatabaseOptions
        {
            OnMigrationCheckpoint = checkpoint =>
            {
                if (checkpoint == MigrationCheckpoint.BeforeCommit)
                    throw new InvalidOperationException("Injected migration failure.");
                if (checkpoint == MigrationCheckpoint.AfterRollbackBeforeVerification)
                {
                    using var connection = RawOpen(workspace.DatabasePath);
                    using var newer = connection.CreateCommand();
                    newer.CommandText =
                        "UPDATE assignments SET title='Newer healthy state' WHERE id=7; " +
                        "PRAGMA user_version=99";
                    newer.ExecuteNonQuery();
                }
            }
        };
        var error = ThrowsResult<DatabaseMigrationException>(() => workspace.Database(options));
        True(error.Message.Contains("live database state was preserved", StringComparison.Ordinal));
        using var verification = RawOpen(workspace.DatabasePath);
        using var state = verification.CreateCommand();
        state.CommandText = "SELECT title FROM assignments WHERE id=7";
        Equal(
            "Newer healthy state",
            Convert.ToString(state.ExecuteScalar(), CultureInfo.InvariantCulture));
        using var version = verification.CreateCommand();
        version.CommandText = "PRAGMA user_version";
        Equal(99L, Convert.ToInt64(version.ExecuteScalar(), CultureInfo.InvariantCulture));
    }

    private static void MissingRollbackEvidenceFailsClosed()
    {
        using var workspace = new TestWorkspace();
        CreateV1Database(workspace.DatabasePath);
        var options = new AssignmentDatabaseOptions
        {
            OnMigrationCheckpoint = checkpoint =>
            {
                if (checkpoint == MigrationCheckpoint.BeforeCommit)
                    throw new InvalidOperationException("Injected migration failure.");
                if (checkpoint == MigrationCheckpoint.BeforeRollbackEvidenceCapture)
                    throw new IOException("Injected rollback evidence failure.");
            }
        };
        var error = ThrowsResult<DatabaseMigrationException>(() => workspace.Database(options));
        True(error.BackupPath is { } backup && File.Exists(backup));
        True(error.Message.Contains("could not be verified", StringComparison.Ordinal));
        using var verification = RawOpen(workspace.DatabasePath);
        using var title = verification.CreateCommand();
        title.CommandText = "SELECT title FROM assignments WHERE id=7";
        Equal("Legacy homework", Convert.ToString(title.ExecuteScalar(), CultureInfo.InvariantCulture));
        using var version = verification.CreateCommand();
        version.CommandText = "PRAGMA user_version";
        Equal(1L, Convert.ToInt64(version.ExecuteScalar(), CultureInfo.InvariantCulture));
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

    private static void RawDueDateAndTimeZone()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var id = database.Add(Draft("Time zones", "DST gap"));
        const string raw = "2026-03-08 02:30:00.123456";
        using (var connection = RawOpen(workspace.DatabasePath))
        using (var update = connection.CreateCommand())
        {
            update.CommandText =
                "UPDATE assignments SET due_date=$due,timezone_id=$zone WHERE id=$id";
            update.Parameters.AddWithValue("$due", raw);
            update.Parameters.AddWithValue("$zone", "America/Los_Angeles");
            update.Parameters.AddWithValue("$id", id);
            update.ExecuteNonQuery();
        }

        database = workspace.Database();
        var item = Required(database.Get(id));
        Equal(raw, item.StoredDueDateText);
        Equal(3, TimeZoneInfo.ConvertTime(
            item.DueDate!.Value,
            LocalWallTime.ResolveTimeZone(item.TimezoneId)).Hour);
        var unrelated = AssignmentDraft.From(item);
        unrelated.Title = "DST gap revised";
        database.Update(id, unrelated);
        Equal(raw, StoredDueDate(workspace.DatabasePath, id));

        var zoneOnly = AssignmentDraft.From(Required(database.Get(id)));
        zoneOnly.TimezoneId = "America/New_York";
        database.Update(id, zoneOnly);
        Equal(raw, StoredDueDate(workspace.DatabasePath, id));

        var changed = AssignmentDraft.From(Required(database.Get(id)));
        var newZone = LocalWallTime.ResolveTimeZone(changed.TimezoneId);
        changed.DueDate = LocalWallTime.FromLocalDateTime(
            new DateTime(2026, 11, 2, 14, 5, 0),
            newZone);
        database.Update(id, changed);
        Equal("2026-11-02 14:05:00", StoredDueDate(workspace.DatabasePath, id));
    }

    private static void InvalidDueDateAndTimeZone()
    {
        Throws<ArgumentException>(() => LocalWallTime.ResolveTimeZone("Mars/Olympus"));
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var id = database.Add(Draft("Time zones", "Invalid raw value"));
        using (var connection = RawOpen(workspace.DatabasePath))
        using (var update = connection.CreateCommand())
        {
            update.CommandText =
                "UPDATE assignments SET due_date='not-a-date',timezone_id='UTC' WHERE id=$id";
            update.Parameters.AddWithValue("$id", id);
            update.ExecuteNonQuery();
        }
        Throws<InvalidDataException>(() => workspace.Database());

        using (var connection = RawOpen(workspace.DatabasePath))
        using (var update = connection.CreateCommand())
        {
            update.CommandText =
                "UPDATE assignments SET due_date='2026-08-05 12:00:00',timezone_id='Mars/Olympus' WHERE id=$id";
            update.Parameters.AddWithValue("$id", id);
            update.ExecuteNonQuery();
        }
        Throws<ArgumentException>(() => workspace.Database());
    }

    private static void DueDisplayUsesTaskTimeZone()
    {
        var zone = LocalWallTime.ResolveTimeZone("America/Los_Angeles");
        var due = LocalWallTime.FromLocalDateTime(
            new DateTime(2026, 11, 2, 17, 0, 0),
            zone);
        var task = new AssignmentItem
        {
            DueDate = due,
            TimezoneId = "America/Los_Angeles"
        };
        var displayed = TaskDueDisplayFormatter.DisplayValue(task)!.Value;
        Equal(2026, displayed.Year);
        Equal(11, displayed.Month);
        Equal(2, displayed.Day);
        Equal(17, displayed.Hour);
        True(TaskDueDisplayFormatter.Format(task, CultureInfo.InvariantCulture)
            .Contains("5:00 PM", StringComparison.Ordinal));

        task = new AssignmentItem
        {
            DueDate = due,
            TimezoneId = "America/Los_Angeles",
            AllDay = true
        };
        True(TaskDueDisplayFormatter.Format(task, CultureInfo.InvariantCulture)
            .Contains("Nov 2", StringComparison.Ordinal));
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
            throw new TestFailureException(
                "Shared conformance fixture was not found; the cross-platform contract cannot be verified.");
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

    private static void SchemaV3MigrationFixture()
    {
        using var workspace = new TestWorkspace();
        var fixturePath = FindOrganizationFixture()
            ?? throw new TestFailureException("task-organization-v3.json was not found.");
        using var document = JsonDocument.Parse(File.ReadAllText(fixturePath));
        var root = document.RootElement;
        CreateV2Database(workspace.DatabasePath, root.GetProperty("v2_tasks"));
        var identity = root.GetProperty("uuid_contract").GetProperty("database_instance_uuid").GetString()!;
        var database = workspace.Database(new AssignmentDatabaseOptions { DatabaseInstanceUuid = identity });
        Equal(3, database.SchemaVersion);
        True(database.LastBackupPath is { } backup && File.Exists(backup));

        var expected = root.GetProperty("expected").GetProperty("task_uuids");
        using var connection = RawOpen(workspace.DatabasePath);
        using var foreignKeys = connection.CreateCommand(); foreignKeys.CommandText = "PRAGMA foreign_keys=ON"; foreignKeys.ExecuteNonQuery();
        SchemaV3Contract.Validate(connection);
        foreach (var property in expected.EnumerateObject())
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT uuid FROM assignments WHERE id=$id";
            command.Parameters.AddWithValue("$id", long.Parse(property.Name, CultureInfo.InvariantCulture));
            Equal(property.Value.GetString(), Convert.ToString(command.ExecuteScalar(), CultureInfo.InvariantCulture));
        }
        using var legacy = connection.CreateCommand();
        legacy.CommandText = "SELECT due_date,completed_at,progress_percent FROM assignments WHERE id=9";
        using var reader = legacy.ExecuteReader(); True(reader.Read());
        Equal("2026-08-07 12:00:00", reader.GetString(0));
        Equal("2026-08-05 15:45:30", reader.GetString(1));
        Equal(100, reader.GetInt32(2));
    }

    private static void SchemaV3IdentityVectors()
    {
        var fixturePath = FindOrganizationFixture()
            ?? throw new TestFailureException("task-organization-v3.json was not found.");
        using var document = JsonDocument.Parse(File.ReadAllText(fixturePath));
        foreach (var vector in document.RootElement
                     .GetProperty("name_normalization_contract")
                     .GetProperty("vectors")
                     .EnumerateArray())
        {
            Equal(
                vector.GetProperty("expected").GetString(),
                SchemaV3Contract.CanonicalName(vector.GetProperty("input").GetString()!));
        }
        Equal("σ / σ", SchemaV3Contract.CanonicalName("ς / Σ"));
        Equal(
            "b6f8937a-8325-5149-9dd7-2f0b1fe4a7ff",
            SchemaV3Contract.DeterministicUuid("8c0f31e2-19a2-4c37-9b5d-4fc09f667c8d", "task", 1));
        Equal(
            "62a43b68-df97-57f4-9786-35ff9a5b3da8",
            SchemaV3Contract.DeterministicUuid("8c0f31e2-19a2-4c37-9b5d-4fc09f667c8d", "course", "语文 / English"));
    }

    private static void MigratedCourseRenameReopens()
    {
        using var workspace = new TestWorkspace();
        var fixturePath = FindOrganizationFixture()
            ?? throw new TestFailureException("task-organization-v3.json was not found.");
        using var document = JsonDocument.Parse(File.ReadAllText(fixturePath));
        CreateV2Database(workspace.DatabasePath, document.RootElement.GetProperty("v2_tasks"));
        var database = workspace.Database(new AssignmentDatabaseOptions
        {
            DatabaseInstanceUuid = document.RootElement
                .GetProperty("uuid_contract")
                .GetProperty("database_instance_uuid")
                .GetString()
        });
        var repository = new TaskOrganizationRepository(database);
        var course = repository.FetchCourses().First(item => item.Name == "Physics");
        repository.UpdateCourse(
            course.Id,
            new CourseDraft("Physics renamed", course.ColorHex, course.Teacher, course.Semester));
        var reopened = workspace.Database();
        var renamed = new TaskOrganizationRepository(reopened)
            .FetchCourses()
            .Single(item => item.Id == course.Id);
        Equal(course.Uuid, renamed.Uuid);
        Equal("Physics renamed", renamed.Name);
        True(reopened.FetchAssignments()
            .Where(item => item.CourseId == course.Id)
            .All(item => item.CourseName == "Physics renamed"));
    }

    private static void OrganizationCrud()
    {
        using var workspace = new TestWorkspace(); var database = workspace.Database();
        var repository = new TaskOrganizationRepository(database);
        var course = repository.CreateCourse(new CourseDraft("数据结构 📚", "#3366AA", "王老师", "2026 Fall"));
        Equal("数据结构 📚", course.Name); Equal("数据结构 📚", course.NormalizedName);
        var updated = repository.UpdateCourse(course.Id, new CourseDraft("算法 / Algorithms", "#112233", "Dr. Li", "Fall"));
        Equal("算法 / Algorithms", updated.Name);
        var project = repository.CreateProject(new ProjectDraft("Final", course.Id, "Capstone", ProjectStatuses.Active));
        Equal(course.Id, project.CourseId);
        var tag = repository.CreateTag(new TagDraft("  Urgent  ", "#FF0000"));
        Equal("urgent", tag.NormalizedName);
        repository.DeleteProject(project.Id); Equal(0, repository.FetchProjects().Count);
        Equal(project.Id, repository.RestoreProject(project.Id).Id);
        repository.DeleteCourse(course.Id); Equal(0, repository.FetchCourses().Count(item => item.Id == course.Id));
        Equal(course.Id, repository.RestoreCourse(course.Id).Id);
    }

    private static void TaskTagLifecycle()
    {
        using var workspace = new TestWorkspace(); var database = workspace.Database();
        var task = database.Add(Draft("Physics", "Lab")); var repository = new TaskOrganizationRepository(database);
        var tag = repository.CreateTag(new TagDraft("lab"));
        var link = repository.AttachTag(task, tag.Id); Equal(1, repository.FetchTaskTags(task).Count);
        repository.DetachTag(task, tag.Id); Equal(0, repository.FetchTaskTags(task).Count);
        var restored = repository.AttachTag(task, tag.Id); Equal(link.Id, restored.Id);
    }

    private static void SubtaskDerivedProgress()
    {
        using var workspace = new TestWorkspace(); var database = workspace.Database();
        var task = database.Add(Draft("Math", "Project")); var repository = new TaskOrganizationRepository(database);
        var first = repository.CreateSubtask(new SubtaskDraft(task, "Part A", TaskStatuses.Done, 0));
        var second = repository.CreateSubtask(new SubtaskDraft(task, "Part B", TaskStatuses.Todo, 1));
        var parent = Required(database.Get(task)); Equal(TaskStatuses.InProgress, parent.Status); Equal(50, parent.ProgressPercent);
        using (var connection = RawOpen(workspace.DatabasePath))
        {
            using var foreignKeys = connection.CreateCommand(); foreignKeys.CommandText = "PRAGMA foreign_keys=ON"; foreignKeys.ExecuteNonQuery();
            using var corrupt = connection.CreateCommand();
            corrupt.CommandText = "UPDATE assignments SET status='not_started',progress_percent=0,completed_at=NULL WHERE id=$id";
            corrupt.Parameters.AddWithValue("$id", task); corrupt.ExecuteNonQuery();
            Throws<SchemaV3ContractException>(() => SchemaV3Contract.Validate(connection));
            using var restore = connection.CreateCommand(); restore.CommandText = "UPDATE assignments SET status='in_progress',progress_percent=50 WHERE id=$id";
            restore.Parameters.AddWithValue("$id", task); restore.ExecuteNonQuery();
        }
        repository.UpdateSubtask(second.Id, new SubtaskDraft(task, "Part B", TaskStatuses.Done, 1));
        parent = Required(database.Get(task)); Equal(TaskStatuses.Done, parent.Status); Equal(100, parent.ProgressPercent); True(parent.CompletedAt is not null);
        database.UpdateStatus(task, TaskStatuses.Todo);
        True(repository.FetchSubtasks(task).All(item => item.Status == TaskStatuses.Todo));
        parent = Required(database.Get(task)); Equal(0, parent.ProgressPercent);
        repository.DeleteSubtask(first.Id); repository.DeleteSubtask(second.Id);
        parent = Required(database.Get(task)); Equal(TaskStatuses.Todo, parent.Status); Equal(0, parent.ProgressPercent);
    }

    private static void AttachmentMetadataContract()
    {
        using var workspace = new TestWorkspace(); var database = workspace.Database();
        var task = database.Add(Draft("Art", "Portfolio")); var repository = new TaskOrganizationRepository(database);
        var digest = new string('a', 64);
        var attachment = repository.CreateAttachment(new AttachmentMetadataDraft(task, "作品 🎨.pdf", "application/pdf", 42, digest));
        Equal($"attachments/{attachment.Uuid}", attachment.RelativePath); Equal(42L, attachment.ByteSize);
        Throws<ArgumentException>(() => repository.CreateAttachment(new AttachmentMetadataDraft(task, "../secret", null, 1, digest)));
        using var connection = RawOpen(workspace.DatabasePath);
        using var foreignKeys = connection.CreateCommand(); foreignKeys.CommandText = "PRAGMA foreign_keys=ON"; foreignKeys.ExecuteNonQuery();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT type FROM pragma_table_info('attachments')"; using var reader = command.ExecuteReader();
        while (reader.Read()) False(string.IsNullOrWhiteSpace(reader.GetString(0)) || reader.GetString(0).Contains("BLOB", StringComparison.OrdinalIgnoreCase));
        reader.Close();
        using var untyped = connection.CreateCommand();
        untyped.CommandText = "ALTER TABLE attachments ADD COLUMN payload BLOB GENERATED ALWAYS AS (x'00') VIRTUAL";
        untyped.ExecuteNonQuery();
        Throws<SchemaV3ContractException>(() => SchemaV3Contract.Validate(connection));
    }

    private static void AttachmentPayloadLifecycle()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var task = database.Add(Draft("Art", "Portfolio payload"));
        var repository = new TaskOrganizationRepository(database);
        var store = new AttachmentFileStore(workspace.DatabasePath);
        var source = Path.Combine(workspace.DirectoryPath, "作品 final.txt");
        var payload = "中英文, emoji 🧪, and <special> data";
        File.WriteAllText(source, payload);

        var attachment = store.Import(source, task, "text/plain", repository);
        var managed = store.PayloadPath(attachment);
        Equal(payload, File.ReadAllText(managed));
        Equal(new FileInfo(source).Length, attachment.ByteSize);
        using (var input = File.OpenRead(source))
        {
            Equal(
                Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(input))
                    .ToLowerInvariant(),
                attachment.Sha256);
        }

        var staging = Path.Combine(workspace.DirectoryPath, ".attachment-staging");
        var tombstone = Path.Combine(staging, $"{attachment.Uuid}.deleted");
        File.Move(managed, tombstone);
        var partial = Path.Combine(staging, "interrupted.partial");
        File.WriteAllText(partial, "partial");
        var restored = store.Reconcile(repository.FetchAllAttachments());
        Equal(0, restored.MissingPayloadNames.Count);
        Equal(payload, File.ReadAllText(managed));
        False(File.Exists(tombstone));
        False(File.Exists(partial));

        var orphan = Path.Combine(
            workspace.DirectoryPath,
            "attachments",
            SchemaV3Contract.NewUuid());
        File.WriteAllText(orphan, "orphan");
        var reconciliation = store.Reconcile(repository.FetchAllAttachments());
        Equal(1, reconciliation.RemovedOrphanCount);
        False(File.Exists(orphan));

        File.Delete(managed);
        var symbolicLinkCreated = false;
        try
        {
            File.CreateSymbolicLink(managed, source);
            symbolicLinkCreated = true;
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (PlatformNotSupportedException) { }
        try
        {
            if (symbolicLinkCreated)
            {
                var unsafePayload = store.Reconcile(repository.FetchAllAttachments());
                Equal(1, unsafePayload.MissingPayloadNames.Count);
                Equal(attachment.FileName, unsafePayload.MissingPayloadNames[0]);
                Throws<IOException>(() => store.PayloadPath(attachment));
            }
        }
        finally
        {
            if (File.Exists(managed)) File.Delete(managed);
            File.Copy(source, managed);
        }

        Throws<OrganizationRepositoryException>(() =>
            store.Import(source, long.MaxValue, "text/plain", repository));
        Equal(1, Directory.EnumerateFiles(
            Path.Combine(workspace.DirectoryPath, "attachments")).Count());

        store.Delete(attachment, repository);
        False(File.Exists(managed));
        Equal(0, repository.FetchAllAttachments().Count);
    }

    private static void ReminderContract()
    {
        using var workspace = new TestWorkspace(); var database = workspace.Database();
        var task = database.Add(Draft("History", "Essay")); var repository = new TaskOrganizationRepository(database);
        var trigger = new DateTimeOffset(2026, 9, 1, 10, 0, 0, TimeSpan.FromHours(8));
        var reminder = repository.CreateReminder(new ReminderDraft(task, trigger, 30, "freq=weekly;byday=mo,we;interval=2"));
        Equal(TimeSpan.Zero, reminder.TriggerAtUtc.Offset); Equal("FREQ=WEEKLY;BYDAY=MO,WE;INTERVAL=2", reminder.RepeatRule);
        Throws<ArgumentException>(() => repository.CreateReminder(new ReminderDraft(task, trigger, 0, "FREQ=DAILY;COUNT=3;UNTIL=20260901")));
        Throws<ArgumentException>(() => repository.CreateReminder(new ReminderDraft(task, trigger, 0, "FREQ=DAILY;COUNT=٢")));
        Throws<ArgumentException>(() => repository.CreateReminder(new ReminderDraft(task, trigger, 0, "FREQ=YEARLY;BYMONTH=１")));
        Throws<ArgumentException>(() => repository.CreateReminder(new ReminderDraft(task, trigger, 0, "FREQ=MONTHLY;BYMONTHDAY=+1")));
        using (var connection = RawOpen(workspace.DatabasePath))
        {
            using var foreignKeys = connection.CreateCommand(); foreignKeys.CommandText = "PRAGMA foreign_keys=ON"; foreignKeys.ExecuteNonQuery();
            using var noncanonical = connection.CreateCommand(); noncanonical.CommandText = "UPDATE reminders SET repeat_rule='freq=weekly' WHERE id=$id";
            noncanonical.Parameters.AddWithValue("$id", reminder.Id); noncanonical.ExecuteNonQuery();
            Throws<SchemaV3ContractException>(() => SchemaV3Contract.Validate(connection));
            using var restore = connection.CreateCommand(); restore.CommandText = "UPDATE reminders SET repeat_rule='FREQ=WEEKLY;BYDAY=MO,WE;INTERVAL=2' WHERE id=$id";
            restore.Parameters.AddWithValue("$id", reminder.Id); restore.ExecuteNonQuery();
        }
        repository.DeleteReminder(reminder.Id); Equal(0, repository.FetchReminders(task).Count);
    }

    private static void TaskSoftDeleteRestore()
    {
        using var workspace = new TestWorkspace(); var database = workspace.Database();
        var draft = Draft("English", "Essay"); draft.Description = "保留 🧪"; draft.Priority = TaskPriorities.High;
        var id = database.Add(draft); var uuid = Required(database.Get(id)).Uuid;
        database.Delete(id); Equal<AssignmentItem?>(null, database.Get(id));
        var restored = database.Restore(id); Equal(uuid, restored.Uuid); Equal("保留 🧪", restored.Description); Equal(TaskPriorities.High, restored.Priority);
    }

    private static void DeletedOrganizationLinksSurviveTaskEdit()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var repository = new TaskOrganizationRepository(database);
        var course = repository.CreateCourse(new CourseDraft("Archived course"));
        var project = repository.CreateProject(new ProjectDraft("Archived project", course.Id));
        var draft = Draft(course.Name, "Original title");
        draft.CourseId = course.Id;
        draft.ProjectId = project.Id;
        var taskId = database.Add(draft);
        repository.DeleteProject(project.Id);
        repository.DeleteCourse(course.Id);

        var edit = AssignmentDraft.From(Required(database.Get(taskId)));
        edit.Title = "Title-only edit";
        database.Update(taskId, edit);
        var saved = Required(database.Get(taskId));
        Equal(course.Id, saved.CourseId);
        Equal(project.Id, saved.ProjectId);
        Equal("Title-only edit", saved.Title);
        Equal(1, repository.FetchCourses(includeDeleted: true)
            .Count(item => item.Name == course.Name));
    }

    private static void LegacyHiddenLinkSurvivesSimpleEditor()
    {
        var legacy = new AssignmentItem
        {
            Link = "  course://资源/relative  ",
            CourseName = "Course",
            Title = "Legacy"
        };
        Equal(
            legacy.Link,
            TaskLinkEditorPolicy.Resolve(legacy, professionalMode: false, enteredValue: ""));
        Equal(
            legacy.Link,
            TaskLinkEditorPolicy.Resolve(
                legacy,
                professionalMode: true,
                enteredValue: legacy.Link));
        Throws<ArgumentException>(() => TaskLinkEditorPolicy.Resolve(
            legacy,
            professionalMode: true,
            enteredValue: "ftp://changed.example.test"));

        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var id = database.Add(Draft("Course", "Legacy raw payload"));
        var expected = new[]
        {
            "  描述 with edges  ",
            "  course://资源/relative  ",
            "  来源 name  ",
            "   ",
            "  folder/file.md  ",
            "  custom://来源  "
        };
        using (var connection = RawOpen(workspace.DatabasePath))
        using (var inject = connection.CreateCommand())
        {
            inject.CommandText =
                "UPDATE assignments SET description=$description,link=$link," +
                "source_name=$sourceName,source_type=$sourceType," +
                "source_file=$sourceFile,source_url=$sourceUrl WHERE id=$id";
            inject.Parameters.AddWithValue("$description", expected[0]);
            inject.Parameters.AddWithValue("$link", expected[1]);
            inject.Parameters.AddWithValue("$sourceName", expected[2]);
            inject.Parameters.AddWithValue("$sourceType", expected[3]);
            inject.Parameters.AddWithValue("$sourceFile", expected[4]);
            inject.Parameters.AddWithValue("$sourceUrl", expected[5]);
            inject.Parameters.AddWithValue("$id", id);
            inject.ExecuteNonQuery();
        }
        var existing = Required(database.Get(id));
        var link = TaskLinkEditorPolicy.Resolve(
            existing,
            professionalMode: false,
            enteredValue: "");
        var edit = TaskEditorDraftProjection.Apply(
            existing,
            existing.CourseName,
            "Title-only simple edit",
            existing.DueDate,
            existing.Status,
            existing.Description,
            existing.Priority,
            link);
        database.Update(id, edit);
        using var verify = RawOpen(workspace.DatabasePath);
        using var payload = verify.CreateCommand();
        payload.CommandText =
            "SELECT description,link,source_name,source_type,source_file,source_url " +
            "FROM assignments WHERE id=$id";
        payload.Parameters.AddWithValue("$id", id);
        using var reader = payload.ExecuteReader();
        True(reader.Read());
        for (var index = 0; index < expected.Length; index++)
            Equal(expected[index], reader.GetString(index));
    }

    private static void DatabaseIdentityImmutable()
    {
        using var workspace = new TestWorkspace(); _ = workspace.Database(); using var connection = RawOpen(workspace.DatabasePath);
        using var update = connection.CreateCommand(); update.CommandText = "UPDATE database_identity SET instance_uuid=$uuid"; update.Parameters.AddWithValue("$uuid", Guid.NewGuid().ToString("D"));
        Throws<SqliteException>(() => update.ExecuteNonQuery());
        using var remove = connection.CreateCommand(); remove.CommandText = "DELETE FROM database_identity"; Throws<SqliteException>(() => remove.ExecuteNonQuery());
    }

    private static void ForgedOrganizationRowsAreRejected()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var repository = new TaskOrganizationRepository(database);
        var firstCourse = repository.CreateCourse(new CourseDraft("First"));
        var secondCourse = repository.CreateCourse(new CourseDraft("Second"));
        var taskDraft = Draft(firstCourse.Name, "Contract target");
        taskDraft.CourseId = firstCourse.Id;
        var task = database.Add(taskDraft);
        var project = repository.CreateProject(new ProjectDraft("Other project", secondCourse.Id));
        var subtask = repository.CreateSubtask(new SubtaskDraft(task, "Part", TaskStatuses.Todo, 0));
        var reminder = repository.CreateReminder(new ReminderDraft(
            task,
            new DateTimeOffset(2026, 9, 1, 10, 0, 0, TimeSpan.Zero)));

        using var connection = RawOpen(workspace.DatabasePath);
        using var foreignKeys = connection.CreateCommand();
        foreignKeys.CommandText = "PRAGMA foreign_keys=ON; PRAGMA ignore_check_constraints=ON";
        foreignKeys.ExecuteNonQuery();

        AssertInvalidV3(connection,
            $"UPDATE courses SET is_archived=2 WHERE id={firstCourse.Id}",
            $"UPDATE courses SET is_archived=0 WHERE id={firstCourse.Id}");
        AssertInvalidV3(connection,
            $"UPDATE projects SET status='bogus' WHERE id={project.Id}",
            $"UPDATE projects SET status='active' WHERE id={project.Id}");
        AssertInvalidV3(connection,
            $"UPDATE reminders SET is_enabled=2 WHERE id={reminder.Id}",
            $"UPDATE reminders SET is_enabled=1 WHERE id={reminder.Id}");
        AssertInvalidV3(connection,
            $"UPDATE reminders SET lead_minutes=-1 WHERE id={reminder.Id}",
            $"UPDATE reminders SET lead_minutes=0 WHERE id={reminder.Id}");
        AssertInvalidV3(connection,
            $"UPDATE subtasks SET sort_order=-1 WHERE id={subtask.Id}",
            $"UPDATE subtasks SET sort_order=0 WHERE id={subtask.Id}");
        AssertInvalidV3(connection,
            $"UPDATE subtasks SET status='completed',completed_at=NULL WHERE id={subtask.Id}",
            $"UPDATE subtasks SET status='not_started',completed_at=NULL WHERE id={subtask.Id}");
        AssertInvalidV3(connection,
            $"UPDATE assignments SET course_name='stale' WHERE id={task}",
            $"UPDATE assignments SET course_name='First' WHERE id={task}");
        AssertInvalidV3(connection,
            $"UPDATE assignments SET project_id={project.Id} WHERE id={task}",
            $"UPDATE assignments SET project_id=NULL WHERE id={task}");
    }

    private static void ForgedNullableScalarIsRejected()
    {
        using var workspace = new TestWorkspace();
        var database = workspace.Database();
        var repository = new TaskOrganizationRepository(database);
        var course = repository.CreateCourse(new CourseDraft("Nullable forge"));
        var taskDraft = Draft(course.Name, "Target");
        taskDraft.CourseId = course.Id;
        var task = database.Add(taskDraft);
        var project = repository.CreateProject(new ProjectDraft("Project", course.Id));
        var subtask = repository.CreateSubtask(
            new SubtaskDraft(task, "Subtask", TaskStatuses.Todo, 0));
        var reminder = repository.CreateReminder(new ReminderDraft(
            task,
            new DateTimeOffset(2026, 9, 1, 10, 0, 0, TimeSpan.Zero)));
        var attachment = repository.CreateAttachment(new AttachmentMetadataDraft(
            task,
            "file.txt",
            "text/plain",
            1,
            new string('a', 64)));

        foreach (var (table, fragment) in new[]
        {
            ("assignments", "progress_percent INTEGER NOT NULL"),
            ("assignments", "all_day INTEGER NOT NULL"),
            ("courses", "is_archived INTEGER NOT NULL"),
            ("projects", "status TEXT NOT NULL"),
            ("subtasks", "status TEXT NOT NULL"),
            ("subtasks", "sort_order INTEGER NOT NULL"),
            ("reminders", "lead_minutes INTEGER NOT NULL"),
            ("reminders", "is_enabled INTEGER NOT NULL"),
            ("attachments", "byte_size INTEGER NOT NULL")
        }) ForgeNotNullAway(workspace.DatabasePath, table, fragment);

        using var connection = RawOpen(workspace.DatabasePath);
        using var foreignKeys = connection.CreateCommand();
        foreignKeys.CommandText = "PRAGMA foreign_keys=ON";
        foreignKeys.ExecuteNonQuery();
        AssertInvalidV3(connection,
            $"UPDATE assignments SET progress_percent=NULL WHERE id={task}",
            $"UPDATE assignments SET progress_percent=0 WHERE id={task}");
        AssertInvalidV3(connection,
            $"UPDATE assignments SET all_day=NULL WHERE id={task}",
            $"UPDATE assignments SET all_day=0 WHERE id={task}");
        AssertInvalidV3(connection,
            $"UPDATE courses SET is_archived=NULL WHERE id={course.Id}",
            $"UPDATE courses SET is_archived=0 WHERE id={course.Id}");
        AssertInvalidV3(connection,
            $"UPDATE projects SET status=NULL WHERE id={project.Id}",
            $"UPDATE projects SET status='active' WHERE id={project.Id}");
        AssertInvalidV3(connection,
            $"UPDATE reminders SET lead_minutes=NULL WHERE id={reminder.Id}",
            $"UPDATE reminders SET lead_minutes=0 WHERE id={reminder.Id}");
        AssertInvalidV3(connection,
            $"UPDATE reminders SET is_enabled=NULL WHERE id={reminder.Id}",
            $"UPDATE reminders SET is_enabled=1 WHERE id={reminder.Id}");
        AssertInvalidV3(connection,
            $"UPDATE subtasks SET status=NULL WHERE id={subtask.Id}",
            $"UPDATE subtasks SET status='not_started' WHERE id={subtask.Id}");
        AssertInvalidV3(connection,
            $"UPDATE subtasks SET sort_order=NULL WHERE id={subtask.Id}",
            $"UPDATE subtasks SET sort_order=0 WHERE id={subtask.Id}");
        AssertInvalidV3(connection,
            $"UPDATE attachments SET byte_size=NULL WHERE id={attachment.Id}",
            $"UPDATE attachments SET byte_size=1 WHERE id={attachment.Id}");
    }

    private static void ConcurrentMigration()
    {
        using var workspace = new TestWorkspace(); CreateV1Database(workspace.DatabasePath);
        var tasks = Enumerable.Range(0, 6).Select(_ => Task.Run(() => new AssignmentDatabase(workspace.DatabasePath).SchemaVersion)).ToArray();
        Task.WaitAll(tasks); True(tasks.All(task => task.Result == 3));
        using var connection = RawOpen(workspace.DatabasePath); using var foreignKeys = connection.CreateCommand(); foreignKeys.CommandText = "PRAGMA foreign_keys=ON"; foreignKeys.ExecuteNonQuery();
        SchemaV3Contract.Validate(connection);
    }

    private static void OrdinaryWriterWaitsForMigration()
    {
        using var workspace = new TestWorkspace();
        CreateV1Database(workspace.DatabasePath);
        using var enteredMigration = new ManualResetEventSlim();
        using var releaseMigration = new ManualResetEventSlim();
        var migrator = Task.Run(() =>
        {
            try
            {
                _ = workspace.Database(new AssignmentDatabaseOptions
                {
                    OnMigrationCheckpoint = checkpoint =>
                    {
                        if (checkpoint == MigrationCheckpoint.BeforeSchemaChanges)
                        {
                            enteredMigration.Set();
                            releaseMigration.Wait(TimeSpan.FromSeconds(10));
                        }
                    }
                });
            }
            catch (Exception error)
            {
                return error;
            }
            return null;
        });
        True(enteredMigration.Wait(TimeSpan.FromSeconds(10)));
        var writerStarted = new ManualResetEventSlim();
        var writer = Task.Run(() =>
        {
            writerStarted.Set();
            var database = workspace.Database();
            return database.Add(Draft("Concurrent", "Committed after migration"));
        });
        True(writerStarted.Wait(TimeSpan.FromSeconds(2)));
        False(writer.Wait(TimeSpan.FromMilliseconds(150)));
        releaseMigration.Set();
        Equal<Exception?>(null, migrator.Result);
        var inserted = writer.Result;
        var reopened = workspace.Database();
        Equal("Legacy homework", Required(reopened.Get(7)).Title);
        Equal("Committed after migration", Required(reopened.Get(inserted)).Title);
    }

    private static void V2ExtensionSurvivesMigration()
    {
        using var workspace = new TestWorkspace();
        var fixturePath = FindOrganizationFixture()
            ?? throw new TestFailureException("task-organization-v3.json was not found.");
        using var document = JsonDocument.Parse(File.ReadAllText(fixturePath));
        CreateV2Database(workspace.DatabasePath, document.RootElement.GetProperty("v2_tasks"));
        using (var connection = RawOpen(workspace.DatabasePath))
        using (var extension = connection.CreateCommand())
        {
            extension.CommandText =
                "ALTER TABLE assignments ADD COLUMN legacy_note TEXT; " +
                "UPDATE assignments SET legacy_note='保留 extension 🧪' WHERE id=1";
            extension.ExecuteNonQuery();
        }
        _ = workspace.Database();
        using var verification = RawOpen(workspace.DatabasePath);
        using var value = verification.CreateCommand();
        value.CommandText = "SELECT legacy_note FROM assignments WHERE id=1";
        Equal("保留 extension 🧪", Convert.ToString(value.ExecuteScalar(), CultureInfo.InvariantCulture));
    }

    private static void CopyDatabase(string sourcePath, string destinationPath)
    {
        var sourceString = new SqliteConnectionStringBuilder
        {
            DataSource = sourcePath,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false
        }.ToString();
        var destinationString = new SqliteConnectionStringBuilder
        {
            DataSource = destinationPath,
            Mode = SqliteOpenMode.ReadWrite,
            Pooling = false
        }.ToString();
        using var source = new SqliteConnection(sourceString);
        using var destination = new SqliteConnection(destinationString);
        source.Open();
        destination.Open();
        source.BackupDatabase(destination);
    }

    private static void ForgeNotNullAway(string path, string table, string fragment)
    {
        using var connection = RawOpen(path);
        using var read = connection.CreateCommand();
        read.CommandText = "SELECT sql FROM sqlite_schema WHERE type='table' AND name=$name";
        read.Parameters.AddWithValue("$name", table);
        var sql = Convert.ToString(read.ExecuteScalar(), CultureInfo.InvariantCulture)
            ?? throw new TestFailureException($"Missing table SQL for {table}.");
        if (!sql.Contains(fragment, StringComparison.Ordinal))
            throw new TestFailureException($"Expected schema fragment was absent: {fragment}");
        sql = sql.Replace(fragment, fragment.Replace(" NOT NULL", ""), StringComparison.Ordinal);
        using var version = connection.CreateCommand();
        version.CommandText = "PRAGMA schema_version";
        var nextVersion = Convert.ToInt64(version.ExecuteScalar(), CultureInfo.InvariantCulture) + 1;
        using var forge = connection.CreateCommand();
        forge.CommandText =
            "PRAGMA writable_schema=ON; " +
            "UPDATE sqlite_schema SET sql=$sql WHERE type='table' AND name=$name; " +
            "PRAGMA writable_schema=OFF; " +
            $"PRAGMA schema_version={nextVersion}";
        forge.Parameters.AddWithValue("$sql", sql);
        forge.Parameters.AddWithValue("$name", table);
        forge.ExecuteNonQuery();
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

    private static void CreateV2Database(string path, JsonElement tasks)
    {
        using var connection = RawOpen(path);
        using (var schema = connection.CreateCommand())
        {
            schema.CommandText =
                """
                CREATE TABLE assignments (
                    id INTEGER NOT NULL PRIMARY KEY,
                    course_name VARCHAR(120) NOT NULL,
                    title VARCHAR(255) NOT NULL,
                    due_date DATETIME,
                    description TEXT,
                    link VARCHAR(1000),
                    status VARCHAR(20) NOT NULL,
                    priority VARCHAR(10) NOT NULL,
                    source_name VARCHAR(255), source_type VARCHAR(80),
                    source_file VARCHAR(1000), source_url VARCHAR(1000),
                    created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL,
                    CHECK (status IN ('not_started','in_progress','completed')),
                    CHECK (priority IN ('low','medium','high'))
                );
                CREATE INDEX ix_assignments_due_date ON assignments(due_date);
                CREATE INDEX ix_assignments_status ON assignments(status);
                CREATE INDEX ix_assignments_priority ON assignments(priority);
                CREATE INDEX ix_assignments_course_name ON assignments(course_name);
                PRAGMA user_version=2;
                """;
            schema.ExecuteNonQuery();
        }
        foreach (var task in tasks.EnumerateArray())
        {
            using var insert = connection.CreateCommand();
            insert.CommandText =
                "INSERT INTO assignments(id,course_name,title,due_date,description,link,status,priority,source_name,source_type,source_file,source_url,created_at,updated_at) " +
                "VALUES($id,$course,$title,$due,$description,$link,$status,$priority,$sourceName,$sourceType,$sourceFile,$sourceUrl,$created,$updated)";
            insert.Parameters.AddWithValue("$id", task.GetProperty("id").GetInt64());
            insert.Parameters.AddWithValue("$course", task.GetProperty("course_name").GetString()!);
            insert.Parameters.AddWithValue("$title", task.GetProperty("title").GetString()!);
            foreach (var (parameter, property) in new[]
            {
                ("$due", "due_date"), ("$description", "description"), ("$link", "link"),
                ("$sourceName", "source_name"), ("$sourceType", "source_type"),
                ("$sourceFile", "source_file"), ("$sourceUrl", "source_url")
            })
            {
                var value = task.GetProperty(property);
                insert.Parameters.AddWithValue(parameter, value.ValueKind == JsonValueKind.Null ? DBNull.Value : value.GetString()!);
            }
            insert.Parameters.AddWithValue("$status", task.GetProperty("status").GetString()!);
            insert.Parameters.AddWithValue("$priority", task.GetProperty("priority").GetString()!);
            insert.Parameters.AddWithValue("$created", task.GetProperty("created_at").GetString()!);
            insert.Parameters.AddWithValue("$updated", task.GetProperty("updated_at").GetString()!);
            insert.ExecuteNonQuery();
        }
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
                    if (File.Exists(preferred))
                    {
                        return preferred;
                    }
                }
                directory = directory.Parent;
            }
        }
        return null;
    }

    private static string? FindOrganizationFixture()
    {
        foreach (var start in new[] { AppContext.BaseDirectory, Directory.GetCurrentDirectory() })
        {
            var directory = new DirectoryInfo(start);
            for (var level = 0; level < 12 && directory is not null; level++)
            {
                var candidate = Path.Combine(directory.FullName, "shared", "fixtures", "task-organization-v3.json");
                if (File.Exists(candidate)) return candidate;
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

    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new TestFailureException($"Expected {typeof(T).Name}.");
    }

    private static T ThrowsResult<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T error) { return error; }
        throw new TestFailureException($"Expected {typeof(T).Name}.");
    }

    private static string? StoredDueDate(string path, long id)
    {
        using var connection = RawOpen(path);
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT due_date FROM assignments WHERE id=$id";
        command.Parameters.AddWithValue("$id", id);
        return Convert.ToString(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private static void AssertInvalidV3(
        SqliteConnection connection,
        string mutation,
        string restore)
    {
        using (var command = connection.CreateCommand())
        {
            command.CommandText = mutation;
            command.ExecuteNonQuery();
        }
        Throws<SchemaV3ContractException>(() => SchemaV3Contract.Validate(connection));
        using (var command = connection.CreateCommand())
        {
            command.CommandText = restore;
            command.ExecuteNonQuery();
        }
        SchemaV3Contract.Validate(connection);
    }

    private static string V1LogicalSnapshot(string path)
    {
        using var connection = RawOpen(path);
        var parts = new List<string>();
        foreach (var sql in new[]
        {
            "PRAGMA user_version",
            "SELECT group_concat(type||':'||name||':'||ifnull(sql,''),char(10)) FROM (SELECT type,name,sql FROM sqlite_master ORDER BY type,name)",
            "SELECT group_concat(quote(id)||'|'||quote(course_name)||'|'||quote(title)||'|'||quote(due_date)||'|'||quote(description)||'|'||quote(link)||'|'||quote(status)||'|'||quote(source_name)||'|'||quote(source_type)||'|'||quote(source_file)||'|'||quote(source_url)||'|'||quote(created_at)||'|'||quote(updated_at),char(10)) FROM assignments ORDER BY id",
            "SELECT group_concat(name||':'||seq,char(10)) FROM sqlite_sequence ORDER BY name"
        })
        {
            using var command = connection.CreateCommand();
            command.CommandText = sql;
            parts.Add(Convert.ToString(command.ExecuteScalar(), CultureInfo.InvariantCulture) ?? "<null>");
        }
        return string.Join("\n--\n", parts);
    }

    private static string FileIdentity(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            if (!GetFileInformationByHandle(
                    stream.SafeFileHandle.DangerousGetHandle(),
                    out var information))
            {
                throw new TestFailureException(
                    $"GetFileInformationByHandle failed: {Marshal.GetLastWin32Error()}");
            }
            return $"{information.VolumeSerialNumber:x8}:" +
                   $"{information.FileIndexHigh:x8}{information.FileIndexLow:x8}";
        }

        var start = new ProcessStartInfo("stat")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        };
        if (OperatingSystem.IsMacOS())
        {
            start.ArgumentList.Add("-f");
            start.ArgumentList.Add("%d:%i");
        }
        else
        {
            start.ArgumentList.Add("-c");
            start.ArgumentList.Add("%d:%i");
        }
        start.ArgumentList.Add(path);
        using var process = Process.Start(start)
            ?? throw new TestFailureException("Could not launch stat for file identity.");
        var output = process.StandardOutput.ReadToEnd().Trim();
        var error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0)
            throw new TestFailureException("stat failed: " + error);
        return output;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowsFileInformation
    {
        public uint FileAttributes;
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

#pragma warning disable SYSLIB1054
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        IntPtr handle,
        out WindowsFileInformation information);
#pragma warning restore SYSLIB1054

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
