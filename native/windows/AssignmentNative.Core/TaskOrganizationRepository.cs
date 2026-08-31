using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace AssignmentNative.Core;

public interface ITaskOrganizationRepository
{
    string DatabasePath { get; }
    IReadOnlyList<CourseItem> FetchCourses(bool includeDeleted = false);
    CourseItem CreateCourse(CourseDraft draft);
    CourseItem UpdateCourse(long id, CourseDraft draft);
    void DeleteCourse(long id);
    CourseItem RestoreCourse(long id);

    IReadOnlyList<ProjectItem> FetchProjects(long? courseId = null, bool includeDeleted = false);
    ProjectItem CreateProject(ProjectDraft draft);
    ProjectItem UpdateProject(long id, ProjectDraft draft);
    void DeleteProject(long id);
    ProjectItem RestoreProject(long id);

    IReadOnlyList<TagItem> FetchTags(bool includeDeleted = false);
    TagItem CreateTag(TagDraft draft);
    TagItem UpdateTag(long id, TagDraft draft);
    void DeleteTag(long id);
    TagItem RestoreTag(long id);
    IReadOnlyList<TaskTagItem> FetchTaskTags(long assignmentId, bool includeDeleted = false);
    TaskTagItem AttachTag(long assignmentId, long tagId);
    void DetachTag(long assignmentId, long tagId);

    IReadOnlyList<SubtaskItem> FetchSubtasks(long assignmentId, bool includeDeleted = false);
    SubtaskItem CreateSubtask(SubtaskDraft draft);
    SubtaskItem UpdateSubtask(long id, SubtaskDraft draft);
    void DeleteSubtask(long id);
    SubtaskItem RestoreSubtask(long id);

    IReadOnlyList<AttachmentMetadataItem> FetchAttachments(long assignmentId, bool includeDeleted = false);
    IReadOnlyList<AttachmentMetadataItem> FetchAllAttachments(bool includeDeleted = false);
    AttachmentMetadataItem CreateAttachment(AttachmentMetadataDraft draft);
    AttachmentMetadataItem UpdateAttachment(long id, AttachmentMetadataDraft draft);
    void DeleteAttachment(long id);
    AttachmentMetadataItem RestoreAttachment(long id);

    IReadOnlyList<ReminderItem> FetchReminders(long assignmentId, bool includeDeleted = false);
    ReminderItem CreateReminder(ReminderDraft draft);
    ReminderItem UpdateReminder(long id, ReminderDraft draft);
    void DeleteReminder(long id);
    ReminderItem RestoreReminder(long id);
}

public sealed partial class TaskOrganizationRepository : ITaskOrganizationRepository
{
    private readonly string _connectionString;
    public string DatabasePath { get; }

    public TaskOrganizationRepository(string databasePath)
        : this(new AssignmentDatabase(databasePath)) { }

