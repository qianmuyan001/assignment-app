using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.Sqlite;

namespace AssignmentNative.Core;

internal static class DatabaseLogicalFingerprint
{
    public static string Compute(
        SqliteConnection connection,
        SqliteTransaction? transaction = null)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Append(hash, ReadScalar(connection, transaction, "PRAGMA user_version"));
        Append(hash, ReadScalar(connection, transaction, "PRAGMA application_id"));

        var objects = new List<(string Type, string Name, string Table, string? Sql)>();
        using (var command = connection.CreateCommand())
        {
            command.CommandText =
                "SELECT type, name, tbl_name, sql FROM sqlite_master " +
                "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name";
            command.Transaction = transaction;
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                objects.Add((
                    reader.GetString(0),
                    reader.GetString(1),
                    reader.GetString(2),
                    reader.IsDBNull(3) ? null : reader.GetString(3)));
            }
        }

        foreach (var item in objects)
        {
            Append(hash, item.Type);
            Append(hash, item.Name);
            Append(hash, item.Table);
            Append(hash, item.Sql);
        }

        var tables = objects
                     .Where(item => item.Type == "table")
                     .Select(item => item.Name)
                     .ToList();
        if (Exists(connection, transaction, "sqlite_sequence")) tables.Add("sqlite_sequence");
        foreach (var table in tables.Distinct(StringComparer.Ordinal).OrderBy(value => value, StringComparer.Ordinal))
        {
            Append(hash, table);
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = $"SELECT * FROM {QuoteIdentifier(table)} {OrderClause(connection, transaction, table)}";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                for (var index = 0; index < reader.FieldCount; index++)
                {
                    AppendValue(hash, reader.GetValue(index));
                }
                Append(hash, "<row>");
            }
        }

        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    private static string ReadScalar(
        SqliteConnection connection,
        SqliteTransaction? transaction,
        string sql)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        return Convert.ToString(command.ExecuteScalar(), CultureInfo.InvariantCulture) ?? "";
    }

    private static void AppendValue(IncrementalHash hash, object value)
    {
        switch (value)
        {
            case DBNull:
                Append(hash, "<null>");
                break;
            case byte[] bytes:
                Append(hash, "<blob>");
                hash.AppendData(bytes);
                Append(hash, bytes.Length.ToString(CultureInfo.InvariantCulture));
                break;
            case long integer:
                Append(hash, "<integer>" + integer.ToString(CultureInfo.InvariantCulture));
                break;
            case double real:
                Append(hash, "<real>" + real.ToString("R", CultureInfo.InvariantCulture));
                break;
            default:
                Append(hash, "<text>" + Convert.ToString(value, CultureInfo.InvariantCulture));
                break;
        }
    }

    private static void Append(IncrementalHash hash, string? value)
    {
        var bytes = Encoding.UTF8.GetBytes(value ?? "<null>");
        hash.AppendData(BitConverter.GetBytes(bytes.Length));
        hash.AppendData(bytes);
    }

    private static string QuoteIdentifier(string value) =>
        '"' + value.Replace("\"", "\"\"") + '"';

    private static string OrderClause(
        SqliteConnection connection,
        SqliteTransaction? transaction,
        string table)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = $"PRAGMA table_info({QuoteIdentifier(table)})";
        using var reader = command.ExecuteReader();
        var primaryKey = new List<(int Order, string Name)>();
        while (reader.Read())
        {
            var order = reader.GetInt32(5);
            if (order > 0) primaryKey.Add((order, reader.GetString(1)));
        }
        if (primaryKey.Count > 0)
            return "ORDER BY " + string.Join(',', primaryKey.OrderBy(item => item.Order).Select(item => QuoteIdentifier(item.Name)));
        return TableSql(connection, transaction, table).Contains("WITHOUT ROWID", StringComparison.OrdinalIgnoreCase)
            ? ""
            : "ORDER BY rowid";
    }

    private static bool Exists(
        SqliteConnection connection,
        SqliteTransaction? transaction,
        string table)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=$name";
        command.Parameters.AddWithValue("$name", table);
        return command.ExecuteScalar() is not null;
    }

    private static string TableSql(
        SqliteConnection connection,
        SqliteTransaction? transaction,
        string table)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT sql FROM sqlite_master WHERE type='table' AND name=$name";
        command.Parameters.AddWithValue("$name", table);
        return Convert.ToString(command.ExecuteScalar(), CultureInfo.InvariantCulture) ?? "";
    }
}
