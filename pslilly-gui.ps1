<#
.SYNOPSIS
    pslilly-gui - the pslilly Lily client in its own Windows window.

.DESCRIPTION
    A scrolling message pane with a typing box underneath. Needs
    pslilly-core.ps1 in the same folder, and shares lily.conf with the
    console version (pslilly.ps1).

    Logging in: a login box asks for the server, your name and password.
    Tick "Remember me" to keep the password in Windows Credential Manager;
    pslilly then logs you in by itself at startup. ($$forget removes it.)
    Otherwise the password is only kept in memory, for reconnecting.

    It reconnects by itself after a dropped connection, after the PC wakes up
    from sleep, and when the network comes back. Locking the PC or putting it
    to sleep sets you /away; unlocking sets you /here again.

    Keys in the typing box:
        Enter              send            Up / Down        earlier lines
        PgUp / PgDn        scroll messages Ctrl+Home / End  top / bottom
        Ctrl+Up / Down     scroll a line   Tab              complete a name
        :  (empty line)    last person who messaged you
        ;  (empty line)    last person you messaged
        F7                 spelling suggestions (again for the next one)
        Shift+F7           add the word to the dictionary
        Ctrl+Z / Ctrl+Y    undo / redo     Esc              clear the line
        Ctrl+mouse wheel   zoom

    $$ lists settings and commands. $$! <command> runs PowerShell.

.NOTES
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/.

.EXAMPLE
    .\pslilly-gui.ps1
.EXAMPLE
    .\pslilly-gui.ps1 -Login             # show the login box even if a password is saved
.EXAMPLE
    .\pslilly-gui.ps1 -CreateShortcut    # put a PSLilly shortcut on the desktop
#>
param(
    [string]$Server,
    [int]$Port,
    [switch]$Login,
    [switch]$CreateShortcut,
    [string]$Config = (Join-Path $PSScriptRoot 'lily.conf')
)

if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    Write-Host 'The pslilly window needs Windows. The console version (pslilly.ps1) works here.' -ForegroundColor Red
    return
}

# Windows Forms needs a single-threaded apartment; restart in one if needed
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $argList = @('-NoProfile', '-STA', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) { if ($kv.Value) { $argList += "-$($kv.Key)" } }
        else { $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`"" }
    }
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList
    return
}

if ($CreateShortcut) {
    # conhost + -WindowStyle Hidden: no console window, even where Windows
    # Terminal is the default. -ExecutionPolicy Bypass is for this run only,
    # so the shortcut also works on a PC where scripts are blocked.
    $exe  = (Get-Process -Id $PID).Path
    $con  = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $runArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $lnk  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PSLilly.lnk'
    $sh   = New-Object -ComObject WScript.Shell
    $sc   = $sh.CreateShortcut($lnk)
    if (Test-Path -LiteralPath $con) { $sc.TargetPath = $con; $sc.Arguments = "`"$exe`" $runArgs" }
    else { $sc.TargetPath = $exe; $sc.Arguments = $runArgs }
    $sc.WorkingDirectory = $PSScriptRoot
    $sc.Description      = 'PSLilly - Lily chat'
    $sc.WindowStyle      = 7
    $ico = Join-Path $PSScriptRoot 'pslilly.ico'
    if (Test-Path -LiteralPath $ico) { $sc.IconLocation = "$ico,0" }
    $sc.Save()
    Write-Host "Created $lnk"
    return
}

$corePath = Join-Path $PSScriptRoot 'pslilly-core.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    Write-Host "pslilly-core.ps1 is missing; it needs to be in the same folder as this script ($PSScriptRoot)." -ForegroundColor Red
    return
}
. $corePath

# ---------------------------------------------------------------------------
# Windows helpers: scrolling the message pane, taskbar flashing, and a hidden
# window that hears about sleep / wake / lock / unlock and network changes.
# ---------------------------------------------------------------------------
$WinHelperCode = @'
using System;
using System.Collections.Concurrent;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;

namespace PsLilly {
    public static class Win {
        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X; public int Y; }

        [StructLayout(LayoutKind.Sequential)]
        struct SCROLLINFO { public uint cbSize; public uint fMask; public int nMin; public int nMax; public uint nPage; public int nPos; public int nTrackPos; }

