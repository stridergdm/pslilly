<#
    Removes PSLilly for the current Windows user.
    Started from Settings > Apps > PSLilly > Uninstall (or run it directly).
    Asks whether to keep your settings and saved password.

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at https://mozilla.org/MPL/2.0/.
#>
param([switch]$Quiet)

$dir = $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms

function Ask([string]$text) {
    if ($Quiet) { return 'Yes' }
    return [string][System.Windows.Forms.MessageBox]::Show($text, 'PSLilly', 'YesNo', 'Question')
}

if ((Ask 'Remove PSLilly from this computer?') -ne 'Yes') { exit 0 }
$wipe = (Ask "Also remove your PSLilly settings and saved password?`n`n(Choose No if you might install PSLilly again.)") -eq 'Yes'

# close PSLilly if it's running (its window title starts with PSLilly)
Get-Process powershell, pwsh -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -like 'PSLilly*' } |
    ForEach-Object { try { $_.CloseMainWindow() | Out-Null; Start-Sleep -Milliseconds 800 } catch {} }

# shortcuts and the Settings > Apps entry
foreach ($lnk in @(
        (Join-Path ([Environment]::GetFolderPath('Desktop'))  'PSLilly.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'PSLilly.lnk'))) {
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
}
Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PSLilly' -Recurse -Force -ErrorAction SilentlyContinue

# saved passwords (Windows Credential Manager entries named pslilly:<server>)
if ($wipe) {
    Add-Type -Namespace PsLillyUninstall -Name Cred -MemberDefinition @'
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredDeleteW(string target, int type, int flags);
'@
    $targets = @{}
    # the server in the settings file...
    $conf = Join-Path $dir 'lily.conf'
    if (Test-Path -LiteralPath $conf) {
        foreach ($l in Get-Content -LiteralPath $conf) {
            if ($l -match '^\s*default_server\s*[:=]\s*(\S+)') { $targets['pslilly:' + $Matches[1].ToLower()] = $true }
        }
    }
    # ...and any other pslilly entries Windows lists
    foreach ($line in (cmdkey /list 2>$null)) {
        if ($line -match 'Target:.*?(pslilly:\S+)') { $targets[$Matches[1]] = $true }
    }
    foreach ($t in $targets.Keys) { [void][PsLillyUninstall.Cred]::CredDeleteW($t, 1, 0) }
}

# files
foreach ($f in @('pslilly-gui.ps1', 'pslilly-core.ps1', 'pslilly.ps1', 'pslilly.ico', 'README.txt')) {
    Remove-Item -LiteralPath (Join-Path $dir $f) -Force -ErrorAction SilentlyContinue
}
if ($wipe) {
    Remove-Item -LiteralPath (Join-Path $dir 'lily.conf') -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $dir 'uninstall.ps1') -Force -ErrorAction SilentlyContinue
if (-not (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
}

if (-not $Quiet) {
    $msg = if ($wipe) { 'PSLilly has been removed.' } else { "PSLilly has been removed.`n`nYour settings were kept in case you install it again." }
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'PSLilly', 'OK', 'Information')
}
