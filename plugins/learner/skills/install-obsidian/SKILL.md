---
name: install-obsidian
description: Set up Obsidian plugins for Claude Code integration — installs BRAT, obsidian-terminal, and obsidian-claude-selection, then enables them and adds a CMD+J terminal hotkey.
argument-hint: "[path/to/vault]"
user_invocable: true
allowed-tools: Read, Write, Glob, Bash(curl:*), Bash(mkdir:*)
---

# Install Obsidian Plugins for Claude Code

Automates the full Obsidian + Claude Code plugin setup. Safe to run multiple times — every step is idempotent.

**Installs:**
- [BRAT](https://github.com/TfTHacker/obsidian42-brat) — beta plugin manager
- [obsidian-claude-selection](https://github.com/ivorscott/obsidian-claude-selection) — directly from GitHub releases (BRAT handles auto-updates)
- [obsidian-terminal](https://github.com/polyipseity/obsidian-terminal) — integrated terminal

**Configures:**
- Enables all three plugins in Community Plugins
- Adds `CMD+J` hotkey to open the integrated terminal
- Creates `.claude/hooks/inject-selection.py` in the vault
- Creates `.claude/settings.json` with the `UserPromptSubmit` hook

---

## Step 1 — Detect the Obsidian vault

If `$ARGUMENTS` is provided, treat it as the vault path and verify that a `.obsidian/` directory exists inside it.

If no argument is given, search for `.obsidian/` using Glob in the following locations (stop at first match):
1. Current working directory (`.obsidian`)
2. Up to 3 ancestor directories (`../.obsidian`, `../../.obsidian`, `../../../.obsidian`)
3. `~/Documents/**/.obsidian` (depth 2)
4. `~/.obsidian`

If multiple vaults are found, use the first one and tell the user which vault was selected.

**If no vault is found → abort immediately** with this message:
```
No Obsidian vault detected.
Run `/install-obsidian path/to/vault` to specify your vault path.
```

Set `VAULT` to the resolved vault root for all subsequent steps.

---

## Step 2 — Install BRAT

Plugin directory: `$VAULT/.obsidian/plugins/obsidian42-brat/`

**Idempotency check:** If `$VAULT/.obsidian/plugins/obsidian42-brat/main.js` already exists, skip this step and report "BRAT already installed."

Otherwise:
1. Fetch the latest release metadata:
   ```
   curl -s https://api.github.com/repos/TfTHacker/obsidian42-brat/releases/latest
   ```
2. Extract the `browser_download_url` for `main.js`, `manifest.json`, and `styles.css` from the `assets` array.
3. `mkdir -p $VAULT/.obsidian/plugins/obsidian42-brat`
4. Download each asset with `curl -sL <url> -o <destination>`.

---

## Step 3 — Configure BRAT to track obsidian-claude-selection

File: `$VAULT/.obsidian/plugins/obsidian42-brat/data.json`

**Idempotency:** Read the file if it exists. If `ivorscott/obsidian-claude-selection` is already in `pluginList`, skip writing and report "BRAT already configured."

Start from this default if the file does not exist:
```json
{
  "pluginList": [],
  "pluginSubListFrozenVersion": [],
  "themesList": [],
  "updateAtStartup": true,
  "updateThemesAtStartup": true,
  "enableAfterInstall": true,
  "loggingEnabled": false,
  "loggingPath": "BRAT-log",
  "loggingVerboseEnabled": false,
  "debuggingMode": false,
  "notificationsEnabled": true,
  "globalTokenName": "",
  "personalAccessToken": "",
  "selectLatestPluginVersionByDefault": false,
  "allowIncompatiblePlugins": false
}
```

Merge the following, preserving all other existing fields:
- Add `"ivorscott/obsidian-claude-selection"` to `pluginList` (if not already present)
- Add `{"repo": "ivorscott/obsidian-claude-selection", "version": ""}` to `pluginSubListFrozenVersion` (if the repo isn't already listed)
- Set `enableAfterInstall: true`
- Set `updateAtStartup: true`

Write the merged result back with the Write tool.

---

## Step 3.5 — Install obsidian-claude-selection directly

Plugin directory: `$VAULT/.obsidian/plugins/claude-selection/`

**Idempotency check:** If `$VAULT/.obsidian/plugins/claude-selection/main.js` already exists, skip and report "obsidian-claude-selection already installed."

Otherwise:
1. Fetch the latest release metadata:
   ```
   curl -s https://api.github.com/repos/ivorscott/obsidian-claude-selection/releases/latest
   ```
2. Extract `browser_download_url` for `main.js` and `manifest.json` from the `assets` array.
3. `mkdir -p $VAULT/.obsidian/plugins/claude-selection`
4. Download each asset with `curl -sL <url> -o <destination>`.

> **Why direct install instead of relying on BRAT?** BRAT's `enableAfterInstall` flag only fires during the interactive modal flow (`addPlugin()`). When BRAT auto-downloads from `pluginList` on Obsidian startup, it uses a different code path that does not call `plugins.enablePlugin()`. Direct install avoids the ~1 min wait and the extra restart.

---

## Step 4 — Install obsidian-terminal

Plugin directory: `$VAULT/.obsidian/plugins/terminal/`

**Idempotency check:** If `$VAULT/.obsidian/plugins/terminal/main.js` already exists, skip and report "obsidian-terminal already installed."

Otherwise:
1. Fetch the latest release metadata:
   ```
   curl -s https://api.github.com/repos/polyipseity/obsidian-terminal/releases/latest
   ```
2. Extract `browser_download_url` for `main.js` and `manifest.json` from the `assets` array. Also download `styles.css` if present.
3. `mkdir -p $VAULT/.obsidian/plugins/terminal`
4. Download each asset with `curl -sL <url> -o <destination>`.

---

## Step 5 — Enable plugins

File: `$VAULT/.obsidian/community-plugins.json`

**Idempotency:** Read the existing array (or start with `[]`). Add only the IDs that are not already present:
- `"obsidian42-brat"`
- `"terminal"`
- `"claude-selection"`

Write back only if the array changed.

---

## Step 6 — Add CMD+J hotkey

File: `$VAULT/.obsidian/hotkeys.json`

**Idempotency:** Read the existing object (or start with `{}`). Only add the following entry if `"terminal:open-terminal.integrated.root"` is not already a key:

```json
"terminal:open-terminal.integrated.root": [
  {
    "modifiers": ["Mod"],
    "key": "J"
  }
]
```

Never modify or remove existing hotkey bindings. Write back only if changed.

---

## Step 7 — Set up Claude Code hook

These two files wire up the Obsidian selection to Claude Code.

### `$VAULT/.claude/hooks/inject-selection.py`

**Idempotency:** Skip if the file already exists.

Otherwise create it with this exact content:

```python
#!/usr/bin/env python3
import sys, os

selection_file = os.path.join(os.getcwd(), '.claude-selection')

if not os.path.isfile(selection_file):
    sys.exit(0)

try:
    with open(selection_file, 'r', encoding='utf-8') as f:
        content = f.read().strip()
except Exception as e:
    print(f'claude-selection hook error: {e}', file=sys.stderr)
    sys.exit(0)

if not content:
    sys.exit(0)

parts = content.split('---\n', 1)
selected_text = parts[1].strip() if len(parts) > 1 else content
line_count = len(selected_text.splitlines())
sys.stderr.write(f'> {line_count} line{"s" if line_count != 1 else ""} of Obsidian context\n')

print(f'The user has selected the following text from their Obsidian notes:\n\n{content}')
```

Use `mkdir -p $VAULT/.claude/hooks` before writing.

### `$VAULT/.claude/settings.json`

**Idempotency:** Read the file if it exists. Skip writing if a `UserPromptSubmit` hook is already present.

Otherwise write:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "python3 .claude/hooks/inject-selection.py"
          }
        ]
      }
    ]
  }
}
```

If `settings.json` already exists but has no `UserPromptSubmit` key, merge the hook in rather than overwriting the file.

---

## Step 8 — Print summary

Print a table showing what was installed vs. skipped, for example:

```
Obsidian setup complete for: /path/to/vault

  BRAT                       installed
  obsidian-claude-selection  installed
  obsidian-terminal          already installed (skipped)
  community-plugins.json     updated
  hotkeys.json               already configured (skipped)
  inject-selection.py        created
  .claude/settings.json      already configured (skipped)

Restart Obsidian once. All three plugins will be active immediately.
BRAT will keep obsidian-claude-selection up to date automatically.
```
