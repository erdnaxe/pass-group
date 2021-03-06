#!/usr/bin/env bash
# Copyright (C) 2020 Cr@ns <roots@crans.org>
# Authors : Alexandre Iooss <erdnaxe@crans.org>
#           Yohann D'anello <ynerant@crans.org>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# This pass extension add group management support for password sharing in small organisations.
# See https://git.zx2c4.com/password-store/tree/src/password-store.sh
#
# The idea is to overwrite functions from pass to make it encrypt for groups
# For long term use, it would be great to merge some feature to upstream such
# as reencrypt command and groups support.

# URL to fetch when looking for an update
UPDATE_URL="https://raw.githubusercontent.com/erdnaxe/pass-group/master/default_organisation.bash"

# Find store name based on extension name
# $extension is defined by pass before sourcing this file
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
	  $PROGRAM $GROUP_NAME [ls] [subfolder]	list files, show if unique
	  $PROGRAM $GROUP_NAME [show] [--clip[=line-number],-c[line-number]] pass-name
	  				show existing password and optionally put it on
	  				the clipboard for $CLIP_TIME seconds
	  $PROGRAM $GROUP_NAME find pass-names...	list files that match pass-names
	  $PROGRAM $GROUP_NAME grep [GREPOPTIONS] search-string
	  				search for files containing search-string
	  $PROGRAM $GROUP_NAME edit [--group=GROUP1,-gGROUP1...] pass-name
	  				edit (or create) a file using ${EDITOR:-vi}
	  $PROGRAM $GROUP_NAME generate [--group=GROUP1,-gGROUP1...] [--no-symbols,-n]
	  	[--clip,-c] [--in-place,-i | --force,-f] pass-name [pass-length]
	  				generate a new password of pass-length (or $GENERATED_LENGTH
	  				if unspecified) with optionally no symbols.
	  				Prompt before overwriting existing password
	  				unless forced. Optionally replace only the first
	  				line of an existing file with a new password.
	  $PROGRAM $GROUP_NAME rm [--recursive,-r] [--force,-f] pass-name
	  				remove existing password or directory.
	  $PROGRAM $GROUP_NAME reencrypt [--group=GROUP1,-gGROUP1...] [paths...]
	  				reencrypt selected files and folder. If set,
	  				change group.
	  $PROGRAM $GROUP_NAME git git-args...	execute a git command
	  $PROGRAM $GROUP_NAME update		check new extension update
	  $PROGRAM $GROUP_NAME help		show this text

	_EOF
}

# Overwrite set_gpg_recipients to set recipients depending on last recipients or defined target group(s)
set_gpg_recipients() {
	# Locate groups and last_group file
	# groups contains fingerprints for each group
	# last_group contains last groups used to encrypt a file
	local groupsfile="$PREFIX/.groups.json"
	local peoplefile="$PREFIX/.people.json"
	local lastgroupfile="$PREFIX/.last_group.json"
	[[ -f $groupsfile ]] || die "$groupsfile was not found, please create one."
	[[ -f $peoplefile ]] || die "$peoplefile was not found, please create one."
	[[ -f $lastgroupfile ]] || echo {} > "$lastgroupfile"

	if [[ "${target_groups[*]}" ]]; then
		# User want to set group
		yesno "Do you want to encrypt $path for ${target_groups[*]}?" < /dev/tty || die

		# Save groups and add to git
		local tmp_file
		tmp_file="$(mktemp).json"
		cat <<< $(jq ".\"$path\" = (\"${target_groups[*]}\"|split(\" \"))" "$lastgroupfile") > "$tmp_file" && mv "$tmp_file" "$lastgroupfile"
		set_git "$lastgroupfile"
		git -C "$INNER_GIT_DIR" add "$lastgroupfile"
	else
		# Get previous groups
		local target_groups
		while read -r group; do
			target_groups+=("$group")
		done < <(jq -r "try .\"$path\"[]" "$lastgroupfile")
	fi

	# Stop if we have no fingerprint to encrypt for
	[[ ${target_groups[*]} ]] || die "No groups were provided for $path, please define receivers with '--group=GROUP1'."

	# We have groups, fetch fingerprints to PASSWORD_STORE_KEY
	GPG_RECIPIENT_ARGS=( )
	GPG_RECIPIENTS=( )
	for group in "${target_groups[@]}"; do
		while read -r username; do
			gpg_id=$(jq -r "try .\"$username\"" "$peoplefile")
			# Check that gpg know recipient and policy allow to encrypt for them
			local can_encrypt=0
			$GPG --list-key "$gpg_id" > /dev/null || (yesno "Fingerprint \"$gpg_id\" for $username was not found. Maybe it is not imported. Do you want to import it?" < /dev/tty && $GPG --recv-keys "$gpg_id" || exit 1)

			while read -r sub; do
				local trust_level capabilities
				trust_level=$(echo "$sub" | cut -d ":" -f 2)
				capabilities=$(echo "$sub" | cut -d ":" -f 12)
				[[ $trust_level =~ [mfu] ]] && [[ $capabilities =~ "e" ]] && can_encrypt=1
			done < <($GPG --list-key --with-colons "$gpg_id" | grep -E "^sub|^pub")
			if [[ $can_encrypt -eq 0 ]] ; then
				echo ""
				$GPG --list-key "$gpg_id"
				echo "GPG can not encrypt for fingerprint \"$gpg_id\" of user $username. Did you trust it?"
				yesno "Do you want to ignore this fingerprint?" < /dev/tty || die "Exiting."
			else
				GPG_RECIPIENT_ARGS+=( "-r" "$gpg_id" )
				GPG_RECIPIENTS+=( "$gpg_id" )
			fi
		done < <(jq -r "try .\"$group\"[]" "$groupsfile")
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
		[[ -f $lastgroupfile ]] || echo {} > "$lastgroupfile"

		# tree -f to get full path
		# tree -P "*.gpg" to get only .gpg files
		# sed remove .gpg at end of line, but keep colors
		while read -r line; do
			# Split output
			local file=${line#*$PREFIX/}
			local treeprefix=${line%$PREFIX*}

			# Get groups
			local groups=( )
			while read -r group; do
				groups+=( "$group" )
			done < <(jq -r "try .\"$file\"[]" "$lastgroupfile")
			echo "$treeprefix$file (${groups[*]})"
		done < <(tree -C -l -f -P "*.gpg" --noreport "$PREFIX/$path" | tail -n +2 | sed -E 's/\.gpg(\x1B\[[0-9]+m)?( ->|$)/\1\2/g')
	else
		# Back to pass
		cmd_show "$@"
	fi
}

# Wrapper around pass cmd_edit() to add group option
cmd_custom_edit() {
	# Parse --group option
	local opts
	opts="$($GETOPT -o g: -l group: -n "$PROGRAM" -- "$@")"
	target_groups=()
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
	local opts passthrough_opts=()
	opts="$($GETOPT -o g:nqcif -l group:,no-symbols,qrcode,clip,in-place,force -n "$PROGRAM" -- "$@")"
	target_groups=()
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-g|--group) target_groups+=("${2:-1}"); shift 2 ;;
		--) shift; break ;;
		*) passthrough_opts+=("$1"); shift ;;
	esac done
	[[ $err -ne 0 || ! ${target_groups[*]} ]] && die "Please specify receivers with '--group=GROUP1'."

	cmd_generate "${passthrough_opts[@]}" "$@"
}

