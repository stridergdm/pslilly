<#
    pslilly-core.ps1 - the engine behind the pslilly window (pslilly-gui.ps1).

    Everything that isn't drawing lives here: settings (lily.conf), the
    connection to the Lily server and its SLCP protocol, automatic login,
    reconnecting, keepalive, message formatting, ASCII conversion, spell
    checking, saved passwords, name completion and the $$ commands.

    The engine never touches the screen. It adds "records" to $s.Out (a line
    to show, a new window title, "flash the taskbar", "ask for the password",
    ...) and the window drains and draws them.

    Works in Windows PowerShell 5.1 and PowerShell 7. Keep this file ASCII.

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>

$script:LillyVersion = '0.7'

# ---------------------------------------------------------------------------
# Settings. Shared with the console client (pslilly.ps1) through lily.conf;
# settings either one doesn't know about are kept as they are.
# Types: string, int, bool, color, style, regex.  Hidden ones aren't listed.
# ---------------------------------------------------------------------------
$script:LillySchema = [ordered]@{
    default_server       = @{ Type = 'string'; Default = 'lily.acm.rpi.edu'; Help = 'server to connect to' }
    default_port         = @{ Type = 'int';    Default = '7777';             Help = 'port to connect to' }
    font                 = @{ Type = 'string'; Default = 'Consolas';         Help = 'font for messages and typing' }
    font_size            = @{ Type = 'int';    Default = '11';               Help = 'font size (Ctrl+mouse wheel zooms too)' }
    input_lines          = @{ Type = 'int';    Default = '3';                Help = 'height of the typing box, in lines' }
    scrollback           = @{ Type = 'int';    Default = '5000';             Help = 'lines of history kept in the window' }
    base_fg              = @{ Type = 'color';  Default = 'default';          Help = 'normal text color' }
    base_bg              = @{ Type = 'color';  Default = 'default';          Help = 'window background' }
    public_fg            = @{ Type = 'color';  Default = 'white';            Help = 'public message text' }
    public_bg            = @{ Type = 'color';  Default = 'dark_blue';        Help = 'public message background' }
    public_style         = @{ Type = 'style';  Default = 'normal';           Help = 'normal, bold, italic, underline (combine freely)' }
    private_fg           = @{ Type = 'color';  Default = 'yellow';           Help = 'private message text' }
    private_bg           = @{ Type = 'color';  Default = 'dark_blue';        Help = 'private message background' }
    private_style        = @{ Type = 'style';  Default = 'normal';           Help = 'normal, bold, italic, underline' }
    emote_fg             = @{ Type = 'color';  Default = 'purple';           Help = 'emote text' }
    emote_bg             = @{ Type = 'color';  Default = 'green';            Help = 'emote background' }
    emote_style          = @{ Type = 'style';  Default = 'normal';           Help = 'normal, bold, italic, underline' }
    system_fg            = @{ Type = 'color';  Default = 'default';          Help = 'arrivals, departures, blurbs, etc.' }
    system_bg            = @{ Type = 'color';  Default = 'default';          Help = 'background for those' }
    system_style         = @{ Type = 'style';  Default = 'normal';           Help = 'normal, bold, italic, underline' }
    mine_fg              = @{ Type = 'color';  Default = 'dark_gray';        Help = 'your own typed lines (echo)' }
    mine_bg              = @{ Type = 'color';  Default = 'default';          Help = 'background for those' }
    mine_style           = @{ Type = 'style';  Default = 'normal';           Help = 'normal, bold, italic, underline' }
    command_fg           = @{ Type = 'color';  Default = 'gray';             Help = 'output of $$! commands' }
    command_bg           = @{ Type = 'color';  Default = 'default';          Help = 'background for that' }
    command_style        = @{ Type = 'style';  Default = 'normal';           Help = 'normal, bold, italic, underline' }
    spell_fg             = @{ Type = 'color';  Default = 'red';              Help = 'misspelled words (also underlined)' }
    spell_bg             = @{ Type = 'color';  Default = 'default';          Help = 'background for those' }
    echo_input           = @{ Type = 'bool';   Default = 'on';               Help = 'show the lines you send in the message pane' }
    alert_private        = @{ Type = 'bool';   Default = 'on';               Help = 'flash the taskbar on a private message' }
    alert_sound          = @{ Type = 'bool';   Default = 'off';              Help = 'also play a sound on a private message' }
    auto_reconnect       = @{ Type = 'bool';   Default = 'on';               Help = 'reconnect by itself after a drop or sleep' }
    keepalive            = @{ Type = 'int';    Default = '5';                Help = 'minutes of quiet before a keepalive ping (0 = off)' }
    away_on_lock         = @{ Type = 'bool';   Default = 'on';               Help = 'go away when the PC locks or sleeps, back on unlock' }
    away_command         = @{ Type = 'string'; Default = '/away';            Help = 'sent when the PC locks or sleeps' }
    here_command         = @{ Type = 'string'; Default = '/here';            Help = 'sent when you come back' }
    quit_command         = @{ Type = 'string'; Default = '';                 Help = 'sent before closing (empty = just disconnect)' }
    slcp                 = @{ Type = 'bool';   Default = 'on';               Help = 'use SLCP (takes effect next connect)' }
    ascii                = @{ Type = 'bool';   Default = 'on';               Help = 'turn smart quotes, accents, emoji... into ASCII when sending' }
    accent_marks         = @{ Type = 'bool';   Default = 'off';              Help = 'e-acute becomes e'' instead of e' }
    spellcheck           = @{ Type = 'bool';   Default = 'on';               Help = 'spell check your typing' }
    spell_language       = @{ Type = 'string'; Default = 'auto';             Help = 'e.g. en-US, or auto = Windows language' }
    showsent             = @{ Type = 'bool';   Default = 'off';              Help = 'show the bytes of each line sent' }
    logfile              = @{ Type = 'string'; Default = '';                 Help = 'transcript file ("off" to stop)' }
    private_pattern      = @{ Type = 'regex';  Default = '^\s*>>\s*(\([\d:]+\)\s*)?Private message from (?<from>[^,:]+)'; Help = 'plain-text mode: private message' }
    public_pattern       = @{ Type = 'regex';  Default = '^\s*->\s*(\([\d:]+\)\s*)?From\s';  Help = 'plain-text mode: public message' }
    emote_pattern        = @{ Type = 'regex';  Default = '^\s*>\s+\S';       Help = 'plain-text mode: emote' }
    continuation_pattern = @{ Type = 'regex';  Default = '^\s*-\s';          Help = 'plain-text mode: body lines' }
    last_user            = @{ Type = 'string'; Default = '';                 Help = 'name used last time'; Hidden = $true }
    window               = @{ Type = 'string'; Default = '';                 Help = 'window position and size'; Hidden = $true }
}
$script:LillyAliases = @{ server = 'default_server'; port = 'default_port'; emote_fb = 'emote_fg' }
$script:LillyClasses = @('public', 'private', 'emote', 'system', 'mine', 'command', 'spell')

# Windows Terminal "Campbell" colors, so the window looks like the console version
$script:LillyRgb = @{
    Black = @(12, 12, 12);      DarkBlue = @(0, 55, 218);     DarkGreen = @(19, 161, 14)
    DarkCyan = @(58, 150, 221); DarkRed = @(197, 15, 31);     DarkMagenta = @(136, 23, 152)
    DarkYellow = @(193, 156, 0); Gray = @(204, 204, 204);     DarkGray = @(118, 118, 118)
    Blue = @(59, 120, 255);     Green = @(22, 198, 12);       Cyan = @(97, 214, 214)
    Red = @(231, 72, 86);       Magenta = @(180, 0, 158);     Yellow = @(249, 241, 165)
    White = @(242, 242, 242)
}

function Test-LillyWindows { [Environment]::OSVersion.Platform -eq 'Win32NT' }

function ConvertTo-LillyBool([string]$v) { $v -match '^(on|true|1|yes)$' }

# "dark_blue" -> [ConsoleColor]::DarkBlue; "default" -> $null
function ConvertTo-LillyColor([string]$name) {
    $n = ($name -replace '[\s_-]', '').ToLower()
    if (-not $n -or $n -in 'default', 'none', 'off') { return $null }
    $map = @{ purple = 'Magenta'; darkpurple = 'DarkMagenta'; grey = 'Gray'; darkgrey = 'DarkGray';
              lightgray = 'Gray'; lightgrey = 'Gray'; brown = 'DarkYellow'; orange = 'DarkYellow' }
    if ($map.ContainsKey($n)) { $n = $map[$n] }
    $match = [Enum]::GetNames([ConsoleColor]) | Where-Object { $_ -eq $n } | Select-Object -First 1
    if ($match) { return [ConsoleColor]$match }
    throw "Unknown color '$name'. Try: black, dark_blue, dark_green, dark_cyan, dark_red, dark_purple, dark_yellow, gray, dark_gray, blue, green, cyan, red, purple, yellow, white, default"
}

# A style: any of "yellow", "yellow on dark_red", "on dark_red", "yellow dark_red",
# plus the words bold / italic / underline / normal anywhere.
# Returns @{ Fg; Bg; Bold; Italic; Underline } ($null colors = not set).
function ConvertTo-LillyStyle([string]$v) {
    $st = @{ Fg = $null; Bg = $null; Bold = $false; Italic = $false; Underline = $false }
    $words = @("$v".Trim().ToLower() -split '\s+' | Where-Object { $_ })
    $colors = @()
    $nextIsBg = $false
    foreach ($w in $words) {
        switch ($w) {
            'on'        { $nextIsBg = $true; continue }
            'bold'      { $st.Bold = $true; continue }
            'italic'    { $st.Italic = $true; continue }
            'underline' { $st.Underline = $true; continue }
            'normal'    { continue }
            default {
                $c = ConvertTo-LillyColor $w
                if ($nextIsBg) { $st.Bg = $c; $nextIsBg = $false }
                else { $colors += , $c }
            }
        }
    }
    if ($colors.Count -ge 1) { $st.Fg = $colors[0] }
    if ($colors.Count -ge 2 -and $null -eq $st.Bg) { $st.Bg = $colors[1] }
    return $st
}

