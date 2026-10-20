<#
.SYNOPSIS
    pslilly - a basic Lily chat client written in PowerShell.

.DESCRIPTION
    Connects to a Lily server over TCP and sends each line you type.

    With slcp on (the default) it speaks SLCP, the Simple Lily Client Protocol:
    the server sends structured events, so pslilly knows exactly which
    messages are public, private or emotes and who sent them, and formats
    them itself. With slcp off it shows the server's plain text output and
    colors it using the *_pattern settings.

    Settings live in lily.conf next to this script. It is created with
    defaults on first run, read at startup, and updated whenever you change a
    setting with a $$ command. You can also edit it by hand (then $$reload).

    Typing shortcuts (on an empty line):
        :   fills in the last person who sent to you   ->  alice:
        ;   fills in the last person you sent to       ->  bob;
    (Same as tigerlily and zephyrlily.)

    Spell checking (Windows only): misspelled words in your input line are
    shown in red (spell_fg). F7 replaces the word at or before the cursor with
    a suggestion; press F7 again to cycle through the others. Shift+F7 adds
    the word to your Windows dictionary. Commands (/, $$ ...), the "name:" at
    the start of a send, and user/discussion names are never flagged.

    Keepalive: after 5 quiet minutes (setting: keepalive, 0 = off) pslilly
    sends "#$# ping"; if the server doesn't answer within a minute you're
    told the connection may be dead.

    Lily is ASCII-only, so when a line is sent, smart quotes, dashes, accents,
    emoji and the like become plain ASCII (" ' -- e :) ...). Your input line
    is left as typed. Turn off with $$ascii off; see $$map for overrides.

    Editing: arrows, Ctrl+arrows (by word), Home/End, Backspace/Delete,
    Esc or Ctrl+U to clear, Up/Down for history, Ctrl+Z undo, Ctrl+Y redo.
    Shift+arrows (Ctrl+Shift by word, Shift+Home/End) select; Ctrl+C copies,
    Ctrl+X cuts, Ctrl+V pastes. Ctrl+C with nothing selected quits.

    Passwords are masked with * when the server shows a password prompt (or
    turns off echo), and in MOO-style "connect <name> <password>" lines.

    Local commands (never sent to the server) start with $$:
        $$                      list settings, commands and a color preview
        $$<setting>             show a setting (on/off settings toggle)
        $$<setting> <value>     change a setting and save it to lily.conf
        $$reload                re-read lily.conf
        $$map <char> <text>     send that character as <text> instead (off = built in)
        $$user <name> <fg> [on <bg>]   color private messages from that person
                                (e.g. $$user strider yellow on dark_red; off removes it)
        $$send <text>           send <text> to the server as-is
        $$quit                  disconnect (same as /!quit)

.NOTES
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/.

.EXAMPLE
    .\pslilly.ps1                      # uses default_server from lily.conf
.EXAMPLE
    .\pslilly.ps1 -Server other.host -Port 7777 -ShowSent
#>
param(
    [string]$Server,                 # overrides default_server for this session
    [int]$Port,                      # overrides default_port for this session
    [string]$LogFile,                # overrides logfile for this session
    [ValidateSet('UTF8', 'Latin1', 'ASCII')][string]$Encoding = 'UTF8',
    [switch]$ShowSent,               # overrides showsent for this session
    [string]$Config = (Join-Path $PSScriptRoot 'lily.conf')
)

# ---------------------------------------------------------------------------
# Settings. To add a new one, add it here; $$ listing, validation and saving
# pick it up automatically.  Types: string, int, bool, color, regex
# ---------------------------------------------------------------------------
$Schema = [ordered]@{
    default_server       = @{ Type = 'string'; Default = 'lily.acm.rpi.edu'; Help = 'server used when -Server is not given' }
    default_port         = @{ Type = 'int';    Default = '7777';             Help = 'port used when -Port is not given' }
    public_fg            = @{ Type = 'color';  Default = 'white';            Help = 'public message text' }
    public_bg            = @{ Type = 'color';  Default = 'dark_blue';        Help = 'public message background' }
    private_fg           = @{ Type = 'color';  Default = 'yellow';           Help = 'private message text' }
    private_bg           = @{ Type = 'color';  Default = 'dark_blue';        Help = 'private message background' }
    emote_fg             = @{ Type = 'color';  Default = 'purple';           Help = 'emote text' }
    emote_bg             = @{ Type = 'color';  Default = 'green';            Help = 'emote background' }
    base_fg              = @{ Type = 'color';  Default = 'default';          Help = 'normal text color for the whole window' }
    base_bg              = @{ Type = 'color';  Default = 'default';          Help = 'window background (repaints at start)' }
    system_fg            = @{ Type = 'color';  Default = 'default';          Help = 'arrivals, departures, blurbs, etc. (slcp)' }
    system_bg            = @{ Type = 'color';  Default = 'default';          Help = 'background for those' }
    spellcheck           = @{ Type = 'bool';   Default = 'on';               Help = 'spell check your typing (Windows only)' }
    spell_language       = @{ Type = 'string'; Default = 'auto';             Help = 'e.g. en-US, or auto = Windows language' }
    spell_fg             = @{ Type = 'color';  Default = 'red';              Help = 'misspelled words' }
    spell_bg             = @{ Type = 'color';  Default = 'default';          Help = 'background for those' }
    select_fg            = @{ Type = 'color';  Default = 'black';            Help = 'selected text in your input line' }
    select_bg            = @{ Type = 'color';  Default = 'gray';             Help = 'background for that' }
    keepalive            = @{ Type = 'int';    Default = '5';                Help = 'minutes of quiet before a keepalive ping (0 = off; SLCP)' }
    ascii                = @{ Type = 'bool';   Default = 'on';               Help = 'turn smart quotes, accents, emoji... into plain ASCII when sending' }
    accent_marks         = @{ Type = 'bool';   Default = 'off';              Help = 'keep a hint of accents: e-acute becomes e'' instead of e' }
    block_mouse          = @{ Type = 'bool';   Default = 'off';              Help = 'on = clicks don''t paste, but mouse selection is off too (Windows)' }
    slcp                 = @{ Type = 'bool';   Default = 'on';               Help = 'use SLCP (takes effect next connect)' }
    showsent            = @{ Type = 'bool';   Default = 'off';              Help = 'print the bytes of each line sent' }
    maskconnect          = @{ Type = 'bool';   Default = 'on';               Help = 'mask password in "connect name password"' }
    logfile              = @{ Type = 'string'; Default = '';                 Help = 'transcript file ("off" to stop)' }
    private_pattern      = @{ Type = 'regex';  Default = '^\s*>>\s*(\([\d:]+\)\s*)?Private message from (?<from>[^,:]+)'; Help = 'plain-text mode: private message (from = sender)' }
    public_pattern       = @{ Type = 'regex';  Default = '^\s*->\s*(\([\d:]+\)\s*)?From\s';  Help = 'plain-text mode: public message' }
    emote_pattern        = @{ Type = 'regex';  Default = '^\s*>\s+\S';       Help = 'plain-text mode: emote' }
    continuation_pattern = @{ Type = 'regex';  Default = '^\s*-\s';          Help = 'plain-text mode: body lines' }
}
# Alternate names accepted in the file or in $$ commands
$Aliases = @{ server = 'default_server'; port = 'default_port'; emote_fb = 'emote_fg' }

function ConvertTo-ConsoleColor([string]$name) {
    $n = ($name -replace '[\s_-]', '').ToLower()
    if (-not $n -or $n -in 'default', 'none', 'off') { return $null }
    $map = @{ purple = 'Magenta'; darkpurple = 'DarkMagenta'; grey = 'Gray'; darkgrey = 'DarkGray';
              lightgray = 'Gray'; lightgrey = 'Gray'; brown = 'DarkYellow'; orange = 'DarkYellow' }
    if ($map.ContainsKey($n)) { $n = $map[$n] }
    # Name lookup that works in both Windows PowerShell 5.1 and PowerShell 7
    $match = [Enum]::GetNames([ConsoleColor]) | Where-Object { $_ -eq $n } | Select-Object -First 1
    if ($match) { return [ConsoleColor]$match }
    throw "Unknown color '$name'. Try: black, dark_blue, dark_green, dark_cyan, dark_red, dark_purple, dark_yellow, gray, dark_gray, blue, green, cyan, red, purple, yellow, white, default"
}

function Read-ConfigFile([string]$path) {
    $vals = [ordered]@{}
    foreach ($k in $Schema.Keys) { $vals[$k] = $Schema[$k].Default }
    $complete = $false
    if (Test-Path -LiteralPath $path) {
        $seen = @{}
        foreach ($raw in Get-Content -LiteralPath $path) {
            $l = $raw.Trim()
            if (-not $l -or $l.StartsWith('#')) { continue }
            $i = $l.IndexOfAny([char[]]':=')
            if ($i -lt 1) { continue }
            $k = ($l.Substring(0, $i).Trim().ToLower()) -replace '[\s-]', '_'
            if ($Aliases.ContainsKey($k)) { $k = $Aliases[$k] }
            $vals[$k] = $l.Substring($i + 1).Trim()
            $seen[$k] = $true
        }
        $complete = @($Schema.Keys | Where-Object { -not $seen.ContainsKey($_) }).Count -eq 0
    }
    return @{ Values = $vals; Complete = $complete }
}

function Save-ConfigFile {
    $lines = @(
        '# pslilly.ps1 settings. Edit here (then $$reload in the client) or with $$<setting> <value>.',
        '# Colors: black, dark_blue, dark_green, dark_cyan, dark_red, dark_purple, dark_yellow,',
        '#         gray, dark_gray, blue, green, cyan, red, purple, yellow, white, default',
        ''
    )
    foreach ($k in $FileCfg.Keys) { $lines += "${k}: $($FileCfg[$k])" }
    try {
        Set-Content -LiteralPath $Config -Value $lines -Encoding UTF8
    } catch {
        Write-Host "Could not save ${Config}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function ConvertTo-Bool([string]$v) { $v -match '^(on|true|1|yes)$' }

# Per-user colors: "yellow", "yellow on dark_red", "on dark_red" or "yellow dark_red"
function ConvertTo-UserStyle([string]$v) {
    # bold / italic / underline are for the window version (pslilly-gui.ps1); ignored here
    $v = (("$v" -replace '\b(bold|italic|underline|normal)\b', ' ') -replace '\s+', ' ').Trim()
    if (-not $v -or $v -match '^(off|none)$') { return $null }
    $fgName = $v; $bgName = ''
    if ($v -match '^(.*?)\s*\bon\s+(\S+)$')   { $fgName = $Matches[1]; $bgName = $Matches[2] }
    elseif ($v -match '^(\S+)\s+(\S+)$')      { $fgName = $Matches[1]; $bgName = $Matches[2] }
    $fg = if ($fgName) { ConvertTo-ConsoleColor $fgName } else { $null }
    $bg = if ($bgName) { ConvertTo-ConsoleColor $bgName } else { $null }
    return ,@($fg, $bg)
}

# Config key for a user's color: user_<name>, lower case, spaces/dashes as _
function Get-UserKey([string]$name) { 'user_' + ($name.Trim().ToLower() -replace '[\s-]+', '_') }

# Recompute the typed values the reader and input loop use
function Update-Derived {
    $sync.BaseFg = $null; $sync.BaseBg = $null
    try { $sync.BaseFg = ConvertTo-ConsoleColor $Cfg.base_fg } catch { Write-Host $_ -ForegroundColor Red }
    try { $sync.BaseBg = ConvertTo-ConsoleColor $Cfg.base_bg } catch { Write-Host $_ -ForegroundColor Red }
    $sync.ShowSent    = ConvertTo-Bool $Cfg.showsent
    $sync.MaskConnect = ConvertTo-Bool $Cfg.maskconnect
    $sync.LogFile     = if ($Cfg.logfile) { $Cfg.logfile } else { $null }
    if (-not $sync.Connecting) { $sync.Slcp = ConvertTo-Bool $Cfg.slcp }  # fixed once connected
    foreach ($cls in 'public', 'private', 'emote', 'system', 'spell', 'select') {
        $fg = $null; $bg = $null
        try { $fg = ConvertTo-ConsoleColor $Cfg["${cls}_fg"] } catch { Write-Host $_ -ForegroundColor Red }
        try { $bg = ConvertTo-ConsoleColor $Cfg["${cls}_bg"] } catch { Write-Host $_ -ForegroundColor Red }
        $sync.Style[$cls] = @($fg, $bg)
    }
    $us = @{}
    foreach ($k in @($Cfg.Keys)) {
        if ($k -notlike 'user_*') { continue }
        try {
            $st = ConvertTo-UserStyle $Cfg[$k]
            if ($st) { $us[$k] = $st }
        } catch { Write-Host "${k}: $_" -ForegroundColor Red }
    }
    $sync.UserStyle = [hashtable]::Synchronized($us)
    $script:AsciiUser = @{}
    foreach ($k in @($Cfg.Keys)) {
        if ($k -match '^map_u\+?([0-9a-f]{2,6})$') {
            $v = [string]$Cfg[$k]
            if ($v -match '^"(.*)"$') { $v = $Matches[1] }
            $script:AsciiUser[[Convert]::ToInt32($Matches[1], 16)] = $v
        }
    }
    $script:AccentMarks = ConvertTo-Bool $Cfg.accent_marks
    foreach ($p in 'private', 'public', 'emote', 'continuation') {
        $pat = $Cfg["${p}_pattern"]
        $sync.Rx[$p] = $null
        if ($pat) {
            try { $sync.Rx[$p] = [regex]::new($pat, 'IgnoreCase') }
            catch { Write-Host "Bad ${p}_pattern: $($_.Exception.Message)" -ForegroundColor Red }
        }
    }
}

# ---------------------------------------------------------------------------
# Load settings
# ---------------------------------------------------------------------------
$sync = [hashtable]::Synchronized(@{
    Running    = $true
    Tail       = ''      # last bit of server output, used to spot the password prompt
    ServerEcho = $false  # true when the server says IAC WILL ECHO (usually = password)
    LastTo     = $null   # last person you sent to     (; shortcut)
    LastFrom   = $null   # last person who sent to you (: shortcut)
    LoginName  = $null   # name typed at the login prompt (window title)
    LoggedIn   = $false  # SLCP login finished (%connected)
    BaseFg     = $null   # base window colors (base_fg / base_bg), $null = console default
    BaseBg     = $null
    LastActivity = [DateTime]::UtcNow   # last time anything was sent or received
    PingSentAt = $null   # keepalive ping waiting for its %pong
    PingWarned = $false  # told you the connection looks dead
    Lock       = [object]::new()   # console output
    SendLock   = [object]::new()   # socket writes
    Slcp       = $true
    Connecting = $false
    OptionsSent = $false
    WhoAmI     = $null   # our own handle, e.g. #850 (SLCP)
    InActive   = $false  # input line on screen (line editor state, used by both threads)
    InDisplay  = ''      #   what's shown (passwords as *)
    InCursor   = 0       #   cursor position within it
    InLeft     = 0       #   screen column where it starts
    InTop      = 0       #   screen row where it starts
    InErrors   = @()     #   misspellings to color: start, length, start, length...
    InSel      = @()     #   selected text: start, length
    UserStyle  = @{}     # user_<name> -> @(fg, bg) for private messages from that person
    NameSet    = [hashtable]::Synchronized(@{})  # words in user/discussion names (never misspelled)
    Version    = '0.6'
    Style      = [hashtable]::Synchronized(@{})
    Rx         = [hashtable]::Synchronized(@{})
})

$loaded  = Read-ConfigFile $Config
$FileCfg = $loaded.Values                 # what's saved in lily.conf
if (-not $loaded.Complete) { Save-ConfigFile }   # create it / add new settings
$Cfg = [ordered]@{}                       # what this session uses
foreach ($k in $FileCfg.Keys) { $Cfg[$k] = $FileCfg[$k] }
if ($PSBoundParameters.ContainsKey('LogFile'))  { $Cfg.logfile  = $LogFile }
if ($PSBoundParameters.ContainsKey('ShowSent')) { $Cfg.showsent = if ($ShowSent) { 'on' } else { 'off' } }
Update-Derived

# Base window colors: set them, and repaint the window if the background changed
function Set-BaseColors([switch]$Repaint) {
    try {
        if ($null -ne $sync.BaseFg) { [Console]::ForegroundColor = $sync.BaseFg }
        if ($null -ne $sync.BaseBg) { [Console]::BackgroundColor = $sync.BaseBg }
        if ($Repaint -and $null -ne $sync.BaseBg) { [Console]::Clear() }
    } catch {}
}
Set-BaseColors -Repaint

# ---------------------------------------------------------------------------
# ASCII folding. Lily is ASCII-only, so before a line is sent, smart quotes,
# dashes, accented letters, emoji and so on are replaced with plain ASCII.
# Your input line is left alone (URLs you paste don't change as you type).
#
# The tables below and the order of the rules in ConvertTo-LilyAsciiChar are
# derived from ZephyrLily's internal/ascify/ascify.go
# (https://github.com/joshw/zephyrlily), licensed under the Mozilla Public
# License 1.1. MPL 1.1 section 6.2 allows using such code under a later version
# of the license; it is used here under the MPL 2.0, like the rest of this file.
# ---------------------------------------------------------------------------
$AsciiMap = @{
    0xA0 = ' '
    0xA1 = '!'
    0xA2 = 'cents'
    0xA3 = 'GBP'
    0xA4 = '$'
    0xA5 = 'JPY'
    0xA6 = '|'
    0xA7 = 'S'
    0xA8 = ':'
    0xA9 = '(c)'
    0xAB = '<<'
    0xAC = '!'
    0xAD = '-'
    0xAE = '(r)'
    0xAF = '-'
    0xB0 = '*'
    0xB1 = '+/-'
    0xB2 = '^2'
    0xB3 = '^3'
    0xB4 = ''''
    0xB5 = 'u'
    0xB6 = '[|P]'
    0xB7 = '.'
    0xB8 = ','
    0xB9 = '^1'
    0xBB = '>>'
    0xBC = '1/4'
    0xBD = '1/2'
    0xBE = '3/4'
    0xBF = '?'
    0xC6 = 'AE'
    0xD7 = 'x'
    0xDF = 'ss'
    0xE6 = 'ae'
    0xF7 = '/'
    0x2B9 = ''''
    0x2BA = '"'
    0x2BB = ''''
    0x2BC = ''''
    0x2C6 = '^'
    0x2C7 = 'v'
    0x2C8 = ''''
    0x2CA = ''''
    0x2CB = '`'
    0x2D9 = '.'
    0x2DA = '*'
    0x2DC = '~'
    0x2DD = '"'
    0xE3F = 'THB'
    0x2010 = '-'
    0x2011 = '-'
    0x2012 = '-'
    0x2013 = '-'
    0x2014 = '--'
    0x2015 = '--'
    0x2016 = '||'
    0x2017 = '='
    0x2018 = ''''
    0x2019 = ''''
    0x201A = ','
    0x201B = ''''
    0x201C = '"'
    0x201D = '"'
    0x201E = ',,'
    0x201F = '"'
    0x2020 = '[t]'
    0x2021 = '[tt]'
    0x2022 = '-'
    0x2023 = '-'
    0x2024 = '.'
    0x2025 = '..'
    0x2026 = '...'
    0x2027 = '.'
    0x2030 = '%%'
    0x2032 = ''''
    0x2033 = '"'
    0x2034 = ''''''''
    0x2035 = ''''
    0x2036 = '"'
    0x2038 = '^'
    0x2039 = '<'
    0x203A = '>'
    0x203B = '*'
    0x203C = '!!'
    0x203D = '?!'
    0x203E = '-'
    0x2043 = '-'
    0x2044 = '/'
    0x2047 = '??'
    0x2048 = '?!'
    0x2049 = '!?'
    0x2053 = '~'
    0x20A6 = 'NGN'
    0x20A9 = 'KRW'
    0x20AA = 'ILS'
    0x20AB = 'VND'
    0x20AC = 'EUR'
    0x20B1 = 'PHP'
    0x20B4 = 'UAH'
    0x20B8 = 'KZT'
    0x20B9 = 'INR'
    0x20BA = 'TRY'
    0x20BD = 'RUB'
    0x20BE = 'GEL'
    0x20BF = 'BTC'
    0x2117 = '(p)'
    0x2120 = '(sm)'
    0x2122 = '(tm)'
    0x2190 = '<-'
    0x2191 = '^'
    0x2192 = '->'
    0x2193 = 'v'
    0x2194 = '<->'
    0x2195 = '^v'
    0x21A9 = '<-'
    0x21AA = '->'
    0x21D0 = '<='
    0x21D1 = '^'
    0x21D2 = '=>'
    0x21D3 = 'v'
    0x21D4 = '<=>'
    0x2205 = '{}'
    0x220F = 'prod'
    0x2211 = 'sum'
    0x2212 = '-'
    0x2213 = '-/+'
    0x2215 = '/'
    0x2216 = '\'
    0x2217 = '*'
    0x2219 = '*'
    0x221A = 'sqrt'
    0x221E = 'inf'
    0x2227 = '&&'
    0x2228 = '||'
    0x222B = 'int'
    0x2245 = '~='
    0x2248 = '~='
    0x2260 = '!='
    0x2261 = '=='
    0x2264 = '<='
    0x2265 = '>='
    0x226A = '<<'
    0x226B = '>>'
    0x22C5 = '.'
    0x22EE = ':'
    0x22EF = '...'
    0x25E6 = '-'
    0x2605 = '*'
    0x2606 = '*'
    0x2610 = '[ ]'
    0x2611 = '[x]'
    0x2612 = '[x]'
    0x2639 = ':('
    0x263A = ':)'
    0x26A0 = '[!]'
    0x2705 = '[ok]'
    0x2713 = '[ok]'
    0x2714 = '[ok]'
    0x2715 = 'x'
    0x2716 = '[x]'
    0x2717 = '[x]'
    0x2718 = '[x]'
    0x274C = '[x]'
    0x274E = '[x]'
    0x2753 = '?'
    0x2757 = '!'
    0x2764 = '<3'
    0x27A1 = '->'
    0x2B05 = '<-'
    0x2B06 = '^'
    0x2B07 = 'v'
    0x2B50 = '*'
    0x1F44D = '(y)'
    0x1F44E = '(n)'
    0x1F47F = '>:('
    0x1F494 = '</3'
    0x1F495 = '<3'
    0x1F496 = '<3'
    0x1F497 = '<3'
    0x1F499 = '<3'
    0x1F49A = '<3'
    0x1F49B = '<3'
    0x1F49C = '<3'
    0x1F600 = ':D'
    0x1F601 = ':D'
    0x1F602 = ':''D'
    0x1F603 = ':D'
    0x1F604 = ':D'
    0x1F605 = ':D'
    0x1F606 = 'XD'
    0x1F607 = 'O:)'
    0x1F608 = '>:)'
    0x1F609 = ';)'
    0x1F60A = ':)'
    0x1F60B = ':P'
    0x1F60C = ':)'
    0x1F60D = '<3'
    0x1F60E = 'B)'
    0x1F60F = ':>'
    0x1F610 = ':|'
    0x1F611 = ':|'
    0x1F612 = ':/'
    0x1F613 = ':''('
    0x1F614 = ':('
    0x1F615 = ':/'
    0x1F616 = '>_<'
    0x1F617 = ':*'
    0x1F618 = ':*'
    0x1F619 = ':*'
    0x1F61A = ':*'
    0x1F61B = ':P'
    0x1F61C = ';P'
    0x1F61D = 'XP'
    0x1F61E = ':('
    0x1F61F = ':('
    0x1F620 = '>:('
    0x1F621 = '>:('
    0x1F622 = ':''('
    0x1F623 = '>_<'
    0x1F624 = '>:('
    0x1F625 = ':''('
    0x1F626 = 'D:'
    0x1F627 = 'D:'
    0x1F628 = 'D:'
    0x1F629 = 'D:'
    0x1F62A = '|)'
    0x1F62B = 'D:'
    0x1F62C = ':E'
    0x1F62D = ':''('
    0x1F62E = ':O'
    0x1F62F = ':O'
    0x1F631 = 'D:'
    0x1F632 = ':O'
    0x1F633 = ':O'
    0x1F634 = '|)'
    0x1F635 = '%)'
    0x1F636 = ':x'
    0x1F637 = ':x'
    0x1F638 = ':3'
    0x1F639 = ':''3'
    0x1F63A = ':3'
    0x1F63B = ':3'
    0x1F63C = ':3'
    0x1F63D = ':3'
    0x1F641 = ':('
    0x1F642 = ':)'
    0x1F643 = '(:'
    0x1F644 = '9_9'
    0x1F910 = ':x'
    0x1F912 = ':('
    0x1F913 = '8)'
    0x1F914 = ':?'
    0x1F915 = ':('
    0x1F917 = '>:D<'
    0x1F922 = ':&'
    0x1F923 = ':''D'
    0x1F92A = '%)'
    0x1F92C = '>:('
    0x1F92E = ':&'
    0x1F92F = ':O'
    0x1F970 = '<3'
    0x1F973 = '\o/'
    0x1F974 = ';}'
    0x1F97A = ':('
    0x1F9D0 = ':?'
    0x1F9E1 = '<3'
}
$AsciiAccented = @{
    0xC0 = @('A', 'A`')
    0xC1 = @('A', 'A''')
    0xC2 = @('A', 'A^')
    0xC3 = @('A', 'A~')
    0xC4 = @('A', 'A:')
    0xC5 = @('A', 'A*')
    0xC7 = @('C', 'C,')
    0xC8 = @('E', 'E`')
    0xC9 = @('E', 'E''')
    0xCA = @('E', 'E^')
    0xCB = @('E', 'E:')
    0xCC = @('I', 'I`')
    0xCD = @('I', 'I''')
    0xCE = @('I', 'I^')
    0xCF = @('I', 'I:')
    0xD1 = @('N', 'N~')
    0xD2 = @('O', 'O`')
    0xD3 = @('O', 'O''')
    0xD4 = @('O', 'O^')
    0xD5 = @('O', 'O~')
    0xD6 = @('O', 'O:')
    0xD8 = @('O', '0')
    0xD9 = @('U', 'U`')
    0xDA = @('U', 'U''')
    0xDB = @('U', 'U^')
    0xDC = @('U', 'U:')
    0xDD = @('Y', 'Y''')
    0xE0 = @('a', 'a`')
    0xE1 = @('a', 'a''')
    0xE2 = @('a', 'a^')
    0xE3 = @('a', 'a~')
    0xE4 = @('a', 'a:')
    0xE5 = @('a', 'a*')
    0xE7 = @('c', 'c,')
    0xE8 = @('e', 'e`')
    0xE9 = @('e', 'e''')
    0xEA = @('e', 'e^')
    0xEB = @('e', 'e:')
    0xEC = @('i', 'i`')
    0xED = @('i', 'i''')
    0xEE = @('i', 'i^')
    0xEF = @('i', 'i:')
    0xF1 = @('n', 'n~')
    0xF2 = @('o', 'o`')
    0xF3 = @('o', 'o''')
    0xF4 = @('o', 'o^')
    0xF5 = @('o', 'o~')
    0xF6 = @('o', 'o:')
    0xF8 = @('o', '0')
    0xF9 = @('u', 'u`')
    0xFA = @('u', 'u''')
    0xFB = @('u', 'u^')
    0xFC = @('u', 'u:')
    0xFD = @('y', 'y''')
    0xFF = @('y', 'y:')
}
$AsciiLatinFallback = @{
    0xD0 = 'D'
    0xDE = 'Th'
    0xF0 = 'd'
    0xFE = 'th'
    0x110 = 'D'
    0x111 = 'd'
    0x126 = 'H'
    0x127 = 'h'
    0x131 = 'i'
    0x138 = 'k'
    0x141 = 'L'
    0x142 = 'l'
    0x14A = 'NG'
    0x14B = 'ng'
    0x152 = 'OE'
    0x153 = 'oe'
    0x166 = 'T'
    0x167 = 't'
    0x17F = 's'
    0x180 = 'b'
    0x18F = 'E'
    0x192 = 'f'
    0x197 = 'I'
    0x19F = 'O'
    0x237 = 'j'
    0x244 = 'U'
    0x259 = 'e'
    0x268 = 'i'
    0x275 = 'o'
    0x289 = 'u'
    0x1E9E = 'SS'
}
$AsciiAccentMarks = @{
    0x300 = '`'
    0x301 = ''''
    0x302 = '^'
    0x303 = '~'
    0x304 = '-'
    0x306 = ')'
    0x307 = '.'
    0x308 = ':'
    0x309 = '?'
    0x30A = '*'
    0x30B = ''''''
    0x30C = 'v'
    0x327 = ','
    0x328 = ','
    0x338 = '/'
}

$script:AsciiUser   = @{}       # your own overrides (map_u+XXXX in lily.conf)
$script:AccentMarks = $false    # e-acute -> e' instead of e
$AsciiHangulFillers = @(0x115F, 0x1160, 0x3164, 0xFFA0)

# '^' for superscripts, '_' for subscripts, '' otherwise
function Get-AsciiScriptClass([int]$cp) {
    if ($cp -in 0xB2, 0xB3, 0xB9 -or ($cp -ge 0x2070 -and $cp -le 0x207F)) { return '^' }
    if ($cp -ge 0x2080 -and $cp -le 0x209C) { return '_' }
    return ''
}

# Box drawing, blocks and shapes: approximated by orientation
function Get-AsciiLineArt([int]$cp) {
    if ($cp -ge 0x2500 -and $cp -le 0x257F) {
        if ($cp -in @(0x2500, 0x2501, 0x2504, 0x2505, 0x2508, 0x2509, 0x2550, 0x254C, 0x254D, 0x2574, 0x2576, 0x2578, 0x257A, 0x257C, 0x257E)) { return '-' }
        if ($cp -in @(0x2502, 0x2503, 0x2506, 0x2507, 0x250A, 0x250B, 0x2551, 0x254E, 0x254F, 0x2575, 0x2577, 0x2579, 0x257B, 0x257D, 0x257F)) { return '|' }
        if ($cp -in @(0x2571, 0x2572, 0x2573)) { return '/' }
        return '+'
    }
    if ($cp -ge 0x2580 -and $cp -le 0x259F) { if ($cp -in @(0x2591, 0x2592)) { return ':' }; return '#' }
    if ($cp -ge 0x25A0 -and $cp -le 0x25FF) {
        if ($cp -in @(0x25B6, 0x25B7, 0x25BA, 0x25BB)) { return '>' }
        if ($cp -in @(0x25C0, 0x25C1, 0x25C4, 0x25C5)) { return '<' }
        if ($cp -in @(0x25B2, 0x25B3, 0x25B4, 0x25B5)) { return '^' }
        if ($cp -in @(0x25BC, 0x25BD, 0x25BE, 0x25BF)) { return 'v' }
        return '*'
    }
    return $null
}

# ASCII for one character (code point), or $null if there's no good one
function ConvertTo-LilyAsciiChar([int]$cp, [int]$depth = 0) {
    if ($cp -lt 128) { return [string][char]$cp }
    if ($script:AsciiUser.ContainsKey($cp))   { return $script:AsciiUser[$cp] }
    if ($AsciiMap.ContainsKey($cp))           { return $AsciiMap[$cp] }
    if ($AsciiAccented.ContainsKey($cp))      { return $AsciiAccented[$cp][[int]$script:AccentMarks] }
    if ($AsciiLatinFallback.ContainsKey($cp)) { return $AsciiLatinFallback[$cp] }
    if ($cp -ge 0xD800 -and $cp -le 0xDFFF)   { return $null }   # broken surrogate
    $s   = [char]::ConvertFromUtf32($cp)
    $cat = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($s, 0)
    if ($cp -eq 0x85 -or $cat -in 'SpaceSeparator', 'LineSeparator', 'ParagraphSeparator') { return ' ' }
    if ($cp -ge 0x1F3FB -and $cp -le 0x1F3FF) { return '' }      # emoji skin tones
    if ($cp -in $AsciiHangulFillers)          { return '' }      # invisible fillers
    if ($cp -ge 0x1F1E6 -and $cp -le 0x1F1FF) { return [string][char](65 + $cp - 0x1F1E6) }   # flags -> "US"
    $art = Get-AsciiLineArt $cp
    if ($null -ne $art) { return $art }
    if ($depth -ge 3) { return $null }
    # Split into base letter + accents (also handles full-width letters,
    # fancy math letters, ligatures, circled numbers...)
    $d = $s.Normalize([Text.NormalizationForm]::FormKD)
    if ([string]::Equals($d, $s, [StringComparison]::Ordinal)) { return $null }   # (-eq would call these equal)
    $out = ''
    for ($i = 0; $i -lt $d.Length; $i++) {
        $c2 = [int]$d[$i]
        if ([char]::IsHighSurrogate($d[$i]) -and $i + 1 -lt $d.Length) { $c2 = [char]::ConvertToUtf32($d[$i], $d[$i + 1]); $i++ }
        $cat2 = [Globalization.CharUnicodeInfo]::GetUnicodeCategory([char]::ConvertFromUtf32($c2), 0)
        if ($cat2 -in 'NonSpacingMark', 'EnclosingMark') {
            if ($script:AccentMarks -and $AsciiAccentMarks.ContainsKey($c2)) { $out += $AsciiAccentMarks[$c2] }
            continue
        }
        $r = ConvertTo-LilyAsciiChar $c2 ($depth + 1)
        if ($null -eq $r) { return $null }
        $out += $r
    }
    $cls = Get-AsciiScriptClass $cp
    if ($cls) { $out = $cls + $out }
    return $out
}

# Fold a whole line to ASCII; anything with no ASCII form becomes '?'
function ConvertTo-LilyAscii([string]$text) {
    if ($text -notmatch '[^\x00-\x7F]') { return $text }
    $sb = [System.Text.StringBuilder]::new()
    $prev = ''
    for ($i = 0; $i -lt $text.Length; $i++) {
        $ch = $text[$i]
        if ([char]::IsHighSurrogate($ch) -and $i + 1 -lt $text.Length -and [char]::IsLowSurrogate($text[$i + 1])) {
            $cp = [char]::ConvertToUtf32($ch, $text[$i + 1]); $i++
        } else {
            $cp = [int]$ch
        }
        $a = ConvertTo-LilyAsciiChar $cp
        if ($null -ne $a) {
            # A run of superscripts/subscripts gets one marker: x_10, not x_1_0
            $cls = Get-AsciiScriptClass $cp
            if ($cls -and $cls -eq $prev -and $a.Length -gt 0 -and [string]$a[0] -eq $cls) { $a = $a.Substring(1) }
            $prev = $cls
            $null = $sb.Append($a)
            continue
        }
        $prev = ''
        $cat = if ($cp -ge 0xD800 -and $cp -le 0xDFFF) { 'Surrogate' }
               else { [string][Globalization.CharUnicodeInfo]::GetUnicodeCategory([char]::ConvertFromUtf32($cp), 0) }
        if ($cat -in 'NonSpacingMark', 'EnclosingMark', 'Format') {
            # invisible joiners, variation selectors, loose accents
            if ($script:AccentMarks -and $AsciiAccentMarks.ContainsKey($cp)) { $null = $sb.Append($AsciiAccentMarks[$cp]) }
            continue
        }
        $null = $sb.Append('?')
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Spell checking through the Windows spell checker (Windows 8 and later), the
# same one Edge and other apps use, including your personal dictionary.
# ---------------------------------------------------------------------------
$WinSpellCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace PsLilly {
    [ComImport, Guid("8E018A9D-2415-4677-BF08-794EA61F94BB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISpellCheckerFactory {
        IEnumString get_SupportedLanguages();
        [return: MarshalAs(UnmanagedType.Bool)]
        bool IsSupported([MarshalAs(UnmanagedType.LPWStr)] string languageTag);
        ISpellChecker CreateSpellChecker([MarshalAs(UnmanagedType.LPWStr)] string languageTag);
    }

    [ComImport, Guid("B6FD0B71-E2BC-4653-8D05-F197E412770B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISpellChecker {
        [return: MarshalAs(UnmanagedType.LPWStr)] string get_LanguageTag();
        IEnumSpellingError Check([MarshalAs(UnmanagedType.LPWStr)] string text);
        IEnumString Suggest([MarshalAs(UnmanagedType.LPWStr)] string word);
        void Add([MarshalAs(UnmanagedType.LPWStr)] string word);
        void Ignore([MarshalAs(UnmanagedType.LPWStr)] string word);
    }

    [ComImport, Guid("803E3BD4-2828-4410-8290-418D1D73C762"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IEnumSpellingError {
        [PreserveSig] int Next(out ISpellingError value);
    }

    [ComImport, Guid("B7C82D61-FBE8-4B47-9B27-6C0D2E0DE0A3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISpellingError {
        uint get_StartIndex();
        uint get_Length();
        int get_CorrectiveAction();
        [return: MarshalAs(UnmanagedType.LPWStr)] string get_Replacement();
    }

    public static class WinSpell {
        static ISpellChecker checker;

        // Returns null on success, or a reason it couldn't start.
        public static string Init(string language) {
            Type t = Type.GetTypeFromCLSID(new Guid("7AB36653-1796-484B-BDFA-E74F1DB7C1DC"));
            ISpellCheckerFactory f = (ISpellCheckerFactory)Activator.CreateInstance(t);
            if (!f.IsSupported(language)) {
                return "Windows has no spell checker for " + language + ". Add the language in Windows Settings, or set spell_language.";
            }
            checker = f.CreateSpellChecker(language);
            return null;
        }

        // Start, length pairs for each problem found
        public static int[] Check(string text) {
            List<int> found = new List<int>();
            if (checker == null || string.IsNullOrEmpty(text)) { return found.ToArray(); }
            IEnumSpellingError errors = checker.Check(text);
            ISpellingError e;
            while (errors.Next(out e) == 0 && e != null) {
                if (e.get_CorrectiveAction() != 0) {
                    found.Add((int)e.get_StartIndex());
                    found.Add((int)e.get_Length());
                }
                Marshal.ReleaseComObject(e);
            }
            Marshal.ReleaseComObject(errors);
            return found.ToArray();
        }

        public static string[] Suggest(string word) {
            List<string> list = new List<string>();
            if (checker == null) { return list.ToArray(); }
            IEnumString e = checker.Suggest(word);
            if (e == null) { return list.ToArray(); }
            string[] one = new string[1];
            while (e.Next(1, one, IntPtr.Zero) == 0) { list.Add(one[0]); }
            Marshal.ReleaseComObject(e);
            return list.ToArray();
        }

        public static void Add(string word) { if (checker != null) { checker.Add(word); } }
    }
}
'@

$script:SpellReady = $false
$script:SpellNote  = $null
function Initialize-Spell {
    $script:SpellReady = $false
    $script:SpellNote  = $null
    if (-not (ConvertTo-Bool $Cfg.spellcheck)) { return }
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $script:SpellNote = 'Spell checking needs Windows, so it is off here.'
        return
    }
    try {
        if (-not ('PsLilly.WinSpell' -as [type])) { Add-Type -TypeDefinition $WinSpellCode -Language CSharp }
        $lang = if ($Cfg.spell_language -and $Cfg.spell_language -ne 'auto') { $Cfg.spell_language }
                else { [Globalization.CultureInfo]::CurrentUICulture.Name }
        $err = [PsLilly.WinSpell]::Init($lang)
        if ($err) { $script:SpellNote = $err; return }
        $script:SpellReady = $true
    } catch {
        $script:SpellNote = "Spell checking couldn't start: $($_.Exception.Message)"
    }
}

# Misspellings in the typed text as start, length pairs.
function Get-SpellRanges([string]$text) {
    $none = [int[]]@()
    if (-not $script:SpellReady -or -not $text) { return ,$none }
    if ($text -match '^\s*[/$?%#]') { return ,$none }          # commands, $$, #$#
    if (Test-ConnectMask $text) { return ,$none }               # "connect name password"
    $off = 0
    if ($text -match '^[^\s:;]+[:;]') { $off = $Matches[0].Length }   # the "name:" part of a send
    $body = $text.Substring($off)
    $raw = @()
    try { $raw = Get-SpellErrors $body } catch { return ,$none }
    $out = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i + 1 -lt $raw.Count; $i += 2) {
        $word = $body.Substring($raw[$i], $raw[$i + 1])
        if ($sync.NameSet.ContainsKey($word.ToLower())) { continue }
        if ($word -match '://|@|\d') { continue }
        $out.Add($raw[$i] + $off); $out.Add($raw[$i + 1])
    }
    return ,$out.ToArray()
}

function Get-SpellErrors([string]$text)      { [PsLilly.WinSpell]::Check($text) }
function Get-SpellSuggestions([string]$word) { [PsLilly.WinSpell]::Suggest($word) }
function Add-SpellWord([string]$word)        { [PsLilly.WinSpell]::Add($word) }

# Stop mouse clicks from pasting: the console sends clicks to pslilly (which
# ignores them) instead of acting on them. Windows only; restored on exit.
$ConsoleModeCode = @'
using System;
using System.Runtime.InteropServices;
namespace PsLilly {
    public static class ConMode {
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int n);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint m);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr h, uint m);
        static uint saved;
        static bool changed;
        const uint MOUSE_INPUT = 0x10, QUICK_EDIT = 0x40, EXTENDED_FLAGS = 0x80;

        public static bool BlockMouse() {
            IntPtr h = GetStdHandle(-10);
            uint m;
            if (!GetConsoleMode(h, out m)) { return false; }
            if (!changed) { saved = m; }
            if (!SetConsoleMode(h, (m | EXTENDED_FLAGS | MOUSE_INPUT) & ~QUICK_EDIT)) { return false; }
            changed = true;
            return true;
        }

        public static void Restore() {
            if (changed) { SetConsoleMode(GetStdHandle(-10), saved); changed = false; }
        }
    }
}
'@

function Set-MouseMode {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return }
    try {
        if (-not ('PsLilly.ConMode' -as [type])) { Add-Type -TypeDefinition $ConsoleModeCode -Language CSharp }
        if (ConvertTo-Bool $Cfg.block_mouse) { $null = [PsLilly.ConMode]::BlockMouse() }
        else { [PsLilly.ConMode]::Restore() }
    } catch {}
}
Set-MouseMode

Initialize-Spell
if ($script:SpellNote -and [Environment]::OSVersion.Platform -eq 'Win32NT') {
    Write-Host $script:SpellNote -ForegroundColor DarkYellow
}

if (-not $Server) { $Server = $Cfg.default_server }
if (-not $Port)   { $Port = [int]$Cfg.default_port }
if (-not $Server) { Write-Host 'No server given and no default_server in lily.conf.' -ForegroundColor Red; return }

$enc = switch ($Encoding) {
    'UTF8'   { [System.Text.UTF8Encoding]::new($false) }
    'Latin1' { [System.Text.Encoding]::GetEncoding(28591) }
    'ASCII'  { [System.Text.Encoding]::ASCII }
}

$script:OldTitle = $null
try { $script:OldTitle = [Console]::Title } catch {}
try { [Console]::Title = 'PSLilly' } catch {}

Write-Host "Connecting to ${Server}:${Port}..." -ForegroundColor DarkGray
$client = [System.Net.Sockets.TcpClient]::new()
try {
    $client.Connect($Server, $Port)
} catch {
    Write-Host "Could not connect: $($_.Exception.Message)" -ForegroundColor Red
    return
}
$client.NoDelay = $true
$stream = $client.GetStream()
$sync.Connecting = $true   # slcp on/off is now fixed for this connection
$mode = if ($sync.Slcp) { 'SLCP' } else { 'plain text' }
Write-Host "Connected ($mode mode). Type `$`$ for client commands, `$`$quit to disconnect." -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Drawing the input line. Shared by the input loop and the reader (which hides
# your half-typed line, prints a message, then puts the line back below it).
# Call these while holding $sync.Lock.
# ---------------------------------------------------------------------------
$InputDrawCode = @'
# After writing something in color, go back to the base colors (base_fg/base_bg)
function Reset-ConsoleColors {
    [Console]::ResetColor()
    if ($null -ne $sync.BaseFg) { [Console]::ForegroundColor = $sync.BaseFg }
    if ($null -ne $sync.BaseBg) { [Console]::BackgroundColor = $sync.BaseBg }
}

function Get-InputWidth {
    $w = 0
    try { $w = [Console]::BufferWidth } catch {}
    if ($w -lt 2) { $w = 80 }
    $w
}

function Draw-Input([int]$oldLen) {
    $w = Get-InputWidth
    $d = [string]$sync.InDisplay
    try { [Console]::SetCursorPosition($sync.InLeft, $sync.InTop) }
    catch { $sync.InLeft = [Console]::CursorLeft; $sync.InTop = [Console]::CursorTop }
    # Pad with spaces to erase leftovers. Never end exactly at the right edge,
    # where consoles disagree about where the cursor goes.
    $pad = [Math]::Max(0, $oldLen - $d.Length)
    if ((($sync.InLeft + $d.Length + $pad) % $w) -eq 0) { $pad++ }
    $written = $d.Length + $pad
    $errs = @($sync.InErrors)
    $sel  = @($sync.InSel)
    if ($d.Length -gt 0 -and ($errs.Count -ge 2 -or ($sel.Count -ge 2 -and $sel[1] -gt 0))) {
        # Mark each character: 0 plain, 1 misspelled, 2 selected
        $mark = New-Object int[] $d.Length
        for ($i = 0; $i + 1 -lt $errs.Count; $i += 2) {
            for ($j = [int]$errs[$i]; $j -lt [Math]::Min($d.Length, $errs[$i] + $errs[$i + 1]); $j++) { $mark[$j] = 1 }
        }
        if ($sel.Count -ge 2) {
            for ($j = [int]$sel[0]; $j -lt [Math]::Min($d.Length, $sel[0] + $sel[1]); $j++) { $mark[$j] = 2 }
        }
        $styles = @($null, $sync.Style.spell, $sync.Style.select)
        # Write runs of the same mark together
        $i = 0
        while ($i -lt $d.Length) {
            $j = $i
            while ($j -lt $d.Length -and $mark[$j] -eq $mark[$i]) { $j++ }
            $st = $styles[$mark[$i]]
            if ($st -and ($null -ne $st[0] -or $null -ne $st[1])) {
                if ($null -ne $st[0]) { [Console]::ForegroundColor = $st[0] }
                if ($null -ne $st[1]) { [Console]::BackgroundColor = $st[1] }
                [Console]::Write($d.Substring($i, $j - $i))
                Reset-ConsoleColors
            } else {
                [Console]::Write($d.Substring($i, $j - $i))
            }
            $i = $j
        }
        [Console]::Write(' ' * $pad)
    } else {
        [Console]::Write($d + (' ' * $pad))
    }
    # Work back from where the cursor ended up, so scrolling is accounted for
    $endLin   = [Console]::CursorTop * $w + [Console]::CursorLeft
    $startLin = [Math]::Max(0, $endLin - $written)
    $sync.InTop  = [int][Math]::Floor($startLin / $w)
    $sync.InLeft = [int]($startLin % $w)
    $cur = $startLin + [int]$sync.InCursor
    try { [Console]::SetCursorPosition([int]($cur % $w), [int][Math]::Floor($cur / $w)) } catch {}
}

function Hide-Input {
    if (-not $sync.InActive) { return }
    try {
        [Console]::SetCursorPosition($sync.InLeft, $sync.InTop)
        $n = ([string]$sync.InDisplay).Length
        if ($n -gt 0) {
            $w = Get-InputWidth
            if ((($sync.InLeft + $n) % $w) -eq 0) { $n++ }
            [Console]::Write(' ' * $n)
            [Console]::SetCursorPosition($sync.InLeft, $sync.InTop)
        }
    } catch {}
}

function Show-Input {
    if (-not $sync.InActive) { return }
    $sync.InLeft = [Console]::CursorLeft
    $sync.InTop  = [Console]::CursorTop
    Draw-Input 0
}
'@
. ([scriptblock]::Create($InputDrawCode))

# ---------------------------------------------------------------------------
# Reader: runs in its own runspace so incoming messages appear while you type
# ---------------------------------------------------------------------------
$reader = {
    param($stream, $sync, $enc, $InputDrawCode)
    . ([scriptblock]::Create($InputDrawCode))

    # ---- output -------------------------------------------------------------
    # Everything the server shows goes through here: it colors, logs, and
    # remembers the tail (used to spot the password prompt).
    function Out-Styled([string]$text, $style) {
        if (-not $text) { return }
        [System.Threading.Monitor]::Enter($sync.Lock)
        try {
            if ($sync.InActive -and -not $script:inputHidden) { Hide-Input; $script:inputHidden = $true }
            if ($style -and ($null -ne $style[0] -or $null -ne $style[1])) {
                if ($null -ne $style[0]) { [Console]::ForegroundColor = $style[0] }
                if ($null -ne $style[1]) { [Console]::BackgroundColor = $style[1] }
                [Console]::Write($text)
                Reset-ConsoleColors
            } else {
                [Console]::Write($text)
            }
        } finally { [System.Threading.Monitor]::Exit($sync.Lock) }

        $log = $sync.LogFile
        if ($log) { try { Add-Content -Path $log -Value $text -NoNewline } catch {} }
        $tail = $sync.Tail + $text
        if ($tail.Length -gt 80) { $tail = $tail.Substring($tail.Length - 80) }
        $sync.Tail = $tail
    }

    function Write-StyledLine([string]$text, $style) {
        Out-Styled $text $style
        Out-Styled "`n" $null
    }

    # Word-wrap $text to the window: first line starts with $first, the rest with $cont
    function Write-Wrapped([string]$first, [string]$cont, [string]$text, $style) {
        $w = 79
        try { $w = [Console]::WindowWidth - 1 } catch {}
        if ($w -lt 20) { $w = 79 }
        $prefix = $first
        foreach ($para in ($text -split "`n")) {
            $line = $prefix
            $has = $false
            foreach ($word in ($para -split ' ')) {
                if ($has -and ($line.Length + 1 + $word.Length) -gt $w) {
                    Write-StyledLine $line $style
                    $line = $cont + $word
                } elseif ($has) {
                    $line += ' ' + $word
                } else {
                    $line += $word
                }
                $has = $true
            }
            Write-StyledLine $line $style
            $prefix = $cont
        }
    }

    function Send-Raw([string]$line) {
        $bytes = $enc.GetBytes($line + "`r`n")
        [System.Threading.Monitor]::Enter($sync.SendLock)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
        finally { [System.Threading.Monitor]::Exit($sync.SendLock) }
    }

    # ---- plain text lines (slcp off, banners, command output) ----------------
    $script:cls = $null
    function Get-LineClass([string]$line) {
        $rx = $sync.Rx
        if ($line -match '^\s*$') { $script:cls = $null; return $null }
        if ($rx.private) {
            $m = $rx.private.Match($line)
            if ($m.Success) {
                $from = $m.Groups['from'].Value.Trim()
                if ($from -and -not $sync.Slcp) { $sync.LastFrom = $from -replace '\s+', '_' }
                $script:privUser = if ($from) { $sync.UserStyle[(Get-UserKey $from)] } else { $null }
                $script:cls = 'private'; return 'private'
            }
        }
        if ($rx.public -and $rx.public.IsMatch($line)) { $script:cls = 'public'; return 'public' }
        if ($rx.emote  -and $rx.emote.IsMatch($line))  { $script:cls = 'emote';  return 'emote' }
        if ($script:cls -and $rx.continuation -and $rx.continuation.IsMatch($line)) { return $script:cls }
        $script:cls = $null
        return $null
    }

    function Get-UserKey([string]$name) { 'user_' + ($name.Trim().ToLower() -replace '[\s-]+', '_') }

    # Window title: "PSLilly - <your name>" once logged in
    function Set-WindowTitle([string]$name) {
        try { [Console]::Title = if ($name) { "PSLilly - $name" } else { 'PSLilly' } } catch {}
    }

    function Show-PlainLine([string]$line, [int]$skip = 0) {
        $kind  = Get-LineClass $line
        $style = if ($kind) { $sync.Style[$kind] } else { $null }
        if ($kind -eq 'private' -and $script:privUser) { $style = $script:privUser }
        Out-Styled $line.Substring([Math]::Min($skip, $line.Length)) $style
        Out-Styled "`n" $null
    }

    # ---- SLCP ----------------------------------------------------------------
    $ents = @{}     # handle (#123) -> @{ Name; Blurb; State; Kind }

    # NAME=VALUE, NAME=LEN=DATA (DATA may hold spaces/newlines), or bare NAME.
    # Returns $null when a length-prefixed value runs past the end of $s,
    # meaning it continues on the next line.
    function ConvertFrom-SlcpParams([string]$s) {
        $p = @{}
        $pos = 0; $len = $s.Length
        while ($pos -lt $len) {
            while ($pos -lt $len -and $s[$pos] -eq ' ') { $pos++ }
            if ($pos -ge $len) { break }
            $ks = $pos
            while ($pos -lt $len -and $s[$pos] -ne '=' -and $s[$pos] -ne ' ') { $pos++ }
            $key = $s.Substring($ks, $pos - $ks)
            if (-not $key) { break }
            if ($pos -ge $len -or $s[$pos] -eq ' ') { $p[$key] = '1'; continue }
            $pos++
            $ne = $pos
            while ($ne -lt $len -and [char]::IsDigit($s[$ne])) { $ne++ }
            if ($ne -gt $pos -and $ne -lt $len -and $s[$ne] -eq '=') {
                $n = [int]$s.Substring($pos, $ne - $pos)
                $pos = $ne + 1
                if ($pos + $n -gt $len) { return $null }
                $p[$key] = $s.Substring($pos, $n)
                $pos += $n
            } else {
                $vs = $pos
                while ($pos -lt $len -and $s[$pos] -ne ' ') { $pos++ }
                $p[$key] = $s.Substring($vs, $pos - $vs)
            }
        }
        return $p
    }

    function Test-SlcpIncomplete([string]$line) {
        if ($line -notmatch '^%(NOTIFY|USER|DISC|GROUP|DATA|server) ') { return $false }
        $null -eq (ConvertFrom-SlcpParams $line.Substring($line.IndexOf(' ') + 1))
    }

    function Get-Name([string]$h) {
        if ($h -and $ents.ContainsKey($h) -and $ents[$h].Name) { return $ents[$h].Name }
        return $h
    }
    function Get-NameBlurb([string]$h) {
        $n = Get-Name $h
        if ($h -and $ents.ContainsKey($h) -and $ents[$h].Blurb) { return "$n [$($ents[$h].Blurb)]" }
        return $n
    }
    function Join-Names($handles) { (@($handles | ForEach-Object { Get-Name $_ })) -join ', ' }

    function Set-Entity($p, [string]$kind) {
        if (-not $p -or -not $p.HANDLE) { return }
        $e = $ents[$p.HANDLE]
        if (-not $e) { $e = @{ Kind = $kind }; $ents[$p.HANDLE] = $e }
        foreach ($k in 'NAME', 'BLURB', 'STATE', 'TITLE') {
            if ($p.ContainsKey($k)) { $e[$k.Substring(0, 1) + $k.Substring(1).ToLower()] = $p[$k] }
        }
        Add-NameWords $p.NAME
    }

    # Words in user and discussion names are never treated as misspelled
    function Add-NameWords([string]$name) {
        if (-not $name) { return }
        foreach ($w in ($name -split '[\s_\-,]+')) { if ($w) { $sync.NameSet[$w.ToLower()] = $true } }
    }

    # Text for the non-message events (mirrors zephyrlily's eventformat.go)
    function Format-Event($ev, $p, [string]$src, [string]$srcB, [bool]$self, $recips, $targets) {
        $val  = $p.VALUE
        $disc = Join-Names $recips
        $tgt  = Join-Names $targets
        $sub  = $p.SUBEVT
        $b = { param($m) "*** $m ***" }
        $q = { param($m) "($m)" }
        switch ($ev) {
            'connect'    { return & $b "$srcB has entered lily" }
            'disconnect' { if ($val) { return & $b "$srcB has left lily ($val)" }; return & $b "$srcB has left lily" }
            'attach'     { return & $b "$srcB has reattached" }
            'detach'     { if ($val) { return & $b "$srcB has been detached $val" }; return & $b "$srcB has detached" }
            'here'       { if ($self) { return & $q 'you are now here' }; return & $b "$src is now `"here`"" }
            'away'       {
                if ($val) { return & $b "$src has idled `"away`"" }
                if ($self) { return & $q 'you are now away' }
                return & $b "$src is now `"away`""
            }
            'unidle'     { return & $b "$src is now unidle" }
            'rename'     { if ($self) { return & $q "you are now named $val" }; return & $b "$src is now named $val" }
            'blurb'      {
                if ($self) { if ($val) { return & $q "your blurb has been set to [$val]" }; return & $q 'your blurb has been turned off' }
                if ($val) { return & $b "$src has changed their blurb to [$val]" }
                return & $b "$src has turned their blurb off"
            }
            'info'       {
                if ($disc) { if ($self) { return & $q "you have changed the info for $disc" }; return & $b "$src has changed the info for discussion $disc" }
                if ($self) { return & $q 'your info has been changed' }
                return & $b "$src has changed their info"
            }
            'create'     { if ($self) { return & $q "you have created discussion $disc" }; return & $b "$src has created discussion $disc" }
            'destroy'    { if ($self) { return & $q "you have destroyed discussion $disc" }; return & $b "$src has destroyed discussion $disc" }
            'join'       { if ($self) { return & $q "you have joined $disc" }; return & $b "$src is now a member of $disc" }
            'quit'       { if ($self) { return & $q "you have quit $disc" }; return & $b "$src is no longer a member of $disc" }
            'retitle'    { if ($self) { return & $q "you have changed the title of $disc to `"$val`"" }; return & $b "$src has changed the title of $disc to `"$val`"" }
            'drename'    { return & $b "Discussion -$disc is now named -$val" }
            'review'     { return & $b "$src has cleared the review for discussion $disc" }
            'ignore'     { if ($val) { return & $b "$src is now ignoring you $val" }; return & $b "$src is now ignoring you" }
            'unignore'   { return & $b "$src is no longer ignoring you" }
            'sysmsg'     { return "*** $val ***" }
            'sysalert'   { return "*** $val ***" }
            { $_ -in 'permit', 'depermit', 'appoint', 'unappoint' } {
                $what = @($ev, $sub, $tgt) | Where-Object { $_ }
                return & $b "$src $($what -join ' ') for discussion $disc"
            }
        }
        $rest = @($val, $disc) | Where-Object { $_ }
        return "[$ev] $src $($rest -join ' ')"
    }

    function Show-Notify($p) {
        $ev      = "$($p.EVENT)".ToLower()
        $srcH    = $p.SOURCE
        $self    = [bool]($sync.WhoAmI -and $srcH -eq $sync.WhoAmI)
        $recips  = @(if ($p.RECIPS)  { $p.RECIPS  -split ',' })
        $targets = @(if ($p.TARGETS) { $p.TARGETS -split ',' })
        $val     = "$($p.VALUE)"
        $src     = Get-Name $srcH
        $srcB    = Get-NameBlurb $srcH
        $show    = $p.ContainsKey('NOTIFY') -or $ev -in 'public', 'private', 'emote', 'pa'

        $ts = ''
        if ($p.STAMP -and $p.TIME -match '^\d+$') {
            $ts = [DateTimeOffset]::FromUnixTimeSeconds([long]$p.TIME).LocalDateTime.ToString('HH:mm')
        }

        if ($show) {
            switch ($ev) {
                'public' {
                    $st = $sync.Style.public
                    $h  = ' -> ' + $(if ($ts) { "($ts) " }) + "From $srcB"
                    if ($recips.Count) { $h += ', to ' + (Join-Names $recips) }
                    Out-Styled "`n" $null
                    Write-StyledLine "${h}:" $st
                    Write-Wrapped ' - ' '   ' $val $st
                }
                'private' {
                    $st = $sync.Style.private
                    $us = $sync.UserStyle[(Get-UserKey $src)]
                    if ($us) { $st = $us }
                    $h  = ' >> ' + $(if ($ts) { "($ts) " }) + "Private message from $srcB"
                    if ($recips.Count -gt 1) { $h += ', to ' + (Join-Names $recips) }
                    Out-Styled "`n" $null
                    Write-StyledLine "${h}:" $st
                    Write-Wrapped ' - ' '   ' $val $st
                    if (-not $self) { $sync.LastFrom = $src -replace '\s+', '_' }
                }
                'emote' {
                    $st = $sync.Style.emote
                    $inner = @()
                    if ($ts) { $inner += $ts }
                    if ($recips.Count) { $inner += 'to ' + (Join-Names $recips) }
                    $h = '> ' + $(if ($inner) { "($($inner -join ', ')) " }) + $src
                    Write-Wrapped '' '> ' ($h + $val) $st
                }
                'pa' {
                    $st = $sync.Style.private
                    Out-Styled "`n" $null
                    Write-StyledLine (' ** ' + $(if ($ts) { "($ts) " }) + "Public address from ${srcB}:") $st
                    Write-Wrapped ' - ' '   ' $val $st
                }
                default {
                    Write-Wrapped '' '    ' (Format-Event $ev $p $src $srcB $self $recips $targets) $sync.Style.system
                }
            }
        }

        # Keep names, blurbs and states current
        if ($srcH -and $ents.ContainsKey($srcH)) {
            switch ($ev) {
                'rename'     { $ents[$srcH].Name  = $val; Add-NameWords $val; if ($self) { Set-WindowTitle $val } }
                'blurb'      { $ents[$srcH].Blurb = $val }
                'here'       { $ents[$srcH].State = 'here' }
                'away'       { $ents[$srcH].State = 'away' }
                'disconnect' { $ents[$srcH].State = 'away' }
            }
        }
        if ($ev -eq 'retitle') { foreach ($r in $recips) { if ($ents.ContainsKey($r)) { $ents[$r].Title = $val } } }
    }

    function Show-SlcpLine([string]$line) {
        if ($line -match '^%command \[\d+\] ?(.*)$') { Show-PlainLine $Matches[1]; return }
        $sp   = $line.IndexOf(' ')
        $tok  = if ($sp -ge 0) { $line.Substring(0, $sp) } else { $line }
        $rest = if ($sp -ge 0) { $line.Substring($sp + 1) } else { '' }
        switch -casesensitive ($tok) {
            '%NOTIFY'    { Show-Notify (ConvertFrom-SlcpParams $rest); return }
            '%USER'      { Set-Entity (ConvertFrom-SlcpParams $rest) 'user'; return }
            '%DISC'      { Set-Entity (ConvertFrom-SlcpParams $rest) 'disc'; return }
            '%DATA'      {
                $p = ConvertFrom-SlcpParams $rest
                if ($p.NAME -eq 'whoami') { $sync.WhoAmI = $p.VALUE }
                return
            }
            '%connected' {
                # The rest of this line isn't always our ID ("%connected attach"
                # when reattaching), so only take it if it looks like one; the
                # %DATA whoami sent during the sync is the reliable source.
                $tag = $rest.Trim()
                if ($tag -match '^#\d+$' -and -not $sync.WhoAmI) { $sync.WhoAmI = $tag }
                $me = $null
                if ($sync.WhoAmI -and $ents.ContainsKey($sync.WhoAmI) -and $ents[$sync.WhoAmI].Name) { $me = $ents[$sync.WhoAmI].Name }
                if (-not $me) { $me = $sync.LoginName }
                if ($me) { Set-WindowTitle $me }
                Send-Raw ('#$# client pslilly "' + $sync.Version + '"')
                $sync.LoggedIn = $true
                return
            }
            '%prompt'    {
                # The normal "lily>" prompt isn't shown; others (like a blurb prompt) are
                if ($rest -notmatch '^\s*lily>\s*$') { Out-Styled $rest $null }
                return
            }
            '%pong'      {
                # Reply to our keepalive ping
                $sync.PingSentAt = $null
                if ($sync.PingWarned) {
                    $sync.PingWarned = $false
                    Write-StyledLine '*** The server is answering again. ***' $sync.Style.system
                }
                return
            }
            { $_ -in '%begin', '%end', '%options', '%server', '%GROUP', '%SLCP-SYNC', '%export_file' } { return }
        }
        Show-PlainLine $line
    }

    # ---- read loop -----------------------------------------------------------
    $IAC = 255; $SB = 250; $SE = 240; $WILL = 251; $WONT = 252; $ECHO = 1
    $buf     = New-Object byte[] 4096
    $chars   = New-Object char[] 8192
    $decoder = $enc.GetDecoder()
    $state   = 0      # telnet parser state
    $verb    = 0
    $pending = ''     # text of the current, unfinished line
    $printed = 0      # how much of $pending is already on screen (prompts)

    try {
        while ($sync.Running) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $sync.LastActivity = [DateTime]::UtcNow

            # Strip telnet command sequences and carriage returns
            $clean = [System.Collections.Generic.List[byte]]::new($n)
            for ($i = 0; $i -lt $n; $i++) {
                $b = $buf[$i]
                switch ($state) {
                    0 { if ($b -eq $IAC) { $state = 1 } elseif ($b -ne 13) { $clean.Add($b) } }
                    1 {
                        if     ($b -eq $IAC)                  { $clean.Add($b); $state = 0 }
                        elseif ($b -ge 251 -and $b -le 254)   { $verb = $b; $state = 2 }
                        elseif ($b -eq $SB)                   { $state = 3 }
                        else                                  { $state = 0 }
                    }
                    2 {
                        if ($b -eq $ECHO) {
                            if ($verb -eq $WILL) { $sync.ServerEcho = $true }
                            if ($verb -eq $WONT) { $sync.ServerEcho = $false }
                        }
                        $state = 0
                    }
                    3 { if ($b -eq $IAC) { $state = 4 } }
                    4 { if ($b -eq $SE) { $state = 0 } else { $state = 3 } }
                }
            }
            if ($clean.Count -eq 0) { continue }

            $bytes = $clean.ToArray()
            $count = $decoder.GetChars($bytes, 0, $bytes.Length, $chars, 0)
            $text  = [string]::new($chars, 0, $count)

            # You answered the prompt that was waiting, so it's no longer part
            # of the next line
            if ($sync.ResetPending) { $sync.ResetPending = $false; $pending = ''; $printed = 0 }

            # Hold the console while printing this batch; your half-typed line
            # is moved out of the way on the first output and redrawn after.
            [System.Threading.Monitor]::Enter($sync.Lock)
            $script:inputHidden = $false
            try {
            $pending += $text
            while (($nl = $pending.IndexOf("`n")) -ge 0) {
                $line = $pending.Substring(0, $nl)
                if ($sync.Slcp -and $printed -eq 0 -and (Test-SlcpIncomplete $line)) {
                    # A length-prefixed value continues onto the following line(s)
                    $joined = $line; $rest = $pending.Substring($nl + 1); $done = $false
                    while (($nl2 = $rest.IndexOf("`n")) -ge 0) {
                        $joined += "`n" + $rest.Substring(0, $nl2)
                        $rest = $rest.Substring($nl2 + 1)
                        if (-not (Test-SlcpIncomplete $joined)) { $done = $true; break }
                    }
                    if (-not $done) { break }   # wait for more data
                    $line = $joined
                    $pending = $rest
                } else {
                    $pending = $pending.Substring($nl + 1)
                }

                try {
                    if ($line -match '^\s*\*\*\* Connected \*\*\*' -and $sync.LoginName) { Set-WindowTitle $sync.LoginName }
                    if ($sync.Slcp -and $printed -eq 0 -and $line.StartsWith('%')) { Show-SlcpLine $line }
                    else { Show-PlainLine $line $printed }
                } catch {
                    Out-Styled "[pslilly couldn't handle a line: $($_.Exception.Message)]`n" $null
                    Show-PlainLine $line
                }
                $printed = 0
            }
            # A partial line with nothing more coming is a prompt: show it now
            # (but never a half-received SLCP line)
            if ($pending.Length -gt $printed -and -not $stream.DataAvailable -and
                -not ($sync.Slcp -and $pending.StartsWith('%'))) {
                Out-Styled $pending.Substring($printed) $null
                $printed = $pending.Length
            }
            } finally {
                if ($script:inputHidden) { Show-Input }
                [System.Threading.Monitor]::Exit($sync.Lock)
            }
        }
    } catch {
        # Socket closed underneath us; fall through
    }
    [System.Threading.Monitor]::Enter($sync.Lock)
    try {
        Hide-Input
        $sync.InActive = $false
        [Console]::WriteLine()
        if (-not $sync.Quitting) { [Console]::WriteLine('*** Connection closed by server. ***') }
    } finally { [System.Threading.Monitor]::Exit($sync.Lock) }
    $sync.Running = $false
}

$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$ps = [powershell]::Create()
$ps.Runspace = $rs
$null = $ps.AddScript($reader).AddArgument($stream).AddArgument($sync).AddArgument($enc).AddArgument($InputDrawCode)
$handle = $ps.BeginInvoke()

# ---------------------------------------------------------------------------
# Helpers for the input side
# ---------------------------------------------------------------------------
function Write-Locked([string]$text) {
    [System.Threading.Monitor]::Enter($sync.Lock)
    try { [Console]::Write($text) } finally { [System.Threading.Monitor]::Exit($sync.Lock) }
}

function Say([string]$text, [ConsoleColor]$color = 'Cyan', [switch]$NoNewline) {
    [System.Threading.Monitor]::Enter($sync.Lock)
    try { Write-Host $text -ForegroundColor $color -NoNewline:$NoNewline }
    finally { [System.Threading.Monitor]::Exit($sync.Lock) }
}

function Send-Line([string]$line) {
    $bytes = $enc.GetBytes($line + "`r`n")
    if ($sync.ShowSent) {
        $hex = ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' '
        Say "[sent] $hex" DarkYellow
    }
    [System.Threading.Monitor]::Enter($sync.SendLock)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
    finally { [System.Threading.Monitor]::Exit($sync.SendLock) }
    $sync.LastActivity = [DateTime]::UtcNow
}

# A one-line notice printed above your input line (which is redrawn below it)
function Show-Notice([string]$text, [ConsoleColor]$color = 'DarkYellow') {
    [System.Threading.Monitor]::Enter($sync.Lock)
    try {
        Hide-Input
        if ([Console]::CursorLeft -ne 0) { [Console]::WriteLine() }
        Write-Host $text -ForegroundColor $color
        Show-Input
    } finally { [System.Threading.Monitor]::Exit($sync.Lock) }
}

# Keepalive: after <keepalive> minutes with nothing sent or received, send
# "#$# ping". The server answers "%pong"; if it doesn't within a minute, warn
# that the connection may be dead. Runs from the input loop while idle.
$KeepaliveTimeout = 60   # seconds to wait for %pong
function Invoke-Keepalive {
    $mins = 0
    [void][int]::TryParse([string]$Cfg.keepalive, [ref]$mins)
    if ($mins -le 0 -or -not $sync.Slcp -or -not $sync.LoggedIn) { return }
    $now = [DateTime]::UtcNow
    if ($null -ne $sync.PingSentAt) {
        if (-not $sync.PingWarned -and ($now - $sync.PingSentAt).TotalSeconds -ge $KeepaliveTimeout) {
            $sync.PingWarned = $true
            Show-Notice '*** No reply to a keepalive ping - the connection may be dead ($$quit to leave) ***'
        }
        return
    }
    if (($now - $sync.LastActivity).TotalMinutes -ge $mins) {
        $bytes = $enc.GetBytes("#`$# ping`r`n")
        [System.Threading.Monitor]::Enter($sync.SendLock)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
        catch { return }
        finally { [System.Threading.Monitor]::Exit($sync.SendLock) }
        $sync.PingSentAt = $now
        $sync.LastActivity = $now
    }
}

function Test-PasswordPrompt {
    $sync.ServerEcho -or ($sync.Tail -match 'pass(word|wd)?\s*[:>]?\s*$')
}

# True once the typed text is past "connect <name> " (MOO-style login)
function Test-ConnectMask([string]$text) {
    $sync.MaskConnect -and ($text -match '^\s*(connect|conn|co)\s+\S+\s')
}

# ---------------------------------------------------------------------------
# Line editor. Your input line is drawn in place, so it can wrap across rows,
# the cursor can move inside it, and incoming messages are printed above it.
# Returns $null if the connection drops while waiting.
# ---------------------------------------------------------------------------
$History    = [System.Collections.Generic.List[string]]::new()
$HistoryMax = 200
$script:LastLineSecret = $false

# What's shown for the typed text: * for passwords
function Get-InputDisplay([string]$text, [bool]$secret) {
    if ($secret) { return ('*' * $text.Length) }
    if ($sync.MaskConnect -and $text -match '^\s*(connect|conn|co)\s+\S+\s') {
        $keep = $Matches[0].Length
        return $text.Substring(0, $keep) + ('*' * ($text.Length - $keep))
    }
    return $text
}

function Update-InputView($sb, [int]$cursor, [bool]$secret, $anchor = $null) {
    # Misspellings to color, except the word you're in the middle of typing
    $text = $sb.ToString()
    $ranges = Get-SpellRanges $text
    $shown = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i + 1 -lt $ranges.Count; $i += 2) {
        $atEnd = $ranges[$i] + $ranges[$i + 1] -eq $cursor -and $cursor -eq $text.Length
        if (-not $atEnd) { $shown.Add($ranges[$i]); $shown.Add($ranges[$i + 1]) }
    }
    [System.Threading.Monitor]::Enter($sync.Lock)
    try {
        $old = ([string]$sync.InDisplay).Length
        $sync.InDisplay = Get-InputDisplay $text $secret
        $sync.InErrors  = $shown.ToArray()
        $sync.InSel     = if ($null -ne $anchor -and $anchor -ne $cursor) {
                              @([Math]::Min($anchor, $cursor), [Math]::Abs($anchor - $cursor))
                          } else { @() }
        $sync.InCursor  = $cursor
        Draw-Input $old
    } finally { [System.Threading.Monitor]::Exit($sync.Lock) }
}

# Start of the word left of / right of position $i
function Get-WordLeft([string]$t, [int]$i) {
    while ($i -gt 0 -and $t[$i - 1] -eq ' ') { $i-- }
    while ($i -gt 0 -and $t[$i - 1] -ne ' ') { $i-- }
    $i
}
function Get-WordRight([string]$t, [int]$i) {
    while ($i -lt $t.Length -and $t[$i] -ne ' ') { $i++ }
    while ($i -lt $t.Length -and $t[$i] -eq ' ') { $i++ }
    $i
}

function Read-InputLine {
    $sb     = [System.Text.StringBuilder]::new()
    $pos    = 0               # cursor position within the text
    $secret = $null           # decided at the first keystroke, once the prompt is on screen
    $cycle  = $null           # F7 suggestion cycle in progress
    $idleTicks = 0
    $undo   = [System.Collections.Generic.List[object]]::new()   # Ctrl+Z
    $redo   = [System.Collections.Generic.List[object]]::new()   # Ctrl+Y
    $lastKind = ''            # typing is undone a word at a time
    $anchor = $null           # other end of the selection (Shift+arrows), or $null
    $hi     = $History.Count  # position in history; Count = the line being typed
    $draft  = ''              # what you'd typed before pressing Up
    $simple = $null           # $true at the login/password prompts (plain typing)
    $isLogin = $false

    try {
        while ($sync.Running) {
            if (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds 20
                if ((++$idleTicks % 50) -eq 0) { Invoke-Keepalive }   # about once a second
                continue
            }
            $k = [Console]::ReadKey($true)

            # At the first key, decide how to read this line
            if ($null -eq $simple) {
                $script:LastLineLogin = $false
                $secret  = [bool](Test-PasswordPrompt)
                $isLogin = $sync.Tail -match 'login:\s*$'
                $simple  = $secret -or $isLogin
                if (-not $simple) {
                    [System.Threading.Monitor]::Enter($sync.Lock)
                    try {
                        $sync.InDisplay = ''
                        $sync.InCursor  = 0
                        $sync.InLeft    = [Console]::CursorLeft
                        $sync.InTop     = [Console]::CursorTop
                        $sync.InActive  = $true
                    } finally { [System.Threading.Monitor]::Exit($sync.Lock) }
                }
            }

            # Login name and password: plain typing, Tab = Enter at the login prompt
            if ($simple) {
                if ([int]$k.KeyChar -eq 3 -or ($k.Key -eq 'C' -and ($k.Modifiers -band [ConsoleModifiers]::Control))) {
                    Write-Locked "`n"; return $null    # Ctrl+C: quit
                }
                if ($k.Key -eq 'Enter' -or ($k.Key -eq 'Tab' -and $isLogin)) {
                    Write-Locked "`n"
                    $script:LastLineSecret = $secret
                    $script:LastLineLogin  = $isLogin
                    return $sb.ToString()
                }
                elseif ($k.Key -eq 'Backspace') {
                    if ($sb.Length -gt 0) { $sb.Length = $sb.Length - 1; Write-Locked "`b `b" }
                }
                elseif ($k.Key -eq 'Escape') {
                    Write-Locked ("`b `b" * $sb.Length)
                    $null = $sb.Clear()
                }
                elseif ($k.KeyChar -ne [char]0 -and -not [char]::IsControl($k.KeyChar)) {
                    $null = $sb.Append($k.KeyChar)
                    if ($secret) { Write-Locked '*' } else { Write-Locked $k.KeyChar }
                }
                continue
            }

            try {   # a problem with one key shouldn't end the session
            $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
            $c    = [int]$k.KeyChar
            # Consoles report Ctrl+letter either as a control character or as
            # the letter with Ctrl held; normalize to the control character.
            if ($ctrl -and $k.Key -ge [ConsoleKey]::A -and $k.Key -le [ConsoleKey]::Z) {
                $c = [int]$k.Key - [int][ConsoleKey]::A + 1
            }
            $text = $sb.ToString()
            if ($k.Key -ne 'F7') { $cycle = $null }   # any other key ends a suggestion cycle
            $before = @{ T = $text; P = $pos }

            # ---- selection (Shift+arrows) and the clipboard ----
            $shiftKey = ($k.Modifiers -band [ConsoleModifiers]::Shift) -ne 0
            $isMove   = $k.Key -in 'LeftArrow', 'RightArrow', 'Home', 'End' -or $c -eq 1 -or $c -eq 5
            $hasSel   = $null -ne $anchor -and $anchor -ne $pos
            $selStart = if ($hasSel) { [Math]::Min($anchor, $pos) } else { $pos }
            $selEnd   = if ($hasSel) { [Math]::Max($anchor, $pos) } else { $pos }
            $paste    = $null

            if ($isMove) {
                if ($shiftKey) {
                    if ($null -eq $anchor) { $anchor = $pos }       # start selecting
                } elseif ($hasSel -and -not $ctrl -and $k.Key -in 'LeftArrow', 'RightArrow') {
                    # Plain Left/Right with a selection: go to that end of it
                    $pos = if ($k.Key -eq 'LeftArrow') { $selStart } else { $selEnd }
                    $anchor = $null
                    Update-InputView $sb $pos $secret
                    continue
                } else {
                    $anchor = $null
                }
            }
            elseif ($c -eq 3 -or $c -eq 24) {                         # Ctrl+C copy, Ctrl+X cut
                if (-not $hasSel) {
                    if ($c -eq 3) {                                    # nothing selected: Ctrl+C quits
                        [System.Threading.Monitor]::Enter($sync.Lock)
                        try { $sync.InActive = $false; [Console]::Write("`n") }
                        finally { [System.Threading.Monitor]::Exit($sync.Lock) }
                        return $null
                    }
                    continue
                }
                try { Set-Clipboard -Value $text.Substring($selStart, $selEnd - $selStart) } catch {}
                if ($c -eq 3) { continue }                             # copy keeps the selection
            }
            elseif ($c -eq 22) {                                       # Ctrl+V paste
                try { $paste = [string](Get-Clipboard -Raw) } catch { $paste = '' }
                $paste = ($paste -replace '\r?\n', ' ').TrimEnd()
                if (-not $paste) { continue }
            }

            # Typing, pasting, Backspace, Delete or cut replace the selection
            $isTyping = $k.KeyChar -ne [char]0 -and -not [char]::IsControl($k.KeyChar)
            if ($hasSel -and ($isTyping -or $null -ne $paste -or $c -eq 24 -or $k.Key -in 'Backspace', 'Delete')) {
                $null = $sb.Remove($selStart, $selEnd - $selStart)
                $pos = $selStart
                $anchor = $null
                $text = $sb.ToString()
                if (-not ($isTyping -or $null -ne $paste)) {
                    $undo.Add($before); $redo.Clear(); $lastKind = ''
                    Update-InputView $sb $pos $secret
                    continue
                }
            }
            if ($null -ne $paste) {
                $null = $sb.Insert($pos, $paste)
                $pos += $paste.Length
                $undo.Add($before); $redo.Clear(); $lastKind = ''
                Update-InputView $sb $pos $secret
                continue
            }
            if ($c -eq 24) { continue }                                # cut with nothing selected

            if ($c -eq 26 -or $c -eq 25) {               # Ctrl+Z undo, Ctrl+Y redo
                $from = $undo; $to = $redo
                if ($c -eq 25) { $from = $redo; $to = $undo }
                if ($from.Count -eq 0) { continue }
                $snap = $from[$from.Count - 1]
                $from.RemoveAt($from.Count - 1)
                $to.Add($before)
                $null = $sb.Clear().Append($snap.T)
                $pos = [Math]::Min($snap.P, $snap.T.Length)
                $lastKind = ''
                $cycle = $null
                $anchor = $null
                Update-InputView $sb $pos $secret
                continue
            }

            if ($k.Key -eq 'Enter') {
                [System.Threading.Monitor]::Enter($sync.Lock)
                try {
                    # Put the cursor after the text, then start a new line
                    $sync.InCursor = $text.Length
                    Draw-Input ([string]$sync.InDisplay).Length
                    $w = Get-InputWidth
                    if ($text.Length -eq 0 -or (($sync.InLeft + $text.Length) % $w) -ne 0) {
                        [Console]::Write("`n")
                    }
                    $sync.InActive = $false
                } finally { [System.Threading.Monitor]::Exit($sync.Lock) }
                $script:LastLineSecret = $secret -or (Test-ConnectMask $text)
                return $text
            }
            elseif ($k.Key -eq 'UpArrow' -or $k.Key -eq 'DownArrow') {
                if ($secret) { continue }   # no history at a password prompt
                if ($k.Key -eq 'UpArrow') {
                    if ($hi -le 0) { continue }
                    if ($hi -eq $History.Count) { $draft = $text }
                    $hi--
                    $new = $History[$hi]
                } else {
                    if ($hi -ge $History.Count) { continue }
                    $hi++
                    $new = if ($hi -eq $History.Count) { $draft } else { $History[$hi] }
                }
                $null = $sb.Clear().Append($new)
                $pos = $new.Length
            }
            elseif ($k.Key -eq 'LeftArrow') {
                $pos = if ($ctrl) { Get-WordLeft $text $pos } else { [Math]::Max(0, $pos - 1) }
            }
            elseif ($k.Key -eq 'RightArrow') {
                $pos = if ($ctrl) { Get-WordRight $text $pos } else { [Math]::Min($text.Length, $pos + 1) }
            }
            elseif ($k.Key -eq 'Home' -or $c -eq 1) {        # Home or Ctrl+A
                $pos = 0
            }
            elseif ($k.Key -eq 'End' -or $c -eq 5) {         # End or Ctrl+E
                $pos = $text.Length
            }
            elseif ($k.Key -eq 'Backspace') {
                if ($pos -gt 0) {
                    $from = if ($ctrl) { Get-WordLeft $text $pos } else { $pos - 1 }
                    $null = $sb.Remove($from, $pos - $from)
                    $pos = $from
                }
            }
            elseif ($k.Key -eq 'Delete') {
                if ($pos -lt $text.Length) { $null = $sb.Remove($pos, 1) }
            }
            elseif ($k.Key -eq 'F7') {
                if (-not $script:SpellReady) {
                    if ($script:SpellNote) { Say "`n$($script:SpellNote)" DarkYellow; Update-InputView $sb $pos $false }
                    continue
                }
                $shift = ($k.Modifiers -band [ConsoleModifiers]::Shift) -ne 0
                if ($cycle -and -not $shift) {
                    # F7 again: next suggestion (the original word comes back at the end)
                    $cycle.Index = ($cycle.Index + 1) % $cycle.List.Count
                    $new = $cycle.List[$cycle.Index]
                    $null = $sb.Remove($cycle.Start, $cycle.Len).Insert($cycle.Start, $new)
                    $cycle.Len = $new.Length
                    $pos = $cycle.Start + $new.Length
                } else {
                    # The misspelled word at the cursor, else the nearest one before it, else the first
                    $r = Get-SpellRanges $text
                    if ($r.Count -lt 2) { continue }
                    $pick = -1
                    for ($i = 0; $i + 1 -lt $r.Count; $i += 2) {
                        if ($r[$i] -le $pos -and $pos -le $r[$i] + $r[$i + 1]) { $pick = $i; break }
                        if ($r[$i] + $r[$i + 1] -le $pos) { $pick = $i }
                    }
                    if ($pick -lt 0) { $pick = 0 }
                    $start = $r[$pick]; $len = $r[$pick + 1]
                    $word  = $text.Substring($start, $len)
                    if ($shift) {
                        try { Add-SpellWord $word } catch {}
                    } else {
                        $sugg = @(Get-SpellSuggestions $word | Where-Object { $_ })
                        if ($sugg.Count -eq 0) { continue }
                        $cycle = @{ Start = $start; Len = $len; Index = 0; List = @($sugg) + @($word) }
                        $new = $sugg[0]
                        $null = $sb.Remove($start, $len).Insert($start, $new)
                        $cycle.Len = $new.Length
                        $pos = $start + $new.Length
                    }
                }
            }
            elseif ($k.Key -eq 'Escape' -or $c -eq 21) {     # Esc or Ctrl+U: clear line
                $null = $sb.Clear()
                $pos = 0
            }
            elseif ($k.KeyChar -ne [char]0 -and -not [char]::IsControl($k.KeyChar)) {
                $ch = [string]$k.KeyChar
                # Autofill on an empty line
                if ($text.Length -eq 0 -and -not $secret) {
                    if ($ch -eq ':' -and $sync.LastFrom) { $ch = "$($sync.LastFrom):" }
                    elseif ($ch -eq ';' -and $sync.LastTo) { $ch = "$($sync.LastTo);" }
                }
                $null = $sb.Insert($pos, $ch)
                $pos += $ch.Length
            }
            else {
                continue
            }

            # Remember the text before this change for Ctrl+Z. Consecutive
            # typed letters count as one change, so undo goes a word at a time.
            if ($sb.ToString() -ne $before.T) {
                $isLetter = $k.KeyChar -ne [char]0 -and -not [char]::IsControl($k.KeyChar) -and
                            $k.KeyChar -ne ' ' -and $k.Key -ne 'F7'
                $kind = if ($isLetter) { 'type' } else { 'other' }
                if (-not ($kind -eq 'type' -and $lastKind -eq 'type')) {
                    $undo.Add($before)
                    if ($undo.Count -gt 100) { $undo.RemoveAt(0) }
                }
                $redo.Clear()
                $lastKind = $kind
            } elseif ($k.Key -ne 'F7') {
                $lastKind = ''   # moving the cursor starts a new undo step
            }
            if (-not ($isMove -and $shiftKey)) { $anchor = $null }
            Update-InputView $sb $pos $secret $anchor
            } catch {
                Say "`n[pslilly hit a problem with that key: $($_.Exception.Message)]" DarkYellow
                [System.Threading.Monitor]::Enter($sync.Lock)
                try { $sync.InLeft = [Console]::CursorLeft; $sync.InTop = [Console]::CursorTop }
                finally { [System.Threading.Monitor]::Exit($sync.Lock) }
                Update-InputView $sb ([Math]::Min($pos, $sb.Length)) $secret
            }
        }
    } finally {
        $sync.InActive = $false
    }
    return $null
}

# Remember who a line was addressed to ("bob:hi", "bob,alice;waves")
function Update-LastTo([string]$line) {
    if ($line -match '^(?<to>[^\s:;/$][^\s:;]*)[:;]') { $sync.LastTo = $Matches.to }
}

function Show-LocalHelp {
    Say 'Settings (saved in lily.conf):'
    foreach ($k in $Schema.Keys) {
        $t = $Schema[$k].Type
        $v = $Cfg[$k]
        Say (('  $$' + $k).PadRight(25)) White -NoNewline
        $shown = if ($v) { $v } else { '(off)' }
        if ($t -eq 'color') {
            [System.Threading.Monitor]::Enter($sync.Lock)
            try {
                $c = $null; try { $c = ConvertTo-ConsoleColor $v } catch {}
                if ($null -ne $c -and $k -like '*_fg') { [Console]::ForegroundColor = $c }
                if ($null -ne $c -and $k -like '*_bg') { [Console]::BackgroundColor = $c }
                [Console]::Write($shown)
                Reset-ConsoleColors
                [Console]::Write(''.PadRight([Math]::Max(1, 14 - $shown.Length)))
            } finally { [System.Threading.Monitor]::Exit($sync.Lock) }
            Say $Schema[$k].Help Gray
        } elseif ($t -eq 'regex') {
            Say $shown Gray
        } else {
            Say ($shown.PadRight(14) + ' ') Gray -NoNewline
            Say $Schema[$k].Help Gray
        }
    }
    $userKeys = @($Cfg.Keys | Where-Object { $_ -like 'user_*' } | Sort-Object)
    if ($userKeys.Count) {
        Say 'Per-user private message colors:'
        foreach ($k in $userKeys) { Show-UserColor $k }
    }
    Say 'Commands:'
    Say '  $$user <name> <color> [on <bg>]  color private messages from someone (off = remove)' Gray
    Say '  $$map <char> <text>              send a character as <text> (off = built-in, $$map lists)' Gray
    Say '  $$send <text>            send text to the server as-is' Gray
    Say '  $$reload                 re-read lily.conf' Gray
    Say '  $$quit                   disconnect' Gray
    $spellState = if ($script:SpellReady) { 'on' } elseif ($script:SpellNote) { $script:SpellNote } else { 'off' }
    Say 'Editing: Ctrl+Z undo, Ctrl+Y redo, Esc clears the line, Up/Down for history' Gray
    Say '         Shift+arrows select (Ctrl+Shift by word); Ctrl+C copy, Ctrl+X cut, Ctrl+V paste' Gray
    Say "Spelling: $spellState.  F7 = suggestions (again for the next one), Shift+F7 = add word to dictionary" Gray
    Say 'Shortcuts: : = last person who sent to you' Gray -NoNewline
    Say " ($(if ($sync.LastFrom) { $sync.LastFrom } else { 'none yet' }))," Gray -NoNewline
    Say ' ; = last person you sent to' Gray -NoNewline
    Say " ($(if ($sync.LastTo) { $sync.LastTo } else { 'none yet' }))" Gray
    Say 'Color preview:'
    foreach ($cls in 'public', 'private', 'emote', 'system', 'spell', 'select') {
        [System.Threading.Monitor]::Enter($sync.Lock)
        try {
            $s = $sync.Style[$cls]
            [Console]::Write('  ')
            if ($null -ne $s[0]) { [Console]::ForegroundColor = $s[0] }
            if ($null -ne $s[1]) { [Console]::BackgroundColor = $s[1] }
            $label = @{ public = 'a public message'; private = 'a private message'; emote = 'an emote'; system = 'a system notice'; spell = 'a mispeled word'; select = 'selected text' }[$cls]
            [Console]::Write(" this is $label ")
            Reset-ConsoleColors
            [Console]::WriteLine()
        } finally { [System.Threading.Monitor]::Exit($sync.Lock) }
    }
}

# Shows a user's color setting, written in that color
function Show-UserColor([string]$key) {
    $st = $sync.UserStyle[$key]
    $who = $key.Substring(5)
    [System.Threading.Monitor]::Enter($sync.Lock)
    try {
        [Console]::Write('  ' + $who.PadRight(16))
        if ($st) {
            if ($null -ne $st[0]) { [Console]::ForegroundColor = $st[0] }
            if ($null -ne $st[1]) { [Console]::BackgroundColor = $st[1] }
        }
        [Console]::Write(" $($Cfg[$key]) ")
        Reset-ConsoleColors
        [Console]::WriteLine()
    } finally { [System.Threading.Monitor]::Exit($sync.Lock) }
}

# $$map                      list your own character mappings
# $$map <char>               show what a character becomes
# $$map <char> <text>        map it ("" for nothing; U+201C works for <char>)
# $$map <char> off           back to the built-in mapping
function Invoke-MapCommand([string]$arg) {
    $keys = @($Cfg.Keys | Where-Object { $_ -match '^map_u\+?[0-9a-f]+$' } | Sort-Object)
    if (-not "$arg".Trim()) {
        if ($keys.Count -eq 0) { Say 'No custom character mappings. Example: $$map ' + [char]0x2019 + " '"; return }
        Say 'Your character mappings (used when sending):'
        foreach ($k in $keys) {
            $cp = [Convert]::ToInt32(($k -replace '^map_u\+?', ''), 16)
            Say ("  {0}  U+{1:X4}  ->  {2}" -f [char]::ConvertFromUtf32($cp), $cp, $Cfg[$k]) Gray
        }
        return
    }
    $parts = $arg.Trim() -split '\s+', 2
    $spec = $parts[0]
    if ($spec -match '^[uU]\+?([0-9a-fA-F]{2,6})$') {
        $cp = [Convert]::ToInt32($Matches[1], 16)
    } elseif ($spec.Length -eq 1 -or ($spec.Length -eq 2 -and [char]::IsSurrogatePair($spec, 0))) {
        $cp = [char]::ConvertToUtf32($spec, 0)
    } else {
        Say 'Give one character, or its code like U+201C.' Red
        return
    }
    $key = 'map_u+{0:x4}' -f $cp
    $glyph = [char]::ConvertFromUtf32($cp)
    if ($parts.Count -lt 2) {
        $now = ConvertTo-LilyAscii $glyph
        $how = if ($Cfg.Contains($key)) { 'your mapping' } else { 'built in' }
        Say ("{0} (U+{1:X4}) is sent as: {2}   ({3})" -f $glyph, $cp, $now, $how)
        return
    }
    $val = $parts[1].Trim()
    if ($val -eq 'off') {
        if ($Cfg.Contains($key))     { $Cfg.Remove($key) }
        if ($FileCfg.Contains($key)) { $FileCfg.Remove($key) }
        Save-ConfigFile
        Update-Derived
        Say ("{0} is back to the built-in mapping: {1} (saved)" -f $glyph, (ConvertTo-LilyAscii $glyph))
        return
    }
    $plain = if ($val -match '^"(.*)"$') { $Matches[1] } else { $val }
    if ($plain -match '[^\x00-\x7F]') { Say 'The replacement has to be plain ASCII.' Red; return }
    $stored = if ($plain -ne $plain.Trim() -or $plain -eq '') { '"' + $plain + '"' } else { $plain }
    $Cfg[$key] = $stored
    $FileCfg[$key] = $stored
    Save-ConfigFile
    Update-Derived
    Say ("{0} will be sent as: {1} (saved)" -f $glyph, $plain)
}

# $$user                         list per-user colors
# $$user <name>                  show one
# $$user <name> <fg> [on <bg>]   set it (saved)
# $$user <name> off              remove it
function Invoke-UserCommand([string]$arg) {
    $keys = @($Cfg.Keys | Where-Object { $_ -like 'user_*' } | Sort-Object)
    if (-not "$arg".Trim()) {
        if ($keys.Count -eq 0) { Say 'No per-user colors yet. Example: $$user strider yellow on dark_red'; return }
        Say 'Private messages from these people use their own colors:'
        foreach ($k in $keys) { Show-UserColor $k }
        return
    }
    $parts = $arg.Trim() -split '\s+', 2
    $key = Get-UserKey $parts[0]
    if ($parts.Count -lt 2) {
        if ($Cfg.Contains($key)) { Show-UserColor $key } else { Say "$($parts[0]) has no color of their own." }
        return
    }
    $val = $parts[1].Trim().ToLower()
    if ($val -match '^(off|none|default)$') {
        if ($Cfg.Contains($key))     { $Cfg.Remove($key) }
        if ($FileCfg.Contains($key)) { $FileCfg.Remove($key) }
        Save-ConfigFile
        Update-Derived
        Say "$($parts[0]) is back to the normal private colors (saved)"
        return
    }
    try { $null = ConvertTo-UserStyle $val } catch { Say $_ Red; return }
    $Cfg[$key] = $val
    $FileCfg[$key] = $val
    Save-ConfigFile
    Update-Derived
    Show-UserColor $key
}

# Handles a line that started with $$. Returns 'quit' to disconnect.
function Invoke-LocalCommand([string]$cmd) {
    $parts = $cmd.Trim() -split '\s+', 2
    $name  = $parts[0].ToLower()
    $arg   = if ($parts.Count -gt 1) { $parts[1] } else { $null }
    if ($Aliases.ContainsKey($name)) { $name = $Aliases[$name] }

    switch ($name) {
        ''       { Show-LocalHelp; return }
        'help'   { Show-LocalHelp; return }
        'quit'   { return 'quit' }
        'user'   { Invoke-UserCommand $arg; return }
        'map'    { Invoke-MapCommand $arg; return }
        'send'   { if ($null -ne $arg) { Send-Line $arg }; return }
        'reload' {
            $script:FileCfg = (Read-ConfigFile $Config).Values
            $script:Cfg = [ordered]@{}
            foreach ($k in $FileCfg.Keys) { $Cfg[$k] = $FileCfg[$k] }
            Update-Derived
            Initialize-Spell
            Set-MouseMode
            Say "Reloaded $Config"
            return
        }
    }

    if (-not $Schema.Contains($name)) {
        Say "Unknown client command '`$`$$name'. Type `$`$ for the list." Red
        return
    }
    $type = $Schema[$name].Type

    if ($null -eq $arg -and $type -ne 'bool') {
        $v = if ($Cfg[$name]) { $Cfg[$name] } else { '(off)' }
        Say "$name is $v"
        return
    }

    # Work out and validate the new value
    $new = $arg
    switch ($type) {
        'bool' {
            if     ($null -eq $arg)                   { $new = if (ConvertTo-Bool $Cfg[$name]) { 'off' } else { 'on' } }
            elseif ($arg -match '^(on|true|1|yes)$')  { $new = 'on' }
            elseif ($arg -match '^(off|false|0|no)$') { $new = 'off' }
            else { Say 'Use on or off.' Red; return }
        }
        'int' {
            if ($arg -notmatch '^\d+$') { Say 'Use a number.' Red; return }
        }
        'color' {
            try { $null = ConvertTo-ConsoleColor $arg } catch { Say $_ Red; return }
            $new = $arg.ToLower()
        }
        'regex' {
            try { $null = [regex]::new($arg) } catch { Say "Bad pattern: $($_.Exception.Message)" Red; return }
        }
        'string' {
            if ($arg -match '^(off|none)$') { $new = '' }
        }
    }

    $Cfg[$name] = $new
    $FileCfg[$name] = $new
    Save-ConfigFile
    Update-Derived
    $shown = if ($new) { $new } else { '(off)' }
    Say "$name is $shown (saved)"
    if ($name -eq 'block_mouse') { Set-MouseMode }
    if ($name -in 'base_fg', 'base_bg') {
        Reset-ConsoleColors
        Say 'New text uses it now; the whole window is repainted next time pslilly starts.' Gray
    }
    if ($name -in 'spellcheck', 'spell_language') {
        Initialize-Spell
        if ($script:SpellNote) { Say $script:SpellNote DarkYellow }
    }
}

# ---------------------------------------------------------------------------
# Input loop
# ---------------------------------------------------------------------------
# Let Ctrl+C reach the line editor (copy); with nothing selected it still quits
$oldCtrlC = $false
try { $oldCtrlC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch {}

try {
    while ($sync.Running -and $client.Connected) {
        $line = Read-InputLine
        if ($null -eq $line) { break }

        # Remember it for Up-arrow recall (never passwords, no repeats)
        if ($line -and -not $script:LastLineSecret -and
            ($History.Count -eq 0 -or $History[$History.Count - 1] -ne $line)) {
            $History.Add($line)
            if ($History.Count -gt $HistoryMax) { $History.RemoveAt(0) }
        }

        if ($line -eq '/!quit') { break }
        if ($line.StartsWith('$$')) {
            if ((Invoke-LocalCommand $line.Substring(2)) -eq 'quit') { break }
            continue
        }

        # Clear the remembered prompt BEFORE sending: the server can answer
        # (e.g. with "password:") before Send-Line even returns.
        $wasSecret = Test-PasswordPrompt
        $sync.Tail = ''
        $sync.ResetPending = $true
        # SLCP: ask for structured output right before the login name goes out
        if ($sync.Slcp -and -not $sync.OptionsSent) {
            Send-Line '#$# options +version +prompt +prompt2 +leaf-notify +leaf-cmd +connected'
            $sync.OptionsSent = $true
        }
        $out = $line
        if (ConvertTo-Bool $Cfg.ascii) {
            try { $out = ConvertTo-LilyAscii $line } catch { $out = $line }
            if (-not [string]::Equals($out, $line, [StringComparison]::Ordinal) -and -not $script:LastLineSecret) { Say "  (sent as: $out)" DarkGray }
        }
        Send-Line $out
        if ($script:LastLineLogin) { $sync.LoginName = ($line.Trim() -split '\s+')[0] }
        if (-not $wasSecret) { Update-LastTo $line }
    }
} catch {
    Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    $sync.Quitting = $true
    try { if ($null -ne $script:OldTitle) { [Console]::Title = $script:OldTitle } } catch {}
    try { [Console]::ResetColor() } catch {}
    $sync.Running = $false
    try { $client.Close() } catch {}
    try { [Console]::TreatControlCAsInput = $oldCtrlC } catch {}
    try { if ('PsLilly.ConMode' -as [type]) { [PsLilly.ConMode]::Restore() } } catch {}
    try { $null = $handle.AsyncWaitHandle.WaitOne(2000) } catch {}
    try { $ps.Dispose(); $rs.Close() } catch {}
    Write-Host 'Disconnected.' -ForegroundColor DarkGray
}
