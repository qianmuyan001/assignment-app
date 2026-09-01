using AssignmentNative.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using CoreAssignmentItem = AssignmentNative.Core.AssignmentItem;

namespace AssignmentNative;

public sealed class TaskRowViewModel
{
    private readonly CoreAssignmentItem _item;

    public TaskRowViewModel(CoreAssignmentItem item, bool showProfessionalDetails)
    {
        _item = item;
        ProfessionalVisibility = showProfessionalDetails
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    public long Id => _item.Id;
    public string CourseName => _item.CourseName;
    public string Title => _item.Title;
    public string? Link => _item.Link;

    public string StatusDisplay => _item.Status switch
    {
        TaskStatuses.InProgress => AppText.Get("DynamicStatusInProgress"),
        TaskStatuses.Done => AppText.Get("DynamicStatusDone"),
        _ => AppText.Get("DynamicStatusTodo")
    };

    public string DueDisplay => AppText.FormatDue(_item);

    public string DescriptionDisplay => string.IsNullOrWhiteSpace(_item.Description)
        ? AppText.Get("NoDescription")
        : _item.Description!;

    public string PriorityDisplay => AppText.Format(
        "PriorityDisplay",
        AppText.Get(_item.Priority switch
        {
            TaskPriorities.High => "DynamicPriorityHigh",
            TaskPriorities.Low => "DynamicPriorityLow",
            _ => "DynamicPriorityMedium"
        }));

    public Visibility ProfessionalVisibility { get; }

    public Visibility LinkVisibility => string.IsNullOrWhiteSpace(_item.Link)
        ? Visibility.Collapsed
        : Visibility.Visible;

    public Visibility CompleteButtonVisibility => _item.Status == TaskStatuses.Done
        ? Visibility.Collapsed
        : Visibility.Visible;

    public SolidColorBrush AccentBrush => new(
        _item.Status == TaskStatuses.Done
            ? Colors.SeaGreen
            : TaskRules.IsOverdue(_item, DateTimeOffset.Now)
                ? Colors.IndianRed
                : _item.Status == TaskStatuses.InProgress
                    ? Colors.DodgerBlue
                    : Colors.SlateBlue);

    public SolidColorBrush PriorityBrush => new(
        _item.Priority switch
        {
            TaskPriorities.High => Colors.IndianRed,
            TaskPriorities.Low => Colors.SeaGreen,
            _ => Colors.DarkGoldenrod
        });

    public override string ToString() =>
        $"{Title}, {CourseName}, {StatusDisplay}, {DueDisplay}";
}