# Config key for a user's style: user_<name>, lower case, spaces/dashes as _
function Get-LillyUserKey([string]$name) { 'user_' + ($name.Trim().ToLower() -replace '[\s-]+', '_') }

# ---------------------------------------------------------------------------
# lily.conf
# ---------------------------------------------------------------------------
function Read-LillyConfig([string]$path) {
    $vals = [ordered]@{}
    foreach ($k in $LillySchema.Keys) { $vals[$k] = $LillySchema[$k].Default }
    $complete = $false
    if (Test-Path -LiteralPath $path) {
        $seen = @{}
        foreach ($raw in Get-Content -LiteralPath $path) {
            $l = $raw.Trim()
            if (-not $l -or $l.StartsWith('#')) { continue }
            $i = $l.IndexOfAny([char[]]':=')
            if ($i -lt 1) { continue }
            $k = ($l.Substring(0, $i).Trim().ToLower()) -replace '[\s-]', '_'
            if ($LillyAliases.ContainsKey($k)) { $k = $LillyAliases[$k] }
            $vals[$k] = $l.Substring($i + 1).Trim()
            $seen[$k] = $true
        }
        $complete = @($LillySchema.Keys | Where-Object { -not $seen.ContainsKey($_) }).Count -eq 0
    }
    return @{ Values = $vals; Complete = $complete }
}

function Save-LillyConfig($s) {
    $lines = @(
        '# pslilly settings, shared by pslilly.ps1 (console) and pslilly-gui.ps1 (window).',
        '# Edit here (then $$reload) or with $$<setting> <value> in either client.',
        '# Colors: black, dark_blue, dark_green, dark_cyan, dark_red, dark_purple, dark_yellow,',
        '#         gray, dark_gray, blue, green, cyan, red, purple, yellow, white, default',
        ''
    )
    foreach ($k in $s.FileCfg.Keys) { $lines += "${k}: $($s.FileCfg[$k])" }
    try {
        Set-Content -LiteralPath $s.ConfigPath -Value $lines -Encoding UTF8
    } catch {
        Write-LillyNote $s "Could not save $($s.ConfigPath): $($_.Exception.Message)" 'error'
    }
}

# Set one setting for this session and in lily.conf
function Set-LillySetting($s, [string]$name, [string]$value) {
    $s.Cfg[$name] = $value
    $s.FileCfg[$name] = $value
    Save-LillyConfig $s
    Update-LillyDerived $s
}

# Recompute everything that depends on settings
function Update-LillyDerived($s) {
    $c = $s.Cfg
    $s.ShowSent = ConvertTo-LillyBool $c.showsent
    $s.LogFile  = if ($c.logfile) { $c.logfile } else { $null }
    if ($s.State -eq 'disconnected' -or $s.State -eq 'waiting') { $s.Slcp = ConvertTo-LillyBool $c.slcp }
    try { $s.BaseFg = ConvertTo-LillyColor $c.base_fg } catch { $s.BaseFg = $null }
    try { $s.BaseBg = ConvertTo-LillyColor $c.base_bg } catch { $s.BaseBg = $null }
    foreach ($cls in $LillyClasses) {
        $st = @{ Fg = $null; Bg = $null; Bold = $false; Italic = $false; Underline = $false }
        try { $st.Fg = ConvertTo-LillyColor $c["${cls}_fg"] } catch { Write-LillyNote $s "${cls}_fg: $($_.Exception.Message)" 'error' }
        try { $st.Bg = ConvertTo-LillyColor $c["${cls}_bg"] } catch { Write-LillyNote $s "${cls}_bg: $($_.Exception.Message)" 'error' }
        if ($c.Contains("${cls}_style")) {
            try {
                $x = ConvertTo-LillyStyle $c["${cls}_style"]
                $st.Bold = $x.Bold; $st.Italic = $x.Italic; $st.Underline = $x.Underline
            } catch { Write-LillyNote $s "${cls}_style: $($_.Exception.Message)" 'error' }
        }
        $s.Styles[$cls] = $st
    }
    # error notes and plain notes reuse the system style, errors in red
    $s.Styles['error'] = @{ Fg = [ConsoleColor]::Red; Bg = $null; Bold = $false; Italic = $false; Underline = $false }
    $us = @{}
    foreach ($k in @($c.Keys)) {
        if ($k -notlike 'user_*') { continue }
        try { $us[$k] = ConvertTo-LillyStyle $c[$k] } catch { Write-LillyNote $s "${k}: $($_.Exception.Message)" 'error' }
    }
    $s.UserStyles = $us
    foreach ($p in 'private', 'public', 'emote', 'continuation') {
        $pat = $c["${p}_pattern"]
        $s.Rx[$p] = $null
        if ($pat) {
            try { $s.Rx[$p] = [regex]::new($pat, 'IgnoreCase') }
            catch { Write-LillyNote $s "Bad ${p}_pattern: $($_.Exception.Message)" 'error' }
        }
    }
    $script:AsciiUser = @{}
    foreach ($k in @($c.Keys)) {
        if ($k -match '^map_u\+?([0-9a-f]{2,6})$') {
            $v = [string]$c[$k]
            if ($v -match '^"(.*)"$') { $v = $Matches[1] }
            $script:AsciiUser[[Convert]::ToInt32($Matches[1], 16)] = $v
        }
    }
    $script:AccentMarks = ConvertTo-LillyBool $c.accent_marks
    $s.Out.Add(@{ Type = 'config' })
}

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
# Spell checking through the Windows spell checker (Windows 8 and later).
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

function Initialize-LillySpell($s) {
    $s.SpellReady = $false
    $s.SpellNote  = $null
    if (-not (ConvertTo-LillyBool $s.Cfg.spellcheck)) { return }
    if (-not (Test-LillyWindows)) { $s.SpellNote = 'Spell checking needs Windows, so it is off here.'; return }
    try {
        if (-not ('PsLilly.WinSpell' -as [type])) { Add-Type -TypeDefinition $WinSpellCode -Language CSharp }
        $lang = if ($s.Cfg.spell_language -and $s.Cfg.spell_language -ne 'auto') { $s.Cfg.spell_language }
                else { [Globalization.CultureInfo]::CurrentUICulture.Name }
        $err = [PsLilly.WinSpell]::Init($lang)
        if ($err) { $s.SpellNote = $err; return }
        $s.SpellReady = $true
    } catch {
        $s.SpellNote = "Spell checking couldn't start: $($_.Exception.Message)"
    }
}

function Get-LillySpellErrors([string]$text)      { [PsLilly.WinSpell]::Check($text) }
function Get-LillySpellSuggestions([string]$word) { [PsLilly.WinSpell]::Suggest($word) }
function Add-LillySpellWord([string]$word)        { [PsLilly.WinSpell]::Add($word) }

# Misspellings as start, length pairs. Skips commands, the "name:" of a send,
# user/discussion names, and anything with digits, @ or ://
function Get-LillySpellRanges($s, [string]$text) {
    $none = [int[]]@()
    if (-not $s.SpellReady -or -not $text) { return ,$none }
    if ($text -match '^\s*[/$?%#]') { return ,$none }
    $off = 0
    if ($text -match '^[^\s:;]+[:;]') { $off = $Matches[0].Length }
    $body = $text.Substring($off)
    $raw = @()
    try { $raw = Get-LillySpellErrors $body } catch { return ,$none }
    $out = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i + 1 -lt $raw.Count; $i += 2) {
        $word = $body.Substring($raw[$i], $raw[$i + 1])
        if ($s.NameSet.ContainsKey($word.ToLower())) { continue }
        if ($word -match '://|@|\d') { continue }
        $out.Add($raw[$i] + $off); $out.Add($raw[$i + 1])
    }
    return ,$out.ToArray()
}

