# PSLilly

A Lily chat client for Windows, written in PowerShell.

PSLilly comes in two flavours that share the same settings file:

- **The window** (`pslilly-gui.ps1`) - a normal Windows app: a scrolling message
  pane with a typing box underneath, a login box, a desktop icon and an installer.
- **The console version** (`pslilly.ps1`) - one self-contained script that runs
  inside a PowerShell window (Windows, and anywhere else PowerShell 7 runs).

It speaks **SLCP** (the Simple Lily Client Protocol), so it knows exactly which
messages are public, private or emotes and who sent them.

## Features

- Public, private and emote messages in their own colours and styles
  (bold / italic / underline in the window), and per-person styles for private messages
- `:` fills in the last person who messaged you, `;` the last person you messaged
- Tab completes user and discussion names
- Spell checking with the Windows spell checker - misspellings in red, F7 for suggestions
- Smart quotes, dashes, accents and emoji are turned into plain ASCII when you send
  (Lily is ASCII-only); your typing is left as you wrote it
- Command history, undo/redo, cut/copy/paste, word-by-word editing
- Logs you in automatically if you tick "Remember me" (password kept in Windows Credential Manager)
- Reconnects by itself after a dropped connection, after the PC wakes from sleep,
  and when the network comes back; keepalive pings catch dead connections
- Taskbar button flashes (and optionally a sound plays) when someone messages you privately
- Scroll back with PgUp / PgDn without leaving the typing box
- `$$! <command>` runs a PowerShell command and shows the output in the chat window;
  `$$!> <command>` sends the output to Lily instead (e.g. `$$!> "/blurb $env:COMPUTERNAME"`)
- Window size, position and all settings are remembered

## Install (the easy way)

Needs Windows 10 or 11. Nothing else - Windows PowerShell is built in.

1. Click the green **Code** button above, then **Download ZIP**.
2. Unzip it, open the folder and double-click **Install.cmd**.
   (If Windows asks whether to run the file, choose Run.)
3. Double-click **PSLilly** on your desktop. Type your name and password, tick
   **Remember me on this PC**, and click Connect.

The installer needs no administrator rights. It puts PSLilly in
`%LOCALAPPDATA%\Programs\PSLilly`, makes Desktop and Start-menu shortcuts, and adds
PSLilly to **Settings > Apps** so it can be uninstalled like any other program.

- **Updating:** download the new version and run Install.cmd again. Settings and
  the saved password are kept.
- **Uninstalling:** Settings > Apps > Installed apps > PSLilly > Uninstall. It asks
  whether to keep your settings.
- To change the settings a new install starts with (server, font size, alert sound,
  ...), edit the block at the top of `install.ps1` before running Install.cmd.

`README.txt` is a one-page, plain-language guide for people who just want to chat.

## Running it without installing

Put these files in one folder: `pslilly-gui.ps1`, `pslilly-core.ps1` and (optional)
`pslilly.ico`. If you downloaded them, unblock them once:

```powershell
Get-ChildItem *.ps1 | Unblock-File
```

Then:

```powershell
.\pslilly-gui.ps1                      # the window
.\pslilly-gui.ps1 -Login               # show the login box even if a password is saved
.\pslilly-gui.ps1 -Server host -Port 7777
.\pslilly-gui.ps1 -CreateShortcut      # put a PSLilly shortcut on the desktop
.\pslilly.ps1                          # the console version
```

Works in Windows PowerShell 5.1 and PowerShell 7. The window needs Windows; the
console version also runs on macOS and Linux with PowerShell 7 (the Windows-only
extras, like spell checking, simply switch off).

## Using it

| To do this | Type or press |
|---|---|
| Send to a person | `bob: are you coming tonight?` |
| Send to a discussion | `cafe: good morning` (or `-cafe:`) |
| Reply to whoever messaged you last | `:` on an empty line |
| Message the last person you messaged | `;` on an empty line |
| Finish a name | Tab (again to cycle through matches) |
| Fix a misspelled word | F7 (again for the next suggestion) |
| Add a word to the dictionary | Shift+F7 |
| Earlier lines you sent | Up / Down |
| Scroll the messages | PgUp / PgDn, Ctrl+Up / Ctrl+Down |
| Jump to the oldest / newest | Ctrl+Home / Ctrl+End |
| Undo / redo | Ctrl+Z / Ctrl+Y |
| Clear the typing box | Esc |
| Bigger / smaller text | Ctrl + mouse wheel |
| Settings and commands | `$$` |

Lines starting with `/` are Lily commands and go to the server as usual (`/who`,
`/join`, `/detach`, ...). After `/detach` PSLilly stays disconnected until you
`$$reconnect`.

Locking the PC sets you `/away` and unlocking sets you `/here` again
(setting `away_on_lock`; the installer turns this off by default, as it can be chatty).

## Settings