# Reencrypt selected files and folders
cmd_reencrypt() {
	# Parse --group option
	local opts
	opts="$($GETOPT -o g: -l group: -n "$PROGRAM" -- "$@")"
	target_groups=()
	local err=$?
	eval set -- "$opts"
	while true; do case $1 in
		-g|--group) target_groups+=("${2:-1}"); shift 2 ;;
		--) shift; break ;;
	esac done

	[[ $err -ne 0 ]] && die "Usage: $PROGRAM $COMMAND [--group=GROUP1,-gGROUP1...] [paths...]"
	[[ $# -lt 1 ]] && die "No file specified. If you really want to reencrypt the whole store, please add '.' as the path."

	# Sneaky sneaky user, I see you :p
	check_sneaky_paths "$@"

	# Check paths exist
	for path in "$@"; do
		[[ -e $PREFIX/$path ]] || [[ -e $PREFIX/$path.gpg ]] || die "Error: $path is not in the password store."
	done

	# Reencrypt all paths
	set_git "$PREFIX/"
	for path in "$@"; do
		# Get path to file
		filepath="$PREFIX/$path"
		if [ -f "$filepath.gpg" ]; then
			filepath="$filepath.gpg"
		fi

		reencrypt_path "$filepath"
		git -C "$INNER_GIT_DIR" add "$filepath" || die "Failed to add $filepath to git"
	done

	# Commit
	[[ "${target_groups[*]}" ]] && git_commit "Reencrypt $* for ${target_groups[*]}." || git_commit "Reencrypt $*."
}

# Check for an extension update
cmd_update() {
	echo "Looking for update..."
	local tmp_file
	tmp_file="$(mktemp).bash"
	curl "$UPDATE_URL" -o "$tmp_file"
	diff --color "$extension" "$tmp_file" && rm "$tmp_file" && echo "Already up to date." && exit 0
	yesno "New update found, do you want to update the extension?" && echo "Updating extension..." && mv "$tmp_file" "$extension" && chmod +x "$extension" && echo "Extension successfully updated" && exit 0 || rm "$tmp_file" && die "Update cancelled."
}


# Used when printing usage
COMMAND="$GROUP_NAME $1"

case "$1" in
	help|-h|--help) shift;		cmd_usage "$@" ;;
	show|ls|list|view) shift;	cmd_custom_show "$@" ;;
	find|search) shift;		cmd_find "$@" ;;
	grep) shift;			cmd_grep "$@" ;;
	edit) shift;			cmd_custom_edit "$@" ;;
	generate) shift;		cmd_custom_generate "$@" ;;
	delete|rm|remove) shift;	cmd_delete "$@" ;;
	reencrypt) shift;		cmd_reencrypt "$@" ;;
	git) shift;			cmd_git "$@" ;;
	update) shift;			cmd_update "$@" ;;
	*)				cmd_custom_show "$@" ;;
esac
exit 0