# ---------------------------------------------------------------------------
# Saved passwords: Windows Credential Manager (encrypted with your Windows
# login; you can see or remove it in Control Panel > Credential Manager >
# Windows Credentials, as "pslilly:<server>").
# ---------------------------------------------------------------------------
$CredStoreCode = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace PsLilly {
    public static class CredStore {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct CREDENTIAL {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public int LastWrittenLow;
            public int LastWrittenHigh;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CredWriteW(ref CREDENTIAL cred, int flags);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CredReadW(string target, int type, int flags, out IntPtr cred);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CredDeleteW(string target, int type, int flags);
        [DllImport("advapi32.dll")]
        static extern void CredFree(IntPtr buffer);

        const int CRED_TYPE_GENERIC = 1;
        const int CRED_PERSIST_LOCAL_MACHINE = 2;

        public static void Write(string target, string user, string password) {
            byte[] blob = Encoding.Unicode.GetBytes(password);
            CREDENTIAL c = new CREDENTIAL();
            c.Type = CRED_TYPE_GENERIC;
            c.TargetName = target;
            c.UserName = user;
            c.Comment = "pslilly Lily client";
            c.Persist = CRED_PERSIST_LOCAL_MACHINE;
            c.CredentialBlobSize = blob.Length;
            c.CredentialBlob = Marshal.AllocHGlobal(blob.Length > 0 ? blob.Length : 1);
            try {
                Marshal.Copy(blob, 0, c.CredentialBlob, blob.Length);
                if (!CredWriteW(ref c, 0)) {
                    throw new InvalidOperationException("Windows refused to save the password (error " + Marshal.GetLastWin32Error() + ")");
                }
            } finally {
                for (int i = 0; i < blob.Length; i++) { Marshal.WriteByte(c.CredentialBlob, i, 0); blob[i] = 0; }
                Marshal.FreeHGlobal(c.CredentialBlob);
            }
        }

        // { user, password }, or null if nothing is saved
        public static string[] Read(string target) {
            IntPtr p;
            if (!CredReadW(target, CRED_TYPE_GENERIC, 0, out p)) { return null; }
            try {
                CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
                string pw = c.CredentialBlobSize > 0 ? Marshal.PtrToStringUni(c.CredentialBlob, c.CredentialBlobSize / 2) : "";
                return new string[] { c.UserName, pw };
            } finally {
                CredFree(p);
            }
        }

        public static bool Delete(string target) { return CredDeleteW(target, CRED_TYPE_GENERIC, 0); }
    }
}
'@

function Get-LillyCredTarget([string]$server) { 'pslilly:' + $server.Trim().ToLower() }

function Initialize-LillyCredStore {
    if (-not (Test-LillyWindows)) { return $false }
    try {
        if (-not ('PsLilly.CredStore' -as [type])) { Add-Type -TypeDefinition $CredStoreCode -Language CSharp }
        return $true
    } catch { return $false }
}

# @{ Name; Password = SecureString } or $null
function Get-LillySavedLogin([string]$server) {
    if (-not (Initialize-LillyCredStore)) { return $null }
    try {
        $r = [PsLilly.CredStore]::Read((Get-LillyCredTarget $server))
        if (-not $r -or -not $r[0]) { return $null }
        $sec = New-Object System.Security.SecureString
        foreach ($ch in $r[1].ToCharArray()) { $sec.AppendChar($ch) }
        $sec.MakeReadOnly()
        return @{ Name = $r[0]; Password = $sec }
    } catch { return $null }
}

function Save-LillyLogin([string]$server, [string]$name, [System.Security.SecureString]$password) {
    if (-not (Initialize-LillyCredStore)) { throw 'Saving passwords needs Windows.' }
    [PsLilly.CredStore]::Write((Get-LillyCredTarget $server), $name, (ConvertFrom-LillySecure $password))
}

function Remove-LillySavedLogin([string]$server) {
    if (-not (Initialize-LillyCredStore)) { return $false }
    try { return [PsLilly.CredStore]::Delete((Get-LillyCredTarget $server)) } catch { return $false }
}

function ConvertFrom-LillySecure([System.Security.SecureString]$sec) {
    if (-not $sec) { return '' }
    return [System.Net.NetworkCredential]::new('', $sec).Password
}

function ConvertTo-LillySecure([string]$plain) {
    $sec = New-Object System.Security.SecureString
    foreach ($ch in "$plain".ToCharArray()) { $sec.AppendChar($ch) }
    $sec.MakeReadOnly()
    return $sec
}

# ---------------------------------------------------------------------------
# The session: one per window. A hashtable so every function can update it.
# ---------------------------------------------------------------------------
function New-LillySession([string]$ConfigPath) {
    $s = @{
        ConfigPath   = $ConfigPath
        Cfg          = $null
        FileCfg      = $null
        Out          = [System.Collections.Generic.List[object]]::new()   # records for the window
        State        = 'disconnected'   # disconnected, connecting, login, connected, waiting
        Status       = 'Not connected'
        Server       = $null
        Port         = 7777
        Client       = $null
        Stream       = $null
        ConnectTask  = $null
        ConnectStart = $null
        Enc          = [System.Text.UTF8Encoding]::new($false)
        Decoder      = $null
        Buf          = New-Object byte[] 8192
        Chars        = New-Object char[] 16384
        Login        = @{ Name = $null; Password = $null; Stage = 'none' }
        Reconnecting = $false
        ReconnectAt  = $null
        ReconnectDelay = 5
        UserQuit     = $false
        Telnet       = 0
        TelVerb      = 0
        ServerEcho   = $false
        Pending      = ''
        Printed      = 0
        OpenPartial  = $false
        Tail         = ''
        Slcp         = $true
        OptionsSent  = $false
        LoggedIn     = $false
        WhoAmI       = $null
        Ents         = @{}
        NameSet      = @{}
        LastFrom     = $null
        LastTo       = $null
        LastBlurb    = ''
        BlurbPrompt  = $false
        LastActivity = [DateTime]::UtcNow
        PingSentAt   = $null
        PingTimeout  = 60
        AutoAway     = $false
        LeaveAt      = $null    # you sent /detach or /bye at this time: don't reconnect when the server closes
        Cls          = $null
        PrivUser     = $null
        Styles       = @{}
        UserStyles   = @{}
        Rx           = @{}
        BaseFg       = $null
        BaseBg       = $null
        ShowSent     = $false
        LogFile      = $null
        Commands     = [System.Collections.Generic.List[object]]::new()
        SpellReady   = $false
        SpellNote    = $null
        ExtraHelp    = @()
    }
    $loaded = Read-LillyConfig $ConfigPath
    $s.FileCfg = $loaded.Values
    if (-not $loaded.Complete) { Save-LillyConfig $s }
    $s.Cfg = [ordered]@{}
    foreach ($k in $s.FileCfg.Keys) { $s.Cfg[$k] = $s.FileCfg[$k] }
    $s.Server = $s.Cfg.default_server
    $p = 0
    if ([int]::TryParse([string]$s.Cfg.default_port, [ref]$p)) { $s.Port = $p }
    Update-LillyDerived $s
    Initialize-LillySpell $s
    return $s
}

# ---- records for the window ----------------------------------------------
# line:    a full line of text in a style class (Style overrides it, Hang = indent
#          for wrapped lines, in characters)
# partial: text without a line break (a prompt such as "login: ")
# -Continue: this line finishes the prompt that's showing (e.g. your answer
# to "login: "); otherwise anything after an open prompt starts a new row.
function Write-LillyLine($s, [string]$text, [string]$cls = '', $style = $null, [int]$hang = 0, [switch]$Continue) {
    if ($s.OpenPartial -and -not $Continue) { $s.Out.Add(@{ Type = 'newline' }) }
    $s.OpenPartial = $false
    $s.Out.Add(@{ Type = 'line'; Text = $text; Class = $cls; Style = $style; Hang = $hang })
    if ($s.LogFile) { try { Add-Content -LiteralPath $s.LogFile -Value $text } catch {} }
}
function Write-LillyPartial($s, [string]$text) {
    $s.Out.Add(@{ Type = 'partial'; Text = $text })
    $s.OpenPartial = $true
    if ($s.LogFile) { try { Add-Content -LiteralPath $s.LogFile -Value $text -NoNewline } catch {} }
}
# pslilly's own messages
function Write-LillyNote($s, [string]$text, [string]$cls = 'system') {
    if ($s.OpenPartial) { $s.Out.Add(@{ Type = 'newline' }); $s.OpenPartial = $false }
    $s.Out.Add(@{ Type = 'line'; Text = $text; Class = $cls; Style = $null; Hang = 0 })
}
function Set-LillyStatus($s, [string]$text) {
    $s.Status = $text
    $s.Out.Add(@{ Type = 'status'; Text = $text })
}
function Set-LillyTitle($s, [string]$name) {
    $t = if ($name) { "PSLilly - $name" } else { 'PSLilly' }
    $s.Out.Add(@{ Type = 'title'; Text = $t })
}

# ---------------------------------------------------------------------------
# Connecting, sending, receiving
# ---------------------------------------------------------------------------
function Connect-LillySession($s, [switch]$Reconnect) {
    Close-LillySocket $s
    $s.UserQuit     = $false
    $s.Reconnecting = [bool]$Reconnect
    $s.Slcp         = ConvertTo-LillyBool $s.Cfg.slcp
    $s.Telnet = 0; $s.TelVerb = 0; $s.ServerEcho = $false
    $s.Pending = ''; $s.Printed = 0; $s.Tail = ''; $s.OpenPartial = $false
    $s.OptionsSent = $false; $s.LoggedIn = $false
    $s.PingSentAt = $null; $s.BlurbPrompt = $false; $s.LeaveAt = $null
    $s.Cls = $null; $s.PrivUser = $null
    $s.Login.Stage = 'none'
    $s.Decoder = $s.Enc.GetDecoder()
    $s.Client = [System.Net.Sockets.TcpClient]::new()
    $s.Client.NoDelay = $true
    $s.ConnectTask = $s.Client.ConnectAsync($s.Server, [int]$s.Port)
    $s.ConnectStart = [DateTime]::UtcNow
    $s.State = 'connecting'
    $what = if ($Reconnect) { 'Reconnecting' } else { 'Connecting' }
    Set-LillyStatus $s "$what to $($s.Server):$($s.Port)..."
    Write-LillyNote $s "*** $what to $($s.Server):$($s.Port)... ***"
}

function Close-LillySocket($s) {
    if ($s.Client) {
        try { $s.Client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Both) } catch {}
        try { $s.Client.Close() } catch {}
    }
    $s.Client = $null; $s.Stream = $null; $s.ConnectTask = $null
}

# You closed it (or $$disconnect): optionally say goodbye, no reconnecting
function Disconnect-LillySession($s, [switch]$Goodbye) {
    $s.UserQuit = $true
    if ($Goodbye -and $s.State -eq 'connected' -and $s.Cfg.quit_command) {
        try { Send-LillyRaw $s $s.Cfg.quit_command; Start-Sleep -Milliseconds 200 } catch {}
    }
    $was = $s.State
    Close-LillySocket $s
    $s.State = 'disconnected'
    $s.LoggedIn = $false
    if ($was -ne 'disconnected') {
        Write-LillyNote $s '*** Disconnected. ($$connect to log in again) ***'
    }
    Set-LillyStatus $s 'Not connected'
    Set-LillyTitle $s $null
}

