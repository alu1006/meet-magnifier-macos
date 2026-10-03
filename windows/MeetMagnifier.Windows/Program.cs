using System.Runtime.InteropServices;

namespace MeetMagnifier;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new MagnifierContext());
    }
}

internal enum DrawMode { None, Arrow, Rectangle }

internal sealed class MagnifierContext : ApplicationContext
{
    private const int HotkeyCursor = 1;
    private const int HotkeyArrow = 2;
    private const int HotkeyRectangle = 3;
    private const int HotkeyReset = 4;
    private const uint ModControl = 0x0002;
    private const int VkControl = 0x11;
    private const int WhMouseLl = 14;
    private const int WmMouseWheel = 0x020A;

    private readonly HotkeyWindow hotkeys = new();
    private readonly MagnifierForm magnifier = new();
    private readonly OverlayForm overlay = new();
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer updateTimer;
    private readonly Native.LowLevelMouseProc mouseProc;
    private IntPtr mouseHook;
    private float zoom = 1f;
    private bool cursorMagnified;
    private bool isFrozen;

    public MagnifierContext()
    {
        hotkeys.HotkeyPressed += HandleHotkey;
        RegisterHotkeys();
        mouseProc = MouseHook;
        mouseHook = Native.SetWindowsHookEx(WhMouseLl, mouseProc, Native.GetModuleHandle(null), 0);
        magnifier.SetExcludedWindows(magnifier.Handle, overlay.Handle);

        overlay.DrawingFinished += () => overlay.ClickThrough = true;
        updateTimer = new System.Windows.Forms.Timer { Interval = 16 };
        updateTimer.Tick += (_, _) => UpdateDisplay();
        updateTimer.Start();

        var menu = new ContextMenuStrip();
        menu.Items.Add("放大滑鼠游標  Ctrl+M", null, (_, _) => ToggleCursor());
        menu.Items.Add("畫箭頭  Ctrl+A", null, (_, _) => BeginDrawing(DrawMode.Arrow));
        menu.Items.Add("畫方框  Ctrl+R", null, (_, _) => BeginDrawing(DrawMode.Rectangle));
        menu.Items.Add("清除並還原  Ctrl+0", null, (_, _) => ResetAll());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("結束", null, (_, _) => ExitThread());
        tray = new NotifyIcon
        {
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application,
            Text = "Meet 放大鏡",
            ContextMenuStrip = menu,
            Visible = true
        };
    }

    private void RegisterHotkeys()
    {
        Native.RegisterHotKey(hotkeys.Handle, HotkeyCursor, ModControl, (uint)Keys.M);
        Native.RegisterHotKey(hotkeys.Handle, HotkeyArrow, ModControl, (uint)Keys.A);
        Native.RegisterHotKey(hotkeys.Handle, HotkeyRectangle, ModControl, (uint)Keys.R);
        Native.RegisterHotKey(hotkeys.Handle, HotkeyReset, ModControl, (uint)Keys.D0);
    }

    private void HandleHotkey(int id)
    {
        switch (id)
        {
            case HotkeyCursor: ToggleCursor(); break;
            case HotkeyArrow: BeginDrawing(DrawMode.Arrow); break;
            case HotkeyRectangle: BeginDrawing(DrawMode.Rectangle); break;
            case HotkeyReset: ResetAll(); break;
        }
    }