        [StructLayout(LayoutKind.Sequential)]
        struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }

        [DllImport("user32.dll", EntryPoint = "SendMessageW")]
        static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll", EntryPoint = "SendMessageW")]
        static extern IntPtr SendMessagePoint(IntPtr h, int msg, IntPtr w, ref POINT l);
        [DllImport("user32.dll")]
        static extern bool GetScrollInfo(IntPtr h, int bar, ref SCROLLINFO si);
        [DllImport("user32.dll")]
        static extern bool FlashWindowEx(ref FLASHWINFO f);
        [DllImport("user32.dll")]
        static extern bool SetProcessDPIAware();

        public static void DpiAware() { try { SetProcessDPIAware(); } catch (Exception) { } }

        // WM_SETREDRAW: stop/start painting while many lines are added
        public static void SetRedraw(IntPtr h, bool on) { SendMessage(h, 0x000B, new IntPtr(on ? 1 : 0), IntPtr.Zero); }

        // EM_GETSCROLLPOS / EM_SETSCROLLPOS
        public static POINT GetScroll(IntPtr h) { POINT p = new POINT(); SendMessagePoint(h, 0x04DD, IntPtr.Zero, ref p); return p; }
        public static void SetScroll(IntPtr h, POINT p) { SendMessagePoint(h, 0x04DE, IntPtr.Zero, ref p); }

        // WM_VSCROLL: 0 line up, 1 line down, 2 page up, 3 page down, 6 top, 7 bottom
        public static void Scroll(IntPtr h, int code) { SendMessage(h, 0x0115, new IntPtr(code), IntPtr.Zero); }

        public static bool AtBottom(IntPtr h) {
            SCROLLINFO si = new SCROLLINFO();
            si.cbSize = (uint)Marshal.SizeOf(typeof(SCROLLINFO));
            si.fMask = 0x17;   // SIF_ALL
            if (!GetScrollInfo(h, 1, ref si)) { return true; }
            if (si.nPage == 0 || si.nMax < (int)si.nPage) { return true; }
            return si.nPos + (int)si.nPage >= si.nMax;
        }

        // Flash the taskbar button until the window comes to the front
        public static void Flash(IntPtr h) {
            FLASHWINFO f = new FLASHWINFO();
            f.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
            f.hwnd = h;
            f.dwFlags = 0x3 | 0xC;   // FLASHW_ALL | FLASHW_TIMERNOFG
            f.uCount = 0;
            f.dwTimeout = 0;
            FlashWindowEx(ref f);
        }
    }

    // A hidden window that gets Windows' power and session messages.
    // Events are queued as text: suspend, resume, lock, unlock, net-up, net-down
    public static class Watcher {
        public static readonly ConcurrentQueue<string> Events = new ConcurrentQueue<string>();

        delegate IntPtr WndProcDelegate(IntPtr h, uint msg, IntPtr w, IntPtr l);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WNDCLASS {
            public uint style;
            public WndProcDelegate lpfnWndProc;
            public int cbClsExtra;
            public int cbWndExtra;
            public IntPtr hInstance;
            public IntPtr hIcon;
            public IntPtr hCursor;
            public IntPtr hbrBackground;
            public string lpszMenuName;
            public string lpszClassName;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern ushort RegisterClassW(ref WNDCLASS wc);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateWindowExW(int ex, string cls, string name, int style, int x, int y, int w, int h,
                                             IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
        [DllImport("user32.dll")]
        static extern IntPtr DefWindowProcW(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr GetModuleHandleW(string name);
        [DllImport("wtsapi32.dll")]
        static extern bool WTSRegisterSessionNotification(IntPtr h, int flags);

        static WndProcDelegate proc;
        static IntPtr hwnd = IntPtr.Zero;

        public static bool Start() {
            if (hwnd != IntPtr.Zero) { return true; }
            proc = new WndProcDelegate(WndProc);
            WNDCLASS wc = new WNDCLASS();
            wc.lpfnWndProc = proc;
            wc.hInstance = GetModuleHandleW(null);
            wc.lpszClassName = "PsLillyWatcher" + System.Diagnostics.Process.GetCurrentProcess().Id;
            RegisterClassW(ref wc);
            hwnd = CreateWindowExW(0, wc.lpszClassName, "PsLillyWatcher", 0, 0, 0, 0, 0,
                                   IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
            if (hwnd == IntPtr.Zero) { return false; }
            try { WTSRegisterSessionNotification(hwnd, 0); } catch (Exception) { }
            try { NetworkChange.NetworkAvailabilityChanged += OnNetwork; } catch (Exception) { }
            return true;
        }

        static void OnNetwork(object sender, NetworkAvailabilityEventArgs e) {
            Events.Enqueue(e.IsAvailable ? "net-up" : "net-down");
        }

        static IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l) {
            if (msg == 0x0218) {            // WM_POWERBROADCAST
                int c = w.ToInt32();
                if (c == 0x4) { Events.Enqueue("suspend"); }
                else if (c == 0x7 || c == 0x12) { Events.Enqueue("resume"); }
            } else if (msg == 0x02B1) {     // WM_WTSSESSION_CHANGE
                int c = w.ToInt32();
                if (c == 0x7) { Events.Enqueue("lock"); }
                else if (c == 0x8) { Events.Enqueue("unlock"); }
            }
            return DefWindowProcW(h, msg, w, l);
        }
    }
}
'@

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('PsLilly.Win' -as [type])) { Add-Type -TypeDefinition $WinHelperCode -Language CSharp }
[PsLilly.Win]::DpiAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

$K = [System.Windows.Forms.Keys]

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$s = New-LillySession $Config
if ($Server) { $s.Server = $Server }
if ($Port)   { $s.Port = $Port }
$s.ExtraHelp = @(
    '  $$connect                 log in (shows the login box)',
    '  $$forget                  remove the saved password for this server',
    '  $$clear                   clear the message pane'
)

$G = @{
    InPump       = $false
    DialogOpen   = $false
    Programmatic = $false     # we're changing the typing box, not you
    LastText     = ''
    LastKind     = ''
    Undo         = [System.Collections.Generic.List[object]]::new()
    Redo         = [System.Collections.Generic.List[object]]::new()
    History      = [System.Collections.Generic.List[string]]::new()
    HistIndex    = 0
    Draft        = ''
    Complete     = $null      # Tab cycle
    Cycle        = $null      # F7 cycle
    Fonts        = @{}
    FontKey      = ''
    BaseFont     = $null
    InputFont    = $null
    InputFontU   = $null
    CharWidth    = 8
    BaseFg       = $null
    BaseBg       = $null
    Locked       = $false
    LastResume   = [DateTime]::MinValue
    LastError    = ''
    LastErrorAt  = [DateTime]::MinValue
    HadMarks     = $false
    LoginMessage = ''
}

# ---------------------------------------------------------------------------
# Colors and fonts
# ---------------------------------------------------------------------------
function ConvertTo-DrawColor($cc, [System.Drawing.Color]$default) {
    if ($null -eq $cc) { return $default }
    $rgb = $LillyRgb[[string]$cc]
    return [System.Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2])
}

function Get-StyledFont([bool]$bold, [bool]$italic, [bool]$underline) {
    $fs = [System.Drawing.FontStyle]::Regular
    if ($bold)      { $fs = $fs -bor [System.Drawing.FontStyle]::Bold }
    if ($italic)    { $fs = $fs -bor [System.Drawing.FontStyle]::Italic }
    if ($underline) { $fs = $fs -bor [System.Drawing.FontStyle]::Underline }
    $key = [int]$fs
    if (-not $G.Fonts.ContainsKey($key)) { $G.Fonts[$key] = New-Object System.Drawing.Font($G.BaseFont, $fs) }
    return $G.Fonts[$key]
}

