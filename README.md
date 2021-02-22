# pass-group: Group Password Store

This is an extension for [pass](https://www.passwordstore.org/) that add group
password management.

By default in `pass`, users must make subfolders containing `.gpg-id` to group
passwords and encrypt for others.
This system has many shortcoming when using `pass` in organisations.

This extension maps groups to GPG fingerprints inside a JSON file and then
enable the user to choose which group to encrypt for when editing a file.

## Set up

*This set up show how to install this extension for an organisation named
"crans".*

### Extension installation

Firstly, make sure that you have a working computer with `pass` installed on
it. It is packaged in many major Linux distributions.
You also need to have `jq` installed.

Then you can download and rename
[default_organisation.bash](./default_organisation.bash)
to `~/.password-store/.extensions/crans.bash`. Make sure the file is executable
with `chmod +x ~/.password-store/.extensions/crans.bash`.
To activate this extension, you need to export
`PASSWORD_STORE_ENABLE_EXTENSIONS=true` in your shell configuration.

### Password store set up

You should now clone your organisation Git repository containing the password
store. For example, in my organisation:

```bash
git clone git@gitlab.crans.org:nounous/password-store.git ~/.password-store/crans
```

If you do not have yet such repository yet, you can create a empty one
containing **.groups.json**, see example to create one:
[.groups.json.example](./.groups.json.example).

If you care about receiving notifications each time passwords are created or
updated, you should subscribe via your web Git management system.
On GitLab you can set the bell on "Watch" for example.

## Usage

*Please remplace "crans" with the name of your organisation in the following.*

To use the group password store, you may use `pass crans COMMAND`.

```bash
# To print help
pass crans help

# To update local password store
pass crans git pull

# To create a new random password named `test` of length 32
pass crans generate --group=nounou test 32

# To reencrypt a file keeping the same groups
pass crans reencrypt test

# To change group
pass crans reencrypt --group=nounou --group=cableur test

# Push new modification
pass crans git push
```

## Update

The extension can be auto-updated. You may use `pass crans update` to
check if an update is available, then if you accept the update the extension
will be replaced.
