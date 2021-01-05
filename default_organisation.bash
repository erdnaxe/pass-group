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

# Find store name based on extension name
EXTENSION_NAME=$(basename -- "$extension")
GROUP_NAME="${EXTENSION_NAME%.*}"

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
	  $PROGRAM $GROUP_NAME update			check for an extension update and download it
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
	[[ -f $lastgroupfile ]] || echo {} > $lastgroupfile

	if [ -n "$target_groups" ]; then
		# User want to set group
		yesno "Do you want to encrypt $path for $target_groups?" || die

		# Save groups and add to git
		cat <<< $(jq ".\"$path\" = (\"$target_groups\"|split(\" \"))" $lastgroupfile) > $lastgroupfile
		set_git $lastgroupfile
		git -C "$INNER_GIT_DIR" add "$lastgroupfile"
	else
		# Get previous groups
		while read group; do
			target_groups+=($group)
		done < <(jq -r "try .\"$path\"[]" $lastgroupfile)
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
			# Check that gpg know recipient and policy allow to encrypt for them
			local can_encrypt=0
			while read sub; do
				local trust_level=$(echo $sub | cut -d ":" -f 2)
				local capabilities=$(echo $sub | cut -d ":" -f 12)
				[[ $trust_level =~ [mfu] ]] && [[ $capabilities =~ "e" ]] && can_encrypt=1
			done < <($GPG --list-key --with-colons "$gpg_id" | grep -E "^sub|^pub")
			[[ $can_encrypt -eq 0 ]] && gpg --list-key "$gpg_id"
			[[ $can_encrypt -eq 0 ]] && die "GPG can not encrypt for \"$gpg_id\". Did you import and trust it?"

			GPG_RECIPIENT_ARGS+=( "-r" "$gpg_id" )
			GPG_RECIPIENTS+=( "$gpg_id" )
		done < <(jq -r "try .\"$group\"[].fingerprint" $groupsfile)
	done
}

# Wrapper around pass cmd_show() to show groups when listing
cmd_custom_show() {
	local path="$1"
	check_sneaky_paths "$path"

	if [[ -d $PREFIX/$path ]]; then
		# Custom list with groups
		if [[ -z $path ]]; then
			echo "$GROUP_NAME"
		else
			echo "${path%\/}"
		fi

		# last_group contains last groups used to encrypt a file
		local lastgroupfile="$PREFIX/.last_group.json"
		[[ -f $lastgroupfile ]] || echo {} > $lastgroupfile

		# tree -f to get full path
		# tree -P "*.gpg" to get only .gpg files
		# sed remove .gpg at end of line, but keep colors
		while read line; do
			# Split output
			local file=${line#*$PREFIX/}
			local treeprefix=${line%$PREFIX*}

			# Get groups
			local groups=( )
			while read group; do
				groups+=( "$group" )
			done < <(jq -r "try .\"$file\"[]" $lastgroupfile)
			echo "$treeprefix$file (${groups[@]})"
		done < <(tree -C -l -f -P "*.gpg" --noreport "$PREFIX/$path" | tail -n +2 | sed -E 's/\.gpg(\x1B\[[0-9]+m)?( ->|$)/\1\2/g')
	else
		# Back to pass
		cmd_show "$@"
	fi
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
	local opts passthrough_opts=() target_groups=()
	opts="$($GETOPT -o g:nqcif -l group:,no-symbols,qrcode,clip,in-place,force -n "$PROGRAM" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-g|--group) target_groups+=("${2:-1}"); shift 2 ;;
		--) shift; break ;;
		*) passthrough_opts+=($1); shift ;;
	esac done
	[[ $err -ne 0 || ! -n $target_groups ]] && die "Please specify receivers with '--group=GROUP1'."

	cmd_generate "${passthrough_opts[@]}" "$@"
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
		if [ -f $filepath.gpg ]; then
			filepath="$filepath.gpg"
		fi

		reencrypt_path "$filepath"
		git -C "$INNER_GIT_DIR" add "$filepath" || die "Failed to add $filepath to git"
	done

	# Commit
	git_commit "Recrypt $* for ${target_groups[*]}."
}

# Check for an extension update
cmd_update() {
	echo "Looking for update..."
	tmp_file="/tmp/pass-group-$EXTENSION_NAME.bash"
	curl -s https://raw.githubusercontent.com/erdnaxe/pass-group/master/default_organisation.bash > $tmp_file
	diff --color $extension $tmp_file && rm $tmp_file && echo "Already up to date." && exit 0
	read -r -p "New update found, do you really want to update the extension? [y/N]" input
	case $input in
		[yY])
			echo "Updating extension..."
			mv $tmp_file $extension && echo "Extension successfully updated" && exit 0
			break ;;
		*)
			echo "Update cancelled."
			rm $tmp_file
			exit 1 ;;
	esac
}


COMMAND="$1"

case "$1" in
	help) shift;			cmd_usage "$@" ;;
	show|ls|list|view) shift;	cmd_custom_show "$@" ;;
	find|search) shift;		cmd_find "$@" ;;
	grep) shift;			cmd_grep "$@" ;;
	edit) shift;			cmd_custom_edit "$@" ;;
	generate) shift;		cmd_custom_generate "$@" ;;
	delete|rm|remove) shift;	cmd_delete "$@" ;;
	recrypt) shift;			cmd_recrypt "$@" ;;
	git) shift;			cmd_git "$@" ;;
	update) shift;			cmd_update "$@" ;;
	*)				cmd_custom_show "$@" ;;
esac
exit 0