# A record's colors and font: its class style, with a per-user style on top
function Get-RecordLook($r) {
    $fg = $null; $bg = $null; $b = $false; $i = $false; $u = $false
    if ($r.Class -and $s.Styles.ContainsKey($r.Class)) {
        $st = $s.Styles[$r.Class]
        $fg = $st.Fg; $bg = $st.Bg; $b = $st.Bold; $i = $st.Italic; $u = $st.Underline
    }
    if ($r.Style) {
        if ($null -ne $r.Style.Fg) { $fg = $r.Style.Fg }
        if ($null -ne $r.Style.Bg) { $bg = $r.Style.Bg }
        $b = $b -or $r.Style.Bold; $i = $i -or $r.Style.Italic; $u = $u -or $r.Style.Underline
    }
    return @{
        Fg   = ConvertTo-DrawColor $fg $G.BaseFg
        Bg   = ConvertTo-DrawColor $bg $G.BaseBg
        Font = Get-StyledFont $b $i $u
    }
}

# Apply font / colors / typing box height from the settings
function Update-Appearance {
    $size = 11.0
    [void][double]::TryParse([string]$s.Cfg.font_size, [ref]$size)
    if ($size -lt 6) { $size = 6 } elseif ($size -gt 48) { $size = 48 }
    $name = if ($s.Cfg.font) { [string]$s.Cfg.font } else { 'Consolas' }
    $key = "$name|$size"
    if ($key -ne $G.FontKey) {
        $font = $null
        try { $font = New-Object System.Drawing.Font($name, [single]$size) } catch { $font = New-Object System.Drawing.Font('Consolas', [single]11) }
        foreach ($f in $G.Fonts.Values) { try { $f.Dispose() } catch {} }
        $G.Fonts = @{}
        $G.BaseFont = $font
        $G.InputFont = $font
        $G.InputFontU = New-Object System.Drawing.Font($font, [System.Drawing.FontStyle]::Underline)
        $G.CharWidth = [Math]::Max(1, [System.Windows.Forms.TextRenderer]::MeasureText('MMMMMMMMMM', $font).Width / 10)
        $out.Font = $font    # (on a later change this restyles text already shown)
        $in.Font = $font
        $G.FontKey = $key
    }
    $G.BaseFg = ConvertTo-DrawColor $s.BaseFg ([System.Drawing.Color]::FromArgb(204, 204, 204))
    $G.BaseBg = ConvertTo-DrawColor $s.BaseBg ([System.Drawing.Color]::FromArgb(12, 12, 12))
    $out.BackColor = $G.BaseBg; $out.ForeColor = $G.BaseFg
    $in.BackColor  = $G.BaseBg; $in.ForeColor  = $G.BaseFg
    $sep.BackColor = ConvertTo-DrawColor ([ConsoleColor]::DarkGray) $G.BaseFg
    $lines = 3
    [void][int]::TryParse([string]$s.Cfg.input_lines, [ref]$lines)
    if ($lines -lt 1) { $lines = 1 } elseif ($lines -gt 20) { $lines = 20 }
    $lineH = [System.Windows.Forms.TextRenderer]::MeasureText('Ag', $G.InputFont).Height
    $in.Height = $lineH * $lines + 8
    Update-InputSpelling
}

# ---------------------------------------------------------------------------
# The message pane
# ---------------------------------------------------------------------------
function Add-PaneText([string]$text, $look, [int]$hang) {
    $out.SelectionStart = $out.TextLength
    $out.SelectionLength = 0
    $out.SelectionColor = $look.Fg
    $out.SelectionBackColor = $look.Bg
    $out.SelectionFont = $look.Font
    $out.SelectionIndent = 0
    $out.SelectionHangingIndent = [int]($hang * $G.CharWidth)
    $out.AppendText($text)
}

# Draw lines, keeping your place if you've scrolled up to read
function Show-Records($recs) {
    if ($recs.Count -eq 0) { return }
    $h = $out.Handle
    $atBottom = [PsLilly.Win]::AtBottom($h)
    $selS = $out.SelectionStart; $selL = $out.SelectionLength
    $pos = [PsLilly.Win]::GetScroll($h)
    [PsLilly.Win]::SetRedraw($h, $false)
    try {
        $plain = @{ Fg = $G.BaseFg; Bg = $G.BaseBg; Font = (Get-StyledFont $false $false $false) }
        foreach ($r in $recs) {
            switch ($r.Type) {
                'line'    { Add-PaneText ($r.Text + "`n") (Get-RecordLook $r) $r.Hang }
                'partial' { Add-PaneText $r.Text $plain 0 }
                'newline' { Add-PaneText "`n" $plain 0 }
            }
        }
        if ($atBottom) { $selS = [Math]::Max(0, $selS - (Limit-Scrollback)) }
        $out.Select([Math]::Min($selS, $out.TextLength), $selL)
        if ($atBottom) { [PsLilly.Win]::Scroll($h, 7) } else { [PsLilly.Win]::SetScroll($h, $pos) }
    } finally {
        [PsLilly.Win]::SetRedraw($h, $true)
        $out.Invalidate()
    }
    Update-MoreBelow
}

# Keep the pane to <scrollback> lines; returns how many characters were removed
function Limit-Scrollback {
    $max = 5000
    [void][int]::TryParse([string]$s.Cfg.scrollback, [ref]$max)
    if ($max -lt 100) { $max = 100 }
    $lines = $out.GetLineFromCharIndex($out.TextLength) + 1
    if ($lines -le [int]($max * 1.1)) { return 0 }
    $cut = $out.GetFirstCharIndexFromLine($lines - $max)
    if ($cut -le 0) { return 0 }
    $out.ReadOnly = $false
    $out.Select(0, $cut)
    $out.SelectedText = ''
    $out.ReadOnly = $true
    return $cut
}

function Update-MoreBelow {
    $stMore.Text = if ([PsLilly.Win]::AtBottom($out.Handle)) { '' } else { 'More below - PgDn or Ctrl+End' }
}

