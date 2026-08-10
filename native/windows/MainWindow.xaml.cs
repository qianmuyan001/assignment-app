using System.Collections.ObjectModel;
using AssignmentNative.Core;
using AssignmentNative.Services;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
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
    private bool _updatingControls;

    public MainWindow()
    {
        InitializeComponent();
        SystemBackdrop = new MicaBackdrop { Kind = MicaKind.BaseAlt };
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1180, 780));
        Navigation.SelectedItem = Navigation.MenuItems[0];
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
            ShowError("Settings could not be loaded. Defaults are being used.", error);
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
        _updatingControls = false;
        ApplyTheme();
    }

    private async Task InitializeDatabaseAsync()
    {
        SetLoading(true);
        try
        {
            _database = await Task.Run(() => new AssignmentDatabase());
            DatabasePathText.Text = _database.DatabasePath;
            DatabaseVersionText.Text = _database.LastBackupPath is { Length: > 0 } backupPath
                ? $"Schema version {_database.SchemaVersion} · migration backup: {backupPath}"
                : $"Schema version {_database.SchemaVersion}";
            AddAssignmentButton.IsEnabled = true;
            await ReloadAssignmentsAsync(showLoading: false);
        }
        catch (Exception error)
        {
            _database = null;
            _allAssignments = [];
            AssignmentRows.Clear();
            ShowError(
                "The local database could not be opened safely. No task changes will be written. " +
                "Check the message and restore from the migration backup if one is listed.",
                error);
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
            ShowError("Assignments could not be loaded.", error);
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
            ShowError("The current filters could not be applied.", error);
        }

        AssignmentRows.Clear();
        foreach (var assignment in visible)
        {
            AssignmentRows.Add(new TaskRowViewModel(assignment, IsProfessionalMode));
        }

        AssignmentCount.Text = AssignmentRows.Count == 1
            ? "1 assignment"
            : $"{AssignmentRows.Count} assignments";
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
        EmptyStateTitle.Text = hasFilters ? "No matching assignments" : "No assignments here";
        EmptyStateMessage.Text = hasFilters
            ? "Clear or change the filters to see more tasks."
            : _filter switch
            {
                "today" => "No tasks are due today.",
                "week" => "No tasks are due in this calendar week.",
                "overdue" => "Nothing is overdue.",
                "completed" => "Completed tasks will appear here.",
                _ => "Add an assignment to get started."
            };
    }

    private void InitializeCourseFilter()
    {
        _updatingControls = true;
        CourseFilterBox.Items.Clear();
        CourseFilterBox.Items.Add(new ComboBoxItem { Content = "All courses", Tag = "all" });
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
        CourseFilterBox.Items.Add(new ComboBoxItem { Content = "All courses", Tag = "all" });
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
            "today" => "Today",
            "week" => "This Week",
            "overdue" => "Overdue",
            "completed" => "Completed",
            _ => "All Assignments"
        };
        ShowPanel("assignments");
        ApplyFilter();
    }

    private void SearchBox_TextChanged(
        AutoSuggestBox sender,
        AutoSuggestBoxTextChangedEventArgs args) => ApplyFilter();

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
        SearchBox.Text = "";
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
            ShowError("The database is unavailable, so the assignment cannot be added.");
            return;
        }

        var dialog = new TaskEditorDialog(
            existing: null,
            professionalMode: IsProfessionalMode)
        {
            XamlRoot = Content.XamlRoot
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && dialog.Result is { } draft)
        {
            await ExecuteDatabaseChangeAsync(database => database.Add(draft));
        }
    }

    private async void EditAssignment_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: long id } ||
            _allAssignments.FirstOrDefault(item => item.Id == id) is not { } assignment)
        {
            return;
        }

        var dialog = new TaskEditorDialog(assignment, IsProfessionalMode)
        {
            XamlRoot = Content.XamlRoot
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && dialog.Result is { } draft)
        {
            await ExecuteDatabaseChangeAsync(database => database.Update(id, draft));
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
            Title = "Delete this assignment?",
            Content = assignment is null
                ? "This removes it from the local assignment database."
                : $"“{assignment.Title}” will be permanently removed from the local database.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
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
            ShowError("The database is unavailable. No changes were written.");
            return;
        }

        SetLoading(true);
        try
        {
            await Task.Run(() => change(database));
            ErrorBar.IsOpen = false;
            await ReloadAssignmentsAsync(showLoading: false);
        }
        catch (Exception error)
        {
            ShowError("The assignment change could not be saved.", error);
        }
        finally
        {
            SetLoading(false);
            ApplyFilter();
        }
    }

    private async void OpenTaskLink_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string link } ||
            !Uri.TryCreate(link, UriKind.Absolute, out var uri) ||
            uri.Scheme is not ("http" or "https"))
        {
            ShowError("This assignment does not have a valid http or https source link.");
            return;
        }

        if (!await Windows.System.Launcher.LaunchUriAsync(uri))
        {
            ShowError("Windows could not open the source link.");
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

    private bool IsProfessionalMode =>
        _settings.DetailMode == AssignmentDisplayMode.Professional;

    private void ApplyTheme()
    {
        Navigation.RequestedTheme = _settings.Theme switch
        {
            AppTheme.Light => ElementTheme.Light,
            AppTheme.Dark => ElementTheme.Dark,
            _ => ElementTheme.Default
        };
    }

    private void SaveSettings()
    {
        try
        {
            _settingsStore.Save(_settings);
        }
        catch (Exception error)
        {
            ShowError("The setting could not be saved for the next launch.", error);
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
            _ = ShowNoticeAsync("Blocked a non-web navigation request.");
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
        BrowserTitle.Text = Browser.CoreWebView2?.DocumentTitle ?? "Web page";
        ScanButton.IsEnabled = args.IsSuccess;
        if (args.IsSuccess && AutoFillToggle.IsOn && LoginModeBox.SelectedIndex == 1)
        {
            await FillCredentialAsync(showNotice: false);
        }
    }

    private void LoginMode_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
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
            await ShowNoticeAsync("Open the HTTPS login page first.");
            return;
        }

        var username = new TextBox { Header = "Username or email" };
        var password = new PasswordBox { Header = "Password" };
        var form = new StackPanel { Spacing = 12 };
        form.Children.Add(new TextBlock
        {
            Text = $"Exact HTTPS origin: {CredentialVaultService.ExactSecureOrigin(current)}",
            Opacity = 0.65
        });
        form.Children.Add(username);
        form.Children.Add(password);
        form.Children.Add(new TextBlock
        {
            Text = "Stored in Windows Credential Locker. Filling never submits the form.",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Opacity = 0.65
        });

        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Saved credential",
            Content = form,
            PrimaryButtonText = "Save",
            SecondaryButtonText = "Fill existing",
            CloseButtonText = "Cancel",
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
                ?? throw new InvalidOperationException("Open a login page first.");
            var credential = _credentials.Retrieve(current)
                ?? throw new InvalidOperationException(
                    $"No credential is saved for {current.IdnHost}.");
            await _browser!.FillAsync(credential);
            if (showNotice)
            {
                await ShowNoticeAsync(
                    "Username and password were filled. Review the page before signing in.");
            }
        }, showError: showNotice);
    }

    private async void ScanPage_Click(object sender, RoutedEventArgs e)
    {
        await RunSafelyAsync(async () =>
        {
            await ApplyAiEndpointAsync();
            ScanButton.IsEnabled = false;
            ScanButton.Content = "Reading locally…";
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
        ScanButton.Content = "Scan current page";
        ScanButton.IsEnabled = _browser?.CurrentUri is not null;
    }

    private async Task ReviewCandidatesAsync(
        IReadOnlyList<AssignmentCandidate> candidates,
        CapturedPage page,
        string source)
    {
        if (candidates.Count == 0)
        {
            await ShowNoticeAsync("The local model found no assignments on this page.");
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
            Title = $"Review {candidates.Count} assignment candidates",
            Content = list,
            PrimaryButtonText = "Add selected",
            CloseButtonText = "Cancel",
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
            ShowError("Imported assignments could not be saved.", error);
            return;
        }
        finally
        {
            SetLoading(false);
        }
        await ShowNoticeAsync($"Added {inserted} assignments. Duplicates were skipped.");
    }

    private async void CheckAi_Click(object sender, RoutedEventArgs e)
    {
        await RunSafelyAsync(async () =>
        {
            await ApplyAiEndpointAsync();
            AiStatusText.Text = await _parser.IsAvailableAsync() ? "Ready" : "Offline";
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
            Title = "Assignments",
            Content = message,
            CloseButtonText = "OK"
        };
        await dialog.ShowAsync();
    }
}

internal static class CapturedPageExtensions
{
    public static string UriHost(this CapturedPage page) =>
        Uri.TryCreate(page.Url, UriKind.Absolute, out var uri)
            ? uri.IdnHost
            : "Web";
}