    public TaskOrganizationRepository(AssignmentDatabase database)
    {
        ArgumentNullException.ThrowIfNull(database);
        DatabasePath = database.DatabasePath;
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadWrite,
            Cache = SqliteCacheMode.Shared,
            Pooling = false
        }.ToString();
    }

    public IReadOnlyList<CourseItem> FetchCourses(bool includeDeleted = false)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT id,uuid,name,normalized_name,color_hex,teacher,semester,is_archived,created_at,updated_at,deleted_at " +
            "FROM courses " + (includeDeleted ? "" : "WHERE deleted_at IS NULL ") +
            "ORDER BY is_archived,name COLLATE NOCASE,id";
        using var reader = command.ExecuteReader();
        var result = new List<CourseItem>();
        while (reader.Read()) result.Add(ReadCourse(reader));
        return result;
    }

    public CourseItem CreateCourse(CourseDraft draft)
    {
        var value = ValidateCourse(draft);
        var id = Write((connection, transaction) =>
        {
            var now = SchemaV3Contract.CanonicalUtcNow();
            using var command = Command(connection, transaction,
                "INSERT INTO courses(uuid,name,normalized_name,color_hex,teacher,semester,is_archived,created_at,updated_at) " +
                "VALUES($uuid,$name,$normalized,$color,$teacher,$semester,$archived,$now,$now); SELECT last_insert_rowid();");
            Add(command, "$uuid", SchemaV3Contract.NewUuid());
            Add(command, "$name", value.Name);
            Add(command, "$normalized", SchemaV3Contract.CanonicalName(value.Name));
            Add(command, "$color", value.ColorHex);
            Add(command, "$teacher", value.Teacher);
            Add(command, "$semester", value.Semester);
            Add(command, "$archived", value.IsArchived ? 1 : 0);
            Add(command, "$now", now);
            return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
        });
        return GetCourse(id);
    }

    public CourseItem UpdateCourse(long id, CourseDraft draft)
    {
        var value = ValidateCourse(draft);
        Write((connection, transaction) =>
        {
            var now = SchemaV3Contract.CanonicalUtcNow();
            using var command = Command(connection, transaction,
                "UPDATE courses SET name=$name,normalized_name=$normalized,color_hex=$color,teacher=$teacher,semester=$semester,is_archived=$archived,updated_at=$now " +
                "WHERE id=$id AND deleted_at IS NULL");
            Add(command, "$name", value.Name);
            Add(command, "$normalized", SchemaV3Contract.CanonicalName(value.Name));
            Add(command, "$color", value.ColorHex);
            Add(command, "$teacher", value.Teacher);
            Add(command, "$semester", value.Semester);
            Add(command, "$archived", value.IsArchived ? 1 : 0);
            Add(command, "$now", now);
            Add(command, "$id", id);
            EnsureOne(command.ExecuteNonQuery(), "Course", id);
            using var tasks = Command(connection, transaction,
                "UPDATE assignments SET course_name=$name,updated_at=$now WHERE course_id=$id");
            Add(tasks, "$name", value.Name);
            Add(tasks, "$now", now);
            Add(tasks, "$id", id);
            tasks.ExecuteNonQuery();
            return 0;
        });
        return GetCourse(id);
    }

    public void DeleteCourse(long id) => SoftDelete("courses", "Course", id);
    public CourseItem RestoreCourse(long id) { Restore("courses", "Course", id); return GetCourse(id); }

    public IReadOnlyList<ProjectItem> FetchProjects(long? courseId = null, bool includeDeleted = false)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        var filters = new List<string>();
        if (!includeDeleted) filters.Add("deleted_at IS NULL");
        if (courseId is not null) filters.Add("course_id=$course");
        command.CommandText =
            "SELECT id,uuid,course_id,name,description,status,created_at,updated_at,deleted_at FROM projects " +
            (filters.Count == 0 ? "" : "WHERE " + string.Join(" AND ", filters)) + " ORDER BY name COLLATE NOCASE,id";
        if (courseId is not null) Add(command, "$course", courseId.Value);
        using var reader = command.ExecuteReader();
        var result = new List<ProjectItem>();
        while (reader.Read()) result.Add(ReadProject(reader));
        return result;
    }

    public ProjectItem CreateProject(ProjectDraft draft)
    {
        var value = ValidateProjectDraft(draft);
        var id = Write((connection, transaction) =>
        {
            RequireActiveCourse(connection, transaction, value.CourseId);
            var now = SchemaV3Contract.CanonicalUtcNow();
            using var command = Command(connection, transaction,
                "INSERT INTO projects(uuid,course_id,name,description,status,created_at,updated_at) " +
                "VALUES($uuid,$course,$name,$description,$status,$now,$now); SELECT last_insert_rowid();");
            Add(command, "$uuid", SchemaV3Contract.NewUuid()); Add(command, "$course", value.CourseId);
            Add(command, "$name", value.Name); Add(command, "$description", value.Description);
            Add(command, "$status", value.Status); Add(command, "$now", now);
            return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
        });
        return GetProject(id);
    }

    public ProjectItem UpdateProject(long id, ProjectDraft draft)
    {
        var value = ValidateProjectDraft(draft);
        Write((connection, transaction) =>
        {
            RequireActiveCourse(connection, transaction, value.CourseId);
            if (value.CourseId is not null)
            {
                using var conflicts = Command(connection, transaction,
                    "SELECT 1 FROM assignments WHERE project_id=$project AND (course_id IS NULL OR course_id!=$course) LIMIT 1");
                Add(conflicts, "$project", id); Add(conflicts, "$course", value.CourseId.Value);
                if (conflicts.ExecuteScalar() is not null)
                    throw new OrganizationRepositoryException("Changing the project course would conflict with linked tasks.");
            }
            using var command = Command(connection, transaction,
                "UPDATE projects SET course_id=$course,name=$name,description=$description,status=$status,updated_at=$now WHERE id=$id AND deleted_at IS NULL");
            Add(command, "$course", value.CourseId); Add(command, "$name", value.Name);
            Add(command, "$description", value.Description); Add(command, "$status", value.Status);
            Add(command, "$now", SchemaV3Contract.CanonicalUtcNow()); Add(command, "$id", id);
            EnsureOne(command.ExecuteNonQuery(), "Project", id);
            return 0;
        });
        return GetProject(id);
    }

    public void DeleteProject(long id) => SoftDelete("projects", "Project", id);
    public ProjectItem RestoreProject(long id)
    {
        Write((connection, transaction) =>
        {
            var courseId = ScalarNullableLong(connection, transaction, "SELECT course_id FROM projects WHERE id=$id", id, "Project");
            RequireActiveCourse(connection, transaction, courseId);
            RestoreRow(connection, transaction, "projects", "Project", id);
            return 0;
        });
        return GetProject(id);
    }

    public IReadOnlyList<TagItem> FetchTags(bool includeDeleted = false)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT id,uuid,name,normalized_name,color_hex,created_at,updated_at,deleted_at FROM tags " +
            (includeDeleted ? "" : "WHERE deleted_at IS NULL ") + "ORDER BY name COLLATE NOCASE,id";
        using var reader = command.ExecuteReader();
        var result = new List<TagItem>();
        while (reader.Read()) result.Add(ReadTag(reader));
        return result;
    }

    public TagItem CreateTag(TagDraft draft)
    {
        var value = ValidateTag(draft);
        var id = Write((connection, transaction) =>
        {
            var now = SchemaV3Contract.CanonicalUtcNow();
            using var command = Command(connection, transaction,
                "INSERT INTO tags(uuid,name,normalized_name,color_hex,created_at,updated_at) VALUES($uuid,$name,$normalized,$color,$now,$now); SELECT last_insert_rowid();");
            Add(command, "$uuid", SchemaV3Contract.NewUuid()); Add(command, "$name", value.Name);
            Add(command, "$normalized", SchemaV3Contract.CanonicalName(value.Name)); Add(command, "$color", value.ColorHex); Add(command, "$now", now);
            return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
        });
        return GetTag(id);
    }

    public TagItem UpdateTag(long id, TagDraft draft)
    {
        var value = ValidateTag(draft);
        Write((connection, transaction) =>
        {
            using var command = Command(connection, transaction,
                "UPDATE tags SET name=$name,normalized_name=$normalized,color_hex=$color,updated_at=$now WHERE id=$id AND deleted_at IS NULL");
            Add(command, "$name", value.Name); Add(command, "$normalized", SchemaV3Contract.CanonicalName(value.Name));
            Add(command, "$color", value.ColorHex); Add(command, "$now", SchemaV3Contract.CanonicalUtcNow()); Add(command, "$id", id);
            EnsureOne(command.ExecuteNonQuery(), "Tag", id);
            return 0;
        });
        return GetTag(id);
    }

    public void DeleteTag(long id)
    {
        Write((connection, transaction) =>
        {
            var now = SchemaV3Contract.CanonicalUtcNow();
            SoftDeleteRow(connection, transaction, "tags", "Tag", id, now);
            using var links = Command(connection, transaction,
                "UPDATE task_tags SET deleted_at=$now,updated_at=$now WHERE tag_id=$id AND deleted_at IS NULL");
            Add(links, "$now", now); Add(links, "$id", id); links.ExecuteNonQuery();
            return 0;
        });
    }

    public TagItem RestoreTag(long id) { Restore("tags", "Tag", id); return GetTag(id); }

    public IReadOnlyList<TaskTagItem> FetchTaskTags(long assignmentId, bool includeDeleted = false)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT id,uuid,assignment_id,tag_id,created_at,updated_at,deleted_at FROM task_tags " +
            "WHERE assignment_id=$assignment " + (includeDeleted ? "" : "AND deleted_at IS NULL ") + "ORDER BY id";
        Add(command, "$assignment", assignmentId);
        using var reader = command.ExecuteReader();
        var result = new List<TaskTagItem>(); while (reader.Read()) result.Add(ReadTaskTag(reader)); return result;
    }

    public TaskTagItem AttachTag(long assignmentId, long tagId)
    {
        var id = Write((connection, transaction) =>
        {
            RequireActiveAssignment(connection, transaction, assignmentId);
            RequireActiveRow(connection, transaction, "tags", "Tag", tagId);
            using var existing = Command(connection, transaction,
                "SELECT id,deleted_at FROM task_tags WHERE assignment_id=$assignment AND tag_id=$tag ORDER BY id LIMIT 1");
            Add(existing, "$assignment", assignmentId); Add(existing, "$tag", tagId);
            using var reader = existing.ExecuteReader();
            if (reader.Read())
            {
                var existingId = reader.GetInt64(0); var deleted = !reader.IsDBNull(1); reader.Close();
                if (deleted) RestoreRow(connection, transaction, "task_tags", "Task tag", existingId);
                return existingId;
            }
            reader.Close();
            var now = SchemaV3Contract.CanonicalUtcNow();
            using var insert = Command(connection, transaction,
                "INSERT INTO task_tags(uuid,assignment_id,tag_id,created_at,updated_at) VALUES($uuid,$assignment,$tag,$now,$now); SELECT last_insert_rowid();");
            Add(insert, "$uuid", SchemaV3Contract.NewUuid()); Add(insert, "$assignment", assignmentId); Add(insert, "$tag", tagId); Add(insert, "$now", now);
            return Convert.ToInt64(insert.ExecuteScalar(), CultureInfo.InvariantCulture);
        });
        return GetTaskTag(id);
    }

    public void DetachTag(long assignmentId, long tagId)
    {
        Write((connection, transaction) =>
        {
            var now = SchemaV3Contract.CanonicalUtcNow();
            using var command = Command(connection, transaction,
                "UPDATE task_tags SET deleted_at=$now,updated_at=$now WHERE assignment_id=$assignment AND tag_id=$tag AND deleted_at IS NULL");
            Add(command, "$now", now); Add(command, "$assignment", assignmentId); Add(command, "$tag", tagId);
            if (command.ExecuteNonQuery() != 1) throw new OrganizationRepositoryException("Active task tag link was not found.");
            return 0;
        });
    }

    public IReadOnlyList<SubtaskItem> FetchSubtasks(long assignmentId, bool includeDeleted = false)
    {
        using var connection = Open(); using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT id,uuid,assignment_id,title,status,sort_order,completed_at,created_at,updated_at,deleted_at FROM subtasks " +
            "WHERE assignment_id=$assignment " + (includeDeleted ? "" : "AND deleted_at IS NULL ") + "ORDER BY sort_order,id";
        Add(command, "$assignment", assignmentId); using var reader = command.ExecuteReader();
        var result = new List<SubtaskItem>(); while (reader.Read()) result.Add(ReadSubtask(reader)); return result;
    }

    public SubtaskItem CreateSubtask(SubtaskDraft draft)
    {
        var value = ValidateSubtask(draft);
        var id = Write((connection, transaction) =>
        {
            RequireActiveAssignment(connection, transaction, value.AssignmentId);
            var now = SchemaV3Contract.CanonicalUtcNow(); var storageStatus = TaskStatuses.ToDatabaseStatus(value.Status);
            using var command = Command(connection, transaction,
                "INSERT INTO subtasks(uuid,assignment_id,title,status,sort_order,completed_at,created_at,updated_at) " +
                "VALUES($uuid,$assignment,$title,$status,$order,$completed,$now,$now); SELECT last_insert_rowid();");
            Add(command, "$uuid", SchemaV3Contract.NewUuid()); Add(command, "$assignment", value.AssignmentId);
            Add(command, "$title", value.Title); Add(command, "$status", storageStatus); Add(command, "$order", value.SortOrder);
            Add(command, "$completed", storageStatus == "completed" ? now : null); Add(command, "$now", now);
            var result = Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
            TaskStatePersistence.RecalculateParent(connection, transaction, value.AssignmentId, now, resetWhenEmpty: false);
            return result;
        });
        return GetSubtask(id);
    }

    public SubtaskItem UpdateSubtask(long id, SubtaskDraft draft)
    {
        var value = ValidateSubtask(draft);
        Write((connection, transaction) =>
        {
            RequireActiveAssignment(connection, transaction, value.AssignmentId);
            var actualParent = ScalarLong(connection, transaction, "SELECT assignment_id FROM subtasks WHERE id=$id AND deleted_at IS NULL", id, "Subtask");
            if (actualParent != value.AssignmentId) throw new OrganizationRepositoryException("A subtask cannot move between tasks.");
            var now = SchemaV3Contract.CanonicalUtcNow(); var storageStatus = TaskStatuses.ToDatabaseStatus(value.Status);
            using var command = Command(connection, transaction,
                "UPDATE subtasks SET title=$title,status=$status,sort_order=$order," +
                "completed_at=CASE WHEN $status='completed' THEN COALESCE(completed_at,$completed) ELSE NULL END," +
                "updated_at=$now WHERE id=$id AND deleted_at IS NULL");
            Add(command, "$title", value.Title); Add(command, "$status", storageStatus); Add(command, "$order", value.SortOrder);
            Add(command, "$completed", storageStatus == "completed" ? now : null); Add(command, "$now", now); Add(command, "$id", id);
            EnsureOne(command.ExecuteNonQuery(), "Subtask", id);
            TaskStatePersistence.RecalculateParent(connection, transaction, value.AssignmentId, now, resetWhenEmpty: false);
            return 0;
        });
        return GetSubtask(id);
    }

    public void DeleteSubtask(long id)
    {
        Write((connection, transaction) =>
        {
            var parent = ScalarLong(connection, transaction, "SELECT assignment_id FROM subtasks WHERE id=$id AND deleted_at IS NULL", id, "Subtask");
            var now = SchemaV3Contract.CanonicalUtcNow(); SoftDeleteRow(connection, transaction, "subtasks", "Subtask", id, now);
            TaskStatePersistence.RecalculateParent(connection, transaction, parent, now, resetWhenEmpty: true);
            return 0;
        });
    }

    public SubtaskItem RestoreSubtask(long id)
    {
        Write((connection, transaction) =>
        {
            var parent = ScalarLong(connection, transaction, "SELECT assignment_id FROM subtasks WHERE id=$id AND deleted_at IS NOT NULL", id, "Subtask");
            RequireActiveAssignment(connection, transaction, parent); RestoreRow(connection, transaction, "subtasks", "Subtask", id);
            TaskStatePersistence.RecalculateParent(connection, transaction, parent, SchemaV3Contract.CanonicalUtcNow(), resetWhenEmpty: false);
            return 0;
        });
        return GetSubtask(id);
    }

    public IReadOnlyList<AttachmentMetadataItem> FetchAttachments(long assignmentId, bool includeDeleted = false)
    {
        using var connection = Open(); using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT id,uuid,assignment_id,file_name,relative_path,mime_type,byte_size,sha256,created_at,updated_at,deleted_at FROM attachments " +
            "WHERE assignment_id=$assignment " + (includeDeleted ? "" : "AND deleted_at IS NULL ") + "ORDER BY id";
        Add(command, "$assignment", assignmentId); using var reader = command.ExecuteReader();
        var result = new List<AttachmentMetadataItem>(); while (reader.Read()) result.Add(ReadAttachment(reader)); return result;
    }

    public IReadOnlyList<AttachmentMetadataItem> FetchAllAttachments(bool includeDeleted = false)
    {
        using var connection = Open(); using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT id,uuid,assignment_id,file_name,relative_path,mime_type,byte_size,sha256,created_at,updated_at,deleted_at FROM attachments " +
            (includeDeleted ? "" : "WHERE deleted_at IS NULL ") + "ORDER BY id";
        using var reader = command.ExecuteReader();
        var result = new List<AttachmentMetadataItem>(); while (reader.Read()) result.Add(ReadAttachment(reader)); return result;
    }

    public AttachmentMetadataItem CreateAttachment(AttachmentMetadataDraft draft)
    {
        var value = ValidateAttachment(draft); var uuid = value.Uuid ?? SchemaV3Contract.NewUuid();
        var id = Write((connection, transaction) =>
        {
            RequireActiveAssignment(connection, transaction, value.AssignmentId); var now = SchemaV3Contract.CanonicalUtcNow();
            using var command = Command(connection, transaction,
                "INSERT INTO attachments(uuid,assignment_id,file_name,relative_path,mime_type,byte_size,sha256,created_at,updated_at) " +
                "VALUES($uuid,$assignment,$file,$path,$mime,$size,$sha,$now,$now); SELECT last_insert_rowid();");
            Add(command, "$uuid", uuid); Add(command, "$assignment", value.AssignmentId); Add(command, "$file", value.FileName);
            Add(command, "$path", SchemaV3Contract.AttachmentRelativePath(uuid)); Add(command, "$mime", value.MimeType);
            Add(command, "$size", value.ByteSize); Add(command, "$sha", value.Sha256); Add(command, "$now", now);
            return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
        });
        return GetAttachment(id);
    }

    public AttachmentMetadataItem UpdateAttachment(long id, AttachmentMetadataDraft draft)
    {
        var value = ValidateAttachment(draft);
        Write((connection, transaction) =>
        {
            RequireActiveAssignment(connection, transaction, value.AssignmentId);
            var parent = ScalarLong(connection, transaction, "SELECT assignment_id FROM attachments WHERE id=$id AND deleted_at IS NULL", id, "Attachment");
            if (parent != value.AssignmentId) throw new OrganizationRepositoryException("Attachment metadata cannot move between tasks.");
            using var command = Command(connection, transaction,
                "UPDATE attachments SET file_name=$file,mime_type=$mime,byte_size=$size,sha256=$sha,updated_at=$now WHERE id=$id AND deleted_at IS NULL");
            Add(command, "$file", value.FileName); Add(command, "$mime", value.MimeType); Add(command, "$size", value.ByteSize);
            Add(command, "$sha", value.Sha256); Add(command, "$now", SchemaV3Contract.CanonicalUtcNow()); Add(command, "$id", id);
            EnsureOne(command.ExecuteNonQuery(), "Attachment", id); return 0;
        });
        return GetAttachment(id);
    }

    public void DeleteAttachment(long id) => SoftDelete("attachments", "Attachment", id);
    public AttachmentMetadataItem RestoreAttachment(long id)
    {
        Write((connection, transaction) =>
        {
            var parent = ScalarLong(connection, transaction, "SELECT assignment_id FROM attachments WHERE id=$id AND deleted_at IS NOT NULL", id, "Attachment");
            RequireActiveAssignment(connection, transaction, parent); RestoreRow(connection, transaction, "attachments", "Attachment", id); return 0;
        });
        return GetAttachment(id);
    }

    public IReadOnlyList<ReminderItem> FetchReminders(long assignmentId, bool includeDeleted = false)
    {
        using var connection = Open(); using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT id,uuid,assignment_id,trigger_at_utc,lead_minutes,repeat_rule,is_enabled,last_scheduled_at,created_at,updated_at,deleted_at FROM reminders " +
            "WHERE assignment_id=$assignment " + (includeDeleted ? "" : "AND deleted_at IS NULL ") + "ORDER BY trigger_at_utc,id";
        Add(command, "$assignment", assignmentId); using var reader = command.ExecuteReader();
        var result = new List<ReminderItem>(); while (reader.Read()) result.Add(ReadReminder(reader)); return result;
    }

    public ReminderItem CreateReminder(ReminderDraft draft)
    {
        var value = ValidateReminder(draft);
        var id = Write((connection, transaction) =>
        {
            RequireActiveAssignment(connection, transaction, value.AssignmentId); var now = SchemaV3Contract.CanonicalUtcNow();
            using var command = Command(connection, transaction,
                "INSERT INTO reminders(uuid,assignment_id,trigger_at_utc,lead_minutes,repeat_rule,is_enabled,last_scheduled_at,created_at,updated_at) " +
                "VALUES($uuid,$assignment,$trigger,$lead,$rule,$enabled,$scheduled,$now,$now); SELECT last_insert_rowid();");
            Add(command, "$uuid", SchemaV3Contract.NewUuid()); Add(command, "$assignment", value.AssignmentId);
            Add(command, "$trigger", Utc(value.TriggerAtUtc)); Add(command, "$lead", value.LeadMinutes); Add(command, "$rule", value.RepeatRule);
            Add(command, "$enabled", value.IsEnabled ? 1 : 0); Add(command, "$scheduled", value.LastScheduledAt is null ? null : Utc(value.LastScheduledAt.Value)); Add(command, "$now", now);
            return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
        });
        return GetReminder(id);
    }

    public ReminderItem UpdateReminder(long id, ReminderDraft draft)
    {
        var value = ValidateReminder(draft);
        Write((connection, transaction) =>
        {
            RequireActiveAssignment(connection, transaction, value.AssignmentId);
            var parent = ScalarLong(connection, transaction, "SELECT assignment_id FROM reminders WHERE id=$id AND deleted_at IS NULL", id, "Reminder");
            if (parent != value.AssignmentId) throw new OrganizationRepositoryException("Reminder cannot move between tasks.");
            using var command = Command(connection, transaction,
                "UPDATE reminders SET trigger_at_utc=$trigger,lead_minutes=$lead,repeat_rule=$rule,is_enabled=$enabled,last_scheduled_at=$scheduled,updated_at=$now WHERE id=$id AND deleted_at IS NULL");
            Add(command, "$trigger", Utc(value.TriggerAtUtc)); Add(command, "$lead", value.LeadMinutes); Add(command, "$rule", value.RepeatRule);
            Add(command, "$enabled", value.IsEnabled ? 1 : 0); Add(command, "$scheduled", value.LastScheduledAt is null ? null : Utc(value.LastScheduledAt.Value));
            Add(command, "$now", SchemaV3Contract.CanonicalUtcNow()); Add(command, "$id", id); EnsureOne(command.ExecuteNonQuery(), "Reminder", id); return 0;
        });
        return GetReminder(id);
    }

    public void DeleteReminder(long id)
    {
        Write((connection, transaction) =>
        {
            var now = SchemaV3Contract.CanonicalUtcNow(); using var command = Command(connection, transaction,
                "UPDATE reminders SET is_enabled=0,deleted_at=$now,updated_at=$now WHERE id=$id AND deleted_at IS NULL");
            Add(command, "$now", now); Add(command, "$id", id); EnsureOne(command.ExecuteNonQuery(), "Reminder", id); return 0;
        });
    }

    public ReminderItem RestoreReminder(long id)
    {
        Write((connection, transaction) =>
        {
            var parent = ScalarLong(connection, transaction, "SELECT assignment_id FROM reminders WHERE id=$id AND deleted_at IS NOT NULL", id, "Reminder");
            RequireActiveAssignment(connection, transaction, parent); RestoreRow(connection, transaction, "reminders", "Reminder", id); return 0;
        });
        return GetReminder(id);
    }

    private CourseItem GetCourse(long id) => Single("courses", id, ReadCourse,
        "SELECT id,uuid,name,normalized_name,color_hex,teacher,semester,is_archived,created_at,updated_at,deleted_at FROM courses WHERE id=$id AND deleted_at IS NULL", "Course");
    private ProjectItem GetProject(long id) => Single("projects", id, ReadProject,
        "SELECT id,uuid,course_id,name,description,status,created_at,updated_at,deleted_at FROM projects WHERE id=$id AND deleted_at IS NULL", "Project");
    private TagItem GetTag(long id) => Single("tags", id, ReadTag,
        "SELECT id,uuid,name,normalized_name,color_hex,created_at,updated_at,deleted_at FROM tags WHERE id=$id AND deleted_at IS NULL", "Tag");
    private TaskTagItem GetTaskTag(long id) => Single("task_tags", id, ReadTaskTag,
        "SELECT id,uuid,assignment_id,tag_id,created_at,updated_at,deleted_at FROM task_tags WHERE id=$id AND deleted_at IS NULL", "Task tag");
    private SubtaskItem GetSubtask(long id) => Single("subtasks", id, ReadSubtask,
        "SELECT id,uuid,assignment_id,title,status,sort_order,completed_at,created_at,updated_at,deleted_at FROM subtasks WHERE id=$id AND deleted_at IS NULL", "Subtask");
    private AttachmentMetadataItem GetAttachment(long id) => Single("attachments", id, ReadAttachment,
        "SELECT id,uuid,assignment_id,file_name,relative_path,mime_type,byte_size,sha256,created_at,updated_at,deleted_at FROM attachments WHERE id=$id AND deleted_at IS NULL", "Attachment");
    private ReminderItem GetReminder(long id) => Single("reminders", id, ReadReminder,
        "SELECT id,uuid,assignment_id,trigger_at_utc,lead_minutes,repeat_rule,is_enabled,last_scheduled_at,created_at,updated_at,deleted_at FROM reminders WHERE id=$id AND deleted_at IS NULL", "Reminder");

    private T Single<T>(string table, long id, Func<SqliteDataReader, T> mapper, string sql, string entity)
    {
        using var connection = Open(); using var command = connection.CreateCommand(); command.CommandText = sql; Add(command, "$id", id);
        using var reader = command.ExecuteReader(); return reader.Read() ? mapper(reader) : throw new KeyNotFoundException($"{entity} {id} was not found.");
    }

    private void SoftDelete(string table, string entity, long id) => Write((connection, transaction) =>
    {
        SoftDeleteRow(connection, transaction, table, entity, id, SchemaV3Contract.CanonicalUtcNow()); return 0;
    });
    private void Restore(string table, string entity, long id) => Write((connection, transaction) =>
    {
        RestoreRow(connection, transaction, table, entity, id); return 0;
    });

    private static void SoftDeleteRow(SqliteConnection connection, SqliteTransaction transaction, string table, string entity, long id, string now)
    {
        using var command = Command(connection, transaction, $"UPDATE {Quote(table)} SET deleted_at=$now,updated_at=$now WHERE id=$id AND deleted_at IS NULL");
        Add(command, "$now", now); Add(command, "$id", id); EnsureOne(command.ExecuteNonQuery(), entity, id);
    }
    private static void RestoreRow(SqliteConnection connection, SqliteTransaction transaction, string table, string entity, long id)
    {
        using var command = Command(connection, transaction, $"UPDATE {Quote(table)} SET deleted_at=NULL,updated_at=$now WHERE id=$id AND deleted_at IS NOT NULL");
        Add(command, "$now", SchemaV3Contract.CanonicalUtcNow()); Add(command, "$id", id); EnsureOne(command.ExecuteNonQuery(), entity, id);
    }

    private long Write(Func<SqliteConnection, SqliteTransaction, long> body)
    {
        using var migrationGate = DatabaseMigrationLock.Acquire(DatabasePath);
        using var connection = Open(); using var transaction = connection.BeginTransaction(deferred: false);
        try { var result = body(connection, transaction); transaction.Commit(); return result; }
        catch { try { transaction.Rollback(); } catch { } throw; }
    }

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection(_connectionString); connection.Open();
        using var command = connection.CreateCommand(); command.CommandText = "PRAGMA busy_timeout=10000; PRAGMA foreign_keys=ON;"; command.ExecuteNonQuery();
        return connection;
    }

    private static SqliteCommand Command(SqliteConnection connection, SqliteTransaction transaction, string sql)
    {
        var command = connection.CreateCommand(); command.Transaction = transaction; command.CommandText = sql; return command;
    }
    private static void Add(SqliteCommand command, string name, object? value) => command.Parameters.AddWithValue(name, value ?? DBNull.Value);
    private static void EnsureOne(int count, string entity, long id)
    { if (count != 1) throw new KeyNotFoundException($"{entity} {id} was not found."); }
    private static string Quote(string value) => '"' + value.Replace("\"", "\"\"") + '"';

    private static void RequireActiveAssignment(SqliteConnection connection, SqliteTransaction transaction, long id) => RequireActiveRow(connection, transaction, "assignments", "Assignment", id);
    private static void RequireActiveCourse(SqliteConnection connection, SqliteTransaction transaction, long? id)
    { if (id is not null) RequireActiveRow(connection, transaction, "courses", "Course", id.Value); }
    private static void RequireActiveRow(SqliteConnection connection, SqliteTransaction transaction, string table, string entity, long id)
    {
        using var command = Command(connection, transaction, $"SELECT 1 FROM {Quote(table)} WHERE id=$id AND deleted_at IS NULL LIMIT 1"); Add(command, "$id", id);
        if (command.ExecuteScalar() is null) throw new OrganizationRepositoryException($"{entity} must exist and be active.");
    }

    private static long ScalarLong(SqliteConnection connection, SqliteTransaction transaction, string sql, long id, string entity)
    {
        using var command = Command(connection, transaction, sql); Add(command, "$id", id); var result = command.ExecuteScalar();
        return result is null ? throw new KeyNotFoundException($"{entity} {id} was not found.") : Convert.ToInt64(result, CultureInfo.InvariantCulture);
    }
    private static long? ScalarNullableLong(SqliteConnection connection, SqliteTransaction transaction, string sql, long id, string entity)
    {
        using var command = Command(connection, transaction, sql); Add(command, "$id", id);
        using var reader = command.ExecuteReader(); if (!reader.Read()) throw new KeyNotFoundException($"{entity} {id} was not found."); return reader.IsDBNull(0) ? null : reader.GetInt64(0);
    }

    private static CourseDraft ValidateCourse(CourseDraft draft) => draft with
    {
        Name = Required(draft.Name, 120, "Course name"),
        ColorHex = Color(draft.ColorHex),
        Teacher = Optional(draft.Teacher),
        Semester = Optional(draft.Semester)
    };
    private static ProjectDraft ValidateProjectDraft(ProjectDraft draft) => draft with
    { Name = Required(draft.Name, 255, "Project name"), Description = Optional(draft.Description), Status = ProjectStatuses.Normalize(draft.Status) };
    private static TagDraft ValidateTag(TagDraft draft) => draft with
    { Name = Required(draft.Name, 80, "Tag name"), ColorHex = Color(draft.ColorHex) };
    private static SubtaskDraft ValidateSubtask(SubtaskDraft draft)
    {
        if (draft.AssignmentId < 1 || draft.SortOrder < 0) throw new ArgumentException("Subtask assignment and sort order are invalid.");
        return draft with { Title = Required(draft.Title, 255, "Subtask title"), Status = TaskStatuses.Normalize(draft.Status) };
    }
    private static AttachmentMetadataDraft ValidateAttachment(AttachmentMetadataDraft draft)
    {
        var file = draft.FileName; var fileLength = file.EnumerateRunes().Count(); if (draft.AssignmentId < 1 || draft.ByteSize < 0 || fileLength is < 1 or > 255 || file is "." or ".." || file.IndexOfAny(['\0', '/', '\\']) >= 0)
            throw new ArgumentException("Attachment metadata is invalid.");
        var digest = draft.Sha256.Trim(); if (!ShaRegex().IsMatch(digest)) throw new ArgumentException("SHA-256 must be lowercase hexadecimal.");
        if (draft.Uuid is not null) _ = SchemaV3Contract.AttachmentRelativePath(draft.Uuid);
        return draft with { MimeType = Optional(draft.MimeType), Sha256 = digest };
    }
    private static ReminderDraft ValidateReminder(ReminderDraft draft)
    {
        if (draft.AssignmentId < 1 || draft.LeadMinutes < 0)
            throw new ArgumentException("Reminder metadata is invalid.");
        var repeatRule = SchemaV3Contract.CanonicalRepeatRule(draft.RepeatRule);
        return draft with
        {
            TriggerAtUtc = draft.TriggerAtUtc.ToUniversalTime(),
            LastScheduledAt = draft.LastScheduledAt?.ToUniversalTime(),
            RepeatRule = repeatRule
        };
    }
    private static string Required(string value, int maximum, string name)
    { var result = value.Trim(); var length = result.EnumerateRunes().Count(); return length is >= 1 && length <= maximum ? result : throw new ArgumentException($"{name} must contain 1 to {maximum} characters."); }
    private static string? Optional(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    private static string? Color(string? value)
    { var result = Optional(value); return result is null || ColorRegex().IsMatch(result) ? result : throw new ArgumentException("Color must use #RRGGBB syntax."); }
    private static string Utc(DateTimeOffset value) => value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
    private static DateTimeOffset Date(SqliteDataReader reader, int index) => DateTimeOffset.Parse(reader.GetString(index), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
    private static DateTimeOffset? OptionalDate(SqliteDataReader reader, int index) => reader.IsDBNull(index) ? null : Date(reader, index);

    private static CourseItem ReadCourse(SqliteDataReader r) => new(r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetString(3), r.IsDBNull(4) ? null : r.GetString(4), r.IsDBNull(5) ? null : r.GetString(5), r.IsDBNull(6) ? null : r.GetString(6), r.GetInt32(7) == 1, Date(r, 8), Date(r, 9), OptionalDate(r, 10));
    private static ProjectItem ReadProject(SqliteDataReader r) => new(r.GetInt64(0), r.GetString(1), r.IsDBNull(2) ? null : r.GetInt64(2), r.GetString(3), r.IsDBNull(4) ? null : r.GetString(4), r.GetString(5), Date(r, 6), Date(r, 7), OptionalDate(r, 8));
    private static TagItem ReadTag(SqliteDataReader r) => new(r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetString(3), r.IsDBNull(4) ? null : r.GetString(4), Date(r, 5), Date(r, 6), OptionalDate(r, 7));
    private static TaskTagItem ReadTaskTag(SqliteDataReader r) => new(r.GetInt64(0), r.GetString(1), r.GetInt64(2), r.GetInt64(3), Date(r, 4), Date(r, 5), OptionalDate(r, 6));
    private static SubtaskItem ReadSubtask(SqliteDataReader r) => new(r.GetInt64(0), r.GetString(1), r.GetInt64(2), r.GetString(3), TaskStatuses.FromDatabaseStatus(r.GetString(4)), r.GetInt32(5), OptionalDate(r, 6), Date(r, 7), Date(r, 8), OptionalDate(r, 9));
    private static AttachmentMetadataItem ReadAttachment(SqliteDataReader r) => new(r.GetInt64(0), r.GetString(1), r.GetInt64(2), r.GetString(3), r.GetString(4), r.IsDBNull(5) ? null : r.GetString(5), r.GetInt64(6), r.GetString(7), Date(r, 8), Date(r, 9), OptionalDate(r, 10));
    private static ReminderItem ReadReminder(SqliteDataReader r) => new(r.GetInt64(0), r.GetString(1), r.GetInt64(2), Date(r, 3), r.GetInt32(4), r.IsDBNull(5) ? null : r.GetString(5), r.GetInt32(6) == 1, OptionalDate(r, 7), Date(r, 8), Date(r, 9), OptionalDate(r, 10));

    [GeneratedRegex("^#[0-9A-Fa-f]{6}$", RegexOptions.CultureInvariant)] private static partial Regex ColorRegex();
    [GeneratedRegex("^[0-9a-f]{64}$", RegexOptions.CultureInvariant)] private static partial Regex ShaRegex();
}