function Move-Pane([int]$code) {
    [PsLilly.Win]::Scroll($out.Handle, $code)
    Update-MoreBelow
}

# ---------------------------------------------------------------------------
# Pumping: network, records, Windows events (about every 50 ms)
# ---------------------------------------------------------------------------
function Show-UiError($err) {
    $msg = "$err"
    $now = [DateTime]::UtcNow
    if ($msg -eq $G.LastError -and ($now - $G.LastErrorAt).TotalSeconds -lt 10) { return }
    $G.LastError = $msg; $G.LastErrorAt = $now
    Write-LillyNote $s "[pslilly problem: $msg]" 'error'
}

function Invoke-Pump {
    if ($G.InPump) { return }
    $G.InPump = $true
    try {
        Invoke-LillyTick $s
        Read-WindowsEvents
        Read-Records
        $n = $s.Commands.Count
        $stCmd.Text = if ($n) { "$n command(s) running" } else { '' }
    } catch {
        Show-UiError $_.Exception.Message
    } finally {
        $G.InPump = $false
    }
}

function Read-Records {
    if ($s.Out.Count -eq 0) { return }
    $recs = $s.Out.ToArray()
    $s.Out.Clear()
    $draw = [System.Collections.Generic.List[object]]::new()
    $restyle = $false; $alert = $false; $action = $null
    foreach ($r in $recs) {
        switch ($r.Type) {
            'line'          { $draw.Add($r) }
            'partial'       { $draw.Add($r) }
            'newline'       { $draw.Add($r) }
            'title'         { $form.Text = $r.Text }
            'status'        { $stConn.Text = $r.Text }
            'config'        { $restyle = $true }
            'alert'         { $alert = $true }
            'login-failed'  { $action = 'failed' }
            'need-login'    { $action = 'login' }
            'need-password' { $action = 'login' }
        }
    }
    if ($restyle) { Update-Appearance }
    Show-Records $draw
    if ($alert) { Invoke-Alert }
    if ($action) {
        # after this tick finishes, so the network keeps running behind the box
        $G.LoginMessage = if ($action -eq 'failed') { 'That name or password was not accepted.' } else { '' }
        $null = $form.BeginInvoke([Action]{ Start-Login -ForceDialog -Message $G.LoginMessage })
    }
}

function Invoke-Alert {
    if (ConvertTo-LillyBool $s.Cfg.alert_private) {
        if ([System.Windows.Forms.Form]::ActiveForm -ne $form) { [PsLilly.Win]::Flash($form.Handle) }
    }
    if (ConvertTo-LillyBool $s.Cfg.alert_sound) { [System.Media.SystemSounds]::Asterisk.Play() }
}

