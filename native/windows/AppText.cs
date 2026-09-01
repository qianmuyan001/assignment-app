using AssignmentNative.Core;
using Microsoft.Windows.ApplicationModel.Resources;
using System.Globalization;

namespace AssignmentNative;

internal static class AppText
{
    private static ResourceLoader? _loader;

    public static AppLanguage Language { get; private set; } = AppLanguage.English;

    public static string LanguageTag(AppLanguage language) => language switch
    {
        AppLanguage.SimplifiedChinese => "zh-CN",
        _ => "en-US"
    };

    public static void SetLanguage(AppLanguage language)
    {
        Language = language;
        var culture = CultureInfo.GetCultureInfo(LanguageTag(language));
        CultureInfo.CurrentCulture = culture;
        CultureInfo.CurrentUICulture = culture;
        CultureInfo.DefaultThreadCurrentCulture = culture;
        CultureInfo.DefaultThreadCurrentUICulture = culture;
        _loader = null;
    }

    public static string Get(string key)
    {
        var value = (_loader ??= new ResourceLoader()).GetString(key);
        return string.IsNullOrEmpty(value) ? key : value;
    }

    public static string Format(string key, params object?[] values) =>
        string.Format(System.Globalization.CultureInfo.CurrentCulture, Get(key), values);

    public static string FormatDue(AssignmentNative.Core.AssignmentItem item)
    {
        var due = TaskDueDisplayFormatter.DisplayValue(item);
        if (due is null)
        {
            return Get("NoDueDate");
        }

        var date = due.Value.ToString("ddd, MMM d", CultureInfo.CurrentCulture);
        return item.AllDay
            ? $"{date} · {Get("AllDay")}"
            : $"{date} · {due.Value.ToString("t", CultureInfo.CurrentCulture)}";
    }
}
