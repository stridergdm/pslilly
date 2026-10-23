<#
    Installs PSLilly for the current Windows user (no administrator needed).

    Run it by double-clicking Install.cmd. Running it again updates PSLilly
    and keeps the existing settings.

    What it does:
      - copies PSLilly to  %LOCALAPPDATA%\Programs\PSLilly
      - clears Windows' "downloaded from the internet" block on those files
      - writes a starter lily.conf (only if there isn't one yet)
      - makes "PSLilly" shortcuts on the Desktop and in the Start menu
      - adds PSLilly to Settings > Apps, so it can be uninstalled from there

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>
param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\PSLilly'),
    [switch]$NoShortcuts,     # for testing: only copy files and write settings
    [switch]$Quiet            # no message boxes
)

# ===========================================================================
# Starter settings for a new install. Change these before giving it away.
# (Only used when there's no lily.conf yet; any setting from $$ works here.)
# ===========================================================================
$Starter = [ordered]@{
    default_server = 'lily.acm.rpi.edu'
    default_port   = '7777'
    font_size      = '12'
    alert_private  = 'on'
    alert_sound    = 'on'
    away_on_lock   = 'off'
}
# ===========================================================================

$ErrorActionPreference = 'Stop'
$Version = '0.8'
$src = $PSScriptRoot
$files = @('pslilly-gui.ps1', 'pslilly-core.ps1', 'pslilly.ps1', 'pslilly.ico', 'uninstall.ps1', 'README.txt')
$onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'

function Show-Message([string]$text, [string]$buttons = 'OK', [string]$icon = 'Information') {
    if ($Quiet -or -not $onWindows) { Write-Host $text; return 'OK' }
    Add-Type -AssemblyName System.Windows.Forms
    return [string][System.Windows.Forms.MessageBox]::Show($text, 'PSLilly', $buttons, $icon)
}

try {
    Write-Host "Installing PSLilly $Version to $Destination ..."

    # --- files ---------------------------------------------------------------
    $missing = @($files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $src $_)) })
    if ($missing.Count) { throw "These files are missing next to the installer: $($missing -join ', ')" }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($f in $files) {
        $to = Join-Path $Destination $f
        Copy-Item -LiteralPath (Join-Path $src $f) -Destination $to -Force
        if ($onWindows) { Unblock-File -LiteralPath $to }
    }

    # --- starter settings (never overwrites existing ones) -------------------
    $conf = Join-Path $Destination 'lily.conf'
    if (-not (Test-Path -LiteralPath $conf)) {
        $lines = @('# PSLilly settings. Change them in PSLilly with $$<setting> <value>, or edit here.', '')
        foreach ($k in $Starter.Keys) { $lines += "${k}: $($Starter[$k])" }
        Set-Content -LiteralPath $conf -Value $lines -Encoding UTF8
        Write-Host '  wrote starter settings'
    } else {
        Write-Host '  kept existing settings'
    }

    if (-not $NoShortcuts) {
        # --- shortcuts ---------------------------------------------------------
        # conhost --headless: PowerShell runs with no console window at all, so
        # Windows Terminal (the default terminal on Windows 11) can't open a tab
        # for it. -WindowStyle Hidden is a fallback for Windows versions without
        # --headless. -ExecutionPolicy Bypass applies to this one run only; it
        # doesn't change any Windows setting.
        $ps   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $host_ = Join-Path $env:SystemRoot 'System32\conhost.exe'
        $gui  = Join-Path $Destination 'pslilly-gui.ps1'
        $icon = Join-Path $Destination 'pslilly.ico'
        $runArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$gui`""
        $target = $ps; $arguments = $runArgs
        if (Test-Path -LiteralPath $host_) { $target = $host_; $arguments = "--headless `"$ps`" $runArgs" }

        $shell = New-Object -ComObject WScript.Shell
        $places = @(
            (Join-Path ([Environment]::GetFolderPath('Desktop'))  'PSLilly.lnk'),
            (Join-Path ([Environment]::GetFolderPath('Programs')) 'PSLilly.lnk')
        )
        foreach ($lnk in $places) {
            $sc = $shell.CreateShortcut($lnk)
            $sc.TargetPath       = $target
            $sc.Arguments        = $arguments
            $sc.WorkingDirectory = $Destination
            $sc.IconLocation     = "$icon,0"
            $sc.Description      = 'PSLilly - Lily chat'
            $sc.WindowStyle      = 7      # start minimized: no flash before it hides
            $sc.Save()
        }
        Write-Host '  made Desktop and Start menu shortcuts'

        # --- Settings > Apps entry (per user, no admin) -------------------------
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PSLilly'
        New-Item -Path $key -Force | Out-Null
        # (headless too: the uninstaller only shows message boxes)
        $unArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $Destination 'uninstall.ps1')`""
        $uninstall = if (Test-Path -LiteralPath $host_) { "`"$host_`" --headless `"$ps`" $unArgs" } else { "`"$ps`" $unArgs" }
        $values = @{
            DisplayName     = 'PSLilly'
            DisplayVersion  = $Version
            Publisher       = 'PSLilly'
            DisplayIcon     = $icon
            InstallLocation = $Destination
            UninstallString = $uninstall
            Comments        = 'Lily chat client'
        }
        foreach ($n in $values.Keys) { Set-ItemProperty -Path $key -Name $n -Value $values[$n] }
        Set-ItemProperty -Path $key -Name NoModify -Value 1 -Type DWord
        Set-ItemProperty -Path $key -Name NoRepair -Value 1 -Type DWord
        Write-Host '  added to Settings > Apps'
    }

    Write-Host 'Done.'
    $answer = Show-Message "PSLilly is installed.`n`nTo start it, double-click PSLilly on your desktop (or find it in the Start menu).`n`nStart it now?" 'YesNo' 'Information'
    if ($answer -eq 'Yes' -and -not $NoShortcuts) {
        Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PSLilly.lnk')
    }
    exit 0
} catch {
    Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
    $null = Show-Message "PSLilly could not be installed:`n`n$($_.Exception.Message)" 'OK' 'Error'
    exit 1
}
