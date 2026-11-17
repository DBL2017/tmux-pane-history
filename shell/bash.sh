#!/usr/bin/env bash

# 仅在 tmux 中的交互式 Bash 启用 pane 历史。
if [[ $- != *i* || -z ${TMUX_PANE:-} ]]; then
	return 0
fi

# 避免同一个 Bash 会话重复加载并重复注册提示符钩子。
if [[ -n ${__TMUX_PANE_HISTORY_INITIALIZED:-} ]]; then
	return 0
fi

# 优先使用 tmux 注入的目录，其次读取 tmux 选项，最后使用默认目录。
__TPH_DATA_DIR="${TMUX_PANE_HISTORY_DATA_DIR:-}"
if [[ -z "$__TPH_DATA_DIR" ]]; then
	__TPH_DATA_DIR="$(command tmux show-option -gqv @pane-history-data-dir 2>/dev/null)" || __TPH_DATA_DIR=""
fi
if [[ -z "$__TPH_DATA_DIR" ]]; then
	__TPH_DATA_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-pane-history"
fi
case "$__TPH_DATA_DIR" in
	\~) __TPH_DATA_DIR="$HOME" ;;
	\~/*) __TPH_DATA_DIR="$HOME/${__TPH_DATA_DIR:2}" ;;
	\$HOME) __TPH_DATA_DIR="$HOME" ;;
	\$HOME/*) __TPH_DATA_DIR="$HOME/${__TPH_DATA_DIR:6}" ;;
	/*) ;;
	*) __TPH_DATA_DIR="$HOME/$__TPH_DATA_DIR" ;;
esac

__TPH_ID=""
__TPH_FILE=""
__TPH_RESTORE_PENDING=0
__TPH_REPORTED_WRITE_ERROR=""

# 从 pane 级 tmux 用户选项读取或写入稳定的历史 ID。
__tph_get_pane_id() {
	command tmux show-option -pqv -t "$TMUX_PANE" @pane-history-id 2>/dev/null
}

__tph_set_pane_id() {
	command tmux set-option -p -t "$TMUX_PANE" @pane-history-id "$1" >/dev/null
}

# 新 pane 首次启动时生成唯一 ID；恢复 pane 则沿用快照中的 ID。
__tph_new_id() {
	local server_pid
	local pane_number="${TMUX_PANE#%}"
	local timestamp

	server_pid="$(command tmux display-message -p -t "$TMUX_PANE" "#{pid}" 2>/dev/null)" ||
		server_pid="unknown"
	timestamp="$(date +%s)" || return 1
	printf 's%s-p%s-t%s-r%s%s\n' "$server_pid" "$pane_number" "$timestamp" "$RANDOM" "$RANDOM"
}

# 等待 tmux-resurrect 完成 pane 映射，避免 Bash 抢先创建错误的历史文件。
__tph_wait_for_restore() {
	local timeout="${TMUX_PANE_HISTORY_RESTORE_TIMEOUT:-120}"
	local started="$SECONDS"
	local restoring

	if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
		printf 'tmux-pane-history: invalid restore timeout; using 120 seconds\n' >&2
		timeout=120
	fi

	while :; do
		restoring="$(command tmux show-option -gqv @pane-history-restore-in-progress 2>/dev/null)" || {
			printf 'tmux-pane-history: cannot query tmux restore state\n' >&2
			return 1
		}
		if [[ "$restoring" != "on" ]]; then
			return 0
		fi
		__TPH_RESTORE_PENDING=1

		if (( SECONDS - started >= timeout )); then
			printf 'tmux-pane-history: timed out waiting for tmux-resurrect\n' >&2
			return 1
		fi
		sleep 0.1
	done
}

# 创建并限制历史目录与文件权限，命令历史只允许当前用户访问。
__tph_prepare_history_file() {
	local id="$1"
	local history_dir="$__TPH_DATA_DIR/bash"
	local previous_umask

	if [[ -z "$__TPH_DATA_DIR" || "$__TPH_DATA_DIR" == "/" || "$__TPH_DATA_DIR" == "$HOME" ]]; then
		printf 'tmux-pane-history: data directory must be dedicated, not %s\n' "$__TPH_DATA_DIR" >&2
		return 1
	fi
	if [[ ! "$id" =~ ^[[:alnum:]_-]+$ ]]; then
		printf 'tmux-pane-history: invalid pane history ID\n' >&2
		return 1
	fi

	previous_umask="$(umask)"
	umask 077
	if ! mkdir -p "$history_dir"; then
		umask "$previous_umask"
		printf 'tmux-pane-history: cannot create history directory: %s\n' "$history_dir" >&2
		return 1
	fi
	if ! chmod 700 "$history_dir"; then
		umask "$previous_umask"
		printf 'tmux-pane-history: cannot secure history directory: %s\n' "$history_dir" >&2
		return 1
	fi

	__TPH_FILE="$history_dir/$id.history"
	if ! : >> "$__TPH_FILE"; then
		umask "$previous_umask"
		printf 'tmux-pane-history: cannot create history file: %s\n' "$__TPH_FILE" >&2
		return 1
	fi
	if ! chmod 600 "$__TPH_FILE"; then
		umask "$previous_umask"
		printf 'tmux-pane-history: cannot secure history file: %s\n' "$__TPH_FILE" >&2
		return 1
	fi
	umask "$previous_umask"
}

# 设置 HISTFILE；Bash 会在启动文件处理完后自行读取该文件。
__tph_set_history_file() {
	local id="$1"

	__tph_prepare_history_file "$id" || return 1
	HISTFILE="$__TPH_FILE"
	export HISTFILE
	__TPH_ID="$id"
}

# 等待恢复完成后，读取或生成当前 pane 的历史 ID 并绑定历史文件。
__tph_initialize() {
	local pane_history_id

	__tph_wait_for_restore || return 1
	pane_history_id="$(__tph_get_pane_id)" || {
		printf 'tmux-pane-history: cannot read the pane history ID\n' >&2
		return 1
	}

	if [[ ! "$pane_history_id" =~ ^[[:alnum:]_-]+$ ]]; then
		if [[ -n "$pane_history_id" ]]; then
			printf 'tmux-pane-history: replacing an invalid pane history ID\n' >&2
		elif [[ "$__TPH_RESTORE_PENDING" -eq 1 ]]; then
			printf 'tmux-pane-history: no saved ID for this pane; starting a new history\n' >&2
		fi
		pane_history_id="$(__tph_new_id)" || {
			printf 'tmux-pane-history: cannot generate a pane history ID\n' >&2
			return 1
		}
		__tph_set_pane_id "$pane_history_id" || {
			printf 'tmux-pane-history: cannot store the pane history ID in tmux\n' >&2
			return 1
		}
	fi

	__tph_set_history_file "$pane_history_id"
}

# 追加当前 Bash 会话尚未写入文件的历史；失败时每个 shell 只报告一次。
__tph_append_history() {
	if ! history -a && [[ -z "$__TPH_REPORTED_WRITE_ERROR" ]]; then
		printf 'tmux-pane-history: failed to append command history to %s\n' "$HISTFILE" >&2
		__TPH_REPORTED_WRITE_ERROR=1
	fi
}

# 每次显示提示符前追加历史，保留原有命令的退出状态。
__tmux_pane_history_prompt() {
	local status="$?"

	__tph_append_history
	return "$status"
}

# 在前台命令执行前追加历史，避免阻塞命令尚未返回时历史还未落盘。
__tmux_pane_history_preexec() {
	__tph_append_history
	return 0
}

# 根据 PROMPT_COMMAND 顶层采集的状态安装 DEBUG trap，避免覆盖用户配置。
__tph_install_preexec_hook() {
	if [[ -n ${__TPH_EXISTING_DEBUG_TRAP:-} ]]; then
		printf 'tmux-pane-history: preserving existing DEBUG trap; history will be appended at the next prompt\n' >&2
	elif ! trap '__tmux_pane_history_preexec' DEBUG; then
		printf 'tmux-pane-history: cannot install pre-command history hook; history will be appended at the next prompt\n' >&2
	fi

	__TPH_PREEXEC_SETUP_DONE=1
	unset __TPH_EXISTING_DEBUG_TRAP
	return 0
}

# 保留用户已有的 PROMPT_COMMAND，并兼容字符串和 Bash 数组两种形式。
__tph_install_prompt_hook() {
	local declaration
	local preexec_setup='if [[ -z ${__TPH_PREEXEC_SETUP_DONE:-} ]]; then __TPH_EXISTING_DEBUG_TRAP="$(trap -p DEBUG)"; __tph_install_preexec_hook; fi'

	declaration="$(declare -p PROMPT_COMMAND 2>/dev/null || true)"
	case "$declaration" in
		"declare -a"*)
			PROMPT_COMMAND+=("$preexec_setup")
			PROMPT_COMMAND+=(__tmux_pane_history_prompt)
			;;
		*)
			if [[ -n ${PROMPT_COMMAND:-} ]]; then
				PROMPT_COMMAND="${PROMPT_COMMAND}"$'\n'"$preexec_setup"
			else
				PROMPT_COMMAND="$preexec_setup"
			fi
			PROMPT_COMMAND="${PROMPT_COMMAND}"$'\n'"__tmux_pane_history_prompt"
			;;
	esac
}

# 仅在用户未设置时提供较大的 Bash 历史容量，并允许追加写入。
if [[ -z ${HISTSIZE:-} ]]; then
	HISTSIZE=10000
fi
if [[ -z ${HISTFILESIZE:-} ]]; then
	HISTFILESIZE=100000
fi
shopt -s histappend

# 初始化成功后才注册追加钩子；失败时明确提示但不阻止 Bash 启动。
if __tph_initialize; then
	if __tph_install_prompt_hook; then
		__TMUX_PANE_HISTORY_INITIALIZED=1
	else
		printf 'tmux-pane-history: cannot install the Bash prompt hook\n' >&2
	fi
else
	printf 'tmux-pane-history: pane history is not enabled in this shell\n' >&2
fi