    private IntPtr MouseHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && wParam.ToInt32() == WmMouseWheel && (Native.GetAsyncKeyState(VkControl) & 0x8000) != 0)
        {
            var info = Marshal.PtrToStructure<Native.MsllHookStruct>(lParam);
            var delta = (short)((info.mouseData >> 16) & 0xffff);
            // Same direction as the native macOS configuration used by this project:
            // wheel down increases magnification, wheel up decreases it.
            zoom = Math.Clamp(zoom - delta / 120f * 0.25f, 1f, 8f);
            if (zoom < 1.08f) zoom = 1f;
            isFrozen = false;
            UpdateDisplay();
            return (IntPtr)1;
        }
        return Native.CallNextHookEx(mouseHook, code, wParam, lParam);
    }

    private void ToggleCursor()
    {
        cursorMagnified = !cursorMagnified;
        overlay.CursorMagnified = cursorMagnified;
        UpdateDisplay();
    }

    private void BeginDrawing(DrawMode mode)
    {
        // Lock the current magnified viewport before the overlay starts receiving
        // mouse input, otherwise the viewport follows the drawing pointer.
        if (zoom > 1f)
        {
            UpdateDisplay();
            isFrozen = true;
        }
        overlay.SetScreen(Screen.FromPoint(Cursor.Position));
        overlay.Mode = mode;
        overlay.ClickThrough = false;
        overlay.ShowWithoutFocus();
    }

    private void ResetAll()
    {
        zoom = 1f;
        isFrozen = false;
        cursorMagnified = false;
        overlay.CursorMagnified = false;
        overlay.ClearAnnotations();
        overlay.ClickThrough = true;
        magnifier.Hide();
        UpdateDisplay();
    }

    private void UpdateDisplay()
    {
        var point = Cursor.Position;
        var screen = Screen.FromPoint(point);
        if (zoom > 1f)
        {
            magnifier.SetScreen(screen);
            if (!isFrozen) magnifier.SetZoom(zoom, point);
            magnifier.ShowWithoutFocus();
        }
        else
        {
            magnifier.Hide();
        }

        if (cursorMagnified || overlay.HasAnnotations || overlay.Mode != DrawMode.None)
        {
            overlay.SetScreen(screen);
            overlay.CursorScreenPosition = point;
            overlay.ShowWithoutFocus();
            overlay.Invalidate();
        }
        else
        {
            overlay.Hide();
        }
    }

    protected override void ExitThreadCore()
    {
        updateTimer.Stop();
        if (mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(mouseHook);
        for (var id = 1; id <= 4; id++) Native.UnregisterHotKey(hotkeys.Handle, id);
        tray.Visible = false;
        tray.Dispose();
        magnifier.Dispose();
        overlay.Dispose();
        hotkeys.Dispose();
        base.ExitThreadCore();
    }
}

internal sealed class HotkeyWindow : NativeWindow, IDisposable
{
    public event Action<int>? HotkeyPressed;
    public HotkeyWindow() => CreateHandle(new CreateParams());
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0312) HotkeyPressed?.Invoke(m.WParam.ToInt32());
        base.WndProc(ref m);
    }
    public void Dispose() => DestroyHandle();
}

internal sealed class MagnifierForm : Form
{
    private const int WsChild = 0x40000000;
    private const int WsVisible = 0x10000000;
    private const uint MwFilterModeExclude = 0;
    private IntPtr magnifierWindow;
    private Screen? currentScreen;
    private IntPtr[] excludedWindows = [];

