#!/usr/bin/env bash
# Copyright (C) 2020 Cr@ns <roots@crans.org>
# Authors : Alexandre Iooss <erdnaxe@crans.org>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# This pass extension add group management support for password sharing in small organisations.
# See https://git.zx2c4.com/password-store/tree/src/password-store.sh
#
# The idea is to overwrite functions from pass to make it encrypt for groups
# For long term use, it would be great to merge some feature to upstream such
# as recrypt command and groups support.

# Change this variable to use this extension with another organisation
GROUP_NAME="default_organisation"

# Change prefix to custom store
PREFIX="${PREFIX}/${GROUP_NAME}"

# Print usage of the custom group store extension
cmd_usage() {
	echo
	cat <<-_EOF
	$PROGRAM $GROUP_NAME - Group passwords manager.

	Usage:
	  $PROGRAM $GROUP_NAME [ls] [subfolder]		list files, show if unique
	  $PROGRAM $GROUP_NAME [show] [--clip[=line-number],-c[line-number]] pass-name
	  					show existing password and optionally put it on the
	  					clipboard for $CLIP_TIME seconds
	  $PROGRAM $GROUP_NAME find pass-names... 	list files that match pass-names
	  $PROGRAM $GROUP_NAME grep [GREPOPTIONS] search-string
	  					search for files containing search-string
	  $PROGRAM $GROUP_NAME edit [--group=GROUP1,-gGROUP1...] pass-name
	  					edit (or create) a file using ${EDITOR:-vi}
	  $PROGRAM $GROUP_NAME generate [--group=GROUP1,-gGROUP1...] [--no-symbols,-n] [--clip,-c] [--in-place,-i | --force,-f] pass-name [pass-length]
	      					generate a new password of pass-length (or $GENERATED_LENGTH
	      					if unspecified) with optionally no symbols.
	      					Prompt before overwriting existing password unless
	      					forced. Optionally replace only the first line of an
	      					existing file with a new password.
	  $PROGRAM $GROUP_NAME rm [--recursive,-r] [--force,-f] pass-name
	      					remove existing password or directory.
	  $PROGRAM $GROUP_NAME recrypt [--group=GROUP1,-gGROUP1...] [paths...]
	  					recrypt selected files and folder. If set, change group.
	  $PROGRAM $GROUP_NAME git git-command-args...	execute a git command
	  $PROGRAM $GROUP_NAME help			show this text

	_EOF
}

# Overwrite set_gpg_recipients to set recipients depending on last recipients or defined target group(s)
set_gpg_recipients() {
	# Locate groups and last_group file
	# groups contains fingerprints for each group
	# last_group contains last groups used to encrypt a file
	local groupsfile="$PREFIX/.groups.json"
	local lastgroupfile="$PREFIX/.last_group.json"
	[[ -f $groupsfile ]] || die "$groupsfile was not found, please create one."
	[[ -f $lastgroupfile ]] || die "$lastgroupfile was not found, please run `echo {} > $lastgroupfile`."

	if [ -n "$target_groups" ]; then
		# User want to set group
		yesno "Do you want to encrypt $path for $target_groups?" || die

		# Save groups and add to git
		cat <<< $(jq ".$path = (\"$target_groups\"|split(\" \"))" $lastgroupfile) > $lastgroupfile
		set_git $lastgroupfile
		git -C "$INNER_GIT_DIR" add "$lastgroupfile"
	else
		# Get previous groups
		while read group; do
			target_groups+=($group)
		done < <(jq -r "try .$path[]" $lastgroupfile)
	fi

	if [ ! -n "$target_groups" ]; then
		# We have no fingerprint to encrypt for
		die "No groups were provided for $path, please define receivers with '--group=GROUP1'."
	fi

	# We have groups, fetch fingerprints to PASSWORD_STORE_KEY
	GPG_RECIPIENT_ARGS=( )
	GPG_RECIPIENTS=( )
	for group in $target_groups; do
		while read gpg_id; do
			GPG_RECIPIENT_ARGS+=( "-r" "$gpg_id" )
			GPG_RECIPIENTS+=( "$gpg_id" )
		done < <(jq -r "try .$group[].fingerprint" $groupsfile)
	done
}

# Wrapper around pass cmd_edit() to add group option
cmd_custom_edit() {
	# Parse --group option
        local opts target_groups=()
        opts="$($GETOPT -o g: -l group: -n "$PROGRAM" -- "$@")"
        local err=$?
        eval set -- "$opts"
        while true; do case $1 in
                -g|--group) target_groups+=("${2:-1}"); shift 2 ;;
                --) shift; break ;;
        esac done
	[[ $err -ne 0 ]] && die "Please specify receivers with '--group=GROUP1'."

	cmd_edit "$@"
}

# Wrapper around pass cmd_generate() to add group option
cmd_custom_generate() {
	# Parse --group option
        local opts target_groups=()
        opts="$($GETOPT -o g: -l group: -n "$PROGRAM" -- "$@")"
        local err=$?
        eval set -- "$opts"
        while true; do case $1 in
                -g|--group) target_groups+=("${2:-1}"); shift 2 ;;
                --) shift; break ;;
        esac done
	[[ $err -ne 0 || ! -n $target_groups ]] && die "Please specify receivers with '--group=GROUP1'."

	cmd_generate "$@"
}

# Recrypt selected files and folders
cmd_recrypt() {
	# Parse --group option
	local opts target_groups=()
	opts="$($GETOPT -o g: -l group: -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-g|--group) target_groups+=("${2:-1}"); shift 2 ;;
		--) shift; break ;;
	esac done

	[[ $err -ne 0 ]] && die "Usage: $PROGRAM $GROUP_NAME recrypt [--group=GROUP1,-gGROUP1...] [paths...]"
	[[ $# -lt 1 ]] && die "If you really want to reencrypt the whole store, please add '.' as the path."
	[[ -n "$target_groups" ]] && yesno "Are you sure you want to recrypt $* for ${target_groups[*]}?"

	# Sneaky sneaky user, I see you :p
	check_sneaky_paths "$@"

	# Check paths exist
	for path in $@; do
		[[ -e $PREFIX/$path ]] || [[ -e $PREFIX/$path.gpg ]] || die "Error: $path is not in the password store."
	done

	# Recrypt all paths
	set_git "$PREFIX/"
	for path in $@; do
		# Get path to file
		filepath="$PREFIX/$path"
		if [ -f $path.gpg ]; then
			filepath="$path.gpg"
		fi

		reencrypt_path "$filepath"
		git -C "$INNER_GIT_DIR" add "$filepath" || die "Failed to add $filepath to git"
	done

	# Commit
	git_commit "Recrypt $*."
}


COMMAND="$1"

case "$1" in
	help) shift;			cmd_usage "$@" ;;
	show|ls|list|view) shift;	cmd_show "$@" ;;
	find|search) shift;		cmd_find "$@" ;;
	grep) shift;			cmd_grep "$@" ;;
	edit) shift;			cmd_custom_edit "$@" ;;
	generate) shift;		cmd_custom_generate "$@" ;;
	delete|rm|remove) shift;	cmd_delete "$@" ;;
	recrypt) shift;			cmd_recrypt "$@" ;;
	git) shift;			cmd_git "$@" ;;
	*)				cmd_show "$@" ;;
esac
exit 0
