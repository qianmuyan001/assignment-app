using System.Globalization;
using System.Text.RegularExpressions;

namespace AssignmentNative.Core;

public sealed record NaturalLanguageParseResult(
    IReadOnlyList<AssignmentCandidate> Candidates,
    IReadOnlyList<string> Warnings);

public sealed class NaturalLanguageScheduleParser
{
    private static readonly Regex SentenceBreak = new(
        @"[。！？\r\n；;]+",
        RegexOptions.Compiled);

    private static readonly Regex CommaBreak = new(
        @"[，,]",
        RegexOptions.Compiled);

    private static readonly Regex AbsoluteChineseDate = new(
        @"(?:(?<year>\d{4})\s*年\s*)?(?<month>\d{1,2})\s*月\s*(?<day>\d{1,2})\s*[日号]?",
        RegexOptions.Compiled);

    private static readonly Regex AbsoluteNumericDate = new(
        @"(?<![\d/-])(?:(?<year>\d{4})\s*[-/]\s*)?(?<month>\d{1,2})\s*[-/]\s*(?<day>\d{1,2})(?![\d/-])",
        RegexOptions.Compiled);

    private static readonly Regex ClockTime = new(
        @"(?<![\d:])(?<hour>\d{1,2})\s*[:：]\s*(?<minute>\d{2})(?![\d:])",
        RegexOptions.Compiled);

    private static readonly Regex SpokenTime = new(
        @"(?<period>凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|夜里|深夜)?\s*" +
        @"(?<hour>\d{1,2}|[零一二两三四五六七八九十]{1,3})\s*[点時时]" +
        @"\s*(?<fraction>半|整|一刻|二刻|两刻|三刻|(?<minute>\d{1,2})\s*分?)?",
        RegexOptions.Compiled);

    private static readonly Regex Url = new(
        @"https?://\S+|www\.\S+",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static readonly IReadOnlyDictionary<string, string> CourseAliases =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["高数"] = "高等数学",
            ["数分"] = "数学分析",
            ["线代"] = "线性代数",
            ["大物"] = "大学物理",
            ["物理"] = "大学物理",
            ["计组"] = "计算机组成原理",
            ["操统"] = "操作系统",
            ["OS"] = "操作系统",
            ["离散"] = "离散数学",
            ["概率"] = "概率论与数理统计",
            ["英语"] = "英语",
            ["数据结构"] = "数据结构",
            ["算法"] = "算法设计与分析",
            ["计网"] = "计算机网络",
            ["数据库"] = "数据库系统",
            ["软工"] = "软件工程",
            ["机器学习"] = "机器学习",
            ["深度学习"] = "深度学习"
        };

    private static readonly string[] IndependentActions =
    [
        "记得", "准备", "去", "做", "写", "完成", "复习", "买", "预约",
        "参加", "开", "讨论", "交", "提交", "看", "读", "整理", "发",
        "回复", "确认", "学习", "练", "检查"
    ];

    private static readonly string[] LeadingWords =
    [
        "记得", "别忘了", "别忘", "务必", "一定", "需要", "请", "帮我",
        "抽空", "顺便", "然后", "之后", "最好", "要", "去", "把",
        "完成", "做完", "写好", "准备", "复习", "预习", "讨论", "参加",
        "提交", "交", "写", "做", "开", "买", "看", "读", "整理", "发"
    ];

    private static readonly string[] TaskSignals =
    [
        "作业", "任务", "交", "提交", "完成", "做", "写", "复习", "考试",
        "测验", "开会", "讨论", "准备", "提醒", "截止", "报告", "论文",
        "项目", "预习", "练", "背", "读", "买", "预约", "参加", "实验", "会"
    ];

    public NaturalLanguageParseResult Parse(string text, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return new NaturalLanguageParseResult([], []);
        }

        var candidates = SplitSegments(text)
            .Select(segment => ParseSegment(segment, now))
            .Where(candidate => candidate is not null)
            .Cast<AssignmentCandidate>()
            .Take(200)
            .ToList();