function Read-WindowsEvents {
    $ev = $null
    while ([PsLilly.Watcher]::Events.TryDequeue([ref]$ev)) {
        switch ($ev) {
            'suspend' {
                Set-LillyAutoAway $s
            }
            'resume' {
                $now = [DateTime]::UtcNow
                if (($now - $G.LastResume).TotalSeconds -lt 5) { break }   # Windows often says it twice
                $G.LastResume = $now
                if ($s.State -ne 'disconnected') {
                    Write-LillyNote $s '*** Woke up - checking the connection... ***'
                    Request-LillyConnectionCheck $s
                }
                if (-not $G.Locked) { Set-LillyAutoHere $s }
            }
            'lock'   { $G.Locked = $true;  Set-LillyAutoAway $s }
            'unlock' { $G.Locked = $false; Set-LillyAutoHere $s }
            'net-down' {
                if ($s.State -ne 'disconnected') { Write-LillyNote $s '*** The network connection dropped. ***' 'error' }
            }
            'net-up' {
                if ($s.State -ne 'disconnected') {
                    Write-LillyNote $s '*** The network is back - checking the connection... ***'
                    Request-LillyConnectionCheck $s
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Logging in
# ---------------------------------------------------------------------------
function Show-LoginDialog([string]$message) {
    $saved = Get-LillySavedLogin $s.Server
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'PSLilly - Log in'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterParent'
    $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'
    $f.ShowInTaskbar = $false
    if ($G.Icon) { $f.Icon = $G.Icon }
    $f.Font = [System.Drawing.SystemFonts]::MessageBoxFont
    $boxW = [System.Windows.Forms.TextRenderer]::MeasureText(('M' * 22), $f.Font).Width

    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.ColumnCount = 2; $t.AutoSize = $true; $t.AutoSizeMode = 'GrowAndShrink'
    $t.Padding = New-Object System.Windows.Forms.Padding(12)
    $f.Controls.Add($t)

    if ($message) {
        $m = New-Object System.Windows.Forms.Label
        $m.Text = $message; $m.AutoSize = $true; $m.ForeColor = [System.Drawing.Color]::Firebrick
        $m.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 10)
        $t.Controls.Add($m); $t.SetColumnSpan($m, 2)
    }
    $fields = @{}
    foreach ($row in @(@('Server', 'Server:'), @('Port', 'Port:'), @('Name', 'Name:'), @('Password', 'Password:'))) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $row[1]; $l.AutoSize = $true; $l.Anchor = 'Left'
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Width = $boxW
        if ($row[0] -eq 'Password') { $tb.UseSystemPasswordChar = $true }
        $t.Controls.Add($l); $t.Controls.Add($tb)
        $fields[$row[0]] = $tb
    }
    $fields.Server.Text = $s.Server
    $fields.Port.Text = "$($s.Port)"
    $fields.Name.Text = if ($s.Login.Name) { $s.Login.Name } elseif ($saved) { $saved.Name } else { $s.Cfg.last_user }

    $remember = New-Object System.Windows.Forms.CheckBox
    $remember.Text = 'Remember me on this PC (password kept in Windows Credential Manager)'
    $remember.AutoSize = $true
    $remember.Checked = [bool]$saved
    $remember.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 8)
    $t.Controls.Add($remember); $t.SetColumnSpan($remember, 2)

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.FlowDirection = 'RightToLeft'; $buttons.AutoSize = $true; $buttons.Dock = 'Fill'
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'; $cancel.AutoSize = $true
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Connect'; $ok.DialogResult = 'OK'; $ok.AutoSize = $true
    $buttons.Controls.Add($cancel); $buttons.Controls.Add($ok)
    $t.Controls.Add($buttons); $t.SetColumnSpan($buttons, 2)
    $f.AcceptButton = $ok; $f.CancelButton = $cancel

    $focus = if ($fields.Name.Text) { $fields.Password } else { $fields.Name }
    $f.Add_Shown({ $focus.Focus() }.GetNewClosure())

    while ($true) {
        $result = $f.ShowDialog($form)
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { $f.Dispose(); return $null }
        $p = 0
        if (-not $fields.Server.Text.Trim() -or -not [int]::TryParse($fields.Port.Text.Trim(), [ref]$p) -or $p -le 0) {
            [void][System.Windows.Forms.MessageBox]::Show($f, 'Please enter a server and a port number.', 'PSLilly'); continue
        }
        if (-not $fields.Name.Text.Trim()) {
            [void][System.Windows.Forms.MessageBox]::Show($f, 'Please enter your name.', 'PSLilly'); continue
        }
        break
    }
    $r = @{
        Server   = $fields.Server.Text.Trim()
        Port     = $p
        Name     = $fields.Name.Text.Trim()
        Password = (ConvertTo-LillySecure $fields.Password.Text)
        Remember = $remember.Checked
    }
    $fields.Password.Text = ''
    $f.Dispose()
    return $r
}

function Start-Login([switch]$ForceDialog, [string]$Message) {
    if ($G.DialogOpen) { return }
    if (-not $ForceDialog) {
        $saved = Get-LillySavedLogin $s.Server
        if ($saved) {
            $s.Login = @{ Name = $saved.Name; Password = $saved.Password; Stage = 'none' }
            Connect-LillySession $s
            return
        }
    }
    $G.DialogOpen = $true
    try { $r = Show-LoginDialog $Message } finally { $G.DialogOpen = $false }
    if (-not $r) {
        if ($s.State -eq 'disconnected') { Write-LillyNote $s '*** Not connected. Type $$connect to log in. ***' }
        return
    }
    $s.Server = $r.Server; $s.Port = $r.Port
    if ($s.Cfg.default_server -ne $r.Server) { Set-LillySetting $s 'default_server' $r.Server }
    if ("$($s.Cfg.default_port)" -ne "$($r.Port)") { Set-LillySetting $s 'default_port' "$($r.Port)" }
    if ($s.Cfg.last_user -ne $r.Name) { Set-LillySetting $s 'last_user' $r.Name }
    $s.Login = @{ Name = $r.Name; Password = $r.Password; Stage = 'none' }
    if ($r.Remember) {
        try {
            Save-LillyLogin $r.Server $r.Name $r.Password
            Write-LillyNote $s "Password saved in Windows Credential Manager for $($r.Server). (`$`$forget removes it)"
        } catch { Write-LillyNote $s "Could not save the password: $($_.Exception.Message)" 'error' }
    } else {
        if (Remove-LillySavedLogin $r.Server) { Write-LillyNote $s "Removed the saved password for $($r.Server)." }
    }
    Connect-LillySession $s
}

# ---------------------------------------------------------------------------
# The typing box
# ---------------------------------------------------------------------------
function Set-InputText([string]$text, [int]$caret) {
    $G.Programmatic = $true
    try {
        $in.Text = $text
        $in.SelectionStart = [Math]::Min([Math]::Max(0, $caret), $in.TextLength)
        $in.SelectionLength = 0
    } finally { $G.Programmatic = $false }
    $G.LastText = $in.Text
    Start-SpellTimer
}

function Save-Undo { $G.Undo.Add(@{ T = $in.Text; P = $in.SelectionStart }); if ($G.Undo.Count -gt 200) { $G.Undo.RemoveAt(0) } }

function Undo-Input([switch]$Redo) {
    $from = $G.Undo; $to = $G.Redo
    if ($Redo) { $from = $G.Redo; $to = $G.Undo }
    if ($from.Count -eq 0) { return }
    $snap = $from[$from.Count - 1]
    $from.RemoveAt($from.Count - 1)
    $to.Add(@{ T = $in.Text; P = $in.SelectionStart })
    Set-InputText $snap.T $snap.P
    $G.LastKind = ''
}

function Start-SpellTimer { $spellTimer.Stop(); $spellTimer.Start() }

# Red, underlined misspellings (not the word you're still typing)
function Update-InputSpelling {
    $spellTimer.Stop()
    if (-not $G.InputFont) { return }
    $text = $in.Text
    $ranges = Get-LillySpellRanges $s $text     # (no @( ): it already returns one list)
    $caret = $in.SelectionStart
    $show = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i + 1 -lt $ranges.Count; $i += 2) {
        $atCaret = ($ranges[$i] + $ranges[$i + 1] -eq $caret) -and ($caret -eq $text.Length) -and $in.Focused
        if (-not $atCaret) { $show.Add($ranges[$i]); $show.Add($ranges[$i + 1]) }
    }
    if ($show.Count -eq 0 -and -not $G.HadMarks) { return }
    $G.Programmatic = $true
    $selS = $in.SelectionStart; $selL = $in.SelectionLength
    [PsLilly.Win]::SetRedraw($in.Handle, $false)
    try {
        $in.SelectAll()
        $in.SelectionColor = $G.BaseFg
        $in.SelectionBackColor = $G.BaseBg
        $in.SelectionFont = $G.InputFont
        $st = $s.Styles.spell
        for ($i = 0; $i + 1 -lt $show.Count; $i += 2) {
            $in.Select($show[$i], $show[$i + 1])
            $in.SelectionColor = ConvertTo-DrawColor $st.Fg $G.BaseFg
            if ($null -ne $st.Bg) { $in.SelectionBackColor = ConvertTo-DrawColor $st.Bg $G.BaseBg }
            $in.SelectionFont = $G.InputFontU
        }
        $in.Select($selS, $selL)
    } finally {
        [PsLilly.Win]::SetRedraw($in.Handle, $true)
        $in.Invalidate()
        $G.Programmatic = $false
    }
    $G.HadMarks = $show.Count -gt 0
}

# F7: replace the misspelled word at / before the cursor; again = next suggestion
function Invoke-SpellKey([bool]$shift) {
    if (-not $s.SpellReady) {
        if ($s.SpellNote) { Write-LillyNote $s $s.SpellNote 'error' }
        return
    }
    $text = $in.Text; $pos = $in.SelectionStart
    if ($G.Cycle -and -not $shift) {
        $c = $G.Cycle
        $c.Index = ($c.Index + 1) % $c.List.Count
        $new = $c.List[$c.Index]
        $in.Select($c.Start, $c.Len); $in.SelectedText = $new
        $c.Len = $new.Length
        $in.SelectionStart = $c.Start + $new.Length
        return
    }
    $r = Get-LillySpellRanges $s $text
    if ($r.Count -lt 2) { return }
    $pick = -1
    for ($i = 0; $i + 1 -lt $r.Count; $i += 2) {
        if ($r[$i] -le $pos -and $pos -le $r[$i] + $r[$i + 1]) { $pick = $i; break }
        if ($r[$i] + $r[$i + 1] -le $pos) { $pick = $i }
    }
    if ($pick -lt 0) { $pick = 0 }
    $start = $r[$pick]; $len = $r[$pick + 1]
    $word = $text.Substring($start, $len)
    if ($shift) {
        try { Add-LillySpellWord $word; Write-LillyNote $s "Added '$word' to your dictionary." } catch {}
        Update-InputSpelling
        return
    }
    $sugg = @(Get-LillySpellSuggestions $word | Where-Object { $_ })
    if ($sugg.Count -eq 0) { Write-LillyNote $s "No suggestions for '$word'."; return }
    $G.Cycle = @{ Start = $start; Len = $len; Index = 0; List = @($sugg) + @($word) }
    $in.Select($start, $len); $in.SelectedText = $sugg[0]
    $G.Cycle.Len = $sugg[0].Length
    $in.SelectionStart = $start + $sugg[0].Length
}

function Invoke-Completion {
    $r = Resolve-LillyCompletion $s $in.Text $in.SelectionStart $G.Complete
    if (-not [string]::Equals($r.Text, $in.Text, [StringComparison]::Ordinal)) {
        Save-Undo
        $G.Redo.Clear()
        Set-InputText $r.Text $r.Caret
    }
    $G.Complete = $r.State
    if ($r.Matches -and $r.Matches.Count -gt 1) {
        $list = @($r.Matches | Select-Object -First 30)
        $more = if ($r.Matches.Count -gt 30) { " (and $($r.Matches.Count - 30) more)" } else { '' }
        Write-LillyNote $s ('Matches: ' + ($list -join ', ') + $more) 'command'
    }
}

function Invoke-History([int]$dir) {
    if ($G.History.Count -eq 0) { return }
    $i = $G.HistIndex + $dir
    if ($i -lt 0 -or $i -gt $G.History.Count) { return }
    if ($G.HistIndex -eq $G.History.Count) { $G.Draft = $in.Text }
    $G.HistIndex = $i
    $new = if ($i -eq $G.History.Count) { $G.Draft } else { $G.History[$i] }
    Save-Undo
    Set-InputText $new $new.Length
}

function Paste-Plain {
    $t = ''
    try { $t = [System.Windows.Forms.Clipboard]::GetText() } catch {}
    if (-not $t) { return }
    $t = ($t -replace "\r?\n", ' ') -replace "`t", ' '
    $in.SelectionColor = $G.BaseFg
    $in.SelectionFont = $G.InputFont
    $in.SelectedText = $t.TrimEnd()
}

function Submit-Input {
    $line = $in.Text -replace "\r?\n", ' '
    if ($line -and ($G.History.Count -eq 0 -or $G.History[$G.History.Count - 1] -cne $line) -and
        $line -notmatch '^\s*(connect|conn|co)\s+\S+\s') {
        $G.History.Add($line)
        if ($G.History.Count -gt 200) { $G.History.RemoveAt(0) }
    }
    $G.HistIndex = $G.History.Count; $G.Draft = ''
    Set-InputText '' 0
    $G.Undo.Clear(); $G.Redo.Clear(); $G.LastKind = ''
    Move-Pane 7
    if ($line.StartsWith('$$')) { Invoke-Local $line.Substring(2) }
    else { Send-LillyUserLine $s $line }
    Read-Records
}

function Invoke-Local([string]$cmd) {
    $name = ($cmd.Trim() -split '\s+', 2)[0].ToLower()
    switch ($name) {
        'connect' { Start-Login -ForceDialog; return }
        'forget'  {
            if (Remove-LillySavedLogin $s.Server) { Write-LillyNote $s "Removed the saved password for $($s.Server)." }
            else { Write-LillyNote $s "No saved password for $($s.Server)." }
            return
        }
        'clear'   { $out.Clear(); Update-MoreBelow; return }
    }
    $r = Invoke-LillyLocalCommand $s $cmd
    if ($r -eq 'quit') { $form.Close() }
}

function Invoke-InputKey($e) {
    $k = $e.KeyCode
    $ctrl = $e.Control; $shift = $e.Shift; $alt = $e.Alt
    if ($k -ne $K::Tab) { $G.Complete = $null }
    if ($k -ne $K::F7) { $G.Cycle = $null }
    $handled = $true
    if ($k -eq $K::Enter) {
        if (-not $shift) { Submit-Input }
    }
    elseif ($k -eq $K::Tab -and -not $ctrl -and -not $alt) { Invoke-Completion }
    elseif ($k -eq $K::F7) { Invoke-SpellKey $shift }
    elseif ($k -eq $K::PageUp)   { Move-Pane 2 }
    elseif ($k -eq $K::PageDown) { Move-Pane 3 }
    elseif ($ctrl -and $k -eq $K::Home) { Move-Pane 6 }
    elseif ($ctrl -and $k -eq $K::End)  { Move-Pane 7 }
    elseif ($ctrl -and $k -eq $K::Up)   { Move-Pane 0 }
    elseif ($ctrl -and $k -eq $K::Down) { Move-Pane 1 }
    elseif ($k -eq $K::Up   -and -not $shift -and -not $alt) { Invoke-History -1 }
    elseif ($k -eq $K::Down -and -not $shift -and -not $alt) { Invoke-History 1 }
    elseif ($k -eq $K::Escape) {
        if ($in.TextLength) { Save-Undo; $G.Redo.Clear(); Set-InputText '' 0 }
    }
    elseif ($ctrl -and -not $alt -and $k -eq $K::Z) { Undo-Input }
    elseif ($ctrl -and -not $alt -and $k -eq $K::Y) { Undo-Input -Redo }
    elseif ($ctrl -and -not $alt -and $k -eq $K::A) { $in.SelectAll() }
    elseif (($ctrl -and -not $alt -and $k -eq $K::C) -or ($ctrl -and $k -eq $K::Insert)) {
        if ($in.SelectionLength) { [System.Windows.Forms.Clipboard]::SetText($in.SelectedText) }
    }
    elseif (($ctrl -and -not $alt -and $k -eq $K::X) -or ($shift -and $k -eq $K::Delete)) {
        if ($in.SelectionLength) { [System.Windows.Forms.Clipboard]::SetText($in.SelectedText); $in.SelectedText = '' }
    }
    elseif (($ctrl -and -not $alt -and $k -eq $K::V) -or ($shift -and $k -eq $K::Insert)) { Paste-Plain }
    elseif ($ctrl -and -not $alt -and $k -ge $K::A -and $k -le $K::Z) {
        # other Ctrl+letters would insert control characters or change alignment
    }
    else {
        $handled = $false
        if ($k -in @($K::Left, $K::Right, $K::Home, $K::End)) { $G.LastKind = '' }
    }
    if ($handled) { $e.SuppressKeyPress = $true; $e.Handled = $true }
}

# ---------------------------------------------------------------------------
# The window
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'PSLilly'
$form.KeyPreview = $false
$G.Icon = $null
$icoPath = Join-Path $PSScriptRoot 'pslilly.ico'
if (Test-Path -LiteralPath $icoPath) {
    try { $G.Icon = New-Object System.Drawing.Icon($icoPath); $form.Icon = $G.Icon } catch {}
}

$out = New-Object System.Windows.Forms.RichTextBox
$out.ReadOnly = $true
$out.Dock = 'Fill'
$out.BorderStyle = 'None'
$out.HideSelection = $false
$out.DetectUrls = $true
$out.ScrollBars = 'ForcedVertical'
$out.WordWrap = $true
$out.ShortcutsEnabled = $true   # keys are handled (and suppressed) in KeyDown below
$out.TabStop = $false

$sep = New-Object System.Windows.Forms.Panel
$sep.Dock = 'Bottom'
$sep.Height = 3

$in = New-Object System.Windows.Forms.RichTextBox
$in.Dock = 'Bottom'
$in.Multiline = $true
$in.WordWrap = $true
$in.ScrollBars = 'Vertical'
$in.AcceptsTab = $true
$in.DetectUrls = $false
$in.ShortcutsEnabled = $true    # keys are handled (and suppressed) in KeyDown below
$in.BorderStyle = 'None'

$status = New-Object System.Windows.Forms.StatusStrip
$stConn = New-Object System.Windows.Forms.ToolStripStatusLabel
$stConn.Spring = $true
$stConn.TextAlign = 'MiddleLeft'
$stConn.Text = 'Not connected'
$stCmd  = New-Object System.Windows.Forms.ToolStripStatusLabel
$stMore = New-Object System.Windows.Forms.ToolStripStatusLabel
$stMore.ForeColor = [System.Drawing.Color]::DarkOrange
$null = $status.Items.Add($stConn)
$null = $status.Items.Add($stCmd)
$null = $status.Items.Add($stMore)

# order matters for docking: the pane fills what's left above the others
$form.Controls.Add($out)
$form.Controls.Add($sep)
$form.Controls.Add($in)
$form.Controls.Add($status)

# right-click menus (no paste-on-click)
$outMenu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $outMenu.Items.Add('Copy', $null, { if ($out.SelectionLength) { [System.Windows.Forms.Clipboard]::SetText($out.SelectedText) } })
$null = $outMenu.Items.Add('Select all', $null, { $out.SelectAll() })
$null = $outMenu.Items.Add('Clear window', $null, { $out.Clear(); Update-MoreBelow })
$out.ContextMenuStrip = $outMenu

$inMenu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $inMenu.Items.Add('Undo', $null, { Undo-Input })
$null = $inMenu.Items.Add('Redo', $null, { Undo-Input -Redo })
$null = $inMenu.Items.Add('-')
$null = $inMenu.Items.Add('Cut', $null, { if ($in.SelectionLength) { [System.Windows.Forms.Clipboard]::SetText($in.SelectedText); $in.SelectedText = '' } })
$null = $inMenu.Items.Add('Copy', $null, { if ($in.SelectionLength) { [System.Windows.Forms.Clipboard]::SetText($in.SelectedText) } })
$null = $inMenu.Items.Add('Paste', $null, { Paste-Plain })
$null = $inMenu.Items.Add('Select all', $null, { $in.SelectAll() })
$in.ContextMenuStrip = $inMenu

# ---- events ----------------------------------------------------------------
$in.Add_KeyDown({
    param($sender, $e)
    try { Invoke-InputKey $e } catch { Show-UiError $_.Exception.Message }
})

$in.Add_KeyPress({
    param($sender, $e)
    try {
        $ch = $e.KeyChar
        if ([char]::IsControl($ch)) { return }
        if ($in.TextLength -eq 0) {
            $fill = $null
            if ($ch -eq ':' -and $s.LastFrom) { $fill = "$($s.LastFrom):" }
            elseif ($ch -eq ';' -and $s.LastTo) { $fill = "$($s.LastTo);" }
            if ($fill) { $e.Handled = $true; $in.SelectedText = $fill; return }
        }
        # new text in the plain style, not the red of a word next to it
        $in.SelectionColor = $G.BaseFg
        $in.SelectionBackColor = $G.BaseBg
        $in.SelectionFont = $G.InputFont
    } catch { Show-UiError $_.Exception.Message }
})

# Undo history: typing a word is one step; anything else is its own step
$in.Add_TextChanged({
    if ($G.Programmatic) { return }
    try {
        $new = $in.Text; $old = $G.LastText
        if ([string]::Equals($new, $old, [StringComparison]::Ordinal)) { return }
        $at = 0
        while ($at -lt $old.Length -and $at -lt $new.Length -and $new[$at] -ceq $old[$at]) { $at++ }
        $typed = ($new.Length -eq $old.Length + 1) -and ($new.Remove($at, 1) -ceq $old) -and ($new[$at] -cne ' ')
        if (-not ($typed -and $G.LastKind -eq 'type')) {
            $G.Undo.Add(@{ T = $old; P = $at })
            if ($G.Undo.Count -gt 200) { $G.Undo.RemoveAt(0) }
        }
        $G.Redo.Clear()
        $G.LastKind = if ($typed) { 'type' } else { 'other' }
        $G.LastText = $new
        Start-SpellTimer
    } catch { Show-UiError $_.Exception.Message }
})

# typing while the message pane has focus goes to the typing box
$out.Add_KeyPress({
    param($sender, $e)
    if ([char]::IsControl($e.KeyChar)) { return }
    $e.Handled = $true
    $in.Focus()
    $in.SelectionStart = $in.TextLength
    $in.SelectedText = [string]$e.KeyChar
})
$out.Add_KeyDown({
    param($sender, $e)
    try {
        $k = $e.KeyCode
        $handled = $true
        if (($e.Control -and -not $e.Alt -and $k -eq $K::C) -or ($e.Control -and $k -eq $K::Insert)) {
            if ($out.SelectionLength) { [System.Windows.Forms.Clipboard]::SetText($out.SelectedText) }
        } elseif ($e.Control -and -not $e.Alt -and $k -eq $K::A) {
            $out.SelectAll()
        } elseif ($e.Control -and -not $e.Alt -and $k -eq $K::V) {
            # paste goes to the typing box
            $in.Focus(); $in.SelectionStart = $in.TextLength; Paste-Plain
        } elseif ($k -eq $K::Enter) {
            $in.Focus()
        } elseif ($e.Control -and -not $e.Alt -and $k -ge $K::A -and $k -le $K::Z) {
            # other Ctrl+letters (alignment, line spacing...) do nothing here
        } else {
            $handled = $false
        }
        if ($handled) { $e.SuppressKeyPress = $true; $e.Handled = $true }
    } catch { Show-UiError $_.Exception.Message }
})
$out.Add_VScroll({ Update-MoreBelow })
$out.Add_LinkClicked({
    param($sender, $e)
    $u = $e.LinkText
    if ($u -match '^www\.') { $u = "http://$u" }
    if ($u -match '^https?://') { try { Start-Process $u } catch {} }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 50
$timer.Add_Tick({ Invoke-Pump })

$spellTimer = New-Object System.Windows.Forms.Timer
$spellTimer.Interval = 300
$spellTimer.Add_Tick({ try { Update-InputSpelling } catch { $spellTimer.Stop() } })
$in.Add_Leave({ Start-SpellTimer })

# window size and place: from last time, else 100 x 32 characters
function Restore-WindowPlace {
    $w = [string]$s.Cfg.window
    if ($w -match '^(-?\d+),(-?\d+),(\d+),(\d+)(,max)?$') {
        $rect = New-Object System.Drawing.Rectangle([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
        $onScreen = @([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.IntersectsWith($rect) }).Count -gt 0
        if ($onScreen -and $rect.Width -gt 200 -and $rect.Height -gt 150) {
            $form.StartPosition = 'Manual'
            $form.Bounds = $rect
            if ($Matches[5]) { $form.WindowState = 'Maximized' }
            return
        }
    }
    $lineH = [System.Windows.Forms.TextRenderer]::MeasureText('Ag', $G.BaseFont).Height
    $form.ClientSize = New-Object System.Drawing.Size([int]($G.CharWidth * 100 + 24), [int]($lineH * 32))
    $form.StartPosition = 'CenterScreen'
}

function Save-WindowPlace {
    $b = if ($form.WindowState -eq 'Normal') { $form.Bounds } else { $form.RestoreBounds }
    $v = "$($b.X),$($b.Y),$($b.Width),$($b.Height)" + $(if ($form.WindowState -eq 'Maximized') { ',max' } else { '' })
    if ($s.Cfg.window -ne $v) { $s.Cfg.window = $v; $s.FileCfg.window = $v; Save-LillyConfig $s }
}

$form.Add_Shown({
    try {
        $in.Focus()
        if (-not [PsLilly.Watcher]::Start()) { Write-LillyNote $s '(Could not watch for sleep/lock events.)' 'error' }
        $timer.Start()
        Start-Login -ForceDialog:$Login
    } catch { Show-UiError $_.Exception.Message }
})

$form.Add_FormClosing({
    try {
        $timer.Stop()
        Save-WindowPlace
        if ($s.State -ne 'disconnected') { Disconnect-LillySession $s -Goodbye }
        $null = Stop-LillyCommands $s
    } catch {}
})

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------
Update-Appearance
Restore-WindowPlace
Write-LillyNote $s "PSLilly $LillyVersion. Type `$`$ for settings and commands."
if ($s.SpellNote) { Write-LillyNote $s $s.SpellNote 'error' }
Read-Records
[System.Windows.Forms.Application]::Run($form)