# The connection went away by itself
function Invoke-LillyConnectionLost($s, [string]$why, [int]$retryIn = -1) {
    Close-LillySocket $s
    $s.LoggedIn = $false
    if ($s.UserQuit) { $s.State = 'disconnected'; return }
    if ($s.LeaveAt -and ([DateTime]::UtcNow - $s.LeaveAt).TotalSeconds -lt 30) {
        # you detached / logged out: stay that way
        $s.LeaveAt = $null
        $s.State = 'disconnected'
        Write-LillyNote $s '*** Detached. ($$connect or $$reconnect to log back in) ***'
        Set-LillyStatus $s 'Detached'
        Set-LillyTitle $s $null
        return
    }
    $failed = $s.Login.Stage -eq 'failed'
    Write-LillyNote $s "*** Connection lost$(if ($why) { " ($why)" }). ***"
    Set-LillyTitle $s $null
    $canRetry = (ConvertTo-LillyBool $s.Cfg.auto_reconnect) -and $s.Login.Name -and $s.Login.Password -and -not $failed
    if ($canRetry) {
        Start-LillyReconnectWait $s $retryIn
    } else {
        $s.State = 'disconnected'
        Set-LillyStatus $s 'Not connected'
        if (-not $failed) { Write-LillyNote $s '*** Type $$connect to log in again. ***' }
    }
}

function Start-LillyReconnectWait($s, [int]$seconds = -1) {
    if ($seconds -lt 0) { $seconds = $s.ReconnectDelay; $s.ReconnectDelay = [Math]::Min(300, $s.ReconnectDelay * 2) }
    $s.State = 'waiting'
    $s.ReconnectAt = [DateTime]::UtcNow.AddSeconds($seconds)
    if ($seconds -gt 0) {
        Write-LillyNote $s "*** Reconnecting in $seconds seconds. (`$`$reconnect = now, `$`$disconnect = stop) ***"
        Set-LillyStatus $s "Reconnecting in $seconds s"
    } else {
        Set-LillyStatus $s 'Reconnecting...'
    }
}