        var warnings = candidates.Count == 0
            ? new[] { "未能从文本中识别出任何任务，请检查输入或手动添加" }
            : [];
        return new NaturalLanguageParseResult(candidates, warnings);
    }

    private static AssignmentCandidate? ParseSegment(string segment, DateTimeOffset now)
    {
        segment = segment.Trim();
        if (segment.Length < 2 || !LooksLikeTask(segment))
        {
            return null;
        }

        var warnings = new List<string>();
        var removable = new List<string>();
        var date = ResolveDate(segment, now.Date, warnings, removable);
        var time = ResolveTime(segment, removable);

        string? dueDate = null;
        string? dueTime = null;
        if (date is not null)
        {
            dueDate = date.Value.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            dueTime = time?.ToString("HH:mm", CultureInfo.InvariantCulture) ?? "23:59";
            if (time is null)
            {
                warnings.Add("未指定具体时间，截止时间默认为当天 23:59，请确认");
            }
        }
        else if (time is not null)
        {
            dueDate = now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            dueTime = time.Value.ToString("HH:mm", CultureInfo.InvariantCulture);
            warnings.Add("未指定日期，已按今天解释该时间，请确认");
        }
        else
        {
            warnings.Add("未识别到截止时间，导入后请在编辑器中补充");
        }

        var priority = ExtractPriority(segment, removable);
        var course = ExtractCourse(segment);
        if (course is null && Regex.IsMatch(segment, @"作业|实验|考试|测验|论文|大作业"))
        {
            warnings.Add("未识别到课程，导入后请在编辑器中补充");
        }

        var url = Url.Match(segment);
        if (url.Success)
        {
            removable.Add(url.Value);
        }

        var title = BuildTitle(segment, removable, date is not null || time is not null);
        if (string.IsNullOrWhiteSpace(title))
        {
            title = CleanTitle(Url.Replace(segment, " "));
            warnings.Add("未能生成明确标题，已使用清理后的原文，请确认");
        }

        return new AssignmentCandidate
        {
            Title = title,
            CourseName = course,
            DueDate = dueDate,
            DueTime = dueTime,
            Description = segment,
            Priority = priority,
            SourceUrl = url.Success ? url.Value.TrimEnd('。', '，', ',', ';', '；') : null,
            SourceSnippet = segment,
            Confidence = warnings.Count switch
            {
                0 or 1 => "high",
                2 => "medium",
                _ => "low"
            },
            Warnings = warnings
        };
    }

    private static IReadOnlyList<string> SplitSegments(string text)
    {
        var segments = new List<string>();
        foreach (var sentence in SentenceBreak.Split(text.Trim()))
        {
            var part = sentence.Trim();
            if (part.Length == 0)
            {
                continue;
            }

            var commaParts = CommaBreak.Split(part);
            var buffer = commaParts[0];
            foreach (var next in commaParts.Skip(1))
            {
                var trimmed = next.Trim();
                if (StartsIndependentAction(trimmed))
                {
                    AddSegment(segments, buffer);
                    buffer = trimmed;
                }
                else
                {
                    buffer += "，" + next;
                }
            }
            AddSegment(segments, buffer);
        }
        return segments;
    }

    private static void AddSegment(List<string> segments, string value)
    {
        value = value.Trim();
        if (value.Length > 0)
        {
            segments.Add(value);
        }
    }

    private static bool StartsIndependentAction(string text) =>
        IndependentActions.Any(action => text.StartsWith(action, StringComparison.Ordinal));

    private static bool LooksLikeTask(string text) =>
        Regex.IsMatch(text, @"[\p{L}]") &&
        (TaskSignals.Any(signal => text.Contains(signal, StringComparison.OrdinalIgnoreCase)) ||
         AbsoluteChineseDate.IsMatch(text) ||
         AbsoluteNumericDate.IsMatch(text) ||
         Regex.IsMatch(text, @"今天|明天|后天|周[一二三四五六日天]|星期[一二三四五六日天]"));

    private static DateOnly? ResolveDate(
        string text,
        DateTimeOffset now,
        List<string> warnings,
        List<string> removable)
    {
        foreach (var regex in new[] { AbsoluteChineseDate, AbsoluteNumericDate })
        {
            var match = regex.Match(text);
            if (!match.Success)
            {
                continue;
            }
            var year = match.Groups["year"].Success
                ? int.Parse(match.Groups["year"].Value, CultureInfo.InvariantCulture)
                : now.Year;
            var month = int.Parse(match.Groups["month"].Value, CultureInfo.InvariantCulture);
            var day = int.Parse(match.Groups["day"].Value, CultureInfo.InvariantCulture);
            if (!DateOnly.TryParseExact(
                    $"{year:D4}-{month:D2}-{day:D2}",
                    "yyyy-MM-dd",
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.None,
                    out var parsed))
            {
                warnings.Add($"无法识别的日期：{match.Value}");
                removable.Add(match.Value);
                return null;
            }
            if (!match.Groups["year"].Success && parsed < DateOnly.FromDateTime(now.DateTime))
            {
                parsed = parsed.AddYears(1);
                warnings.Add("日期早于今天，已按明年解释，请确认");
            }
            removable.Add(match.Value);
            return parsed;
        }

        foreach (var item in new[]
        {
            (Word: "大后天", Days: 3),
            (Word: "后天", Days: 2),
            (Word: "明天", Days: 1),
            (Word: "明日", Days: 1),
            (Word: "今天", Days: 0),
            (Word: "今日", Days: 0),
            (Word: "昨天", Days: -1)
        })
        {
            if (!text.Contains(item.Word, StringComparison.Ordinal))
            {
                continue;
            }
            removable.Add(item.Word);
            if (item.Days < 0)
            {
                warnings.Add($"日期「{item.Word}」已在过去，请确认");
            }
            return DateOnly.FromDateTime(now.DateTime).AddDays(item.Days);
        }

        var weekday = Regex.Match(
            text,
            @"(?<prefix>下下|下一|下|本|这|这个)?\s*(?:周|星期|礼拜)(?<day>[一二三四五六日天1-7])");
        if (weekday.Success)
        {
            var targetDay = WeekdayNumber(weekday.Groups["day"].Value);
            var current = ((int)now.DayOfWeek + 6) % 7;
            var daysAhead = (targetDay - current + 7) % 7;
            var prefix = weekday.Groups["prefix"].Value;
            if (prefix is "下" or "下一")
            {
                daysAhead += 7;
            }
            else if (prefix == "下下")
            {
                daysAhead += 14;
            }
            removable.Add(weekday.Value);
            return DateOnly.FromDateTime(now.DateTime).AddDays(daysAhead);
        }

        var weekend = Regex.Match(text, "周末");
        if (weekend.Success)
        {
            var current = ((int)now.DayOfWeek + 6) % 7;
            removable.Add(weekend.Value);
            return DateOnly.FromDateTime(now.DateTime).AddDays((5 - current + 7) % 7);
        }

        var nextMonthWeek = Regex.Match(text, @"下\s*个?\s*月\s*第一?\s*周");
        if (nextMonthWeek.Success)
        {
            var first = new DateOnly(now.Year, now.Month, 1).AddMonths(1);
            var current = ((int)first.DayOfWeek + 6) % 7;
            removable.Add(nextMonthWeek.Value);
            return first.AddDays((7 - current) % 7);
        }

        var nextMonth = Regex.Match(text, @"下\s*个?\s*月");
        if (nextMonth.Success)
        {
            removable.Add(nextMonth.Value);
            return new DateOnly(now.Year, now.Month, 1).AddMonths(1);
        }

        var monthEnd = Regex.Match(text, @"(?:本|这个|这)?\s*月[底末]");
        if (monthEnd.Success)
        {
            removable.Add(monthEnd.Value);
            var first = new DateOnly(now.Year, now.Month, 1);
            return first.AddMonths(1).AddDays(-1);
        }

        return null;
    }

    private static TimeOnly? ResolveTime(string text, List<string> removable)
    {
        var clock = ClockTime.Match(text);
        if (clock.Success &&
            int.TryParse(clock.Groups["hour"].Value, out var hour) &&
            int.TryParse(clock.Groups["minute"].Value, out var minute) &&
            hour is >= 0 and <= 23 && minute is >= 0 and <= 59)
        {
            removable.Add(clock.Value);
            return new TimeOnly(hour, minute);
        }

        var spoken = SpokenTime.Match(text);
        if (!spoken.Success || !TrySpokenNumber(spoken.Groups["hour"].Value, out hour))
        {
            return null;
        }
        var period = spoken.Groups["period"].Value;
        hour = To24Hour(period, hour);
        if (hour is < 0 or > 23)
        {
            return null;
        }
        minute = spoken.Groups["fraction"].Value switch
        {
            "半" or "二刻" or "两刻" => 30,
            "一刻" => 15,
            "三刻" => 45,
            _ when spoken.Groups["minute"].Success &&
                int.TryParse(spoken.Groups["minute"].Value, out var parsed) => parsed,
            _ => 0
        };
        if (minute is < 0 or > 59)
        {
            return null;
        }
        removable.Add(spoken.Value);
        return new TimeOnly(hour, minute);
    }

    private static int To24Hour(string period, int hour) => period switch
    {
        "凌晨" or "早上" or "早晨" or "上午" => hour % 12,
        "中午" => hour == 12 ? 12 : hour + 12,
        "下午" or "傍晚" => hour == 12 ? 12 : hour + 12,
        "晚上" or "夜里" or "深夜" => hour == 12 ? 0 : hour + 12,
        _ => hour
    };

    private static bool TrySpokenNumber(string value, out int number)
    {
        if (int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out number))
        {
            return true;
        }
        var digits = new Dictionary<char, int>
        {
            ['零'] = 0, ['一'] = 1, ['二'] = 2, ['两'] = 2, ['三'] = 3,
            ['四'] = 4, ['五'] = 5, ['六'] = 6, ['七'] = 7, ['八'] = 8,
            ['九'] = 9
        };
        if (value == "十")
        {
            number = 10;
            return true;
        }
        var ten = value.IndexOf('十');
        if (ten >= 0)
        {
            var tens = ten == 0 ? 1 : digits.GetValueOrDefault(value[0]);
            var ones = ten == value.Length - 1 ? 0 : digits.GetValueOrDefault(value[^1]);
            number = tens * 10 + ones;
            return true;
        }
        if (value.Length == 1 && digits.TryGetValue(value[0], out number))
        {
            return true;
        }
        number = 0;
        return false;
    }

    private static int WeekdayNumber(string value) => value switch
    {
        "一" or "1" => 0,
        "二" or "2" => 1,
        "三" or "3" => 2,
        "四" or "4" => 3,
        "五" or "5" => 4,
        "六" or "6" => 5,
        _ => 6
    };

    private static string? ExtractPriority(string text, List<string> removable)
    {
        foreach (var word in new[] { "紧急", "特急", "重要", "优先", "尽快", "urgent", "asap" })
        {
            if (text.Contains(word, StringComparison.OrdinalIgnoreCase))
            {
                removable.Add(word);
                return TaskPriorities.High;
            }
        }
        foreach (var word in new[] { "不急", "低优先", "不太重要", "有空再" })
        {
            if (text.Contains(word, StringComparison.OrdinalIgnoreCase))
            {
                removable.Add(word);
                return TaskPriorities.Low;
            }
        }
        return null;
    }

    private static string? ExtractCourse(string text)
    {
        foreach (var pair in CourseAliases.OrderByDescending(pair => pair.Key.Length))
        {
            if (text.Contains(pair.Key, StringComparison.OrdinalIgnoreCase))
            {
                return pair.Value;
            }
        }
        return null;
    }

    private static string BuildTitle(
        string segment,
        IEnumerable<string> removable,
        bool hasDeadline)
    {
        var title = removable
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Aggregate(segment, (current, value) => ReplaceFirst(current, value, " "));
        if (hasDeadline)
        {
            title = Regex.Replace(
                title,
                @"(?:之前|前)?\s*(?:提交|交上去|交|完成|做完|写完)(?=\s*$|[，,])",
                " ");
        }
        title = title.Replace("没有明确截止时间", " ", StringComparison.Ordinal);
        var changed = true;
        while (changed)
        {
            changed = false;
            title = title.TrimStart();
            foreach (var word in LeadingWords.OrderByDescending(word => word.Length))
            {
                if (!title.StartsWith(word, StringComparison.Ordinal))
                {
                    continue;
                }
                title = title[word.Length..];
                changed = true;
                break;
            }
        }
        return CleanTitle(title);
    }

    private static string CleanTitle(string value) => Regex.Replace(
        value.Trim(' ', '，', ',', '。', '；', ';', '：', ':'),
        @"[，,。；;：:、\s]+",
        " ").Trim();

    private static string ReplaceFirst(string value, string oldValue, string newValue)
    {
        var index = value.IndexOf(oldValue, StringComparison.Ordinal);
        return index < 0
            ? value
            : string.Concat(value.AsSpan(0, index), newValue, value.AsSpan(index + oldValue.Length));
    }
}
