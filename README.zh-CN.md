# tmux-pane-history

为每个 tmux pane 单独记录 Bash 命令历史，并在 `tmux-resurrect` 恢复会话后重新关联历史文件。恢复后可以使用 Bash 的 `history` 命令或上下方向键查找和切换历史命令。

## 功能与原理

- 每个 pane 使用独立的历史文件，不同 pane 的命令历史互不混合。
- 插件为 pane 设置 `@pane-history-id`，并将它与 pane 的 session、window 和 pane 索引一起保存到 `tmux-resurrect` 快照。
- 恢复时，插件根据快照重新设置 pane 的历史 ID；Bash 等待恢复完成后再选择对应的历史文件。
- 插件使用 Bash 的 `HISTFILE`、`histappend` 和 `history -a`，保留 Bash 原生的历史命令和上下方向键行为。每条命令执行前都会先追加历史，因此 `docker exec ... /bin/bash` 这类前台阻塞命令在进入容器前就会写入宿主 pane 的历史文件。
- 如果 Bash 已设置 `DEBUG` trap，插件会保留该 trap，并退回到下一个提示符出现时追加历史。

## 依赖与限制

- tmux
- Bash 交互式 shell
- 支持以下 hooks 的 `tmux-resurrect`：`post-save-layout`、`pre-restore-all` 和 `post-restore-all`

目前只支持 Bash；Zsh 和 Fish 需要各自的 shell 集成。若不使用 `tmux-resurrect`，pane 的历史 ID 不会随会话恢复，新建的 pane 会开始新的历史记录。

## 安装和配置

以下示例假设插件位于 `~/.tmux/plugins/tmux-pane-history`，并通过 TPM 安装 `tmux-resurrect`。将配置加入 `~/.tmux.conf`：

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'

# pane 历史文件的存放目录
set -g @pane-history-data-dir "~/.local/state/tmux-pane-history"

# Bash 等待 tmux-resurrect 完成恢复的最长时间（秒）
set-environment -g TMUX_PANE_HISTORY_RESTORE_TIMEOUT 120

# 加载本地 pane-history 插件；若通过 TPM 安装本插件，请改用 TPM 配置并删除此行
run-shell '~/.tmux/plugins/tmux-pane-history/tmux-pane-history.tmux'

# TPM 初始化通常放在配置文件末尾
run '~/.tmux/plugins/tpm/tpm'
```

在 `~/.bashrc` 末尾添加 shell 集成：

```bash
source "${TMUX_PANE_HISTORY_PLUGIN_DIR:-$HOME/.tmux/plugins/tmux-pane-history}/shell/bash.sh"
```

插件只会在 tmux 中的交互式 Bash 启用。TPM 只加载 tmux 侧插件，不会自动修改或加载 Bash 启动文件，因此需要单独添加上述 `source` 配置。

如果本插件通过 TPM 安装，可将 `run-shell` 行替换为以下配置，并将占位的 GitHub 用户名替换为实际仓库所有者：

```tmux
set -g @plugin '你的GitHub用户名/tmux-pane-history'
```

## 启用

重新加载 tmux 配置：

```sh
tmux source-file ~/.tmux.conf
```

然后在已有 pane 中重新启动 Bash，或新建 pane，使 `.bashrc` 中的集成生效。确认当前 pane 使用的历史文件：

```bash
echo "$HISTFILE"
```

使用 `tmux-resurrect` 保存和恢复会话后，恢复的 pane 会继续使用原来的历史文件。可以运行 `history`，或按上下方向键浏览命令。

## 配置项与存储位置

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `@pane-history-data-dir` | `${XDG_STATE_HOME:-~/.local/state}/tmux-pane-history` | 历史文件根目录 |
| `TMUX_PANE_HISTORY_RESTORE_TIMEOUT` | `120` 秒 | Bash 等待 tmux 恢复完成的最长时间 |
| `HISTSIZE` | `10000`（仅在未设置时） | 当前 Bash 会话保留的历史条数 |
| `HISTFILESIZE` | `100000`（仅在未设置时） | 历史文件保留的最大条数 |

历史文件存放在数据目录下的 `bash/` 子目录中。插件将该目录权限设为 `0700`，历史文件权限设为 `0600`。在 tmux 中，命令写入 pane 专属历史文件，不会同时写入常规的 `~/.bash_history`。

已有的 `HISTCONTROL` 和 `HISTIGNORE` 设置仍然生效；被这些设置排除的命令不会记录。命令历史可能包含敏感信息，请避免将密码、令牌等直接输入到命令行。
