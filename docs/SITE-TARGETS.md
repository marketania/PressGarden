# Website names instead of hosting paths

Examples for PressGarden's own responsibilities:

```bash
./pressgarden status example.com
./pressgarden db status example.com
./pressgarden db check example.com
./pressgarden cache status example.com
./pressgarden cleanup preview example.com
./pressgarden litespeed status example.com
./pressgarden litespeed-db status example.com
./pressgarden sites
```

A website argument resolves to a **local directory**, not a remote connection. No target, or explicit `all`, uses the configured/default fleet root. A parent target includes discovered nested installations; `example.com/shop` selects that nested directory. Existing discovery limits and exclusions remain in force. Explicit empty, unknown, excluded, ambiguous or invalid targets never fall back to the fleet.

Program updates and configuration advice are not website-targeted operations. Use `sites` to inspect the discovered names and directories before choosing a target.

The examples above are inspections/previews. Native repair/optimization, cleanup execution and cache/LiteSpeed mutations must be invoked separately. Their preflights, confirmations, backup requirements and partial-result reporting still apply after target selection.

## Resolution and safety

Name lookup first runs fresh structural discovery beneath the configured/default scan root. It recognizes domain folders in common layouts, including `example.com/public_html`, `example.com/httpdocs`, `example.com/htdocs` and `/var/www/example.com`. Plain domain names are lowercased; nested path case is retained. HTTP(S) URLs and trailing slashes may be pasted, but query strings, credentials, ports and traversal segments are rejected. `www.example.com` is not silently treated as `example.com`.

For otherwise unnamed directories, bounded static token reading can recognize plain literal `WP_HOME` or `WP_SITEURL` definitions in that root's `wp-config.php`. It does not execute includes/expressions, load WordPress, invoke WP-CLI, query a database or contact DNS/the website. These names identify local installations; they do not verify the domain's ownership or effective runtime URL. Dynamic definitions, parent-directory configs, IDNs not supplied as punycode, and sites with URLs only in the database can require an explicit alias.

Unknown names, duplicate names, exclusions, malformed alias files and failed discovery refuse selection with exit 2. There is no fuzzy match, first-match selection or fallback from an unknown website to the fleet. An existing relative folder named `example.com` is still treated as a website name; use `./example.com` to explicitly select it as a filesystem directory. Ordinary absolute/relative paths remain supported. The name resolver requires PHP CLI. Individual operations have their own additional dependencies; resolving a name is not an operation preflight.

`sites` prints names with local directories and marks ambiguous names. It never changes configuration or site contents. A narrowed name preserves discovered exclusions originally expressed relative to the fleet, so excluding `example.com/shop` is not lost when selecting `example.com`.

## Unnamed/custom hosting layouts

Most domain-folder installations need no mapping. For an opaque folder, create a private text file, for example `config/sites`, containing:

```text
example.com=/home/account/public_html
client.example=/var/www/client-project
```

Set its absolute path in private `config/config`:

```bash
PRESSGARDEN_SITE_ALIASES_FILE="/home/account/PressGarden/config/sites"
```

Values are data, not shell commands. The alias must point to an already discovered, non-excluded WordPress installation inside the configured scan root; it cannot broaden scope or bypass exclusions. Multiple aliases can point to one installation, but one alias resolving to multiple installations is refused. The file is limited to 256 KiB and must be a regular non-symlink file. Keep it private and outside served directories. Updating program code preserves private configuration and this untracked mapping file.

## Maintenance and provider scope

Use `--target SITE` with advanced LiteSpeed commands when positional arguments belong to the provider. For example, `./pressgarden litespeed option get cache --target example.com` treats `cache` as an option key, not as a website. Native database operations use `db status|check|repair|optimize|cleanup`; there is no combined security or full-maintenance suite.

`litespeed-db status` measures optimizer counters. `litespeed database status` checks command availability. These are different read-only checks; see [LiteSpeed database maintenance](LITESPEED-DATABASE.md). Native database blog/table selection and LiteSpeed network-wide scope are also distinct; review the [README](../README.md#database-operations) before writes.

PHP/security configuration belongs to PressHarden; malware and incident investigation belong to PressWarden. See the [migration mapping](MIGRATION.md). PressGarden does not need either sibling installed.
