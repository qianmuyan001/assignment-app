using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using CommunityToolkit.WinUI.Notifications;

namespace AssignmentNative.Services;

#pragma warning disable CS0618 // Stable COM activation is required for the explicit unpackaged sender identity.
[ComVisible(true)]
[Guid(WindowsToastIdentity.ActivatorClassId)]
public sealed class AssignmentNotificationActivator : NotificationActivator
{
    public override void OnActivated(
        string arguments,
        NotificationUserInput userInput,
        string appUserModelId) =>
        WindowsNotificationScheduler.Shared.HandleActivation(arguments);
}
#pragma warning restore CS0618

internal static class WindowsToastIdentity
{
    public const string AppUserModelId = "qianmuyan001.AssignmentApp";
    public const string ActivatorClassId = "B9D88D1E-45B5-4C27-91E9-06C8F75E4826";

    private static readonly PropertyKey AppUserModelIdKey = new(
        new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);
    private static readonly PropertyKey ToastActivatorClsidKey = new(
        new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 26);

    public static void InstallShortcut()
    {
        var executablePath = Environment.ProcessPath ??
            throw new InvalidOperationException("The application executable path is unavailable.");
        var shortcutPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Programs),
            "Assignment App.lnk");
        Directory.CreateDirectory(Path.GetDirectoryName(shortcutPath)!);
        var existed = File.Exists(shortcutPath);

        var shellObject = (object)new ShellLink();
        try
        {
            var link = (IShellLinkW)shellObject;
            link.SetPath(executablePath);
            link.SetArguments(AcceptanceArguments());
            link.SetWorkingDirectory(Path.GetDirectoryName(executablePath)!);
            link.SetDescription("Assignment App");
            link.SetIconLocation(executablePath, 0);

            var appId = PropVariant.FromString(AppUserModelId);
            var activatorId = PropVariant.FromGuid(typeof(AssignmentNotificationActivator).GUID);
            try
            {
                var store = (IPropertyStore)shellObject;
                store.SetValue(AppUserModelIdKey, appId);
                store.SetValue(ToastActivatorClsidKey, activatorId);
                store.Commit();
                ((IPersistFile)shellObject).Save(shortcutPath, true);
            }
            finally
            {
                appId.Dispose();
                activatorId.Dispose();
            }

            SHChangeNotify(existed ? 0x00002000u : 0x00000002u, 0x0005, shortcutPath, IntPtr.Zero);
            SHChangeNotify(0x08000000u, 0, null, IntPtr.Zero);
        }
        finally
        {
            Marshal.FinalReleaseComObject(shellObject);
        }
    }

    private static string AcceptanceArguments()
    {
        var arguments = new List<string>();
        AddAcceptanceArgument(
            arguments,
            "--acceptance-database-path",
            Environment.GetEnvironmentVariable("ASSIGNMENT_DB_PATH"));
        AddAcceptanceArgument(
            arguments,
            "--acceptance-settings-path",
            Environment.GetEnvironmentVariable("ASSIGNMENT_SETTINGS_PATH"));
        return string.Join(" ", arguments);
    }

    private static void AddAcceptanceArgument(
        ICollection<string> arguments,
        string option,
        string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) return;
        arguments.Add(option);
        arguments.Add($"\"{Path.GetFullPath(path)}\"");
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern void SHChangeNotify(
        uint eventId,
        uint flags,
        [MarshalAs(UnmanagedType.LPWStr)] string? item1,
        IntPtr item2);

    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    private sealed class ShellLink
    {
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int maxPath, IntPtr findData, uint flags);
        void GetIDList(out IntPtr itemIdList);
        void SetIDList(IntPtr itemIdList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder description, int maxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string description);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int maxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int maxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCommand);
        void SetShowCmd(int showCommand);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int iconPathLength, out int iconIndex);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    private interface IPropertyStore
    {
        uint GetCount();
        PropertyKey GetAt(uint propertyIndex);
        void GetValue(in PropertyKey key, out PropVariant value);
        void SetValue(in PropertyKey key, in PropVariant value);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private readonly struct PropertyKey(Guid formatId, uint propertyId)
    {
        public readonly Guid FormatId = formatId;
        public readonly uint PropertyId = propertyId;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PropVariant : IDisposable
    {
        [FieldOffset(0)]
        private ushort _valueType;

        [FieldOffset(8)]
        private IntPtr _pointerValue;

        public static PropVariant FromString(string value) => new()
        {
            _valueType = (ushort)VarEnum.VT_LPWSTR,
            _pointerValue = Marshal.StringToCoTaskMemUni(value)
        };

        public static PropVariant FromGuid(Guid value)
        {
            var pointer = Marshal.AllocCoTaskMem(Marshal.SizeOf<Guid>());
            Marshal.StructureToPtr(value, pointer, false);
            return new PropVariant
            {
                _valueType = (ushort)VarEnum.VT_CLSID,
                _pointerValue = pointer
            };
        }

        public void Dispose()
        {
            if (_pointerValue == IntPtr.Zero) return;
            Marshal.FreeCoTaskMem(_pointerValue);
            _pointerValue = IntPtr.Zero;
        }
    }
}
