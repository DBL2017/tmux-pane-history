# tmux-pane-history

Keep a separate Bash history for each tmux pane and reload it when a pane is
recreated by `tmux-resurrect`. Bash's normal `history` command and Up/Down
history navigation continue to work.

## Install

Add the plugin to TPM:

```tmux
set -g @plugin 'your-github-user/tmux-pane-history'
```

Source the shell integration at the end of `~/.bashrc`:

```bash
source "${TMUX_PANE_HISTORY_PLUGIN_DIR:-$HOME/.tmux/plugins/tmux-pane-history}/shell/bash.sh"
```

Reload tmux and restart existing pane shells. The plugin entry file is loaded
by TPM, but TPM does not source shell startup files automatically.
Adjust the fallback path if TPM installs plugins elsewhere.

This version supports Bash. Zsh and Fish need their own shell-specific
integrations.

## tmux-resurrect integration

`tmux-resurrect` is required for history IDs to follow panes across a restore;
without it, new panes start with new histories.

Each pane gets a generated ID in the tmux pane option `@pane-history-id`.
When `tmux-resurrect` saves a snapshot, the plugin appends `tph` records that
map session/window/pane indices to those IDs. After panes are restored, the
plugin reads that map and reapplies the IDs before the Bash integration selects
the history files. This avoids relying on pane titles, which applications can
change.

The Bash integration appends history before each command as well as before
each prompt. Long-running foreground commands, such as `docker exec ... /bin/bash`,
are therefore saved to the host pane's history file before they start. If a
`DEBUG` trap is already configured, the plugin preserves it and falls back to
appending history when the next prompt appears.

The plugin appends commands to `@resurrect-hook-post-save-layout`,
`@resurrect-hook-pre-restore-all`, and `@resurrect-hook-post-restore-all`,
preserving existing hook commands. The installed `tmux-resurrect` version must
support these hooks.

## Options

Set these before TPM loads the plugin:

```tmux
set -g @pane-history-data-dir "~/.local/state/tmux-pane-history"
set-environment -g TMUX_PANE_HISTORY_RESTORE_TIMEOUT 120
```

History files are stored under `bash/` inside the data directory. The default
is `${XDG_STATE_HOME:-~/.local/state}/tmux-pane-history`. The `bash/` directory
is restricted to mode `0700`, and history files to `0600`.

The shell integration sets `HISTSIZE=10000` and `HISTFILESIZE=100000` only when
they are unset. Existing `HISTCONTROL` and `HISTIGNORE` settings are respected,
so commands excluded by those settings are not recorded.
Inside tmux, commands are written to the pane-specific history file rather
than mirrored to the usual `~/.bash_history`.
