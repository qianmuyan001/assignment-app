using System.Globalization;
using Microsoft.Data.Sqlite;

namespace AssignmentNative.Core;

public sealed class TaskStateConflictException : InvalidOperationException
{
    public TaskStateConflictException(string message) : base(message) { }
}

internal sealed record PersistedTaskState(string Status, int Progress, string? CompletedAt);

internal static class TaskStatePersistence
{
    public static PersistedTaskState UpdateParent(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long assignmentId,
        string requestedDatabaseStatus,
        int? requestedProgress,
        string timestamp)
    {
        var subtasks = ReadActiveSubtasks(connection, transaction, assignmentId);
        if (subtasks.Count == 0)
        {
            var current = ReadParent(connection, transaction, assignmentId);
            return Independent(current, requestedDatabaseStatus, requestedProgress, timestamp);
        }

        var currentParent = ReadParent(connection, transaction, assignmentId);
        var derived = Derive(subtasks, timestamp, currentParent.CompletedAt);
        if (requestedDatabaseStatus != derived.Status)
        {
            ApplyStatusCommand(connection, transaction, subtasks, requestedDatabaseStatus, timestamp);
            subtasks = ReadActiveSubtasks(connection, transaction, assignmentId);
            derived = Derive(subtasks, timestamp, currentParent.CompletedAt);
        }
        if (requestedProgress is not null && requestedProgress != derived.Progress)
            throw new TaskStateConflictException("Task progress is derived from active subtasks.");
        if (requestedDatabaseStatus != derived.Status)
            throw new TaskStateConflictException("Task status conflicts with active subtasks.");
        return derived;
    }

    public static PersistedTaskState RecalculateParent(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long assignmentId,
        string timestamp,
        bool resetWhenEmpty)
    {
        var subtasks = ReadActiveSubtasks(connection, transaction, assignmentId);
        var state = subtasks.Count == 0
            ? (resetWhenEmpty ? new PersistedTaskState("not_started", 0, null) : ReadParent(connection, transaction, assignmentId))
            : Derive(subtasks, timestamp, ReadParent(connection, transaction, assignmentId).CompletedAt);
        WriteParent(connection, transaction, assignmentId, state, timestamp);
        return state;
    }

    public static void WriteParent(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long assignmentId,
        PersistedTaskState state,
        string timestamp)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "UPDATE assignments SET status=$status, progress_percent=$progress, " +
            "completed_at=$completed, updated_at=$updated WHERE id=$id AND deleted_at IS NULL";
        command.Parameters.AddWithValue("$status", state.Status);
        command.Parameters.AddWithValue("$progress", state.Progress);
        command.Parameters.AddWithValue("$completed", (object?)state.CompletedAt ?? DBNull.Value);
        command.Parameters.AddWithValue("$updated", timestamp);
        command.Parameters.AddWithValue("$id", assignmentId);
        if (command.ExecuteNonQuery() != 1)
            throw new KeyNotFoundException($"Assignment {assignmentId} was not found.");
    }

    private static PersistedTaskState Independent(
        PersistedTaskState current,
        string requested,
        int? progress,
        string timestamp)
    {
        if (progress is < 0 or > 100) throw new TaskStateConflictException("Progress must be 0 through 100.");
        if (requested == "completed" && progress is not null and not 100)
            throw new TaskStateConflictException("Done status requires progress 100.");
        if (requested == "not_started" && progress is not null and not 0)
            throw new TaskStateConflictException("Todo status requires progress 0.");
        if (requested == "in_progress" && progress == 100)
            throw new TaskStateConflictException("Progress 100 requires done status.");

        var finalStatus = requested;
        var finalProgress = progress ?? current.Progress;
        if (requested == "completed") finalProgress = 100;
        else if (requested == "not_started") finalProgress = 0;
        else if (current.Status == "completed" && progress is null) finalProgress = 0;
        if (finalStatus != "completed" && finalProgress >= 100)
            throw new TaskStateConflictException("Non-completed tasks must have progress below 100.");
        return new PersistedTaskState(
            finalStatus,
            finalProgress,
            finalStatus == "completed" ? current.CompletedAt ?? timestamp : null);
    }

    private static PersistedTaskState Derive(
        IReadOnlyList<SubtaskState> subtasks,
        string timestamp,
        string? existingCompletedAt)
    {
        var completed = subtasks.Count(item => item.Status == "completed");
        var progress = completed * 100 / subtasks.Count;
        var status = completed == subtasks.Count
            ? "completed"
            : completed > 0 || subtasks.Any(item => item.Status == "in_progress")
                ? "in_progress"
                : "not_started";
        return new PersistedTaskState(
            status,
            progress,
            status == "completed" ? existingCompletedAt ?? timestamp : null);
    }

    private static void ApplyStatusCommand(
        SqliteConnection connection,
        SqliteTransaction transaction,
        IReadOnlyList<SubtaskState> subtasks,
        string status,
        string timestamp)
    {
        if (status == "completed" || status == "not_started")
        {
            foreach (var subtask in subtasks) SetSubtask(connection, transaction, subtask.Id, status, timestamp);
            return;
        }
        if (status != "in_progress") throw new TaskStateConflictException("Unsupported task status.");
        if (subtasks.Any(item => item.Status == "in_progress")) return;
        var candidate = subtasks.FirstOrDefault(item => item.Status == "not_started") ?? subtasks[^1];
        SetSubtask(connection, transaction, candidate.Id, status, timestamp);
    }

    private static void SetSubtask(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long id,
        string status,
        string timestamp)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "UPDATE subtasks SET status=$status, " +
            "completed_at=CASE WHEN $status='completed' THEN COALESCE(completed_at,$completed) ELSE NULL END, " +
            "updated_at=$updated " +
            "WHERE id=$id AND deleted_at IS NULL";
        command.Parameters.AddWithValue("$status", status);
        command.Parameters.AddWithValue("$completed", status == "completed" ? timestamp : DBNull.Value);
        command.Parameters.AddWithValue("$updated", timestamp);
        command.Parameters.AddWithValue("$id", id);
        command.ExecuteNonQuery();
    }

    private static PersistedTaskState ReadParent(SqliteConnection connection, SqliteTransaction transaction, long id)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT status, progress_percent, completed_at FROM assignments WHERE id=$id AND deleted_at IS NULL";
        command.Parameters.AddWithValue("$id", id);
        using var reader = command.ExecuteReader();
        if (!reader.Read()) throw new KeyNotFoundException($"Assignment {id} was not found.");
        return new PersistedTaskState(reader.GetString(0), reader.GetInt32(1), reader.IsDBNull(2) ? null : reader.GetString(2));
    }

    private static List<SubtaskState> ReadActiveSubtasks(SqliteConnection connection, SqliteTransaction transaction, long id)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT id, status FROM subtasks WHERE assignment_id=$id AND deleted_at IS NULL ORDER BY sort_order,id";
        command.Parameters.AddWithValue("$id", id);
        using var reader = command.ExecuteReader();
        var result = new List<SubtaskState>();
        while (reader.Read()) result.Add(new SubtaskState(reader.GetInt64(0), reader.GetString(1)));
        return result;
    }

    private sealed record SubtaskState(long Id, string Status);
}