function Send-LillyRaw($s, [string]$line, [switch]$Secret) {
    if (-not $s.Stream) { throw 'not connected' }
    $bytes = $s.Enc.GetBytes($line + "`r`n")
    if ($s.ShowSent) {
        $hex = if ($Secret) { '(hidden)' } else { ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ' }
        Write-LillyNote $s "[sent] $hex" 'command'
    }
    $s.Stream.Write($bytes, 0, $bytes.Length)
    $s.Stream.Flush()
    $s.LastActivity = [DateTime]::UtcNow
}

# A line you typed (not a $$ command): fold to ASCII, echo, send
function Send-LillyUserLine($s, [string]$line) {
    if ($s.State -ne 'connected' -and $s.State -ne 'login') {
        Write-LillyNote $s '*** Not connected. ($$connect to log in) ***' 'error'
        return
    }
    $out = $line
    if (ConvertTo-LillyBool $s.Cfg.ascii) {
        try { $out = ConvertTo-LilyAscii $line } catch { $out = $line }
    }
    if ($s.OpenPartial) {
        Write-LillyLine $s $line 'mine' -Continue      # finishes the prompt line
    } elseif (ConvertTo-LillyBool $s.Cfg.echo_input) {
        Write-LillyLine $s $line 'mine'
    }
    if (-not [string]::Equals($out, $line, [StringComparison]::Ordinal)) { Write-LillyNote $s "  (sent as: $out)" 'mine' }
    if ($s.Printed -gt 0) { $s.Pending = ''; $s.Printed = 0 }   # that prompt is answered
    $s.Tail = ''
    # /detach (or /det, /deta...) and /bye: the server will close the connection on purpose
    if ($line -match '^\s*/(det(a(ch?)?)?|bye)\s*$') { $s.LeaveAt = [DateTime]::UtcNow }
    try { Send-LillyRaw $s $out } catch { Invoke-LillyConnectionLost $s 'send failed'; return }
    if ($line -match '^(?<to>[^\s:;/$][^\s:;]*)[:;]') { $s.LastTo = $Matches.to }
}

# Called about every 50 ms by the window
function Invoke-LillyTick($s) {
    $now = [DateTime]::UtcNow
    switch ($s.State) {
        'connecting' {
            $t = $s.ConnectTask
            if (-not $t) { return }
            if (-not $t.IsCompleted) {
                if (($now - $s.ConnectStart).TotalSeconds -gt 30) { Invoke-LillyConnectFailed $s 'timed out' }
                break
            }
            if ($t.IsFaulted -or $t.IsCanceled) {
                $msg = if ($t.Exception) { $t.Exception.GetBaseException().Message } else { 'cancelled' }
                Invoke-LillyConnectFailed $s $msg
                break
            }
            $s.Stream = $s.Client.GetStream()
            $s.State = 'login'
            $s.LastActivity = $now
            Set-LillyStatus $s "Logging in to $($s.Server)..."
        }
        'waiting' {
            if ($s.ReconnectAt -and $now -ge $s.ReconnectAt) { Connect-LillySession $s -Reconnect }
        }
    }
    if ($s.State -eq 'login' -or $s.State -eq 'connected') {
        Receive-LillyData $s
    }
    if ($s.State -eq 'connected') { Invoke-LillyKeepalive $s }
    Update-LillyCommands $s
}

function Invoke-LillyConnectFailed($s, [string]$msg) {
    Close-LillySocket $s
    Write-LillyNote $s "*** Could not connect: $msg ***" 'error'
    $canRetry = (ConvertTo-LillyBool $s.Cfg.auto_reconnect) -and $s.Reconnecting -and $s.Login.Password
    if ($canRetry) { Start-LillyReconnectWait $s }
    else { $s.State = 'disconnected'; Set-LillyStatus $s 'Not connected' }
}

function Receive-LillyData($s) {
    $sock = $s.Client.Client
    try {
        $got = $false
        while ($s.Client -and $s.Client.Available -gt 0) {
            $n = $s.Stream.Read($s.Buf, 0, $s.Buf.Length)
            if ($n -le 0) { break }
            $got = $true
            Add-LillyBytes $s $n
        }
        if ($s.Client -and $sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and $s.Client.Available -eq 0) {
            Invoke-LillyConnectionLost $s 'closed by the server'
            return
        }
        if ($got) { $s.LastActivity = [DateTime]::UtcNow }
    } catch {
        if ($s.Client) { Invoke-LillyConnectionLost $s $_.Exception.Message }
        return
    }
    if ($s.State -ne 'login' -and $s.State -ne 'connected') { return }
    # A partial line with nothing more coming is a prompt: show it now
    if ($s.Pending.Length -gt $s.Printed -and -not ($s.Slcp -and $s.Pending.StartsWith('%'))) {
        Write-LillyPartial $s $s.Pending.Substring($s.Printed)
        $s.Printed = $s.Pending.Length
        Test-LillyPrompt $s $s.Pending -FromPending
    }
}

# Telnet negotiation stripped; text split into lines
function Add-LillyBytes($s, [int]$n) {
    $IAC = 255; $SB = 250; $SE = 240; $WILL = 251; $WONT = 252; $ECHO = 1
    $clean = [System.Collections.Generic.List[byte]]::new($n)
    for ($i = 0; $i -lt $n; $i++) {
        $b = $s.Buf[$i]
        switch ($s.Telnet) {
            0 { if ($b -eq $IAC) { $s.Telnet = 1 } elseif ($b -ne 13) { $clean.Add($b) } }
            1 {
                if     ($b -eq $IAC)                { $clean.Add($b); $s.Telnet = 0 }
                elseif ($b -ge 251 -and $b -le 254) { $s.TelVerb = $b; $s.Telnet = 2 }
                elseif ($b -eq $SB)                 { $s.Telnet = 3 }
                else                                { $s.Telnet = 0 }
            }
            2 {
                if ($b -eq $ECHO) {
                    if ($s.TelVerb -eq $WILL) { $s.ServerEcho = $true }
                    if ($s.TelVerb -eq $WONT) { $s.ServerEcho = $false }
                }
                $s.Telnet = 0
            }
            3 { if ($b -eq $IAC) { $s.Telnet = 4 } }
            4 { if ($b -eq $SE) { $s.Telnet = 0 } else { $s.Telnet = 3 } }
        }
    }
    if ($clean.Count -eq 0) { return }
    $bytes = $clean.ToArray()
    $count = $s.Decoder.GetChars($bytes, 0, $bytes.Length, $s.Chars, 0)
    $text  = [string]::new($s.Chars, 0, $count)
    $tail = $s.Tail + $text
    if ($tail.Length -gt 120) { $tail = $tail.Substring($tail.Length - 120) }
    $s.Tail = $tail

    $s.Pending += $text
    while (($nl = $s.Pending.IndexOf("`n")) -ge 0) {
        $line = $s.Pending.Substring(0, $nl)
        if ($s.Slcp -and $s.Printed -eq 0 -and (Test-SlcpIncomplete $line)) {
            # a length-prefixed value continues onto the following line(s)
            $joined = $line; $rest = $s.Pending.Substring($nl + 1); $done = $false
            while (($nl2 = $rest.IndexOf("`n")) -ge 0) {
                $joined += "`n" + $rest.Substring(0, $nl2)
                $rest = $rest.Substring($nl2 + 1)
                if (-not (Test-SlcpIncomplete $joined)) { $done = $true; break }
            }
            if (-not $done) { break }
            $line = $joined
            $s.Pending = $rest
        } else {
            $s.Pending = $s.Pending.Substring($nl + 1)
        }
        $skip = $s.Printed
        $s.Printed = 0
        try {
            Invoke-LillyLine $s $line $skip
        } catch {
            Write-LillyNote $s "[pslilly couldn't handle a line: $($_.Exception.Message)]" 'error'
            Write-LillyLine $s $line
        }
    }
}

# Show our answer to a prompt, and forget the prompt text if it was the
# unfinished line we were holding (never when called mid-way through lines)
function Complete-LillyPrompt($s, [string]$shown, [switch]$FromPending) {
    if ($s.OpenPartial) { Write-LillyLine $s $shown 'mine' -Continue } else { Write-LillyLine $s $shown 'mine' }
    if ($FromPending) { $s.Pending = ''; $s.Printed = 0 }
}

# Answer login prompts by itself
function Test-LillyPrompt($s, [string]$text, [switch]$FromPending) {
    $login = $s.Login
    if ($text -match '^\s*login:\s*$') {
        if ($login.Stage -eq 'none') {
            if (-not $login.Name) { $s.Out.Add(@{ Type = 'need-login' }); return }
            if ($s.Slcp -and -not $s.OptionsSent) {
                Send-LillyRaw $s '#$# options +version +prompt +prompt2 +leaf-notify +leaf-cmd +connected'
                $s.OptionsSent = $true
            }
            Send-LillyRaw $s $login.Name
            Complete-LillyPrompt $s $login.Name -FromPending:$FromPending
            $login.Stage = 'name'
        } elseif ($login.Stage -in 'name', 'password') {
            # asked again: the name or password was wrong
            $login.Stage = 'failed'
            $s.Out.Add(@{ Type = 'login-failed' })
            Invoke-LillyConnectionLost $s 'login failed'
        }
    }
    elseif ($text -match '^\s*password:\s*$') {
        if ($login.Stage -eq 'name') {
            if (-not $login.Password) { $s.Out.Add(@{ Type = 'need-password' }); return }
            Send-LillyRaw $s (ConvertFrom-LillySecure $login.Password) -Secret
            Complete-LillyPrompt $s '(password hidden)' -FromPending:$FromPending
            $login.Stage = 'password'
        } elseif ($login.Stage -eq 'password') {
            $login.Stage = 'failed'
            $s.Out.Add(@{ Type = 'login-failed' })
            Invoke-LillyConnectionLost $s 'login failed'
        }
    }
    elseif ($s.BlurbPrompt -and $s.Reconnecting -and $text -match '-->\s*$') {
        # reconnecting replaced the old session; keep the blurb you had
        $s.BlurbPrompt = $false
        Send-LillyRaw $s $s.LastBlurb
        Complete-LillyPrompt $s $(if ($s.LastBlurb) { $s.LastBlurb } else { '(no blurb)' }) -FromPending:$FromPending
    }
}

# For the password dialog the window shows after 'need-password'
function Submit-LillyPassword($s, [System.Security.SecureString]$password) {
    $s.Login.Password = $password
    if ($s.Login.Stage -eq 'name' -and $s.Stream) {
        Send-LillyRaw $s (ConvertFrom-LillySecure $password) -Secret
        Complete-LillyPrompt $s '(password hidden)' -FromPending:($s.Printed -gt 0)
        $s.Login.Stage = 'password'
    }
}

function Set-LillyLoggedIn($s) {
    if ($s.Login.Stage -eq 'done') { return }
    $s.Login.Stage = 'done'
    $s.State = 'connected'
    $s.ReconnectDelay = 5
    $s.LastActivity = [DateTime]::UtcNow
    $name = if ($s.Login.Name) { $s.Login.Name } else { 'you' }
    Set-LillyStatus $s "Connected to $($s.Server) as $name"
    Set-LillyTitle $s $s.Login.Name
}

# ---------------------------------------------------------------------------
# One line from the server
# ---------------------------------------------------------------------------
function Invoke-LillyLine($s, [string]$line, [int]$skip = 0) {
    # login progress, from plain text lines
    if ($line -match '^\s*\*\*\* (Connected|Redirecting old connection)') { Set-LillyLoggedIn $s }
    if ($line -match 'Please enter a blurb') { $s.BlurbPrompt = $true }
    if ($line -match '^\s*(login|password):\s*$') {
        if ($skip -eq 0) { Write-LillyLine $s $line }
        Test-LillyPrompt $s $line.Trim()
        return
    }
    if ($s.Slcp -and $skip -eq 0 -and $line.StartsWith('%')) { Show-LillySlcpLine $s $line; return }
    Show-LillyPlainLine $s $line $skip
}

# Plain text: color it using the *_pattern settings
function Show-LillyPlainLine($s, [string]$line, [int]$skip = 0) {
    $kind = Get-LillyLineClass $s $line
    $style = $null
    if ($kind -eq 'private' -and $s.PrivUser) { $style = $s.PrivUser }
    Write-LillyLine $s $line.Substring([Math]::Min($skip, $line.Length)) $kind $style -Continue:($skip -gt 0)
}

function Get-LillyLineClass($s, [string]$line) {
    $rx = $s.Rx
    if ($line -match '^\s*$') { $s.Cls = $null; return '' }
    if ($rx.private) {
        $m = $rx.private.Match($line)
        if ($m.Success) {
            $from = $m.Groups['from'].Value.Trim()
            if ($from) {
                if (-not $s.Slcp) { $s.LastFrom = $from -replace '\s+', '_'; $s.Out.Add(@{ Type = 'alert'; From = $from }) }
                $s.PrivUser = $s.UserStyles[(Get-LillyUserKey $from)]
            } else { $s.PrivUser = $null }
            $s.Cls = 'private'; return 'private'
        }
    }
    if ($rx.public -and $rx.public.IsMatch($line)) { $s.Cls = 'public'; return 'public' }
    if ($rx.emote  -and $rx.emote.IsMatch($line))  { $s.Cls = 'emote';  return 'emote' }
    if ($s.Cls -and $rx.continuation -and $rx.continuation.IsMatch($line)) { return $s.Cls }
    $s.Cls = $null
    return ''
}

# ---- SLCP ------------------------------------------------------------------
# NAME=VALUE, NAME=LEN=DATA (DATA may hold spaces/newlines), or bare NAME.
# Returns $null when a length-prefixed value runs past the end of $str.
function ConvertFrom-SlcpParams([string]$str) {
    $p = @{}
    $pos = 0; $len = $str.Length
    while ($pos -lt $len) {
        while ($pos -lt $len -and $str[$pos] -eq ' ') { $pos++ }
        if ($pos -ge $len) { break }
        $ks = $pos
        while ($pos -lt $len -and $str[$pos] -ne '=' -and $str[$pos] -ne ' ') { $pos++ }
        $key = $str.Substring($ks, $pos - $ks)
        if (-not $key) { break }
        if ($pos -ge $len -or $str[$pos] -eq ' ') { $p[$key] = '1'; continue }
        $pos++
        $ne = $pos
        while ($ne -lt $len -and [char]::IsDigit($str[$ne])) { $ne++ }
        if ($ne -gt $pos -and $ne -lt $len -and $str[$ne] -eq '=') {
            $n = [int]$str.Substring($pos, $ne - $pos)
            $pos = $ne + 1
            if ($pos + $n -gt $len) { return $null }
            $p[$key] = $str.Substring($pos, $n)
            $pos += $n
        } else {
            $vs = $pos
            while ($pos -lt $len -and $str[$pos] -ne ' ') { $pos++ }
            $p[$key] = $str.Substring($vs, $pos - $vs)
        }
    }
    return $p
}

function Test-SlcpIncomplete([string]$line) {
    if ($line -notmatch '^%(NOTIFY|USER|DISC|GROUP|DATA|server) ') { return $false }
    $null -eq (ConvertFrom-SlcpParams $line.Substring($line.IndexOf(' ') + 1))
}

function Get-LillyName($s, [string]$h) {
    if ($h -and $s.Ents.ContainsKey($h) -and $s.Ents[$h].Name) { return $s.Ents[$h].Name }
    return $h
}
function Get-LillyNameBlurb($s, [string]$h) {
    $n = Get-LillyName $s $h
    if ($h -and $s.Ents.ContainsKey($h) -and $s.Ents[$h].Blurb) { return "$n [$($s.Ents[$h].Blurb)]" }
    return $n
}
function Join-LillyNames($s, $handles) { (@($handles | ForEach-Object { Get-LillyName $s $_ })) -join ', ' }

# Words in user and discussion names are never treated as misspelled
function Add-LillyNameWords($s, [string]$name) {
    if (-not $name) { return }
    foreach ($w in ($name -split '[\s_\-,]+')) { if ($w) { $s.NameSet[$w.ToLower()] = $true } }
}

function Set-LillyEntity($s, $p, [string]$kind) {
    if (-not $p -or -not $p.HANDLE) { return }
    $e = $s.Ents[$p.HANDLE]
    if (-not $e) { $e = @{ Kind = $kind; Name = $null; Blurb = ''; State = ''; Title = '' }; $s.Ents[$p.HANDLE] = $e }
    if ($p.ContainsKey('NAME'))  { $e.Name  = $p.NAME }
    if ($p.ContainsKey('BLURB')) { $e.Blurb = $p.BLURB }
    if ($p.ContainsKey('STATE')) { $e.State = $p.STATE }
    if ($p.ContainsKey('TITLE')) { $e.Title = $p.TITLE }
    Add-LillyNameWords $s $e.Name
    if ($s.WhoAmI -and $p.HANDLE -eq $s.WhoAmI) { $s.LastBlurb = $e.Blurb }
}

# Text for the non-message events (mirrors zephyrlily's eventformat.go)
function Format-LillyEvent($s, $ev, $p, [string]$src, [string]$srcB, [bool]$self, $recips, $targets) {
    $val  = $p.VALUE
    $disc = Join-LillyNames $s $recips
    $tgt  = Join-LillyNames $s $targets
    $sub  = $p.SUBEVT
    switch ($ev) {
        'connect'    { return "*** $srcB has entered lily ***" }
        'disconnect' { if ($val) { return "*** $srcB has left lily ($val) ***" }; return "*** $srcB has left lily ***" }
        'attach'     { return "*** $srcB has reattached ***" }
        'detach'     { if ($val) { return "*** $srcB has been detached $val ***" }; return "*** $srcB has detached ***" }
        'here'       { if ($self) { return '(you are now here)' }; return "*** $src is now `"here`" ***" }
        'away'       {
            if ($val) { return "*** $src has idled `"away`" ***" }
            if ($self) { return '(you are now away)' }
            return "*** $src is now `"away`" ***"
        }
        'unidle'     { return "*** $src is now unidle ***" }
        'rename'     { if ($self) { return "(you are now named $val)" }; return "*** $src is now named $val ***" }
        'blurb'      {
            if ($self) { if ($val) { return "(your blurb has been set to [$val])" }; return '(your blurb has been turned off)' }
            if ($val) { return "*** $src has changed their blurb to [$val] ***" }
            return "*** $src has turned their blurb off ***"
        }
        'info'       {
            if ($disc) { if ($self) { return "(you have changed the info for $disc)" }; return "*** $src has changed the info for discussion $disc ***" }
            if ($self) { return '(your info has been changed)' }
            return "*** $src has changed their info ***"
        }
        'create'     { if ($self) { return "(you have created discussion $disc)" }; return "*** $src has created discussion $disc ***" }
        'destroy'    { if ($self) { return "(you have destroyed discussion $disc)" }; return "*** $src has destroyed discussion $disc ***" }
        'join'       { if ($self) { return "(you have joined $disc)" }; return "*** $src is now a member of $disc ***" }
        'quit'       { if ($self) { return "(you have quit $disc)" }; return "*** $src is no longer a member of $disc ***" }
        'retitle'    { if ($self) { return "(you have changed the title of $disc to `"$val`")" }; return "*** $src has changed the title of $disc to `"$val`" ***" }
        'drename'    { return "*** Discussion -$disc is now named -$val ***" }
        'review'     { return "*** $src has cleared the review for discussion $disc ***" }
        'ignore'     { if ($val) { return "*** $src is now ignoring you $val ***" }; return "*** $src is now ignoring you ***" }
        'unignore'   { return "*** $src is no longer ignoring you ***" }
        'sysmsg'     { return "*** $val ***" }
        'sysalert'   { return "*** $val ***" }
        { $_ -in 'permit', 'depermit', 'appoint', 'unappoint' } {
            $what = @($ev, $sub, $tgt) | Where-Object { $_ }
            return "*** $src $($what -join ' ') for discussion $disc ***"
        }
    }
    $rest = @($val, $disc) | Where-Object { $_ }
    return "[$ev] $src $($rest -join ' ')"
}

