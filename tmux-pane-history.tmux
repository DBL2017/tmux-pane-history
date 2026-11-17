#!/usr/bin/env bash

# 记录插件目录，用于加载恢复钩子脚本。
CURRENT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# 将配置中的 ~、$HOME 和相对路径展开为绝对路径。
expand_path() {
	local path="$1"
	case "$path" in
		\~) path="$HOME" ;;
		\~/*) path="$HOME/${path:2}" ;;
		\$HOME) path="$HOME" ;;
		\$HOME/*) path="$HOME/${path:6}" ;;
		/*) ;;
		*) path="$HOME/$path" ;;
	esac
	printf '%s\n' "$path"
}

# 幂等地追加 tmux-resurrect 钩子，不覆盖用户已配置的命令。
register_resurrect_hook() {
	local option="$1"
	local action="$2"
	local existing
	local command

	existing="$(tmux show-option -gqv "$option")"
	printf -v command '%q %q' "$CURRENT_DIR/scripts/resurrect_hook.sh" "$action"
	if [[ "$existing" == *"$command"* ]]; then
		return 0
	fi

	if [[ -n "$existing" ]]; then
		existing="${existing}"$'\n'"${command}"
	else
		existing="$command"
	fi
	tmux set-option -gq "$option" "$existing"
}

# 初始化历史目录和 Bash 环境变量，并注册保存、恢复前后钩子。
main() {
	local data_dir
	data_dir="$(tmux show-option -gqv @pane-history-data-dir)"
	if [[ -z "$data_dir" ]]; then
		data_dir="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-pane-history"
	fi
	data_dir="$(expand_path "$data_dir")"

	tmux set-option -gq @pane-history-data-dir "$data_dir"
	tmux set-environment -g TMUX_PANE_HISTORY_PLUGIN_DIR "$CURRENT_DIR"
	tmux set-environment -g TMUX_PANE_HISTORY_DATA_DIR "$data_dir"

	# 保存时把 pane 与历史 ID 的映射写入快照。
	if ! register_resurrect_hook "@resurrect-hook-post-save-layout" "save"; then
		printf 'tmux-pane-history: cannot register the tmux-resurrect save hook\n' >&2
		return 1
	fi
	# 恢复前设置标记，让新启动的 Bash 等待 pane ID 映射恢复完成。
	if ! register_resurrect_hook "@resurrect-hook-pre-restore-all" "pre"; then
		printf 'tmux-pane-history: cannot register the tmux-resurrect pre-restore hook\n' >&2
		return 1
	fi
	# 恢复后为 pane 重新设置历史 ID，并解除 Bash 的等待。
	if ! register_resurrect_hook "@resurrect-hook-post-restore-all" "post"; then
		printf 'tmux-pane-history: cannot register the tmux-resurrect post-restore hook\n' >&2
		return 1
	fi
}

main
