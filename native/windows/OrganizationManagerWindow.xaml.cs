using AssignmentNative.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AssignmentNative;

public sealed partial class OrganizationManagerWindow : Window
{
    private readonly ITaskOrganizationRepository _organization;
    private IReadOnlyList<CourseItem> _courses = System.Array.Empty<CourseItem>();

    private CourseItem? _selectedCourse;
    private ProjectItem? _selectedProject;
    private TagItem? _selectedTag;

    public OrganizationManagerWindow(ITaskOrganizationRepository organization)
    {
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(900, 620));
        _organization = organization;
        LoadAll();
    }

    private void LoadAll()
    {
        _courses = _organization.FetchCourses();
        CourseList.ItemsSource = _courses;

        ProjectCourseBox.Items.Clear();
        ProjectCourseBox.Items.Add(new ComboBoxItem { Content = "(No course)", Tag = 0L });
        foreach (var course in _courses)
        {
            ProjectCourseBox.Items.Add(new ComboBoxItem { Content = course.Name, Tag = course.Id });
        }

        ProjectList.ItemsSource = _organization.FetchProjects();
        TagList.ItemsSource = _organization.FetchTags();
    }

    private void CourseList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CourseList.SelectedItem is CourseItem course)
        {
            _selectedCourse = course;
            CourseNameBox.Text = course.Name;
            CourseColorBox.Text = course.ColorHex ?? "";
            CourseTeacherBox.Text = course.Teacher ?? "";
            CourseSemesterBox.Text = course.Semester ?? "";
            CourseArchivedBox.IsChecked = course.IsArchived;
        }
        else
        {
            _selectedCourse = null;
            ClearCourseForm();
        }
    }

    private void ProjectList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ProjectList.SelectedItem is ProjectItem project)
        {
            _selectedProject = project;
            ProjectNameBox.Text = project.Name;
            ProjectDescriptionBox.Text = project.Description ?? "";
            SelectProjectCourse(project.CourseId);
            SelectByTag(ProjectStatusBox, project.Status);
        }
        else
        {
            _selectedProject = null;
            ClearProjectForm();
        }
    }

    private void TagList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (TagList.SelectedItem is TagItem tag)
        {
            _selectedTag = tag;
            TagNameBox.Text = tag.Name;
            TagColorBox.Text = tag.ColorHex ?? "";
        }
        else
        {
            _selectedTag = null;
            ClearTagForm();
        }
    }

    private void SelectProjectCourse(long? courseId)
    {
        foreach (ComboBoxItem item in ProjectCourseBox.Items)
        {
            var id = item.Tag is long value ? value : 0L;
            if (id == (courseId ?? 0L))
            {
                ProjectCourseBox.SelectedItem = item;
                return;
            }
        }
        ProjectCourseBox.SelectedIndex = 0;
    }

    private void SaveCourse_Click(object sender, RoutedEventArgs e)
    {
        var name = CourseNameBox.Text.Trim();
        if (name.Length == 0)
        {
            ShowNotice("A course name is required.");
            return;
        }
        var draft = new CourseDraft(
            name,
            Clean(CourseColorBox.Text),
            Clean(CourseTeacherBox.Text),
            Clean(CourseSemesterBox.Text),
            CourseArchivedBox.IsChecked == true);
        try
        {
            if (_selectedCourse is null) _organization.CreateCourse(draft);
            else _organization.UpdateCourse(_selectedCourse.Id, draft);
            ClearCourseForm();
            LoadAll();
        }
        catch (System.Exception error)
        {
            ShowNotice($"The course could not be saved: {error.Message}");
        }
    }

    private void NewCourse_Click(object sender, RoutedEventArgs e)
    {
        _selectedCourse = null;
        CourseList.SelectedItem = null;
        ClearCourseForm();
    }

    private void DeleteCourse_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedCourse is null) return;
        try
        {
            _organization.DeleteCourse(_selectedCourse.Id);
            _selectedCourse = null;
            ClearCourseForm();
            LoadAll();
        }
        catch (System.Exception error)
        {
            ShowNotice($"The course could not be deleted: {error.Message}");
        }
    }

    private void SaveProject_Click(object sender, RoutedEventArgs e)
    {
        var name = ProjectNameBox.Text.Trim();
        if (name.Length == 0)
        {
            ShowNotice("A project name is required.");
            return;
        }
        long? courseId = ProjectCourseBox.SelectedItem is ComboBoxItem { Tag: long id } && id != 0L
            ? id
            : null;
        var draft = new ProjectDraft(
            name,
            courseId,
            Clean(ProjectDescriptionBox.Text),
            SelectedTag(ProjectStatusBox, ProjectStatuses.Active));
        try
        {
            if (_selectedProject is null) _organization.CreateProject(draft);
            else _organization.UpdateProject(_selectedProject.Id, draft);
            ClearProjectForm();
            LoadAll();
        }
        catch (System.Exception error)
        {
            ShowNotice($"The project could not be saved: {error.Message}");
        }
    }

    private void NewProject_Click(object sender, RoutedEventArgs e)
    {
        _selectedProject = null;
        ProjectList.SelectedItem = null;
        ClearProjectForm();
    }

    private void DeleteProject_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedProject is null) return;
        try
        {
            _organization.DeleteProject(_selectedProject.Id);
            _selectedProject = null;
            ClearProjectForm();
            LoadAll();
        }
        catch (System.Exception error)
        {
            ShowNotice($"The project could not be deleted: {error.Message}");
        }
    }

    private void SaveTag_Click(object sender, RoutedEventArgs e)
    {
        var name = TagNameBox.Text.Trim();
        if (name.Length == 0)
        {
            ShowNotice("A tag name is required.");
            return;
        }
        var draft = new TagDraft(name, Clean(TagColorBox.Text));
        try
        {
            if (_selectedTag is null) _organization.CreateTag(draft);
            else _organization.UpdateTag(_selectedTag.Id, draft);
            ClearTagForm();
            LoadAll();
        }
        catch (System.Exception error)
        {
            ShowNotice($"The tag could not be saved: {error.Message}");
        }
    }

    private void NewTag_Click(object sender, RoutedEventArgs e)
    {
        _selectedTag = null;
        TagList.SelectedItem = null;
        ClearTagForm();
    }

    private void DeleteTag_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedTag is null) return;
        try
        {
            _organization.DeleteTag(_selectedTag.Id);
            _selectedTag = null;
            ClearTagForm();
            LoadAll();
        }
        catch (System.Exception error)
        {
            ShowNotice($"The tag could not be deleted: {error.Message}");
        }
    }

    private void ClearCourseForm()
    {
        CourseNameBox.Text = "";
        CourseColorBox.Text = "";
        CourseTeacherBox.Text = "";
        CourseSemesterBox.Text = "";
        CourseArchivedBox.IsChecked = false;
    }

    private void ClearProjectForm()
    {
        ProjectNameBox.Text = "";
        ProjectDescriptionBox.Text = "";
        ProjectCourseBox.SelectedIndex = 0;
        SelectByTag(ProjectStatusBox, ProjectStatuses.Active);
    }

    private void ClearTagForm()
    {
        TagNameBox.Text = "";
        TagColorBox.Text = "";
    }

    private async void ShowNotice(string message)
    {
        if (Content is not UIElement root)
        {
            return;
        }
        var dialog = new ContentDialog
        {
            XamlRoot = root.XamlRoot,
            Title = "Organization",
            Content = message,
            CloseButtonText = "OK"
        };
        await dialog.ShowAsync();
    }

    private static string? Clean(string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }

    private static string SelectedTag(ComboBox box, string fallback) =>
        (box.SelectedItem as ComboBoxItem)?.Tag as string ?? fallback;

    private static void SelectByTag(ComboBox box, string tag)
    {
        foreach (var item in box.Items.OfType<ComboBoxItem>())
        {
            if (string.Equals(item.Tag as string, tag, System.StringComparison.Ordinal))
            {
                box.SelectedItem = item;
                return;
            }
        }
    }
}