# Message body: " - " then the text; extra lines indented to match
function Write-LillyBody($s, [string]$val, [string]$cls, $style) {
    $first = $true
    foreach ($para in ("$val" -split "`n")) {
        $prefix = if ($first) { ' - ' } else { '   ' }
        Write-LillyLine $s ($prefix + $para) $cls $style 3
        $first = $false
    }
}

function Show-LillyNotify($s, $p) {
    $ev      = "$($p.EVENT)".ToLower()
    $srcH    = $p.SOURCE
    $self    = [bool]($s.WhoAmI -and $srcH -eq $s.WhoAmI)
    $recips  = @(if ($p.RECIPS)  { $p.RECIPS  -split ',' })
    $targets = @(if ($p.TARGETS) { $p.TARGETS -split ',' })
    $val     = "$($p.VALUE)"
    $src     = Get-LillyName $s $srcH
    $srcB    = Get-LillyNameBlurb $s $srcH
    $show    = $p.ContainsKey('NOTIFY') -or $ev -in 'public', 'private', 'emote', 'pa'

    $ts = ''
    if ($p.STAMP -and $p.TIME -match '^\d+$') {
        $ts = [DateTimeOffset]::FromUnixTimeSeconds([long]$p.TIME).LocalDateTime.ToString('HH:mm')
    }

    if ($show) {
        switch ($ev) {
            'public' {
                $h = ' -> ' + $(if ($ts) { "($ts) " }) + "From $srcB"
                if ($recips.Count) { $h += ', to ' + (Join-LillyNames $s $recips) }
                Write-LillyLine $s '' ''
                Write-LillyLine $s "${h}:" 'public'
                Write-LillyBody $s $val 'public' $null
            }
            'private' {
                $us = $s.UserStyles[(Get-LillyUserKey $src)]
                $h  = ' >> ' + $(if ($ts) { "($ts) " }) + "Private message from $srcB"
                if ($recips.Count -gt 1) { $h += ', to ' + (Join-LillyNames $s $recips) }
                Write-LillyLine $s '' ''
                Write-LillyLine $s "${h}:" 'private' $us
                Write-LillyBody $s $val 'private' $us
                if (-not $self) {
                    $s.LastFrom = $src -replace '\s+', '_'
                    $s.Out.Add(@{ Type = 'alert'; From = $src })
                }
            }
            'emote' {
                $inner = @()
                if ($ts) { $inner += $ts }
                if ($recips.Count) { $inner += 'to ' + (Join-LillyNames $s $recips) }
                $h = '> ' + $(if ($inner) { "($($inner -join ', ')) " }) + $src
                Write-LillyLine $s ($h + $val) 'emote' $null 2
            }
            'pa' {
                Write-LillyLine $s '' ''
                Write-LillyLine $s (' ** ' + $(if ($ts) { "($ts) " }) + "Public address from ${srcB}:") 'private'
                Write-LillyBody $s $val 'private' $null
                $s.Out.Add(@{ Type = 'alert'; From = $src })
            }
            default {
                Write-LillyLine $s (Format-LillyEvent $s $ev $p $src $srcB $self $recips $targets) 'system' $null 4
            }
        }
    }

    # keep names, blurbs and states current
    if ($srcH -and $s.Ents.ContainsKey($srcH)) {
        $e = $s.Ents[$srcH]
        switch ($ev) {
            'rename'     { $e.Name = $val; Add-LillyNameWords $s $val; if ($self) { Set-LillyTitle $s $val } }
            'blurb'      { $e.Blurb = $val; if ($self) { $s.LastBlurb = $val } }
            'here'       { $e.State = 'here' }
            'away'       { $e.State = 'away' }
            'disconnect' { $e.State = 'away' }
        }
    }
    if ($ev -eq 'retitle') { foreach ($r in $recips) { if ($s.Ents.ContainsKey($r)) { $s.Ents[$r].Title = $val } } }
    if ($ev -eq 'destroy') { foreach ($r in $recips) { if ($s.Ents.ContainsKey($r)) { $s.Ents.Remove($r) } } }
}

function Show-LillySlcpLine($s, [string]$line) {
    if ($line -match '^%command \[\d+\] ?(.*)$') { Show-LillyPlainLine $s $Matches[1]; return }
    $sp   = $line.IndexOf(' ')
    $tok  = if ($sp -ge 0) { $line.Substring(0, $sp) } else { $line }
    $rest = if ($sp -ge 0) { $line.Substring($sp + 1) } else { '' }
    switch -casesensitive ($tok) {
        '%NOTIFY'    { Show-LillyNotify $s (ConvertFrom-SlcpParams $rest); return }
        '%USER'      { Set-LillyEntity $s (ConvertFrom-SlcpParams $rest) 'user'; return }
        '%DISC'      { Set-LillyEntity $s (ConvertFrom-SlcpParams $rest) 'disc'; return }
        '%DATA'      {
            $p = ConvertFrom-SlcpParams $rest
            if ($p.NAME -eq 'whoami') { $s.WhoAmI = $p.VALUE }
            return
        }
        '%connected' {
            # what follows isn't always our ID ("%connected attach"), so only
            # take it if it looks like one; %DATA whoami is the reliable source
            $tag = $rest.Trim()
            if ($tag -match '^#\d+$' -and -not $s.WhoAmI) { $s.WhoAmI = $tag }
            try { Send-LillyRaw $s ('#$# client pslilly "' + $LillyVersion + '"') } catch {}
            $s.LoggedIn = $true
            Set-LillyLoggedIn $s
            $me = $null
            if ($s.WhoAmI -and $s.Ents.ContainsKey($s.WhoAmI) -and $s.Ents[$s.WhoAmI].Name) {
                $me = $s.Ents[$s.WhoAmI].Name
                $s.LastBlurb = $s.Ents[$s.WhoAmI].Blurb
            }
            if (-not $me) { $me = $s.Login.Name }
            Set-LillyTitle $s $me
            if ($me) { Set-LillyStatus $s "Connected to $($s.Server) as $me" }
            return
        }
        '%pong'      {
            $s.PingSentAt = $null
            return
        }
        '%prompt'    {
            # the normal "lily>" prompt isn't shown; others (like a blurb prompt) are
            if ($rest -notmatch '^\s*lily>\s*$') {
                Write-LillyPartial $s $rest
                Test-LillyPrompt $s $rest
            }
            return
        }
        { $_ -in '%begin', '%end', '%options', '%server', '%GROUP', '%SLCP-SYNC', '%export_file' } { return }
    }
    Show-LillyPlainLine $s $line
}

