using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace AssignmentNative.Core;

public sealed class SchemaV3ContractException : Exception
{
    public SchemaV3ContractException(string message) : base(message) { }
}

public static partial class SchemaV3Contract
{
    public const int DatabaseVersion = 3;

    private static readonly string[] V2Columns =
    [
        "id", "course_name", "title", "due_date", "description", "link",
        "status", "priority", "source_name", "source_type", "source_file",
        "source_url", "created_at", "updated_at"
    ];

    private static readonly IReadOnlyDictionary<string, string[]> RequiredColumns =
        new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            ["database_identity"] = ["singleton", "instance_uuid", "created_at"],
            ["assignments"] = [.. V2Columns, "uuid", "course_id", "project_id", "completed_at", "progress_percent", "all_day", "timezone_id", "deleted_at"],
            ["courses"] = ["id", "uuid", "name", "normalized_name", "color_hex", "teacher", "semester", "is_archived", "created_at", "updated_at", "deleted_at"],
            ["projects"] = ["id", "uuid", "course_id", "name", "description", "status", "created_at", "updated_at", "deleted_at"],
            ["tags"] = ["id", "uuid", "name", "normalized_name", "color_hex", "created_at", "updated_at", "deleted_at"],
            ["task_tags"] = ["id", "uuid", "assignment_id", "tag_id", "created_at", "updated_at", "deleted_at"],
            ["subtasks"] = ["id", "uuid", "assignment_id", "title", "status", "sort_order", "completed_at", "created_at", "updated_at", "deleted_at"],
            ["attachments"] = ["id", "uuid", "assignment_id", "file_name", "relative_path", "mime_type", "byte_size", "sha256", "created_at", "updated_at", "deleted_at"],
            ["reminders"] = ["id", "uuid", "assignment_id", "trigger_at_utc", "lead_minutes", "repeat_rule", "is_enabled", "last_scheduled_at", "created_at", "updated_at", "deleted_at"]
        };

    private sealed record IndexContract(
        string Table,
        string[] Columns,
        bool Unique = false,
        bool Partial = false);

    private static readonly IReadOnlyDictionary<string, IndexContract> Indexes =
        new Dictionary<string, IndexContract>(StringComparer.Ordinal)
        {
            ["ux_assignments_uuid"] = new("assignments", ["uuid"], true),
            ["ix_assignments_course_id"] = new("assignments", ["course_id"]),
            ["ix_assignments_project_id"] = new("assignments", ["project_id"]),
            ["ix_assignments_due_date"] = new("assignments", ["due_date"]),
            ["ix_assignments_status"] = new("assignments", ["status"]),
            ["ix_assignments_priority"] = new("assignments", ["priority"]),
            ["ix_assignments_deleted_at"] = new("assignments", ["deleted_at"]),
            ["ux_courses_uuid"] = new("courses", ["uuid"], true),
            ["ix_courses_normalized_name"] = new("courses", ["normalized_name"]),
            ["ix_courses_archived_name"] = new("courses", ["is_archived", "name"]),
            ["ux_projects_uuid"] = new("projects", ["uuid"], true),
            ["ix_projects_course_status"] = new("projects", ["course_id", "status"]),
            ["ix_projects_deleted_at"] = new("projects", ["deleted_at"]),
            ["ux_tags_uuid"] = new("tags", ["uuid"], true),
            ["ux_tags_normalized_name"] = new("tags", ["normalized_name"], true),
            ["ix_tags_deleted_at"] = new("tags", ["deleted_at"]),
            ["ux_task_tags_uuid"] = new("task_tags", ["uuid"], true),
            ["ux_task_tags_active_pair"] = new("task_tags", ["assignment_id", "tag_id"], true, true),
            ["ix_task_tags_assignment"] = new("task_tags", ["assignment_id"]),
            ["ix_task_tags_tag"] = new("task_tags", ["tag_id"]),
            ["ux_subtasks_uuid"] = new("subtasks", ["uuid"], true),
            ["ix_subtasks_assignment_order"] = new("subtasks", ["assignment_id", "sort_order", "id"]),
            ["ix_subtasks_status"] = new("subtasks", ["status"]),
            ["ux_attachments_uuid"] = new("attachments", ["uuid"], true),
            ["ux_attachments_relative_path"] = new("attachments", ["relative_path"], true),
            ["ix_attachments_assignment"] = new("attachments", ["assignment_id"]),
            ["ix_attachments_sha256"] = new("attachments", ["sha256"]),
            ["ux_reminders_uuid"] = new("reminders", ["uuid"], true),
            ["ix_reminders_assignment"] = new("reminders", ["assignment_id"]),
            ["ix_reminders_enabled_trigger"] = new("reminders", ["is_enabled", "trigger_at_utc"])
        };

    private static readonly string[] UuidTables =
        ["assignments", "courses", "projects", "tags", "task_tags", "subtasks", "attachments", "reminders"];

    public static string CanonicalName(string value)
        => SharedNameNormalizer.Normalize(value);

    public static string NewUuid() => Guid.NewGuid().ToString("D").ToLowerInvariant();

    public static string DeterministicUuid(string databaseInstanceUuid, string entity, object legacyKey)
    {
        if (!IsCanonicalUuid(databaseInstanceUuid, 4))
        {
            throw new ArgumentException("Database instance UUID must be canonical UUID v4.");
        }
        var cleanedEntity = entity.Trim().ToLowerInvariant();
        string key;
        if (cleanedEntity == "task")
        {
            var id = Convert.ToInt64(legacyKey, CultureInfo.InvariantCulture);
            if (id < 1) throw new ArgumentOutOfRangeException(nameof(legacyKey));
            key = id.ToString(CultureInfo.InvariantCulture);
        }
        else if (cleanedEntity == "course")
        {
            key = Convert.ToString(legacyKey, CultureInfo.InvariantCulture) ?? "";
            if (key.Length == 0) throw new ArgumentException("Course legacy name is required.");
        }
        else
        {
            throw new ArgumentOutOfRangeException(nameof(entity));
        }

        var namespaceBytes = Convert.FromHexString(databaseInstanceUuid.Replace("-", ""));
        var nameBytes = Encoding.UTF8.GetBytes($"{cleanedEntity}:{key}");
        var payload = new byte[namespaceBytes.Length + nameBytes.Length];
        namespaceBytes.CopyTo(payload, 0);
        nameBytes.CopyTo(payload, namespaceBytes.Length);
        var digest = SHA1.HashData(payload);
        var uuid = digest[..16];
        uuid[6] = (byte)((uuid[6] & 0x0f) | 0x50);
        uuid[8] = (byte)((uuid[8] & 0x3f) | 0x80);
        var hex = Convert.ToHexString(uuid).ToLowerInvariant();
        return $"{hex[..8]}-{hex[8..12]}-{hex[12..16]}-{hex[16..20]}-{hex[20..]}";
    }

    public static string CanonicalUtcNow() =>
        DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    public static string AttachmentRelativePath(string uuid)
    {
        if (!IsCanonicalUuid(uuid, 4))
        {
            throw new ArgumentException("Attachment UUID must be canonical UUID v4.");
        }
        return $"attachments/{uuid}";
    }

    internal static void MigrateV2ToV3(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string? databaseInstanceUuid = null)
    {
        if (ReadVersion(connection, transaction) != 2)
        {
            throw new SchemaV3ContractException("v2 to v3 migration requires user_version 2.");
        }
        var columns = ColumnNames(connection, transaction, "assignments");
        var missing = V2Columns.Where(column => !columns.Contains(column)).ToArray();
        if (missing.Length > 0)
        {
            throw new SchemaV3ContractException("v2 assignments columns missing: " + string.Join(", ", missing));
        }
        var reserved = new[] { "uuid", "course_id", "project_id", "completed_at", "progress_percent", "all_day", "timezone_id", "deleted_at" }
            .Where(columns.Contains).ToArray();
        if (reserved.Length > 0)
        {
            throw new SchemaV3ContractException("Partial v3 assignment columns found: " + string.Join(", ", reserved));
        }
        var conflicts = RequiredColumns.Keys
            .Where(table => table != "assignments" && TableExists(connection, transaction, table))
            .ToArray();
        if (conflicts.Length > 0)
        {
            throw new SchemaV3ContractException("Partial v3 tables found: " + string.Join(", ", conflicts));
        }
        EnsureReservedTriggerNamesAvailable(connection, transaction);

        var legacy = ReadLegacyRows(connection, transaction);
        foreach (var row in legacy)
        {
            if (row.Id < 1 || row.CourseName is null || row.Title is null)
                throw new SchemaV3ContractException("Legacy task identity is invalid.");
            if (row.Status is not ("not_started" or "in_progress" or "completed"))
                throw new SchemaV3ContractException($"Unsupported legacy status: {row.Status}");
            if (row.Priority is not ("low" or "medium" or "high"))
                throw new SchemaV3ContractException($"Unsupported legacy priority: {row.Priority}");
        }

        var instanceUuid = databaseInstanceUuid ?? NewUuid();
        if (!IsCanonicalUuid(instanceUuid, 4))
            throw new SchemaV3ContractException("Database identity must be canonical UUID v4.");

        CreateIdentity(connection, transaction, instanceUuid);
        CreatePrimaryTables(connection, transaction);
        var courseIds = MigrateCourses(connection, transaction, legacy, instanceUuid);
        AddAssignmentColumns(connection, transaction);
        var triggers = ReadAssignmentTriggers(connection, transaction);
        foreach (var trigger in triggers)
            Execute(connection, transaction, $"DROP TRIGGER {QuoteIdentifier(trigger.Name)}");
        foreach (var row in legacy)
        {
            using var update = connection.CreateCommand();
            update.Transaction = transaction;
            update.CommandText =
                "UPDATE assignments SET uuid=$uuid, course_id=$course, project_id=NULL, " +
                "completed_at=$completed, progress_percent=$progress, all_day=0, " +
                "timezone_id=NULL, deleted_at=NULL WHERE id=$id";
            update.Parameters.AddWithValue("$uuid", DeterministicUuid(instanceUuid, "task", row.Id));
            update.Parameters.AddWithValue("$course", courseIds.TryGetValue(row.CourseName, out var courseId) ? courseId : DBNull.Value);
            update.Parameters.AddWithValue("$completed", row.Status == "completed" ? row.UpdatedAt : DBNull.Value);
            update.Parameters.AddWithValue("$progress", row.Status == "completed" ? 100 : 0);
            update.Parameters.AddWithValue("$id", row.Id);
            if (update.ExecuteNonQuery() != 1)
                throw new SchemaV3ContractException($"Task {row.Id} could not be backfilled.");
        }
        foreach (var trigger in triggers)
            Execute(connection, transaction, trigger.Sql);

        CreateChildTables(connection, transaction);
        CreateIndexes(connection, transaction);
        CreateContractTriggers(connection, transaction);
        Execute(connection, transaction, "PRAGMA user_version = 3");
        Validate(connection, transaction);
        ValidateMigratedLineage(connection, transaction, legacy, instanceUuid);

        var after = ReadLegacyRows(connection, transaction);
        if (!legacy.SequenceEqual(after))
            throw new SchemaV3ContractException("The v2 task payload changed during v3 migration.");
    }

    public static void Validate(SqliteConnection connection, SqliteTransaction? transaction = null)
    {
        using (var foreignKeys = connection.CreateCommand())
        {
            foreignKeys.Transaction = transaction;
            foreignKeys.CommandText = "PRAGMA foreign_keys";
            if (Convert.ToInt32(foreignKeys.ExecuteScalar(), CultureInfo.InvariantCulture) != 1)
                throw new SchemaV3ContractException("Schema v3 validation requires PRAGMA foreign_keys=ON.");
        }
        if (ReadVersion(connection, transaction) != DatabaseVersion)
            throw new SchemaV3ContractException("Database user_version must be 3.");
        foreach (var (table, required) in RequiredColumns)
        {
            if (!TableExists(connection, transaction, table))
                throw new SchemaV3ContractException($"Schema v3 table is missing: {table}");
            var actual = ColumnNames(connection, transaction, table);
            var missing = required.Where(column => !actual.Contains(column)).ToArray();
            if (missing.Length > 0)
                throw new SchemaV3ContractException($"{table} columns missing: {string.Join(", ", missing)}");
        }
        ValidateIndexes(connection, transaction);
        ValidateTriggers(connection, transaction);
        ValidateForeignKeys(connection, transaction);
        ExpectScalar(connection, transaction, "PRAGMA integrity_check", "ok", "integrity_check failed");

        var identity = QueryRows(connection, transaction, "SELECT singleton, instance_uuid, created_at FROM database_identity");
        if (identity.Count != 1 || Convert.ToInt64(identity[0][0], CultureInfo.InvariantCulture) != 1)
            throw new SchemaV3ContractException("database_identity must contain one singleton row.");
        var instanceUuid = Convert.ToString(identity[0][1], CultureInfo.InvariantCulture) ?? "";
        if (!IsCanonicalUuid(instanceUuid, 4) || !IsUtcTimestamp(identity[0][2]))
            throw new SchemaV3ContractException("database_identity is invalid.");

        foreach (var table in UuidTables)
        {
            foreach (var row in QueryRows(connection, transaction, $"SELECT id, uuid, created_at, updated_at, deleted_at FROM {table}"))
            {
                var id = Convert.ToInt64(row[0], CultureInfo.InvariantCulture);
                var uuid = Convert.ToString(row[1], CultureInfo.InvariantCulture) ?? "";
                var version = UuidVersion(uuid);
                if (version is not (4 or 5) || (version == 5 && table is not ("assignments" or "courses")))
                    throw new SchemaV3ContractException($"{table} row {id} UUID is invalid.");
                if (version == 4 && (!IsUtcTimestamp(row[2]) || !IsUtcTimestamp(row[3])))
                    throw new SchemaV3ContractException($"{table} row {id} audit timestamp is invalid.");
                if (row[4] is not DBNull && !IsUtcTimestamp(row[4]))
                    throw new SchemaV3ContractException($"{table} row {id} deleted_at is invalid.");
                if (table == "assignments" && version == 5 && uuid != DeterministicUuid(instanceUuid, "task", id))
                    throw new SchemaV3ContractException($"Task {id} UUID does not match database lineage.");
            }
        }

        foreach (var table in new[] { "courses", "tags" })
        {
            foreach (var row in QueryRows(connection, transaction, $"SELECT id, name, normalized_name FROM {table}"))
                if (CanonicalName(Convert.ToString(row[1], CultureInfo.InvariantCulture) ?? "") != Convert.ToString(row[2], CultureInfo.InvariantCulture))
                    throw new SchemaV3ContractException($"{table} normalized_name is invalid.");
        }

        foreach (var column in QueryRows(connection, transaction, "PRAGMA table_xinfo(attachments)"))
        {
            var declaredType = Convert.ToString(column[2], CultureInfo.InvariantCulture)?.Trim() ?? "";
            if (declaredType.Length == 0 || declaredType.Contains("BLOB", StringComparison.OrdinalIgnoreCase))
                throw new SchemaV3ContractException("Attachments must contain metadata only, never BLOB-affinity columns.");
        }
        foreach (var row in QueryRows(connection, transaction, "SELECT id, uuid, file_name, relative_path, sha256 FROM attachments"))
        {
            var uuid = (string)row[1];
            var fileName = (string)row[2];
            var path = (string)row[3];
            var digest = (string)row[4];
            if (!SafeFileName(fileName) || path != $"attachments/{uuid}" || !SafeRelativePath(path) || !Sha256Regex().IsMatch(digest))
                throw new SchemaV3ContractException("Attachment metadata is unsafe.");
        }
        foreach (var row in QueryRows(connection, transaction, "SELECT id, trigger_at_utc, last_scheduled_at, repeat_rule FROM reminders"))
        {
            if (!IsUtcTimestamp(row[1]) || (row[2] is not DBNull && !IsUtcTimestamp(row[2])))
                throw new SchemaV3ContractException("Reminder UTC timestamp is invalid.");
            var storedRule = row[3] is DBNull ? null : (string)row[3];
            try
            {
                if (CanonicalRepeatRule(storedRule) != storedRule)
                    throw new SchemaV3ContractException("Reminder repeat_rule is not stored canonically.");
            }
            catch (ArgumentException error)
            {
                throw new SchemaV3ContractException("Reminder repeat_rule is invalid: " + error.Message);
            }
        }
        foreach (var row in QueryRows(connection, transaction, "SELECT timezone_id FROM assignments WHERE timezone_id IS NOT NULL"))
        {
            try { _ = LocalWallTime.ResolveTimeZone((string)row[0]); }
            catch (ArgumentException error)
            {
                throw new SchemaV3ContractException("Task timezone_id is invalid: " + error.Message);
            }
        }

        using (var invalidRelations = connection.CreateCommand())
        {
            invalidRelations.Transaction = transaction;
            invalidRelations.CommandText =
                "SELECT a.id FROM assignments a LEFT JOIN courses c ON c.id=a.course_id " +
                "LEFT JOIN projects p ON p.id=a.project_id " +
                "WHERE (a.course_id IS NOT NULL AND (c.id IS NULL OR a.course_name!=c.name)) " +
                "OR (a.project_id IS NOT NULL AND (p.id IS NULL OR (p.course_id IS NOT NULL AND (a.course_id IS NULL OR p.course_id!=a.course_id)))) LIMIT 1";
            if (invalidRelations.ExecuteScalar() is not null)
                throw new SchemaV3ContractException("Task course/project relationship is inconsistent.");
        }

        using (var invalidRows = connection.CreateCommand())
        {
            invalidRows.Transaction = transaction;
            invalidRows.CommandText =
                "SELECT 1 FROM courses WHERE is_archived IS NULL OR is_archived NOT IN (0,1) " +
                "UNION ALL SELECT 1 FROM projects WHERE status IS NULL OR status NOT IN ('active','on_hold','completed','archived') " +
                "UNION ALL SELECT 1 FROM reminders WHERE is_enabled IS NULL OR is_enabled NOT IN (0,1) " +
                "OR lead_minutes IS NULL OR lead_minutes<0 " +
                "UNION ALL SELECT 1 FROM subtasks WHERE status IS NULL " +
                "OR status NOT IN ('not_started','in_progress','completed') " +
                "OR sort_order IS NULL OR sort_order<0 " +
                "OR (status='completed' AND completed_at IS NULL) " +
                "OR (status!='completed' AND completed_at IS NOT NULL) " +
                "UNION ALL SELECT 1 FROM attachments WHERE byte_size IS NULL OR byte_size<0 LIMIT 1";
            if (invalidRows.ExecuteScalar() is not null)
                throw new SchemaV3ContractException("Organization row semantics are invalid.");
        }

        using (var invalid = connection.CreateCommand())
        {
            invalid.Transaction = transaction;
            invalid.CommandText =
                "SELECT id FROM assignments WHERE status IS NULL OR priority IS NULL " +
                "OR status NOT IN ('not_started','in_progress','completed') " +
                "OR priority NOT IN ('low','medium','high') " +
                "OR progress_percent IS NULL OR progress_percent NOT BETWEEN 0 AND 100 " +
                "OR all_day IS NULL OR all_day NOT IN (0,1) " +
                "OR (all_day=1 AND due_date IS NULL) " +
                "OR (status='completed' AND (progress_percent!=100 OR completed_at IS NULL)) " +
                "OR (status!='completed' AND (progress_percent=100 OR completed_at IS NOT NULL)) LIMIT 1";
            if (invalid.ExecuteScalar() is not null)
                throw new SchemaV3ContractException("Task progress semantics are invalid.");
        }
        foreach (var row in QueryRows(connection, transaction,
                     "SELECT a.id,a.status,a.progress_percent,COUNT(s.id)," +
                     "SUM(CASE WHEN s.status='completed' THEN 1 ELSE 0 END)," +
                     "SUM(CASE WHEN s.status='in_progress' THEN 1 ELSE 0 END) " +
                     "FROM assignments a JOIN subtasks s ON s.assignment_id=a.id AND s.deleted_at IS NULL " +
                     "GROUP BY a.id,a.status,a.progress_percent"))
        {
            var total = Convert.ToInt32(row[3], CultureInfo.InvariantCulture);
            var completed = Convert.ToInt32(row[4], CultureInfo.InvariantCulture);
            var inProgress = Convert.ToInt32(row[5], CultureInfo.InvariantCulture);
            var expectedProgress = completed * 100 / total;
            var expectedStatus = completed == total
                ? "completed"
                : completed > 0 || inProgress > 0 ? "in_progress" : "not_started";
            if ((string)row[1] != expectedStatus || Convert.ToInt32(row[2], CultureInfo.InvariantCulture) != expectedProgress)
                throw new SchemaV3ContractException($"Assignment {row[0]} does not match active subtasks.");
        }
        foreach (var table in new[] { "assignments", "subtasks" })
        {
            foreach (var row in QueryRows(connection, transaction, $"SELECT uuid, completed_at FROM {table} WHERE completed_at IS NOT NULL"))
                if (UuidVersion((string)row[0]) == 4 && !IsUtcTimestamp(row[1]))
                    throw new SchemaV3ContractException($"{table} completed_at is invalid.");
        }
    }

    private static void ValidateMigratedLineage(
        SqliteConnection connection,
        SqliteTransaction transaction,
        IReadOnlyList<LegacyTask> legacy,
        string instanceUuid)
    {
        var expectedCourses = legacy
            .Select(row => row.CourseName)
            .Where(name => CanonicalName(name).Length > 0)
            .Distinct(StringComparer.Ordinal)
            .ToDictionary(
                name => name,
                name => DeterministicUuid(instanceUuid, "course", name),
                StringComparer.Ordinal);
        var actualCourses = QueryRows(connection, transaction, "SELECT name,uuid FROM courses")
            .ToDictionary(row => (string)row[0], row => (string)row[1], StringComparer.Ordinal);
        if (expectedCourses.Count != actualCourses.Count ||
            expectedCourses.Any(pair =>
                !actualCourses.TryGetValue(pair.Key, out var uuid) || uuid != pair.Value))
        {
            throw new SchemaV3ContractException(
                "Migrated course UUIDs do not match the legacy snapshot and database lineage.");
        }

        var courseIds = QueryRows(connection, transaction, "SELECT name,id FROM courses")
            .ToDictionary(
                row => (string)row[0],
                row => Convert.ToInt64(row[1], CultureInfo.InvariantCulture),
                StringComparer.Ordinal);
        foreach (var row in legacy)
        {
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText =
                "SELECT uuid,course_id,project_id,completed_at,progress_percent," +
                "all_day,timezone_id,deleted_at FROM assignments WHERE id=$id";
            command.Parameters.AddWithValue("$id", row.Id);
            using var reader = command.ExecuteReader();
            if (!reader.Read())
                throw new SchemaV3ContractException($"Migrated task {row.Id} is missing.");
            var expectedCourseId = courseIds.TryGetValue(row.CourseName, out var courseId)
                ? courseId
                : (long?)null;
            var expectedCompletedAt = row.Status == "completed" ? row.UpdatedAt : null;
            if (reader.GetString(0) != DeterministicUuid(instanceUuid, "task", row.Id) ||
                (reader.IsDBNull(1) ? null : reader.GetInt64(1)) != expectedCourseId ||
                !reader.IsDBNull(2) ||
                (reader.IsDBNull(3) ? null : reader.GetString(3)) != expectedCompletedAt ||
                reader.GetInt32(4) != (row.Status == "completed" ? 100 : 0) ||
                reader.GetInt32(5) != 0 ||
                !reader.IsDBNull(6) ||
                !reader.IsDBNull(7))
            {
                throw new SchemaV3ContractException(
                    $"Migrated task {row.Id} fields do not match the legacy snapshot.");
            }
        }
    }

    public static bool IsUtcTimestamp(object value)
    {
        if (value is not string text || !UtcRegex().IsMatch(text)) return false;
        return DateTimeOffset.TryParseExact(
            text,
            ["yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.FFFFFF'Z'"],
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out _);
    }

    public static bool IsIanaTimeZoneId(string value) => IanaRegex().IsMatch(value);

    public static string? CanonicalRepeatRule(string? value)
    {
        if (value is null) return null;
        var cleaned = value.Trim();
        if (cleaned.Length == 0) return null;
        if (cleaned.Length > 1000 || cleaned.Any(char.IsWhiteSpace) || cleaned.Contains("DTSTART", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("repeat_rule must be one RRULE without DTSTART or whitespace.");
        var parts = cleaned.Split(';');
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var ordered = new List<(string Key, string Value)>();
        var allowed = new HashSet<string>(["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH"], StringComparer.Ordinal);
        foreach (var part in parts)
        {
            var pair = part.Split('=', 2);
            if (pair.Length != 2 || part.Count(character => character == '=') != 1)
                throw new ArgumentException("repeat_rule components require KEY=VALUE syntax.");
            var key = pair[0].ToUpperInvariant();
            var ruleValue = pair[1].ToUpperInvariant();
            if (!allowed.Contains(key) || ruleValue.Length == 0 || !seen.Add(key))
                throw new ArgumentException("repeat_rule contains an unsupported or duplicate key.");
            ordered.Add((key, ruleValue));
        }
        var parsed = ordered.ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
        if (!parsed.TryGetValue("FREQ", out var frequency) || frequency is not ("DAILY" or "WEEKLY" or "MONTHLY" or "YEARLY"))
            throw new ArgumentException("repeat_rule requires a supported FREQ.");
        if (parsed.ContainsKey("COUNT") && parsed.ContainsKey("UNTIL"))
            throw new ArgumentException("repeat_rule cannot combine COUNT and UNTIL.");
        foreach (var (key, maximum) in new[] { ("INTERVAL", 999), ("COUNT", 9999) })
            if (parsed.TryGetValue(key, out var number) &&
                (!number.All(character => character is >= '0' and <= '9') ||
                 !int.TryParse(number, NumberStyles.None, CultureInfo.InvariantCulture, out var integer) ||
                 integer < 1 || integer > maximum))
                throw new ArgumentException($"repeat_rule {key} is outside the allowed range.");
        if (parsed.TryGetValue("UNTIL", out var until))
        {
            var format = until.Length == 8 ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'";
            if (!Regex.IsMatch(until, @"^(?:[0-9]{8}|[0-9]{8}T[0-9]{6}Z)$", RegexOptions.CultureInvariant) ||
                !DateTime.TryParseExact(until, format, CultureInfo.InvariantCulture, DateTimeStyles.None, out _))
                throw new ArgumentException("repeat_rule UNTIL is invalid.");
        }
        if (parsed.TryGetValue("BYDAY", out var byDay))
        {
            var days = byDay.Split(',');
            var allowedDays = new HashSet<string>(["MO", "TU", "WE", "TH", "FR", "SA", "SU"], StringComparer.Ordinal);
            if (days.Length != days.Distinct(StringComparer.Ordinal).Count() || days.Any(day => !allowedDays.Contains(day)))
                throw new ArgumentException("repeat_rule BYDAY is invalid.");
        }
        ValidateIntegerList(parsed, "BYMONTHDAY", -31, 31);
        ValidateIntegerList(parsed, "BYMONTH", 1, 12);
        return string.Join(';', ordered.Select(item => $"{item.Key}={item.Value}"));
    }

    public static bool IsValidRepeatRule(string? value)
    {
        try { _ = CanonicalRepeatRule(value); return true; }
        catch (ArgumentException) { return false; }
    }

    private static void ValidateIntegerList(
        IReadOnlyDictionary<string, string> parsed,
        string key,
        int minimum,
        int maximum)
    {
        if (!parsed.TryGetValue(key, out var raw)) return;
        var values = raw.Split(',');
        var parsedValues = new List<int>();
        foreach (var value in values)
        {
            var digits = value.StartsWith("-", StringComparison.Ordinal) ? value[1..] : value;
            if (digits.Length == 0 || !digits.All(character => character is >= '0' and <= '9') ||
                !int.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var number))
                throw new ArgumentException($"repeat_rule {key} must contain integers.");
            parsedValues.Add(number);
        }
        if (parsedValues.Count != parsedValues.Distinct().Count() || parsedValues.Any(number => number == 0 || number < minimum || number > maximum))
            throw new ArgumentException($"repeat_rule {key} contains an invalid value.");
    }

    private static void CreateIdentity(SqliteConnection connection, SqliteTransaction transaction, string uuid)
    {
        Execute(connection, transaction, $"""
            CREATE TABLE database_identity (
                singleton INTEGER NOT NULL PRIMARY KEY CHECK (singleton = 1),
                instance_uuid TEXT NOT NULL CHECK ({UuidCheck("instance_uuid", false)}),
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            )
            """);
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "INSERT INTO database_identity(singleton, instance_uuid) VALUES(1, $uuid)";
        command.Parameters.AddWithValue("$uuid", uuid);
        command.ExecuteNonQuery();
    }

    private static void CreatePrimaryTables(SqliteConnection connection, SqliteTransaction transaction)
    {
        var migrated = UuidCheck("uuid", true);
        var fresh = UuidCheck("uuid", false);
        var audit = "created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), deleted_at TEXT";
        Execute(connection, transaction, $"""
            CREATE TABLE courses (
                id INTEGER NOT NULL PRIMARY KEY,
                uuid TEXT NOT NULL CHECK ({migrated}),
                name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
                normalized_name TEXT NOT NULL CHECK (length(normalized_name) >= 1),
                color_hex TEXT CHECK (color_hex IS NULL OR (length(color_hex)=7 AND substr(color_hex,1,1)='#' AND substr(color_hex,2) NOT GLOB '*[^0-9A-Fa-f]*')),
                teacher TEXT, semester TEXT,
                is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0,1)),
                {audit}
            )
            """);
        Execute(connection, transaction, $"""
            CREATE TABLE projects (
                id INTEGER NOT NULL PRIMARY KEY,
                uuid TEXT NOT NULL CHECK ({fresh}),
                course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
                name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 255),
                description TEXT,
                status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','on_hold','completed','archived')),
                {audit}
            )
            """);
        Execute(connection, transaction, $"""
            CREATE TABLE tags (
                id INTEGER NOT NULL PRIMARY KEY,
                uuid TEXT NOT NULL CHECK ({fresh}),
                name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 80),
                normalized_name TEXT NOT NULL CHECK (length(normalized_name) >= 1),
                color_hex TEXT CHECK (color_hex IS NULL OR (length(color_hex)=7 AND substr(color_hex,1,1)='#' AND substr(color_hex,2) NOT GLOB '*[^0-9A-Fa-f]*')),
                {audit}
            )
            """);
    }

    private static Dictionary<string, long> MigrateCourses(
        SqliteConnection connection,
        SqliteTransaction transaction,
        IReadOnlyList<LegacyTask> rows,
        string instanceUuid)
    {
        var firstRows = rows
            .Where(row => CanonicalName(row.CourseName).Length > 0)
            .GroupBy(row => row.CourseName, StringComparer.Ordinal)
            .Select(group => group.OrderBy(row => row.Id).First())
            .OrderBy(row => Encoding.UTF8.GetBytes(row.CourseName), ByteArrayComparer.Instance)
            .ToArray();
        var result = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var row in firstRows)
        {
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText =
                "INSERT INTO courses(uuid,name,normalized_name,created_at,updated_at) " +
                "VALUES($uuid,$name,$normalized,$created,$updated); SELECT last_insert_rowid();";
            command.Parameters.AddWithValue("$uuid", DeterministicUuid(instanceUuid, "course", row.CourseName));
            command.Parameters.AddWithValue("$name", row.CourseName);
            command.Parameters.AddWithValue("$normalized", CanonicalName(row.CourseName));
            command.Parameters.AddWithValue("$created", row.CreatedAt);
            command.Parameters.AddWithValue("$updated", row.UpdatedAt);
            result[row.CourseName] = Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
        }
        return result;
    }

    private static void AddAssignmentColumns(SqliteConnection connection, SqliteTransaction transaction)
    {
        foreach (var statement in new[]
        {
            "ALTER TABLE assignments ADD COLUMN uuid TEXT",
            "ALTER TABLE assignments ADD COLUMN course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL",
            "ALTER TABLE assignments ADD COLUMN project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL",
            "ALTER TABLE assignments ADD COLUMN completed_at TEXT",
            "ALTER TABLE assignments ADD COLUMN progress_percent INTEGER NOT NULL DEFAULT 0 CHECK (progress_percent BETWEEN 0 AND 100)",
            "ALTER TABLE assignments ADD COLUMN all_day INTEGER NOT NULL DEFAULT 0 CHECK (all_day IN (0,1))",
            "ALTER TABLE assignments ADD COLUMN timezone_id TEXT",
            "ALTER TABLE assignments ADD COLUMN deleted_at TEXT"
        }) Execute(connection, transaction, statement);
    }

    private static void CreateChildTables(SqliteConnection connection, SqliteTransaction transaction)
    {
        var uuid = UuidCheck("uuid", false);
        var audit = "created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), deleted_at TEXT";
        Execute(connection, transaction, $"""
            CREATE TABLE task_tags (
                id INTEGER NOT NULL PRIMARY KEY, uuid TEXT NOT NULL CHECK ({uuid}),
                assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
                tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE, {audit}
            )
            """);
        Execute(connection, transaction, $"""
            CREATE TABLE subtasks (
                id INTEGER NOT NULL PRIMARY KEY, uuid TEXT NOT NULL CHECK ({uuid}),
                assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
                title TEXT NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 255),
                status TEXT NOT NULL DEFAULT 'not_started' CHECK (status IN ('not_started','in_progress','completed')),
                sort_order INTEGER NOT NULL DEFAULT 0 CHECK (sort_order >= 0), completed_at TEXT,
                {audit},
                CHECK ((status='completed' AND completed_at IS NOT NULL) OR (status!='completed' AND completed_at IS NULL))
            )
            """);
        Execute(connection, transaction, $"""
            CREATE TABLE attachments (
                id INTEGER NOT NULL PRIMARY KEY, uuid TEXT NOT NULL CHECK ({uuid}),
                assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
                file_name TEXT NOT NULL CHECK (length(file_name) BETWEEN 1 AND 255 AND file_name NOT IN ('.','..') AND instr(file_name,char(0))=0 AND instr(file_name,'/')=0 AND instr(file_name,char(92))=0),
                relative_path TEXT NOT NULL CHECK (
                    length(relative_path) BETWEEN 1 AND 1000 AND relative_path='attachments/'||uuid
                    AND substr(relative_path,1,1)!='/' AND substr(relative_path,-1,1)!='/'
                    AND instr(relative_path,char(0))=0 AND instr(relative_path,'//')=0
                    AND instr(relative_path,char(92))=0 AND instr(relative_path,':')=0
                    AND relative_path!='..' AND relative_path NOT LIKE '../%' AND relative_path NOT LIKE '%/../%'
                    AND relative_path!='.' AND relative_path NOT LIKE './%' AND relative_path NOT LIKE '%/./%'),
                mime_type TEXT, byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
                sha256 TEXT NOT NULL CHECK (length(sha256)=64 AND sha256=lower(sha256) AND sha256 NOT GLOB '*[^0-9a-f]*'),
                {audit}
            )
            """);
        Execute(connection, transaction, $"""
            CREATE TABLE reminders (
                id INTEGER NOT NULL PRIMARY KEY, uuid TEXT NOT NULL CHECK ({uuid}),
                assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
                trigger_at_utc TEXT NOT NULL,
                lead_minutes INTEGER NOT NULL DEFAULT 0 CHECK (lead_minutes >= 0),
                repeat_rule TEXT, is_enabled INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0,1)),
                last_scheduled_at TEXT, {audit}
            )
            """);
    }

    private static void CreateIndexes(SqliteConnection connection, SqliteTransaction transaction)
    {
        foreach (var (name, contract) in Indexes)
        {
            var unique = contract.Unique ? "UNIQUE " : "";
            var where = contract.Partial ? " WHERE deleted_at IS NULL" : "";
            Execute(connection, transaction,
                $"CREATE {unique}INDEX IF NOT EXISTS {name} ON {contract.Table}({string.Join(",", contract.Columns)}){where}");
        }
    }

    private static IReadOnlyDictionary<string, (string Table, string Sql)> TriggerStatements()
    {
        var invalid = """
            NEW.status IS NULL
            OR NEW.priority IS NULL
            OR NEW.status NOT IN ('not_started', 'in_progress', 'completed')
            OR NEW.priority NOT IN ('low', 'medium', 'high')
            OR NEW.progress_percent NOT BETWEEN 0 AND 100
            OR NEW.all_day NOT IN (0, 1)
            OR (NEW.all_day = 1 AND NEW.due_date IS NULL)
            OR (NEW.status = 'completed' AND
                (NEW.progress_percent != 100 OR NEW.completed_at IS NULL))
            OR (NEW.status != 'completed' AND
                (NEW.progress_percent = 100 OR NEW.completed_at IS NOT NULL))
            """.Trim();
        var result = new Dictionary<string, (string, string)>(StringComparer.Ordinal)
        {
            ["assignments_v3_contract_insert"] = ("assignments", $"""
                CREATE TRIGGER assignments_v3_contract_insert
                BEFORE INSERT ON assignments
                WHEN NEW.uuid IS NULL OR NOT ({UuidCheck("NEW.uuid", true)}) OR ({invalid})
                BEGIN
                    SELECT RAISE(ABORT, 'assignment violates schema v3 contract');
                END
                """.Trim()),
            ["assignments_v3_contract_update"] = ("assignments", $"""
                CREATE TRIGGER assignments_v3_contract_update
                BEFORE UPDATE ON assignments
                WHEN NEW.uuid IS NULL OR NOT ({UuidCheck("NEW.uuid", true)}) OR ({invalid})
                BEGIN
                    SELECT RAISE(ABORT, 'assignment violates schema v3 contract');
                END
                """.Trim()),
            ["database_identity_immutable_update"] = ("database_identity", """
                CREATE TRIGGER database_identity_immutable_update
                BEFORE UPDATE ON database_identity
                BEGIN
                    SELECT RAISE(ABORT, 'database identity is immutable');
                END
                """.Trim()),
            ["database_identity_immutable_delete"] = ("database_identity", """
                CREATE TRIGGER database_identity_immutable_delete
                BEFORE DELETE ON database_identity
                BEGIN
                    SELECT RAISE(ABORT, 'database identity is immutable');
                END
                """.Trim())
        };
        foreach (var table in UuidTables)
        {
            var name = $"{table}_uuid_immutable";
            result[name] = (table, $"""
                CREATE TRIGGER {name}
                BEFORE UPDATE OF uuid ON {table}
                WHEN NEW.uuid IS NOT OLD.uuid
                BEGIN
                    SELECT RAISE(ABORT, '{table} UUID is immutable');
                END
                """.Trim());
        }
        return result;
    }

    private static void CreateContractTriggers(SqliteConnection connection, SqliteTransaction transaction)
    {
        foreach (var item in TriggerStatements().Values) Execute(connection, transaction, item.Sql);
    }

    private static void ValidateIndexes(SqliteConnection connection, SqliteTransaction? transaction)
    {
        foreach (var (name, expected) in Indexes)
        {
            var rows = QueryRows(connection, transaction, "SELECT tbl_name, sql FROM sqlite_master WHERE type='index' AND name=$name", ("$name", name));
            if (rows.Count != 1 || (string)rows[0][0] != expected.Table)
                throw new SchemaV3ContractException($"Index {name} is missing or belongs to the wrong table.");
            var info = QueryRows(connection, transaction, $"PRAGMA index_info({QuoteIdentifier(name)})");
            var columns = info.Select(row => (string)row[2]).ToArray();
            if (!columns.SequenceEqual(expected.Columns))
                throw new SchemaV3ContractException($"Index {name} has the wrong columns.");
            var list = QueryRows(connection, transaction, $"PRAGMA index_list({QuoteIdentifier(expected.Table)})");
            var index = list.SingleOrDefault(row => (string)row[1] == name);
            if (index is null || Convert.ToInt64(index[2], CultureInfo.InvariantCulture) != (expected.Unique ? 1 : 0) || Convert.ToInt64(index[4], CultureInfo.InvariantCulture) != (expected.Partial ? 1 : 0))
                throw new SchemaV3ContractException($"Index {name} has the wrong uniqueness contract.");
            if (expected.Partial && !Regex.IsMatch(NormalizeSql((string)rows[0][1]), @"\bwhere\s+deleted_at\s+is\s+null$", RegexOptions.IgnoreCase))
                throw new SchemaV3ContractException($"Index {name} has the wrong partial predicate.");
        }
    }

    private static void ValidateTriggers(SqliteConnection connection, SqliteTransaction? transaction)
    {
        foreach (var (name, expected) in TriggerStatements())
        {
            var rows = QueryRows(connection, transaction, "SELECT tbl_name, sql FROM sqlite_master WHERE type='trigger' AND name=$name", ("$name", name));
            if (rows.Count != 1 || (string)rows[0][0] != expected.Table || NormalizeSql((string)rows[0][1]) != NormalizeSql(expected.Sql))
                throw new SchemaV3ContractException($"Trigger {name} does not match the v3 contract.");
        }
    }

    private static void ValidateForeignKeys(SqliteConnection connection, SqliteTransaction? transaction)
    {
        if (QueryRows(connection, transaction, "PRAGMA foreign_key_check").Count != 0)
            throw new SchemaV3ContractException("Foreign-key validation failed.");
        var expected = new Dictionary<string, (string From, string Table, string To, string Delete)[]>
        {
            ["assignments"] = [("course_id", "courses", "id", "SET NULL"), ("project_id", "projects", "id", "SET NULL")],
            ["projects"] = [("course_id", "courses", "id", "SET NULL")],
            ["task_tags"] = [("assignment_id", "assignments", "id", "CASCADE"), ("tag_id", "tags", "id", "CASCADE")],
            ["subtasks"] = [("assignment_id", "assignments", "id", "CASCADE")],
            ["attachments"] = [("assignment_id", "assignments", "id", "CASCADE")],
            ["reminders"] = [("assignment_id", "assignments", "id", "CASCADE")]
        };
        foreach (var (table, relationships) in expected)
        {
            var rows = QueryRows(connection, transaction, $"PRAGMA foreign_key_list({QuoteIdentifier(table)})");
            foreach (var relationship in relationships)
                if (!rows.Any(row => (string)row[3] == relationship.From && (string)row[2] == relationship.Table && (string)row[4] == relationship.To && string.Equals((string)row[6], relationship.Delete, StringComparison.OrdinalIgnoreCase)))
                    throw new SchemaV3ContractException($"{table} foreign key is missing.");
        }
    }

    private static string UuidCheck(string column, bool allowV5)
    {
        var versions = allowV5 ? "('4', '5')" : "('4')";
        return $"""
            length({column}) = 36
            AND length(replace({column}, '-', '')) = 32
            AND {column} = lower({column})
            AND substr({column}, 9, 1) = '-'
            AND substr({column}, 14, 1) = '-'
            AND substr({column}, 19, 1) = '-'
            AND substr({column}, 24, 1) = '-'
            AND substr({column}, 15, 1) IN {versions}
            AND substr({column}, 20, 1) IN ('8', '9', 'a', 'b')
            AND replace({column}, '-', '') NOT GLOB '*[^0-9a-f]*'
            """.Trim();
    }

    private static bool IsCanonicalUuid(string value, int? requiredVersion = null)
    {
        if (!Guid.TryParseExact(value, "D", out var parsed) || parsed.ToString("D") != value) return false;
        var version = UuidVersion(value);
        return requiredVersion is null || version == requiredVersion;
    }

    private static int UuidVersion(string value) =>
        IsUuidSyntax(value) ? Convert.ToInt32(value[14].ToString(), 16) : -1;

    private static bool IsUuidSyntax(string value) =>
        value.Length == 36 &&
        Guid.TryParseExact(value, "D", out var parsed) &&
        parsed.ToString("D") == value &&
        value[19] is '8' or '9' or 'a' or 'b';

    private static bool SafeFileName(string value) =>
        value.EnumerateRunes().Count() is >= 1 and <= 255 &&
        value is not ("." or "..") &&
        value.IndexOfAny(['\0', '/', '\\']) < 0;

    private static bool SafeRelativePath(string value) =>
        value.Length is >= 1 and <= 1000 && !value.StartsWith('/') && !value.EndsWith('/') &&
        !value.Contains('\\') && !value.Contains(':') && !value.Contains('\0') &&
        value.Split('/').All(part => part is not ("" or "." or ".."));

    private static string NormalizeSql(string value) =>
        Regex.Replace(value.Trim().TrimEnd(';'), @"\s+", " ").ToLowerInvariant();

    private static HashSet<string> ColumnNames(SqliteConnection connection, SqliteTransaction? transaction, string table) =>
        QueryRows(connection, transaction, $"PRAGMA table_info({QuoteIdentifier(table)})")
            .Select(row => (string)row[1]).ToHashSet(StringComparer.OrdinalIgnoreCase);

    private static bool TableExists(SqliteConnection connection, SqliteTransaction? transaction, string table) =>
        QueryRows(connection, transaction, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=$name LIMIT 1", ("$name", table)).Count == 1;

    private static int ReadVersion(SqliteConnection connection, SqliteTransaction? transaction)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "PRAGMA user_version";
        return Convert.ToInt32(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private static List<LegacyTask> ReadLegacyRows(SqliteConnection connection, SqliteTransaction transaction)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT " + string.Join(',', V2Columns) + " FROM assignments ORDER BY id";
        using var reader = command.ExecuteReader();
        var rows = new List<LegacyTask>();
        while (reader.Read())
        {
            rows.Add(new LegacyTask(
                reader.GetInt64(0), reader.GetString(1), reader.GetString(2), Value(reader, 3),
                Value(reader, 4), Value(reader, 5), reader.GetString(6), reader.GetString(7),
                Value(reader, 8), Value(reader, 9), Value(reader, 10), Value(reader, 11),
                reader.GetString(12), reader.GetString(13)));
        }
        return rows;
    }

    private static string? Value(SqliteDataReader reader, int index) => reader.IsDBNull(index) ? null : reader.GetString(index);

    private static List<(string Name, string Sql)> ReadAssignmentTriggers(SqliteConnection connection, SqliteTransaction transaction) =>
        QueryRows(connection, transaction, "SELECT name, sql FROM sqlite_master WHERE type='trigger' AND tbl_name='assignments' AND sql IS NOT NULL ORDER BY name")
            .Select(row => ((string)row[0], (string)row[1])).ToList();

    private static void EnsureReservedTriggerNamesAvailable(SqliteConnection connection, SqliteTransaction transaction)
    {
        foreach (var name in TriggerStatements().Keys)
            if (QueryRows(connection, transaction, "SELECT 1 FROM sqlite_master WHERE name=$name LIMIT 1", ("$name", name)).Count != 0)
                throw new SchemaV3ContractException($"Reserved trigger name already exists: {name}");
    }

    private static List<object[]> QueryRows(
        SqliteConnection connection,
        SqliteTransaction? transaction,
        string sql,
        params (string Name, object Value)[] parameters)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        foreach (var parameter in parameters) command.Parameters.AddWithValue(parameter.Name, parameter.Value);
        using var reader = command.ExecuteReader();
        var rows = new List<object[]>();
        while (reader.Read())
        {
            var values = new object[reader.FieldCount];
            reader.GetValues(values);
            rows.Add(values);
        }
        return rows;
    }

    private static void ExpectScalar(SqliteConnection connection, SqliteTransaction? transaction, string sql, string expected, string message)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        if (!string.Equals(Convert.ToString(command.ExecuteScalar(), CultureInfo.InvariantCulture), expected, StringComparison.OrdinalIgnoreCase))
            throw new SchemaV3ContractException(message);
    }

    private static void Execute(SqliteConnection connection, SqliteTransaction transaction, string sql)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private static string QuoteIdentifier(string value) => '"' + value.Replace("\"", "\"\"") + '"';

    private sealed record LegacyTask(
        long Id, string CourseName, string Title, string? DueDate, string? Description,
        string? Link, string Status, string Priority, string? SourceName,
        string? SourceType, string? SourceFile, string? SourceUrl,
        string CreatedAt, string UpdatedAt);

    private sealed class ByteArrayComparer : IComparer<byte[]>
    {
        public static ByteArrayComparer Instance { get; } = new();
        public int Compare(byte[]? left, byte[]? right)
        {
            if (ReferenceEquals(left, right)) return 0;
            if (left is null) return -1;
            if (right is null) return 1;
            for (var index = 0; index < Math.Min(left.Length, right.Length); index++)
            {
                var comparison = left[index].CompareTo(right[index]);
                if (comparison != 0) return comparison;
            }
            return left.Length.CompareTo(right.Length);
        }
    }

    [GeneratedRegex(@"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?Z$", RegexOptions.CultureInvariant)]
    private static partial Regex UtcRegex();

    [GeneratedRegex(@"^(?:UTC|[A-Za-z_+\-]+(?:/[A-Za-z0-9_+\-.]+)+)$", RegexOptions.CultureInvariant)]
    private static partial Regex IanaRegex();

    [GeneratedRegex("^[0-9a-f]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex Sha256Regex();
}
