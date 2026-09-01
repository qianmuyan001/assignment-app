using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using AssignmentNative.Core;
using AssignmentNative.Services;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using WinRT;
using WinRT.Interop;
using AssignmentDatabase = AssignmentNative.Services.AssignmentDatabase;
using CoreAssignmentItem = AssignmentNative.Core.AssignmentItem;

namespace AssignmentNative;

public sealed partial class MainWindow : Window
{
    public ObservableCollection<TaskRowViewModel> AssignmentRows { get; } = [];

    private readonly CredentialVaultService _credentials = new();
    private readonly LocalAiParser _parser = new();
    private readonly AppSettingsStore _settingsStore = new();
    private AssignmentDatabase? _database;
    private SecureBrowserService? _browser;
    private IReadOnlyList<CoreAssignmentItem> _allAssignments = [];
    private AppSettings _settings = new();
    private string _filter = "all";
    private bool _browserInitialized;
    private bool _rootLoaded;
    private bool _searchExpanded;
    private bool _updatingControls;
    private long? _pendingNotificationAssignmentId;
    private OrganizationManagerWindow? _organizationWindow;

    private const double CompactNavigationThreshold = 760;

    public MainWindow()
    {
        InitializeComponent();
        Title = AppText.Get("AppWindowTitle");
        RootGrid.AddHandler(
            UIElement.PointerPressedEvent,
            new PointerEventHandler(RootGrid_PointerPressed),
            handledEventsToo: true);
        SystemBackdrop = new MicaBackdrop { Kind = MicaKind.BaseAlt };
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1180, 780));
        Navigation.SelectedItem = Navigation.MenuItems[0];
        Closed += (_, _) => CloseAuxiliaryWindows();
    }

    private async void RootGrid_Loaded(object sender, RoutedEventArgs e)
    {
        if (_rootLoaded)
        {
            return;
        }

        _rootLoaded = true;
        LoadSettings();
        InitializeCourseFilter();
        await InitializeDatabaseAsync();
    }

    private void LoadSettings()
    {
        try
        {
            _settings = _settingsStore.Load();
        }
        catch (Exception error)
        {
            _settings = new AppSettings();
            ShowError(AppText.Get("SettingsLoadError"), error);
        }

        _updatingControls = true;
        SelectByTag(
            DisplayModeBox,
            _settings.DetailMode == AssignmentDisplayMode.Professional
                ? "professional"
                : "simple");
        SelectByTag(
            ThemeBox,
            _settings.Theme switch
            {
                AppTheme.Light => "light",
                AppTheme.Dark => "dark",
                _ => "system"
            });
        SelectByTag(
            LanguageBox,
            _settings.Language == AppLanguage.SimplifiedChinese
                ? "zh-CN"
                : "en-US");
        if (Navigation.SettingsItem is NavigationViewItem settingsItem)
        {
            settingsItem.Content = AppText.Get("Settings");
        }
        _updatingControls = false;
        ApplyTheme();
        ApplyNavigationPaneMode(RootGrid.ActualWidth);
    }

    private async Task InitializeDatabaseAsync()
    {
        SetLoading(true);
        try
        {
            _database = await Task.Run(() => new AssignmentDatabase());
            DatabasePathText.Text = _database.DatabasePath;
            DatabaseVersionText.Text = _database.LastBackupPath is { Length: > 0 } backupPath
                ? AppText.Format("SchemaVersionBackup", _database.SchemaVersion, backupPath)
                : AppText.Format("SchemaVersion", _database.SchemaVersion);
            AddAssignmentButton.IsEnabled = true;
            await ReconcileAttachmentFilesAsync(_database);
            await ReloadAssignmentsAsync(showLoading: false);
            ReconcileNotifications();
            NotificationStatusText.Text = WindowsNotificationScheduler.Shared.Status;
            ScrollToPendingNotificationAssignment();
        }
        catch (Exception error)
        {
            _database = null;
            _allAssignments = [];
            AssignmentRows.Clear();
            ShowError(AppText.Get("DatabaseOpenError"), error);
        }
        finally
        {
            SetLoading(false);
            ApplyFilter();
        }
    }

    private async Task ReloadAssignmentsAsync(bool showLoading = true)
    {
        var database = _database;
        if (database is null)
        {
            return;
        }

        if (showLoading)
        {
            SetLoading(true);
        }

        try
        {
            _allAssignments = await Task.Run(() => database.FetchAssignments());
            RebuildCourseFilter();
            ApplyFilter();
        }
        catch (Exception error)
        {
            ShowError(AppText.Get("AssignmentsLoadError"), error);
        }
        finally
        {
            if (showLoading)
            {
                SetLoading(false);
            }
        }
    }

    private void ApplyFilter()
    {
        if (!_rootLoaded || SearchBox is null)
        {
            return;
        }

        IReadOnlyList<CoreAssignmentItem> visible;
        try
        {
            visible = TaskRules.Apply(
                _allAssignments,
                new AssignmentQuery
                {
                    View = _filter switch
                    {
                        "today" => AssignmentView.Today,
                        "week" => AssignmentView.ThisWeek,
                        "overdue" => AssignmentView.Overdue,
                        "completed" => AssignmentView.Completed,
                        _ => AssignmentView.All
                    },
                    Search = SearchBox.Text,
                    Status = SelectedFilterTag(StatusFilterBox),
                    Course = SelectedFilterTag(CourseFilterBox),
                    Priority = SelectedFilterTag(PriorityFilterBox),
                    Sort = SelectedTag(SortBox, "due_date") == "priority"
                        ? AssignmentSort.PriorityDescending
                        : AssignmentSort.DueDateAscending,
                    Now = DateTimeOffset.Now,
                    TimeZone = TimeZoneInfo.Local
                });
        }
        catch (Exception error)
        {
            visible = [];
            ShowError(AppText.Get("FiltersApplyError"), error);
        }

        AssignmentRows.Clear();
        foreach (var assignment in visible)
        {
            AssignmentRows.Add(new TaskRowViewModel(assignment, IsProfessionalMode));
        }

        AssignmentCount.Text = AssignmentRows.Count == 1
            ? AppText.Get("AssignmentCountOne")
            : AppText.Format("AssignmentCount", AssignmentRows.Count);
        UpdateEmptyState();
    }

    private void SetLoading(bool isLoading)
    {
        LoadingState.Visibility = isLoading ? Visibility.Visible : Visibility.Collapsed;
        AssignmentList.Visibility = isLoading ? Visibility.Collapsed : Visibility.Visible;
        if (isLoading)
        {
            EmptyState.Visibility = Visibility.Collapsed;
        }
        AddAssignmentButton.IsEnabled = !isLoading && _database is not null;
    }

    private void UpdateEmptyState()
    {
        if (LoadingState.Visibility == Visibility.Visible)
        {
            EmptyState.Visibility = Visibility.Collapsed;
            return;
        }

        EmptyState.Visibility = AssignmentRows.Count == 0
            ? Visibility.Visible
            : Visibility.Collapsed;
        var hasFilters = !string.IsNullOrWhiteSpace(SearchBox.Text) ||
            SelectedFilterTag(StatusFilterBox) is not null ||
            SelectedFilterTag(CourseFilterBox) is not null ||
            SelectedFilterTag(PriorityFilterBox) is not null;
        EmptyStateTitle.Text = AppText.Get(
            hasFilters ? "NoMatchingAssignments" : "NoAssignmentsHere");
        EmptyStateMessage.Text = hasFilters
            ? AppText.Get("ClearFiltersForTasks")
            : _filter switch
            {
                "today" => AppText.Get("NoTasksToday"),
                "week" => AppText.Get("NoTasksWeek"),
                "overdue" => AppText.Get("NothingOverdue"),
                "completed" => AppText.Get("CompletedTasksHere"),
                _ => AppText.Get("AddAssignmentGetStarted")
            };
    }

    private void InitializeCourseFilter()
    {
        _updatingControls = true;
        CourseFilterBox.Items.Clear();
        CourseFilterBox.Items.Add(new ComboBoxItem { Content = AppText.Get("AllCourses"), Tag = "all" });
        CourseFilterBox.SelectedIndex = 0;
        _updatingControls = false;
    }

    private void RebuildCourseFilter()
    {
        var current = SelectedFilterTag(CourseFilterBox);
        var courses = _allAssignments
            .Select(item => item.CourseName.Trim())
            .Where(course => course.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(course => course, StringComparer.CurrentCultureIgnoreCase)
            .ToList();

        _updatingControls = true;
        CourseFilterBox.Items.Clear();
        CourseFilterBox.Items.Add(new ComboBoxItem { Content = AppText.Get("AllCourses"), Tag = "all" });
        foreach (var course in courses)
        {
            CourseFilterBox.Items.Add(new ComboBoxItem { Content = course, Tag = course });
        }
        SelectByTag(CourseFilterBox, current ?? "all");
        _updatingControls = false;
    }

    private void ShowPanel(string panel)
    {
        AssignmentPanel.Visibility = panel == "assignments"
            ? Visibility.Visible
            : Visibility.Collapsed;
        SourcePanel.Visibility = panel == "sources"
            ? Visibility.Visible
            : Visibility.Collapsed;
        SettingsPanel.Visibility = panel == "settings"
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private async void Navigation_SelectionChanged(
        NavigationView sender,
        NavigationViewSelectionChangedEventArgs args)
    {
        if (_rootLoaded)
        {
            CollapseSearch(clearQuery: false);
        }

        if (args.IsSettingsSelected)
        {
            ShowPanel("settings");
            return;
        }
        if (args.SelectedItemContainer?.Tag is not string tag)
        {
            return;
        }
        if (tag == "sources")
        {
            ShowPanel("sources");
            await RunSafelyAsync(EnsureBrowserAsync);
            return;
        }

        _filter = tag;
        PageTitle.Text = tag switch
        {
            "today" => AppText.Get("NavTodayTitle"),
            "week" => AppText.Get("NavWeekTitle"),
            "overdue" => AppText.Get("NavOverdueTitle"),
            "completed" => AppText.Get("NavCompletedTitle"),
            _ => AppText.Get("NavAllTitle")
        };
        ShowPanel("assignments");
        ApplyFilter();
    }

    private void SearchBox_TextChanged(
        AutoSuggestBox sender,
        AutoSuggestBoxTextChangedEventArgs args) => ApplyFilter();

    private void SearchToggle_Click(object sender, RoutedEventArgs e) =>
        ExpandSearch();

    private void SearchClose_Click(object sender, RoutedEventArgs e)
    {
        CollapseSearch(clearQuery: true);
        SearchToggleButton.Focus(FocusState.Programmatic);
    }

    private void SearchBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Escape)
        {
            return;
        }

        CollapseSearch(clearQuery: false);
        SearchToggleButton.Focus(FocusState.Programmatic);
        e.Handled = true;
    }

    private void Find_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        ExpandSearch();
        args.Handled = true;
    }

    private void RootGrid_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_searchExpanded &&
            e.OriginalSource is DependencyObject source &&
            !IsDescendantOf(source, SearchChrome))
        {
            CollapseSearch(clearQuery: false);
        }
    }

    private void ExpandSearch()
    {
        _searchExpanded = true;
        SearchChrome.Width = 300;
        SearchToggleButton.Visibility = Visibility.Collapsed;
        SearchEditor.Visibility = Visibility.Visible;
        DispatcherQueue.TryEnqueue(() => SearchBox.Focus(FocusState.Programmatic));
    }

    private void CollapseSearch(bool clearQuery)
    {
        if (clearQuery)
        {
            SearchBox.Text = "";
        }
        _searchExpanded = false;
        SearchEditor.Visibility = Visibility.Collapsed;
        SearchToggleButton.Visibility = Visibility.Visible;
        SearchChrome.Width = 40;
    }

    private static bool IsDescendantOf(DependencyObject source, DependencyObject ancestor)
    {
        for (DependencyObject? current = source;
             current is not null;
             current = VisualTreeHelper.GetParent(current))
        {
            if (ReferenceEquals(current, ancestor))
            {
                return true;
            }
        }
        return false;
    }

    private void Filter_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_updatingControls)
        {
            ApplyFilter();
        }
    }

    private void ClearFilters_Click(object sender, RoutedEventArgs e)
    {
        _updatingControls = true;
        CollapseSearch(clearQuery: true);
        StatusFilterBox.SelectedIndex = 0;
        CourseFilterBox.SelectedIndex = 0;
        PriorityFilterBox.SelectedIndex = 0;
        SortBox.SelectedIndex = 0;
        _updatingControls = false;
        ApplyFilter();
    }

    private async void AddAssignment_Click(object sender, RoutedEventArgs e)
    {
        if (_database is null)
        {
            ShowError(AppText.Get("DatabaseUnavailableAdd"));
            return;
        }

        var dialog = new TaskEditorDialog(
            existing: null,
            professionalMode: IsProfessionalMode,
            organization: _database.Organization,
            ownerHandle: OwnerHandle)
        {
            XamlRoot = Content.XamlRoot
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && dialog.Result is { } draft)
        {
            var tagIds = dialog.SelectedTagIds;
            long? newId = null;
            await ExecuteDatabaseChangeAsync(database => { newId = database.Add(draft); });
            if (newId is { } id)
            {
                ApplyOrganizationTags(id, tagIds);
            }
        }
    }

    private async void EditAssignment_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: long id } ||
            _database is null ||
            _allAssignments.FirstOrDefault(item => item.Id == id) is not { } assignment)
        {
            return;
        }

        var dialog = new TaskEditorDialog(
            assignment,
            IsProfessionalMode,
            _database.Organization,
            OwnerHandle,
            notificationReconcile: ReconcileNotifications)
        {
            XamlRoot = Content.XamlRoot
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && dialog.Result is { } draft)
        {
            var tagIds = dialog.SelectedTagIds;
            await ExecuteDatabaseChangeAsync(database => database.Update(id, draft));
            ApplyOrganizationTags(id, tagIds);
        }
    }

    private async void Done_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: long id })
        {
            await ExecuteDatabaseChangeAsync(
                database => database.UpdateStatus(id, TaskStatuses.Done));
        }
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: long id })
        {
            return;
        }

        var assignment = _allAssignments.FirstOrDefault(item => item.Id == id);
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = AppText.Get("DeleteAssignmentTitle"),
            Content = assignment is null
                ? AppText.Get("DeleteAssignmentGeneric")
                : AppText.Format("DeleteAssignmentNamed", assignment.Title),
            PrimaryButtonText = AppText.Get("Delete"),
            CloseButtonText = AppText.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await ExecuteDatabaseChangeAsync(database => database.Delete(id));
        }
    }

    private async Task ExecuteDatabaseChangeAsync(Action<AssignmentDatabase> change)
    {
        var database = _database;
        if (database is null)
        {
            ShowError(AppText.Get("DatabaseUnavailableChanges"));
            return;
        }

        SetLoading(true);
        try
        {
            await Task.Run(() => change(database));
            ErrorBar.IsOpen = false;
            await ReloadAssignmentsAsync(showLoading: false);
            ReconcileNotifications();
        }
        catch (Exception error)
        {
            ShowError(AppText.Get("AssignmentSaveError"), error);
        }
        finally
        {
            SetLoading(false);
            ApplyFilter();
        }
    }

    private async void OpenNotificationSettings_Click(object sender, RoutedEventArgs e)
    {
        await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications"));
        NotificationStatusText.Text = WindowsNotificationScheduler.Shared.Status;
    }

    private void RefreshNotificationStatus_Click(object sender, RoutedEventArgs e)
    {
        NotificationStatusText.Text = WindowsNotificationScheduler.Shared.Status;
        ReconcileNotifications();
    }

    private void SendTestNotification_Click(object sender, RoutedEventArgs e)
    {
        var scheduled = WindowsNotificationScheduler.Shared.ScheduleTestNotification(
            TimeSpan.FromSeconds(5));
        NotificationStatusText.Text = scheduled
            ? AppText.Get("TestReminderScheduled")
            : WindowsNotificationScheduler.Shared.Status;
    }

    public void OpenFromNotification(long? assignmentId)
    {
        _pendingNotificationAssignmentId = assignmentId;
        if (!_rootLoaded || _database is null) return;

        Navigation.SelectedItem = Navigation.MenuItems[0];
        _filter = "all";
        ShowPanel("assignments");
        _updatingControls = true;
        CollapseSearch(clearQuery: true);
        StatusFilterBox.SelectedIndex = 0;
        CourseFilterBox.SelectedIndex = 0;
        PriorityFilterBox.SelectedIndex = 0;
        _updatingControls = false;
        ApplyFilter();
        ScrollToPendingNotificationAssignment();
    }

    private void ScrollToPendingNotificationAssignment()
    {
        if (_pendingNotificationAssignmentId is not { } assignmentId) return;
        var row = AssignmentRows.FirstOrDefault(item => item.Id == assignmentId);
        if (row is null) return;

        _pendingNotificationAssignmentId = null;
        AssignmentList.ScrollIntoView(row);
        DispatcherQueue.TryEnqueue(() =>
        {
            if (AssignmentList.ContainerFromItem(row) is ListViewItem container)
            {
                container.Focus(FocusState.Programmatic);
            }
            else
            {
                AssignmentList.Focus(FocusState.Programmatic);
            }
        });
    }

    private void ReconcileNotifications()
    {
        if (_database is not null)
            WindowsNotificationScheduler.Shared.Reconcile(_database);
        NotificationStatusText.Text = WindowsNotificationScheduler.Shared.Status;
    }

    private async Task ReconcileAttachmentFilesAsync(AssignmentDatabase database)
    {
        try
        {
            var result = await Task.Run(() =>
                new AttachmentFileStore(database.DatabasePath).Reconcile(
                    database.Organization.FetchAllAttachments()));
            if (result.MissingPayloadNames.Count > 0)
            {
                ShowError(AppText.Format(
                    "AttachmentFilesMissing",
                    string.Join(", ", result.MissingPayloadNames)));
            }
        }
        catch (Exception error)
        {
            ShowError(AppText.Get("AttachmentReconcileError"), error);
        }
    }

    private async void OpenTaskLink_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string link } ||
            !Uri.TryCreate(link, UriKind.Absolute, out var uri) ||
            uri.Scheme is not ("http" or "https"))
        {
            ShowError(AppText.Get("InvalidSourceLink"));
            return;
        }

        if (!await Windows.System.Launcher.LaunchUriAsync(uri))
        {
            ShowError(AppText.Get("OpenSourceLinkError"));
        }
    }

    private void DisplayMode_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingControls || !_rootLoaded)
        {
            return;
        }

        _settings.DetailMode = SelectedTag(DisplayModeBox, "simple") == "professional"
            ? AssignmentDisplayMode.Professional
            : AssignmentDisplayMode.Simple;
        SaveSettings();
        ApplyFilter();
    }

    private void Theme_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingControls || !_rootLoaded)
        {
            return;
        }

        _settings.Theme = SelectedTag(ThemeBox, "system") switch
        {
            "light" => AppTheme.Light,
            "dark" => AppTheme.Dark,
            _ => AppTheme.System
        };
        ApplyTheme();
        SaveSettings();
    }

    private void Language_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingControls || !_rootLoaded)
        {
            return;
        }

        var language = SelectedTag(LanguageBox, "en-US") == "zh-CN"
            ? AppLanguage.SimplifiedChinese
            : AppLanguage.English;
        if (_settings.Language == language)
        {
            return;
        }

        _settings.Language = language;
        if (!SaveSettings())
        {
            _settings.Language = AppText.Language;
            _updatingControls = true;
            SelectByTag(
                LanguageBox,
                _settings.Language == AppLanguage.SimplifiedChinese
                    ? "zh-CN"
                    : "en-US");
            _updatingControls = false;
            return;
        }
        (Application.Current as App)?.SwitchLanguage(language, this);
    }

    private void NavigationStyle_Click(object sender, RoutedEventArgs e)
    {
        _settings.NavigationPaneMode = _settings.NavigationPaneMode == NavigationPaneMode.Compact
            ? NavigationPaneMode.Expanded
            : NavigationPaneMode.Compact;
        ApplyNavigationPaneMode(RootGrid.ActualWidth);
        SaveSettings();
    }

    private void RootGrid_SizeChanged(object sender, SizeChangedEventArgs e) =>
        ApplyNavigationPaneMode(e.NewSize.Width);

    private void ApplyNavigationPaneMode(double width)
    {
        var compact = _settings.NavigationPaneMode == NavigationPaneMode.Compact ||
                      width is > 0 and < CompactNavigationThreshold;
        Navigation.PaneDisplayMode = compact
            ? NavigationViewPaneDisplayMode.LeftCompact
            : NavigationViewPaneDisplayMode.Left;
        Navigation.IsPaneOpen = !compact;
        NavigationStyleLabel.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;

        var action = _settings.NavigationPaneMode == NavigationPaneMode.Compact
            ? AppText.Get("ShowNavigationLabels")
            : AppText.Get("UseCompactNavigation");
        NavigationStyleLabel.Text = action;
        ToolTipService.SetToolTip(NavigationStyleButton, action);
        AutomationProperties.SetName(NavigationStyleButton, action);
    }

    private bool IsProfessionalMode =>
        _settings.DetailMode == AssignmentDisplayMode.Professional;

    private IntPtr OwnerHandle => WindowNative.GetWindowHandle(this);

    private void ApplyOrganizationTags(long assignmentId, IReadOnlyList<long> tagIds)
    {
        var org = _database?.Organization;
        if (org is null)
        {
            return;
        }
        try
        {
            var current = new HashSet<long>(
                org.FetchTaskTags(assignmentId).Select(link => link.TagId));
            var desired = new HashSet<long>(tagIds);
            foreach (var tagId in desired.Except(current))
            {
                org.AttachTag(assignmentId, tagId);
            }
            foreach (var tagId in current.Except(desired))
            {
                org.DetachTag(assignmentId, tagId);
            }
        }
        catch (Exception error)
        {
            ShowError(AppText.Get("AssignmentTagsSaveError"), error);
        }
    }

    private void ManageOrganization_Click(object sender, RoutedEventArgs e)
    {
        if (_database is null)
        {
            ShowError(AppText.Get("OrganizationUnavailable"));
            return;
        }
        if (_organizationWindow is null)
        {
            var window = new OrganizationManagerWindow(_database.Organization);
            window.Closed += (_, _) =>
            {
                if (ReferenceEquals(_organizationWindow, window))
                {
                    _organizationWindow = null;
                }
            };
            _organizationWindow = window;
        }
        _organizationWindow.Activate();
    }

    internal void CloseAuxiliaryWindows()
    {
        var window = _organizationWindow;
        _organizationWindow = null;
        window?.Close();
    }

    private void ApplyTheme()
    {
        Navigation.RequestedTheme = _settings.Theme switch
        {
            AppTheme.Light => ElementTheme.Light,
            AppTheme.Dark => ElementTheme.Dark,
            _ => ElementTheme.Default
        };
    }

    private bool SaveSettings()
    {
        try
        {
            _settingsStore.Save(_settings);
            return true;
        }
        catch (Exception error)
        {
            ShowError(AppText.Get("SettingsSaveError"), error);
            return false;
        }
    }

    private static string? SelectedFilterTag(ComboBox box)
    {
        var tag = SelectedTag(box, "all");
        return tag == "all" ? null : tag;
    }

    private static string SelectedTag(ComboBox box, string fallback) =>
        (box.SelectedItem as ComboBoxItem)?.Tag as string ?? fallback;

    private static void SelectByTag(ComboBox box, string tag)
    {
        foreach (var item in box.Items.OfType<ComboBoxItem>())
        {
            if (string.Equals(item.Tag as string, tag, StringComparison.OrdinalIgnoreCase))
            {
                box.SelectedItem = item;
                return;
            }
        }
        if (box.Items.Count > 0)
        {
            box.SelectedIndex = 0;
        }
    }

    private void ShowError(string message, Exception? error = null)
    {
        ErrorBar.Message = error is null ? message : $"{message} {error.Message}";
        ErrorBar.IsOpen = true;
    }

    private async Task EnsureBrowserAsync()
    {
        if (_browserInitialized)
        {
            return;
        }
        _browser = new SecureBrowserService(Browser);
        await _browser.InitializeAsync();
        _browserInitialized = true;
    }

    private async void OpenAddress_Click(object sender, RoutedEventArgs e) =>
        await OpenAddressAsync();

    private async void AddressBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            await OpenAddressAsync();
        }
    }

    private async Task OpenAddressAsync()
    {
        await RunSafelyAsync(async () =>
        {
            await EnsureBrowserAsync();
            _browser!.Navigate(AddressBox.Text);
        });
    }

    private void BrowserBack_Click(object sender, RoutedEventArgs e)
    {
        if (Browser.CanGoBack) Browser.GoBack();
    }

    private void BrowserForward_Click(object sender, RoutedEventArgs e)
    {
        if (Browser.CanGoForward) Browser.GoForward();
    }

    private void BrowserReload_Click(object sender, RoutedEventArgs e) => Browser.Reload();

    private void Browser_NavigationStarting(
        WebView2 sender,
        Microsoft.Web.WebView2.Core.CoreWebView2NavigationStartingEventArgs args)
    {
        if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out var destination) ||
            destination.Scheme is not ("http" or "https"))
        {
            args.Cancel = true;
            _ = ShowNoticeAsync(AppText.Get("BlockedNonWebNavigation"));
            return;
        }
        ScanButton.IsEnabled = false;
        BrowserLocation.Text = args.Uri;
    }

    private async void Browser_NavigationCompleted(
        WebView2 sender,
        Microsoft.Web.WebView2.Core.CoreWebView2NavigationCompletedEventArgs args)
    {
        BrowserLocation.Text = Browser.Source?.AbsoluteUri ?? "";
        BrowserTitle.Text = Browser.CoreWebView2?.DocumentTitle ?? AppText.Get("WebPage");
        ScanButton.IsEnabled = args.IsSuccess;
        if (args.IsSuccess && AutoFillToggle.IsOn && LoginModeBox.SelectedIndex == 1)
        {
            await FillCredentialAsync(showNotice: false);
        }
    }

    private void LoginMode_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // SelectedIndex raises while later XAML fields are still being created.
        if (!_rootLoaded)
        {
            return;
        }

        var saved = LoginModeBox.SelectedIndex == 1;
        CredentialButton.Visibility = saved ? Visibility.Visible : Visibility.Collapsed;
        AutoFillToggle.Visibility = saved ? Visibility.Visible : Visibility.Collapsed;
        if (!saved)
        {
            AutoFillToggle.IsOn = false;
        }
    }

    private async void CredentialButton_Click(object sender, RoutedEventArgs e)
    {
        var current = _browser?.CurrentUri;
        if (current is null)
        {
            await ShowNoticeAsync(AppText.Get("OpenHttpsLoginFirst"));
            return;
        }

        var username = new TextBox { Header = AppText.Get("UsernameOrEmail") };
        var password = new PasswordBox { Header = AppText.Get("Password") };
        var form = new StackPanel { Spacing = 12 };
        form.Children.Add(new TextBlock
        {
            Text = AppText.Format(
                "ExactHttpsOrigin",
                CredentialVaultService.ExactSecureOrigin(current)),
            Opacity = 0.65
        });
        form.Children.Add(username);
        form.Children.Add(password);
        form.Children.Add(new TextBlock
        {
            Text = AppText.Get("CredentialLockerHelp"),
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Opacity = 0.65
        });

        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = AppText.Get("SavedCredential"),
            Content = form,
            PrimaryButtonText = AppText.Get("Save"),
            SecondaryButtonText = AppText.Get("FillExisting"),
            CloseButtonText = AppText.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary
        };
        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            await RunSafelyAsync(() =>
            {
                _credentials.Save(current, username.Text, password.Password);
                password.Password = "";
                return Task.CompletedTask;
            });
        }
        else if (result == ContentDialogResult.Secondary)
        {
            await FillCredentialAsync(showNotice: true);
        }
    }

    private async Task FillCredentialAsync(bool showNotice)
    {
        await RunSafelyAsync(async () =>
        {
            var current = _browser?.CurrentUri
                ?? throw new InvalidOperationException(AppText.Get("OpenLoginFirst"));
            var credential = _credentials.Retrieve(current)
                ?? throw new InvalidOperationException(
                    AppText.Format("NoCredentialSaved", current.IdnHost));
            await _browser!.FillAsync(credential);
            if (showNotice)
            {
                await ShowNoticeAsync(AppText.Get("CredentialFilled"));
            }
        }, showError: showNotice);
    }

    private async void ScanPage_Click(object sender, RoutedEventArgs e)
    {
        await RunSafelyAsync(async () =>
        {
            await ApplyAiEndpointAsync();
            ScanButton.IsEnabled = false;
            ScanButton.Content = AppText.Get("ReadingLocally");
            var page = await _browser!.CapturePageAsync();
            var source = string.IsNullOrWhiteSpace(SourceNameBox.Text)
                ? page.UriHost()
                : SourceNameBox.Text.Trim();
            var candidates = await _parser.ParseAsync(
                page,
                source,
                CourseHintBox.Text.Trim());
            await ReviewCandidatesAsync(candidates, page, source);
        });
        ScanButton.Content = AppText.Get("ScanCurrentPage");
        ScanButton.IsEnabled = _browser?.CurrentUri is not null;
    }

    private async Task ReviewCandidatesAsync(
        IReadOnlyList<AssignmentCandidate> candidates,
        CapturedPage page,
        string source)
    {
        if (candidates.Count == 0)
        {
            await ShowNoticeAsync(AppText.Get("NoAssignmentsFoundOnPage"));
            return;
        }

        var list = new ListView
        {
            ItemsSource = candidates,
            SelectionMode = ListViewSelectionMode.Multiple,
            MaxHeight = 430,
            ItemTemplate = (DataTemplate)Navigation.Resources["CandidateTemplate"]
        };
        list.SelectAll();
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = AppText.Format("ReviewCandidates", candidates.Count),
            Content = list,
            PrimaryButtonText = AppText.Get("AddSelected"),
            CloseButtonText = AppText.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || _database is null)
        {
            return;
        }

        var selected = list.SelectedItems.Cast<AssignmentCandidate>().ToList();
        var inserted = 0;
        var database = _database;
        SetLoading(true);
        try
        {
            inserted = await Task.Run(() => database.InsertCandidates(
                selected,
                CourseHintBox.Text,
                source,
                page.Url));
            await ReloadAssignmentsAsync(showLoading: false);
        }
        catch (Exception error)
        {
            ShowError(AppText.Get("ImportedAssignmentsSaveError"), error);
            return;
        }
        finally
        {
            SetLoading(false);
        }
        await ShowNoticeAsync(AppText.Format("AssignmentsImported", inserted));
    }

    private async void CheckAi_Click(object sender, RoutedEventArgs e)
    {
        await RunSafelyAsync(async () =>
        {
            await ApplyAiEndpointAsync();
            AiStatusText.Text = await _parser.IsAvailableAsync()
                ? AppText.Get("AiReady")
                : AppText.Get("AiOffline");
        });
    }

    private Task ApplyAiEndpointAsync()
    {
        _parser.SetEndpoint(AiEndpointBox.Text);
        return Task.CompletedTask;
    }

    private async Task RunSafelyAsync(Func<Task> action, bool showError = true)
    {
        try
        {
            await action();
        }
        catch (Exception error)
        {
            if (showError)
            {
                await ShowNoticeAsync(error.Message);
            }
        }
    }

    private async Task ShowNoticeAsync(string message)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = AppText.Get("NoticeTitle"),
            Content = message,
            CloseButtonText = AppText.Get("OK")
        };
        await dialog.ShowAsync();
    }
}

internal static class CapturedPageExtensions
{
    public static string UriHost(this CapturedPage page) =>
        Uri.TryCreate(page.Url, UriKind.Absolute, out var uri)
            ? uri.IdnHost
            : AppText.Get("Web");
}