Type `$$` to see every setting with its current value. Change one with
`$$<setting> <value>`; it's saved at once to `lily.conf` next to the scripts
(you can also edit that file and `$$reload`). Both versions share `lily.conf`.

Colors: `black`, `dark_blue`, `dark_green`, `dark_cyan`, `dark_red`, `dark_purple`,
`dark_yellow`, `gray`, `dark_gray`, `blue`, `green`, `cyan`, `red`, `purple`,
`yellow`, `white`, `default`. Styles (window): `normal`, `bold`, `italic`,
`underline`, combined freely.

| Setting | Default | What it does |
|---|---|---|
| `default_server`, `default_port` | `lily.acm.rpi.edu`, `7777` | Where to connect |
| `font`, `font_size` | `Consolas`, `11` | Window font |
| `input_lines` | `3` | Height of the typing box |
| `scrollback` | `5000` | Lines kept in the window |
| `base_fg`, `base_bg` | `default` | Normal text and background |
| `public_fg` / `_bg` / `_style` | `white` on `dark_blue` | Public messages |
| `private_fg` / `_bg` / `_style` | `yellow` on `dark_blue` | Private messages |
| `emote_fg` / `_bg` / `_style` | `purple` on `green` | Emotes |
| `system_fg` / `_bg` / `_style` | `default` | Arrivals, departures, blurbs... |
| `mine_fg` / `_bg` / `_style` | `dark_gray` | The lines you send (window) |
| `command_fg` / `_bg` / `_style` | `gray` | `$$!` output (window) |
| `spell_fg`, `spell_bg` | `red` | Misspelled words |
| `echo_input` | `on` | Show what you send in the message pane |
| `alert_private`, `alert_sound` | `on`, `off` | Flash the taskbar / play a sound on a private message |
| `auto_reconnect` | `on` | Reconnect after drops and sleep |
| `keepalive` | `5` | Minutes of quiet before a keepalive ping (0 = off) |
| `away_on_lock` | `on` | `/away` when the PC locks or sleeps, `/here` when you're back |
| `away_command`, `here_command` | `/away`, `/here` | What those send |
| `quit_command` | (empty) | Sent before closing; empty = just disconnect |
| `ascii`, `accent_marks` | `on`, `off` | ASCII conversion; `e'` instead of `e` for accents |
| `spellcheck`, `spell_language` | `on`, `auto` | Spell checking (Windows) |
| `slcp` | `on` | Use SLCP (off = plain text, coloured with the `*_pattern` settings) |
| `showsent`, `logfile` | `off`, (empty) | Debugging: show sent bytes; keep a transcript |

**Per-person styles:** `$$user strider yellow on dark_red bold` styles private
messages from strider (`$$user` lists them, `$$user strider off` removes it).

**Your own ASCII replacements:** `$$map ’ '` (or `$$map U+2019 '`) changes what a
character is sent as; `$$map` lists yours, `$$map ’ off` goes back to the built-in one.

## Commands

| Command | |
|---|---|
| `$$` | Settings, commands and a style preview |
| `$$<setting> [value]` | Show or change a setting |
| `$$user`, `$$map` | Per-person styles, character replacements (see above) |
| `$$! <command>` | Run PowerShell in the background; output appears when it finishes |
| `$$!> <command>` | Run PowerShell and send each output line to Lily as if you typed it (at most 10 lines / 1024 characters), e.g. `$$!> "/blurb $env:COMPUTERNAME"` or `$$!> "bob: it's $(Get-Date -Format t) here"` |
| `$$stop` | Stop running `$$!` commands |
| `$$connect` | Log in (shows the login box) - window |
| `$$reconnect` / `$$disconnect` | Reconnect now / disconnect and stay disconnected |
| `$$forget` | Remove the saved password for this server - window |
| `$$clear` | Clear the message pane - window |
| `$$send <text>` | Send text exactly as typed |
| `$$reload` | Re-read `lily.conf` |
| `$$quit` | Close PSLilly |

## Files

| File | |
|---|---|
| `pslilly-gui.ps1` | The window |
| `pslilly-core.ps1` | The engine behind the window (connection, SLCP, settings, ...) |
| `pslilly.ps1` | The console version (standalone) |
| `pslilly.ico` | Icon |
| `Install.cmd`, `install.ps1`, `uninstall.ps1` | Installer and uninstaller |
| `README.txt` | Plain-language guide for everyday users |
| `lily.conf` | Your settings (created on first run; not in this repository) |

## Credits

- [zephyrlily](https://github.com/joshw/zephyrlily) - its SLCP protocol notes and
  message layouts guided PSLilly's SLCP support, and its ASCII conversion tables
  are used (MPL 1.1, used here under MPL 2.0 as MPL 1.1 section 6.2 allows).
- tigerlily, the reference SLCP client.
- The Lily community.

## License

[Mozilla Public License 2.0](LICENSE).
