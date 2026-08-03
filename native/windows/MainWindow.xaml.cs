using System.Collections.ObjectModel;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using AssignmentNative.Services;

namespace AssignmentNative;

public sealed partial class MainWindow : Window
{
    public ObservableCollection<AssignmentItem> Assignments { get; } = [];

    private readonly AssignmentDatabase _database;
    private readonly CredentialVaultService _credentials = new();
    private readonly LocalAiParser _parser = new();
    private SecureBrowserService? _browser;
    private IReadOnlyList<AssignmentItem> _allAssignments = [];
    private string _filter = "all";
    private bool _browserInitialized;

    public MainWindow()
    {
        InitializeComponent();
        SystemBackdrop = new MicaBackdrop { Kind = MicaKind.BaseAlt };
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1180, 780));

        _database = new AssignmentDatabase();
        DatabasePathText.Text = _database.DatabasePath;
        ReloadAssignments();
        Navigation.SelectedItem = Navigation.MenuItems[0];
    }

    private void ReloadAssignments()
    {
        _allAssignments = _database.FetchAssignments();
        ApplyFilter();
    }

    private void ApplyFilter()
    {
        var now = DateTimeOffset.Now;
        var startOfToday = new DateTimeOffset(
            now.Year, now.Month, now.Day, 0, 0, 0, now.Offset);
        var endOfToday = new DateTimeOffset(
            now.Year, now.Month, now.Day, 23, 59, 59, now.Offset);
        var endOfWeek = endOfToday.AddDays(7);
        var search = SearchBox.Text?.Trim() ?? "";

        var visible = _allAssignments.Where(item =>
        {
            var inSection = _filter switch
            {
                "today" => item.DueDate >= startOfToday && item.DueDate <= endOfToday,
                "week" => item.DueDate >= startOfToday && item.DueDate <= endOfWeek,
                "completed" => item.Status == "completed",
                _ => true
            };
            if (!inSection || search.Length == 0)
            {
                return inSection;
            }
            return item.Title.Contains(search, StringComparison.OrdinalIgnoreCase) ||
                item.CourseName.Contains(search, StringComparison.OrdinalIgnoreCase) ||
                item.SourceDisplay.Contains(search, StringComparison.OrdinalIgnoreCase);
        });

        Assignments.Clear();
        foreach (var assignment in visible)
        {
            Assignments.Add(assignment);
        }
        AssignmentCount.Text = $"{Assignments.Count} assignments";
        EmptyState.Visibility = Assignments.Count == 0
            ? Visibility.Visible
            : Visibility.Collapsed;
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
            "completed" => "Completed",
            _ => "All Assignments"
        };
        ShowPanel("assignments");
        ApplyFilter();
    }

    private async void ConnectSource_Click(object sender, RoutedEventArgs e)
    {
        Navigation.SelectedItem = Navigation.MenuItems[4];
        ShowPanel("sources");
        await RunSafelyAsync(EnsureBrowserAsync);
    }

    private void SearchBox_TextChanged(
        AutoSuggestBox sender,
        AutoSuggestBoxTextChangedEventArgs args) => ApplyFilter();

    private void Done_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: long id })
        {
            _database.UpdateStatus(id, "completed");
            ReloadAssignments();
        }
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: long id })
        {
            return;
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Delete this assignment?",
            Content = "This removes it from the local assignment database.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            _database.Delete(id);
            ReloadAssignments();
        }
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

    private void BrowserReload_Click(object sender, RoutedEventArgs e) =>
        Browser.Reload();

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
        if (args.IsSuccess &&
            AutoFillToggle.IsOn &&
            LoginModeBox.SelectedIndex == 1)
        {
            await FillCredentialAsync(showNotice: false);
        }
    }

    private void LoginMode_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        var saved = LoginModeBox.SelectedIndex == 1;
        CredentialButton.Visibility = saved
            ? Visibility.Visible
            : Visibility.Collapsed;
        AutoFillToggle.Visibility = saved
            ? Visibility.Visible
            : Visibility.Collapsed;
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
            Text = $"Exact HTTPS origin: " +
                CredentialVaultService.ExactSecureOrigin(current),
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
            MaxHeight = 430
        };
        list.SelectAll();
        list.ItemTemplate = (DataTemplate)Resources["CandidateTemplate"];
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = $"Review {candidates.Count} assignment candidates",
            Content = list,
            PrimaryButtonText = "Add selected",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }
        var selected = list.SelectedItems.Cast<AssignmentCandidate>().ToList();
        var inserted = _database.InsertCandidates(
            selected,
            CourseHintBox.Text,
            source,
            page.Url);
        ReloadAssignments();
        await ShowNoticeAsync(
            $"Added {inserted} assignments. Duplicates were skipped.");
    }

    private async void CheckAi_Click(object sender, RoutedEventArgs e)
    {
        await RunSafelyAsync(async () =>
        {
            await ApplyAiEndpointAsync();
            AiStatusText.Text = await _parser.IsAvailableAsync()
                ? "Ready"
                : "Offline";
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
