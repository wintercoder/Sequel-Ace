# Importing connections from JSON

In the connection window, use the favorites menu's **Import Favorites…** action,
choose the file option if prompted about a clipboard connection string, and select
an `.json` file. Existing plist imports remain supported.

The file can contain an array of connections, one connection object, or an object
with a `Connections` array. Connection field names are case-insensitive.

```json
[
  {
    "Name": "Local development",
    "level1": "fo",
    "level2": "uat",
    "Host": "127.0.0.1",
    "Port": 3306,
    "User": "dev",
    "Password": "example-password",
    "Database": "app"
  },
  {
    "Name": "Reporting",
    "Host": "db.example.com",
    "User": "reporter",
    "Password": "another-example-password"
  }
]
```

`Name`, `Host`, and `User` are required nonempty strings. `Name` becomes the saved
connection's display name. `Port` accepts an integer or integer string from 1 to
65535 and defaults to 3306. `Database` and `Password` are optional strings.
This format creates standard TCP/IP MySQL/MariaDB connections.

Optional string fields `level1` through `level5` select up to five folder levels. For example,
`"level1": "fo", "level2": "uat"` places the connection inside `fo/uat`.
Existing folders at that path are reused; missing folders are created. With only
`level1`, the connection is placed in that top-level folder. Without any folder fields,
new connections go in the root. Levels must be consecutive: `level3` requires
nonempty `level1` and `level2`, and the same rule applies through `level5`. Blank
whitespace-only folder names, non-string values, gaps, and levels above five are
rejected. For example, `level1=staging`, `level2=id`, `level3=finance`,
`level4=archive`, `level5=2026` places the connection in
`staging/id/finance/archive/2026`.
When updating a duplicate, a supplied folder path moves it into that folder;
omitting the folder fields keeps its existing location.

The whole file is validated before importing. Validation errors identify the
record's position without displaying its values. Password text is preserved
exactly, including whitespace and Unicode. Accepted passwords are saved through
the application's macOS Keychain store, outside the favorites plist. The original
JSON file is not modified. If Keychain storage is disabled in preferences, imported
passwords are not saved, consistent with other saved connections.

Existing duplicate handling offers Update, Create New, or Skip. Update retains
the existing favorite's name and identity; its password is replaced only when
`Password` is provided. An empty string explicitly sets an empty password.
Cancelling or skipping does not save that connection's imported password.

To distribute a standalone build, build the macOS app using Xcode and package the
resulting `.app` in a DMG. This change does not create a DMG or alter signing,
notarization, or release automation.

## Exporting JSON with plaintext passwords

Select connections or folders and choose **Export…**. In the format chooser,
select **JSON With Plaintext Passwords**, then save the `.json` file. The default
**Plist Without Passwords** choice keeps the original password-free plist export.

JSON export reads saved database passwords from macOS Keychain only after the
save panel is accepted. A missing or inaccessible password is omitted; an actual
empty password is exported as `"Password": ""`. Unsaved password edits in the
connection form are not exported. Export does not change saved connections or
Keychain entries.

Exported JSON uses the same `Name`, `Host`, `Port`, `User`, `Password`, `Database`,
`level1` through `level5` fields as import. Standard TCP/IP options such as SSL and
time zone settings are retained in an optional `Options` object, which the JSON
importer also accepts. SSL certificate/key paths reference local files; their
contents are not embedded. A selected connection keeps its ancestor folder path.
Selecting both a folder and its descendants exports each connection once.

JSON export currently supports standard TCP/IP connections and at most five
folder levels. Other connection types (SSH, socket, AWS IAM, Vault) or deeper
folders cause an error before writing, so no partial export is produced. Use the
existing plist export to preserve those configurations without passwords.
