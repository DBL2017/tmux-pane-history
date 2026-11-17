#!/usr/bin/env bash

set -euo pipefail

# 保存过程使用临时文件；无论成功或失败，退出时都清理它。
temporary_file=""

cleanup() {
	if [[ -n "$temporary_file" ]]; then
		rm -f "$temporary_file"
	fi
}
trap cleanup EXIT

# 按 tmux-resurrect 的配置和默认规则定位快照目录。
resurrect_directory() {
	local path
	local host

	path="$(tmux show-option -gqv @resurrect-dir)"
	if [[ -z "$path" ]]; then
		if [[ -d "$HOME/.tmux/resurrect" ]]; then
			path="$HOME/.tmux/resurrect"
		else
			path="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
		fi
	fi
	host="$(hostname)"
	path="${path//\$HOME/$HOME}"
	path="${path//\$HOSTNAME/$host}"
	path="${path//\~/$HOME}"
	case "$path" in
		/*) ;;
		*) path="$HOME/$path" ;;
	esac
	printf '%s\n' "$path"
}

# 将每个 pane 的 session/window/pane 索引与历史 ID 追加到当前快照。
save_pane_ids() {
	local state_file="${1:-}"
	local tab=$'\t'
	local format
	local pane_rows
	local record
	local session_name
	local window_index
	local pane_index
	local pane_history_id

	if [[ -z "$state_file" || ! -f "$state_file" ]]; then
		printf 'tmux-pane-history: tmux-resurrect did not provide a valid state file\n' >&2
		return 1
	fi

	temporary_file="${state_file}.pane-history.$$"
	umask 077
	: > "$temporary_file"
	# 使用独立的 tph 记录，避免影响 tmux-resurrect 自身的 pane 记录。
	format="tph${tab}#{session_name}${tab}#{window_index}${tab}#{pane_index}${tab}#{@pane-history-id}"
	pane_rows="$(tmux list-panes -a -F "$format")" || {
		printf 'tmux-pane-history: cannot list panes while saving history IDs\n' >&2
		return 1
	}

	while IFS="$tab" read -r record session_name window_index pane_index pane_history_id; do
		[[ "$record" == "tph" && -n "$pane_history_id" ]] || continue
		if [[ ! "$pane_history_id" =~ ^[[:alnum:]_-]+$ ]]; then
			printf 'tmux-pane-history: refusing to save an invalid pane history ID\n' >&2
			return 1
		fi
		printf 'tph\t%s\t%s\t%s\t%s\n' \
			"$session_name" "$window_index" "$pane_index" "$pane_history_id" >> "$temporary_file"
	done <<< "$pane_rows"

	chmod 600 "$temporary_file"
	if [[ -s "$temporary_file" ]]; then
		cat "$temporary_file" >> "$state_file"
	fi
	rm -f "$temporary_file"
	temporary_file=""
}

# 在恢复开始时标记状态，并记下最近一次快照以供后续匹配。
prepare_restore() {
	local map_file
	local directory

	tmux set-option -gq @pane-history-restore-in-progress on
	directory="$(resurrect_directory)"
	map_file="$directory/last"
	if [[ -r "$map_file" ]]; then
		tmux set-option -gq @pane-history-restore-map "$map_file"
	else
		tmux set-option -gu @pane-history-restore-map
	fi
}

# 根据保存时的 pane 索引，查找对应的历史 ID。
find_saved_id() {
	local map_file="$1"
	local target_session="$2"
	local target_window="$3"
	local target_pane="$4"
	local tab=$'\t'
	local record
	local session_name
	local window_index
	local pane_index
	local pane_history_id

	while IFS="$tab" read -r record session_name window_index pane_index pane_history_id; do
		if [[ "$record" == "tph" &&
			"$session_name" == "$target_session" &&
			"$window_index" == "$target_window" &&
			"$pane_index" == "$target_pane" ]]; then
			if [[ "$pane_history_id" =~ ^[[:alnum:]_-]+$ ]]; then
				printf '%s\n' "$pane_history_id"
				return 0
			fi
			printf 'tmux-pane-history: invalid history ID in tmux-resurrect state\n' >&2
			return 2
		fi
	done < "$map_file"
	return 1
}

# 对恢复出的 pane 应用快照中保存的历史 ID。
restore_pane_ids() {
	local map_file
	local tab=$'\t'
	local format
	local panes
	local pane_id
	local session_name
	local window_index
	local pane_index
	local existing_id
	local saved_id

	map_file="$(tmux show-option -gqv @pane-history-restore-map)"
	if [[ -z "$map_file" || ! -r "$map_file" ]]; then
		printf 'tmux-pane-history: no pane history map in the tmux-resurrect snapshot\n' >&2
		return 1
	fi

	format="#{pane_id}${tab}#{session_name}${tab}#{window_index}${tab}#{pane_index}"
	panes="$(tmux list-panes -a -F "$format")" || {
		printf 'tmux-pane-history: cannot list panes while restoring history IDs\n' >&2
		return 1
	}

	while IFS="$tab" read -r pane_id session_name window_index pane_index; do
		[[ -n "$pane_id" ]] || continue
		existing_id="$(tmux show-option -pqv -t "$pane_id" @pane-history-id)"
		if [[ "$existing_id" =~ ^[[:alnum:]_-]+$ ]]; then
			continue
		fi
		if saved_id="$(find_saved_id "$map_file" "$session_name" "$window_index" "$pane_index")"; then
			tmux set-option -p -t "$pane_id" @pane-history-id "$saved_id"
		else
			local lookup_status="$?"
			if [[ "$lookup_status" -eq 2 ]]; then
				return 1
			fi
		fi
	done <<< "$panes"
}

# 尽量完成 ID 恢复后清除标记，避免 Bash 一直等待。
finish_restore() {
	local status=0

	restore_pane_ids || status="$?"
	tmux set-option -gu @pane-history-restore-in-progress || status="$?"
	return "$status"
}

# 供 tmux-resurrect 调用的三个阶段：保存、恢复前和恢复后。
case "${1:-}" in
	save)
		save_pane_ids "${2:-}"
		;;
	pre)
		prepare_restore
		;;
	post)
		finish_restore
		;;
	*)
		printf 'Usage: %s {save state-file|pre|post}\n' "$0" >&2
		exit 2
		;;
esac
