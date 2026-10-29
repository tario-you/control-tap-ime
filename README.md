# ControlTapIME

**Tap Control to switch languages. Keep Control combinations working normally.**

A small, native macOS menu-bar helper integrated with Karabiner-Elements. It
selects the input source directly and applies a temporary-focus workaround for
Chinese, Japanese, Korean, and Vietnamese input methods. This addresses the
macOS failure where the language indicator changes but the focused text field
continues typing with the previous input method.

## Behavior

- Tap either Control key on its own, releasing within 250 ms: cycle the language group.
- Control plus another key, a mouse click, or scrolling: normal Control behavior;
  Karabiner cancels the standalone-tap action.
- Hold Control longer than 250 ms: normal Control, with no language switch.
- English selection does not borrow focus. CJK selection briefly focuses a tiny,
  almost transparent input window, then returns to the previous application.
- A small `EN` / `中` menu-bar indicator shows the active source. Its menu can also switch languages.
- Switches are serialized so quick taps are processed in order.

The helper stays running. Karabiner sends a local command on release, so each tap
avoids launching a new GUI app or sending the system Control–Space shortcut.

## Install

Requires macOS 13+, Karabiner-Elements, Python 3, and existing Apple command-line
developer tools. Builds a universal Apple Silicon / Intel app with no package dependencies.

```sh
git clone https://github.com/tario-you/control-tap-ime.git
cd control-tap-ime
bash scripts/build.sh
bash scripts/test.sh
python3 scripts/install.py
```

The installer adds **one rule** to the selected Karabiner profile, preserves the
rest of its JSON, and keeps a private backup. It installs the helper into
`~/Applications/ControlTapIME.app` and a login LaunchAgent. The app uses Karabiner's
existing input permissions; it has no global keyboard listener of its own and
does not request Accessibility or Input Monitoring access.

Existing Control remaps cause installation to stop for reconciliation. The rule
also skips Control taps when a `caps_hyper_down` variable equals `1`, supporting
setups that use a Caps Lock Hyper layer.

## Select your language pair

Automatic mode chooses ABC (or another enabled English Apple keyboard layout)
and the first enabled Chinese input source, falling back to another CJK source.
To choose a specific pair at first installation:

```sh
python3 scripts/install.py \
  --source-id com.apple.keylayout.ABC \
  --source-id com.tencent.inputmethod.wetype.pinyin
```

Local settings are in `~/Library/Application Support/ControlTapIME/config.json`:

```json
{
  "sourceIDs": ["com.apple.keylayout.ABC", "com.tencent.inputmethod.wetype.pinyin"],
  "refreshMilliseconds": 80
}
```

An empty `sourceIDs` array enables automatic mode. Configuration is reread on
each switch. To discover enabled IDs:

```sh
"$HOME/Applications/ControlTapIME.app/Contents/MacOS/controltap-ime" list
```

## How the Chinese fix works

1. Select the exact enabled input source through Carbon Text Input Sources (TIS).
2. For CJK sources, activate a 3 × 3 point input window at 1% opacity for the
   configured refresh interval (80 ms by default).
3. Close it and restore the previous application, unless you changed apps during
   the refresh. This nudges macOS to reconnect the active input-method session.
4. Check the source reported by macOS. If it reverted, retry selection once and
   report failure if it still does not remain selected.

The refresh is a workaround for macOS input-method behavior, not a guarantee of
every third-party IME's internal mode. Verification checks TIS selection, not the
characters you type. Focus briefly moves; a menu-bar flash is possible. Wait for
the indicator before typing immediately after a switch. If an IME is slow to
activate, increase `refreshMilliseconds` to 150; the accepted range is 20–500 ms.
Secure keyboard input causes a switch to be skipped. No guard is disabled.

The temporary-focus approach was inspired by
[macism](https://github.com/laishulu/macism) and the temporary-input-window mode in
[Input Source Pro](https://github.com/runjuu/InputSourcePro). This repository is an
independent, focused implementation of the helper and Karabiner integration.

## Commands and privacy

```sh
controltap-ime status
controltap-ime toggle
controltap-ime set SOURCE_ID
```

Use the executable inside the installed app bundle, or add that directory to your
PATH. Commands return JSON, including the selected source, whether a refresh ran,
and elapsed milliseconds. Selection failures return a nonzero exit code.

IPC uses a local Unix socket with `0600` permissions and verifies the peer UID in
both directions. A lock prevents duplicate servers. Messages are limited to
16 KiB and have timeouts. The helper uses no network connection, clipboard access,
or key logging. Personal Karabiner settings, device identifiers, and runtime
configuration are never part of this repository.

## Disable / uninstall

```sh
python3 scripts/install.py --uninstall
```

This removes only the ControlTapIME rule and login registration, preserving later
Karabiner edits. The app, local settings, and backups are retained for recovery.
The original Control–Space shortcut is never changed by this installer.

## Development

Written in Objective-C with AppKit, Carbon, and POSIX sockets. Apple clang builds
the app without Xcode project generation or third-party libraries.

```sh
bash scripts/test.sh
bash scripts/build.sh
```

Tests cover language ordering and input modes, unavailable-source failures,
refresh configuration, idempotent installation, preservation of unrelated rules,
concurrent-edit protection, and symlink protection. Live typing must be checked
on the intended macOS version and input method.

Verified on macOS 15.6 with ABC and WeType on October 6, 2026: 20 core checks,
six installer tests, and ten successful live TIS switches. A physical Control tap
was also confirmed to enable Chinese candidate entry and switch back to English.
This is one tested setup; other input methods still need their own typing check.

MIT licensed.