    public MagnifierForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Native.MagInitialize();
        _ = Handle;
        magnifierWindow = Native.CreateWindowEx(0, "Magnifier", "MeetMagnifierControl",
            WsChild | WsVisible, 0, 0, Width, Height, Handle, IntPtr.Zero, Native.GetModuleHandle(null), IntPtr.Zero);
        ApplyClickThrough();
    }

    protected override bool ShowWithoutActivation => true;

    public void ShowWithoutFocus()
    {
        if (!Visible) Native.ShowWindow(Handle, 4);
        Native.SetWindowPos(Handle, new IntPtr(-1), Left, Top, Width, Height, 0x0010);
    }

    public void SetScreen(Screen screen)
    {
        if (currentScreen?.DeviceName == screen.DeviceName) return;
        currentScreen = screen;
        Bounds = screen.Bounds;
        Native.MoveWindow(magnifierWindow, 0, 0, Width, Height, true);
    }

    public void SetZoom(float zoom, Point pointer)
    {
        if (currentScreen is null) return;
        var bounds = currentScreen.Bounds;
        var sourceWidth = (int)Math.Ceiling(bounds.Width / zoom);
        var sourceHeight = (int)Math.Ceiling(bounds.Height / zoom);
        var x = (int)(pointer.X - (pointer.X - bounds.Left) / zoom);
        var y = (int)(pointer.Y - (pointer.Y - bounds.Top) / zoom);
        x = Math.Clamp(x, bounds.Left, bounds.Right - sourceWidth);
        y = Math.Clamp(y, bounds.Top, bounds.Bottom - sourceHeight);
        var source = new Native.Rect(x, y, x + sourceWidth, y + sourceHeight);
        var transform = new Native.MagTransform(zoom);
        Native.MagSetWindowTransform(magnifierWindow, ref transform);
        Native.MagSetWindowSource(magnifierWindow, source);
        Native.MagSetWindowFilterList(magnifierWindow, MwFilterModeExclude, excludedWindows.Length, excludedWindows);
        Invalidate();
    }

    public void SetExcludedWindows(params IntPtr[] windows) => excludedWindows = windows;

    private void ApplyClickThrough()
    {
        var style = Native.GetWindowLongPtr(Handle, -20).ToInt64();
        Native.SetWindowLongPtr(Handle, -20, new IntPtr(style | 0x20 | 0x80 | 0x08000000));
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        Native.MagUninitialize();
    }
}

internal readonly record struct Shape(DrawMode Mode, Point Start, Point End);

internal sealed class OverlayForm : Form
{
    private readonly List<Shape> shapes = [];
    private Point? dragStart;
    private Point dragEnd;
    private Screen? currentScreen;
    private bool clickThrough = true;

    public event Action? DrawingFinished;
    public DrawMode Mode { get; set; }
    public bool CursorMagnified { get; set; }
    public Point CursorScreenPosition { get; set; }
    public bool HasAnnotations => shapes.Count > 0;
    public bool ClickThrough
    {
        get => clickThrough;
        set { clickThrough = value; ApplyClickThrough(); }
    }