# ---------------------------------------------------------------------------
# Keepalive and connection checks
# After <keepalive> quiet minutes send "#$# ping"; the server answers
# "%pong". No answer in time means the connection is dead: reconnect.
# ---------------------------------------------------------------------------
function Invoke-LillyKeepalive($s) {
    if (-not $s.Slcp -or -not $s.LoggedIn) { return }
    $now = [DateTime]::UtcNow
    if ($null -ne $s.PingSentAt) {
        if (($now - $s.PingSentAt).TotalSeconds -ge $s.PingTimeout) {
            $s.PingSentAt = $null
            Write-LillyNote $s '*** No reply from the server; the connection seems to be dead. ***' 'error'
            Invoke-LillyConnectionLost $s 'no reply to keepalive' 0     # try again right away
        }
        return
    }
    $mins = 0
    [void][int]::TryParse([string]$s.Cfg.keepalive, [ref]$mins)
    if ($mins -gt 0 -and ($now - $s.LastActivity).TotalMinutes -ge $mins) {
        Send-LillyPing $s 60
    }
}

function Send-LillyPing($s, [int]$timeout) {
    try {
        Send-LillyRaw $s '#$# ping'
        $s.PingSentAt = [DateTime]::UtcNow
        $s.PingTimeout = $timeout
    } catch {
        Invoke-LillyConnectionLost $s 'send failed'
    }
}

# After waking up or the network coming back: is the connection still alive?
function Request-LillyConnectionCheck($s) {
    switch ($s.State) {
        'connected' {
            if ($s.Slcp -and $s.LoggedIn -and $null -eq $s.PingSentAt) { Send-LillyPing $s 10 }
        }
        'waiting' { $s.ReconnectAt = [DateTime]::UtcNow; $s.ReconnectDelay = 5 }
    }
}

# Locked / asleep -> away; unlocked -> here (only if pslilly set you away)
function Set-LillyAutoAway($s) {
    if (-not (ConvertTo-LillyBool $s.Cfg.away_on_lock)) { return }
    if ($s.State -ne 'connected' -or $s.AutoAway -or -not $s.Cfg.away_command) { return }
    $me = if ($s.WhoAmI) { $s.Ents[$s.WhoAmI] } else { $null }
    if ($me -and $me.State -eq 'away') { return }     # you were already away
    try { Send-LillyRaw $s $s.Cfg.away_command; $s.AutoAway = $true } catch {}
}
function Set-LillyAutoHere($s) {
    if (-not $s.AutoAway) { return }
    $s.AutoAway = $false
    if ($s.State -ne 'connected' -or -not $s.Cfg.here_command) { return }
    try { Send-LillyRaw $s $s.Cfg.here_command } catch {}
}

# ---------------------------------------------------------------------------
# $$! commands: run PowerShell in the background, show the output when done
# ---------------------------------------------------------------------------
function Start-LillyCommand($s, [string]$cmd) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    try { $null = $rs.SessionStateProxy.Path.SetLocation((Get-Location).ProviderPath) } catch {}
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($cmd).AddCommand('Out-String').AddParameter('Width', 160)
    $async = $ps.BeginInvoke()
    $s.Commands.Add(@{ PS = $ps; RS = $rs; Async = $async; Cmd = $cmd; Started = [DateTime]::UtcNow })
    Write-LillyNote $s "[running: $cmd]" 'command'
}

function Update-LillyCommands($s) {
    if ($s.Commands.Count -eq 0) { return }
    foreach ($c in @($s.Commands)) {
        if (-not $c.Async.IsCompleted) { continue }
        $s.Commands.Remove($c) | Out-Null
        $text = ''
        try {
            $res = $c.PS.EndInvoke($c.Async)
            $text = ($res | ForEach-Object { "$_" }) -join ''
        } catch {
            Write-LillyNote $s "[$($c.Cmd)] $($_.Exception.GetBaseException().Message)" 'error'
        }
        $lines = @($text -split "\r?\n")
        while ($lines.Count -gt 0 -and $lines[0] -match '^\s*$') { $lines = @($lines | Select-Object -Skip 1) }
        while ($lines.Count -gt 0 -and $lines[-1] -match '^\s*$') { $lines = @($lines | Select-Object -SkipLast 1) }
        Write-LillyNote $s "[$($c.Cmd)]" 'command'
        foreach ($l in $lines) { Write-LillyLine $s $l 'command' }
        foreach ($e in $c.PS.Streams.Error) { Write-LillyNote $s "  $e" 'error' }
        if ($lines.Count -eq 0 -and $c.PS.Streams.Error.Count -eq 0) { Write-LillyNote $s '  (no output)' 'command' }
        $c.PS.Dispose()
        try { $c.RS.Dispose() } catch {}
    }
}

function Stop-LillyCommands($s) {
    $n = $s.Commands.Count
    foreach ($c in @($s.Commands)) {
        try { $null = $c.PS.BeginStop($null, $null) } catch {}
    }
    return $n
}

# ---------------------------------------------------------------------------
# Name completion (Tab)
# ---------------------------------------------------------------------------
# Users and discussions starting with $partial ("-" prefix = discussions only).
# Spaces in names are written as _ ; discussions get a leading -.
function Get-LillyCompletions($s, [string]$partial) {
    $discOnly = $partial.StartsWith('-')
    $q = ($partial.TrimStart('-') -replace '_', ' ').ToLower()
    $users = @(); $discs = @()
    foreach ($e in $s.Ents.Values) {
        if (-not $e.Name) { continue }
        if (-not $e.Name.ToLower().StartsWith($q)) { continue }
        $n = $e.Name -replace ' ', '_'
        if ($e.Kind -eq 'disc') { $discs += "-$n" }
        elseif (-not $discOnly) { $users += $n }
    }
    return @(@($users | Sort-Object -Unique) + @($discs | Sort-Object -Unique))
}

# Where the word at the cursor starts (words end at spaces , : ;)
function Get-LillyWordStart([string]$text, [int]$caret) {
    $i = $caret
    while ($i -gt 0 -and " `t,:;".IndexOf($text[$i - 1]) -lt 0) { $i-- }
    return $i
}

# Tab pressed. $state carries a cycle between presses ($null to start).
# Returns @{ Text; Caret; State; Matches } (Matches set when several fit).
function Resolve-LillyCompletion($s, [string]$text, [int]$caret, $state) {
    if ($state) {
        # Tab again: next candidate
        $state.Index = ($state.Index + 1) % $state.List.Count
        $word = $state.List[$state.Index]
        $new = $text.Substring(0, $state.Start) + $word + $text.Substring($state.Start + $state.Len)
        $state.Len = $word.Length
        return @{ Text = $new; Caret = $state.Start + $word.Length; State = $state; Matches = $null }
    }
    $start = Get-LillyWordStart $text $caret
    $partial = $text.Substring($start, $caret - $start)
    if (-not $partial) { return @{ Text = $text; Caret = $caret; State = $null; Matches = $null } }
    $c = @(Get-LillyCompletions $s $partial)
    if ($c.Count -eq 0) { return @{ Text = $text; Caret = $caret; State = $null; Matches = @() } }
    if ($c.Count -eq 1) {
        $new = $text.Substring(0, $start) + $c[0] + $text.Substring($caret)
        return @{ Text = $new; Caret = $start + $c[0].Length; State = $null; Matches = $null }
    }
    # several: fill in what they share, then Tab again cycles through them
    $common = $c[0]
    foreach ($x in $c) {
        $n = 0
        while ($n -lt $common.Length -and $n -lt $x.Length -and [char]::ToLower($common[$n]) -eq [char]::ToLower($x[$n])) { $n++ }
        $common = $common.Substring(0, $n)
    }
    if ($common.Length -gt $partial.Length) {
        $new = $text.Substring(0, $start) + $common + $text.Substring($caret)
        return @{ Text = $new; Caret = $start + $common.Length; State = $null; Matches = $c }
    }
    $state = @{ Start = $start; Len = $partial.Length; Index = -1; List = @($c + $partial) }
    $r = Resolve-LillyCompletion $s $text $caret $state
    $r.Matches = $c
    return $r
}

# ---------------------------------------------------------------------------
# $$ commands
# ---------------------------------------------------------------------------
function Show-LillyHelp($s) {
    Write-LillyNote $s 'Settings (saved in lily.conf) - $$<setting> <value> to change:'
    foreach ($k in $LillySchema.Keys) {
        if ($LillySchema[$k].Hidden) { continue }
        $v = $s.Cfg[$k]
        $shown = if ("$v" -ne '') { "$v" } else { '(off)' }
        if ($LillySchema[$k].Type -eq 'regex') {
            Write-LillyNote $s ('  $$' + $k.PadRight(21) + ' ' + $shown) 'command'
        } else {
            Write-LillyNote $s ('  $$' + $k.PadRight(21) + ' ' + $shown.PadRight(17) + ' ' + $LillySchema[$k].Help) 'command'
        }
    }
    $userKeys = @($s.Cfg.Keys | Where-Object { $_ -like 'user_*' } | Sort-Object)
    if ($userKeys.Count) {
        Write-LillyNote $s 'Per-user private message styles:'
        foreach ($k in $userKeys) { Show-LillyUserStyle $s $k }
    }
    Write-LillyNote $s 'Commands:'
    $cmds = @(
        '  $$user <name> <style>     style private messages from someone, e.g. yellow on dark_red bold (off = remove)',
        '  $$map <char> <text>       send a character as <text> (off = built in; $$map lists yours)',
        '  $$! <command>             run a PowerShell command; output shows here when it finishes',
        '  $$stop                    stop running $$! commands',
        '  $$reconnect               reconnect now',
        '  $$disconnect              disconnect (no automatic reconnecting)',
        '  $$send <text>             send text to the server exactly as typed',
        '  $$reload                  re-read lily.conf',
        '  $$quit                    close pslilly'
    ) + $s.ExtraHelp
    foreach ($l in $cmds) { Write-LillyNote $s $l 'command' }
    $spell = if ($s.SpellReady) { 'on' } elseif ($s.SpellNote) { $s.SpellNote } else { 'off' }
    Write-LillyNote $s "Spelling: $spell.  F7 = suggestions (again for the next), Shift+F7 = add word to dictionary" 'command'
    $lf = if ($s.LastFrom) { $s.LastFrom } else { 'none yet' }
    $lt = if ($s.LastTo) { $s.LastTo } else { 'none yet' }
    Write-LillyNote $s "Keys: : = last person who sent to you ($lf), ; = last person you sent to ($lt), Tab = complete a name," 'command'
    Write-LillyNote $s '      PgUp/PgDn = scroll, Ctrl+Home/End = top/bottom, Up/Down = history, Ctrl+Z/Y = undo/redo' 'command'
    Write-LillyNote $s 'Style preview:'
    foreach ($cls in 'public', 'private', 'emote', 'system', 'mine', 'command', 'spell') {
        Write-LillyLine $s "  this is $cls text" $cls
    }
}

function Show-LillyUserStyle($s, [string]$key) {
    Write-LillyLine $s ("  " + $key.Substring(5).PadRight(16) + " $($s.Cfg[$key])") 'private' $s.UserStyles[$key]
}

function Invoke-LillyUserCommand($s, [string]$arg) {
    $keys = @($s.Cfg.Keys | Where-Object { $_ -like 'user_*' } | Sort-Object)
    if (-not "$arg".Trim()) {
        if ($keys.Count -eq 0) { Write-LillyNote $s 'No per-user styles yet. Example: $$user strider yellow on dark_red bold'; return }
        Write-LillyNote $s 'Private messages from these people use their own style:'
        foreach ($k in $keys) { Show-LillyUserStyle $s $k }
        return
    }
    $parts = $arg.Trim() -split '\s+', 2
    $key = Get-LillyUserKey $parts[0]
    if ($parts.Count -lt 2) {
        if ($s.Cfg.Contains($key)) { Show-LillyUserStyle $s $key } else { Write-LillyNote $s "$($parts[0]) has no style of their own." }
        return
    }
    $val = $parts[1].Trim().ToLower()
    if ($val -match '^(off|none|default)$') {
        if ($s.Cfg.Contains($key))     { $s.Cfg.Remove($key) }
        if ($s.FileCfg.Contains($key)) { $s.FileCfg.Remove($key) }
        Save-LillyConfig $s
        Update-LillyDerived $s
        Write-LillyNote $s "$($parts[0]) is back to the normal private style (saved)"
        return
    }
    try { $null = ConvertTo-LillyStyle $val } catch { Write-LillyNote $s $_.Exception.Message 'error'; return }
    Set-LillySetting $s $key $val
    Show-LillyUserStyle $s $key
}

function Invoke-LillyMapCommand($s, [string]$arg) {
    $keys = @($s.Cfg.Keys | Where-Object { $_ -match '^map_u\+?[0-9a-f]+$' } | Sort-Object)
    if (-not "$arg".Trim()) {
        if ($keys.Count -eq 0) { Write-LillyNote $s ('No custom character mappings. Example: $$map ' + [char]0x2019 + " '"); return }
        Write-LillyNote $s 'Your character mappings (used when sending):'
        foreach ($k in $keys) {
            $cp = [Convert]::ToInt32(($k -replace '^map_u\+?', ''), 16)
            Write-LillyNote $s ("  {0}  U+{1:X4}  ->  {2}" -f [char]::ConvertFromUtf32($cp), $cp, $s.Cfg[$k]) 'command'
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
        Write-LillyNote $s 'Give one character, or its code like U+201C.' 'error'
        return
    }
    $key = 'map_u+{0:x4}' -f $cp
    $glyph = [char]::ConvertFromUtf32($cp)
    if ($parts.Count -lt 2) {
        $how = if ($s.Cfg.Contains($key)) { 'your mapping' } else { 'built in' }
        Write-LillyNote $s ("{0} (U+{1:X4}) is sent as: {2}   ({3})" -f $glyph, $cp, (ConvertTo-LilyAscii $glyph), $how)
        return
    }
    $val = $parts[1].Trim()
    if ($val -eq 'off') {
        if ($s.Cfg.Contains($key))     { $s.Cfg.Remove($key) }
        if ($s.FileCfg.Contains($key)) { $s.FileCfg.Remove($key) }
        Save-LillyConfig $s
        Update-LillyDerived $s
        Write-LillyNote $s ("{0} is back to the built-in mapping: {1} (saved)" -f $glyph, (ConvertTo-LilyAscii $glyph))
        return
    }
    $plain = if ($val -match '^"(.*)"$') { $Matches[1] } else { $val }
    if ($plain -match '[^\x00-\x7F]') { Write-LillyNote $s 'The replacement has to be plain ASCII.' 'error'; return }
    $stored = if ($plain -ne $plain.Trim() -or $plain -eq '') { '"' + $plain + '"' } else { $plain }
    Set-LillySetting $s $key $stored
    Write-LillyNote $s ("{0} will be sent as: {1} (saved)" -f $glyph, $plain)
}

# A line that started with $$. Returns 'quit' to close pslilly.
function Invoke-LillyLocalCommand($s, [string]$cmd) {
    $cmd = $cmd.Trim()
    if ($cmd.StartsWith('!')) {
        $c = $cmd.Substring(1).Trim()
        if (-not $c) { Write-LillyNote $s 'Usage: $$! <PowerShell command>, e.g. $$! Get-Date' 'error'; return }
        Start-LillyCommand $s $c
        return
    }
    $parts = $cmd -split '\s+', 2
    $name  = $parts[0].ToLower()
    $arg   = if ($parts.Count -gt 1) { $parts[1] } else { $null }
    if ($LillyAliases.ContainsKey($name)) { $name = $LillyAliases[$name] }

    switch ($name) {
        ''           { Show-LillyHelp $s; return }
        'help'       { Show-LillyHelp $s; return }
        'quit'       { return 'quit' }
        'send'       {
            if ($null -ne $arg) { try { Send-LillyRaw $s $arg } catch { Write-LillyNote $s '*** Not connected. ***' 'error' } }
            return
        }
        'user'       { Invoke-LillyUserCommand $s $arg; return }
        'map'        { Invoke-LillyMapCommand $s $arg; return }
        'stop'       {
            $n = Stop-LillyCommands $s
            Write-LillyNote $s $(if ($n) { "Stopping $n command(s)." } else { 'Nothing is running.' })
            return
        }
        'reconnect'  {
            if (-not $s.Login.Name -or -not $s.Login.Password) { $s.Out.Add(@{ Type = 'need-login' }); return }
            $s.ReconnectDelay = 5
            Connect-LillySession $s -Reconnect
            return
        }
        'disconnect' { Disconnect-LillySession $s -Goodbye; return }
        'reload'     {
            $s.FileCfg = (Read-LillyConfig $s.ConfigPath).Values
            $s.Cfg = [ordered]@{}
            foreach ($k in $s.FileCfg.Keys) { $s.Cfg[$k] = $s.FileCfg[$k] }
            Update-LillyDerived $s
            Initialize-LillySpell $s
            Write-LillyNote $s "Reloaded $($s.ConfigPath)"
            return
        }
    }

    if (-not $LillySchema.Contains($name)) {
        Write-LillyNote $s "Unknown command '`$`$$name'. Type `$`$ for the list." 'error'
        return
    }
    $type = $LillySchema[$name].Type
    if ($null -eq $arg -and $type -ne 'bool') {
        $v = if ("$($s.Cfg[$name])" -ne '') { $s.Cfg[$name] } else { '(off)' }
        Write-LillyNote $s "$name is $v"
        return
    }
    $new = $arg
    switch ($type) {
        'bool' {
            if     ($null -eq $arg)                   { $new = if (ConvertTo-LillyBool $s.Cfg[$name]) { 'off' } else { 'on' } }
            elseif ($arg -match '^(on|true|1|yes)$')  { $new = 'on' }
            elseif ($arg -match '^(off|false|0|no)$') { $new = 'off' }
            else { Write-LillyNote $s 'Use on or off.' 'error'; return }
        }
        'int' {
            if ($arg -notmatch '^\d+$') { Write-LillyNote $s 'Use a whole number.' 'error'; return }
        }
        'color' {
            try { $null = ConvertTo-LillyColor $arg } catch { Write-LillyNote $s $_.Exception.Message 'error'; return }
            $new = $arg.ToLower()
        }
        'style' {
            try { $x = ConvertTo-LillyStyle $arg } catch { Write-LillyNote $s $_.Exception.Message 'error'; return }
            $new = $arg.ToLower()
        }
        'regex' {
            try { $null = [regex]::new($arg) } catch { Write-LillyNote $s "Bad pattern: $($_.Exception.Message)" 'error'; return }
        }
        'string' {
            if ($arg -match '^(off|none)$') { $new = '' }
        }
    }
    Set-LillySetting $s $name $new
    $shown = if ("$new" -ne '') { $new } else { '(off)' }
    Write-LillyNote $s "$name is $shown (saved)"
    if ($name -in 'spellcheck', 'spell_language') {
        Initialize-LillySpell $s
        if ($s.SpellNote) { Write-LillyNote $s $s.SpellNote 'error' }
    }
    if ($name -eq 'slcp') { Write-LillyNote $s 'This takes effect the next time pslilly connects ($$reconnect).' }
}