    public OverlayForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.Magenta;
        TransparencyKey = Color.Magenta;
        DoubleBuffered = true;
        _ = Handle;
        ApplyClickThrough();
    }

    protected override bool ShowWithoutActivation => true;

    public void ShowWithoutFocus()
    {
        if (!Visible) Native.ShowWindow(Handle, 4);
        Native.SetWindowPos(Handle, new IntPtr(-1), Left, Top, Width, Height, 0x0010);
    }

    public void SetScreen(Screen screen)
    {
        if (currentScreen?.DeviceName == screen.DeviceName) return;
        currentScreen = screen;
        Bounds = screen.Bounds;
    }

    public void ClearAnnotations()
    {
        shapes.Clear();
        Mode = DrawMode.None;
        dragStart = null;
        Invalidate();
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (Mode == DrawMode.None) return;
        dragStart = e.Location;
        dragEnd = e.Location;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (dragStart is null) return;
        dragEnd = e.Location;
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (dragStart is not Point start || Mode == DrawMode.None) return;
        if (Math.Abs(e.X - start.X) + Math.Abs(e.Y - start.Y) > 10)
            shapes.Add(new Shape(Mode, start, e.Location));
        dragStart = null;
        Mode = DrawMode.None;
        Invalidate();
        DrawingFinished?.Invoke();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using var pen = new Pen(Color.Red, 6) { StartCap = System.Drawing.Drawing2D.LineCap.Round, EndCap = System.Drawing.Drawing2D.LineCap.Round };
        foreach (var shape in shapes) DrawShape(e.Graphics, pen, shape);
        if (dragStart is Point start && Mode != DrawMode.None)
            DrawShape(e.Graphics, pen, new Shape(Mode, start, dragEnd));
        if (CursorMagnified)
            DrawLargeCursor(e.Graphics, PointToClient(CursorScreenPosition));
    }

    private static void DrawShape(Graphics graphics, Pen pen, Shape shape)
    {
        if (shape.Mode == DrawMode.Rectangle)
        {
            graphics.DrawRectangle(pen, Math.Min(shape.Start.X, shape.End.X), Math.Min(shape.Start.Y, shape.End.Y),
                Math.Abs(shape.End.X - shape.Start.X), Math.Abs(shape.End.Y - shape.Start.Y));
            return;
        }
        graphics.DrawLine(pen, shape.Start, shape.End);
        var angle = Math.Atan2(shape.End.Y - shape.Start.Y, shape.End.X - shape.Start.X);
        var a = new Point((int)(shape.End.X - 24 * Math.Cos(angle - Math.PI / 6)), (int)(shape.End.Y - 24 * Math.Sin(angle - Math.PI / 6)));
        var b = new Point((int)(shape.End.X - 24 * Math.Cos(angle + Math.PI / 6)), (int)(shape.End.Y - 24 * Math.Sin(angle + Math.PI / 6)));
        graphics.DrawLine(pen, shape.End, a);
        graphics.DrawLine(pen, shape.End, b);
    }

    private static void DrawLargeCursor(Graphics graphics, Point point)
    {
        Point[] points = [point, new(point.X + 2, point.Y + 58), new(point.X + 17, point.Y + 44),
            new(point.X + 29, point.Y + 68), new(point.X + 43, point.Y + 61),
            new(point.X + 31, point.Y + 39), new(point.X + 53, point.Y + 38)];
        using var fill = new SolidBrush(Color.White);
        using var outline = new Pen(Color.Black, 4) { LineJoin = System.Drawing.Drawing2D.LineJoin.Round };
        graphics.FillPolygon(fill, points);
        graphics.DrawPolygon(outline, points);
    }

    private void ApplyClickThrough()
    {
        if (!IsHandleCreated) return;
        var style = Native.GetWindowLongPtr(Handle, -20).ToInt64();
        style |= 0x80 | 0x08000000;
        if (clickThrough) style |= 0x20; else style &= ~0x20L;
        Native.SetWindowLongPtr(Handle, -20, new IntPtr(style));
    }
}

internal static class Native
{
    internal delegate IntPtr LowLevelMouseProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    internal struct MsllHookStruct { public Point pt; public uint mouseData, flags, time; public IntPtr extraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    internal readonly struct Rect(int left, int top, int right, int bottom)
    { public readonly int Left = left, Top = top, Right = right, Bottom = bottom; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct MagTransform
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 9)] public float[] v;
        public MagTransform(float zoom) => v = [zoom, 0, 0, 0, zoom, 0, 0, 0, 1];
    }

    [DllImport("Magnification.dll")] internal static extern bool MagInitialize();
    [DllImport("Magnification.dll")] internal static extern bool MagUninitialize();
    [DllImport("Magnification.dll")] internal static extern bool MagSetWindowSource(IntPtr hwnd, Rect rect);
    [DllImport("Magnification.dll")] internal static extern bool MagSetWindowTransform(IntPtr hwnd, ref MagTransform transform);
    [DllImport("Magnification.dll")] internal static extern bool MagSetWindowFilterList(IntPtr hwnd, uint mode, int count, IntPtr[] windows);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern IntPtr CreateWindowEx(int exStyle, string className, string name, int style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")] internal static extern bool MoveWindow(IntPtr hwnd, int x, int y, int width, int height, bool repaint);
    [DllImport("user32.dll")] internal static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] internal static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] internal static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] internal static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] internal static extern IntPtr SetWindowsHookEx(int id, LowLevelMouseProc callback, IntPtr module, uint threadId);
    [DllImport("user32.dll")] internal static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] internal static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern IntPtr GetModuleHandle(string? name);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] internal static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] internal static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
}
