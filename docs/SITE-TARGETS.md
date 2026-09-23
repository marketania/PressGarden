# Website names instead of hosting paths

```bash
./pressgarden status example.com
./pressgarden full example.com
./pressgarden incident example.com
./pressgarden lock example.com
./pressgarden unlock example.com
./pressgarden lock-status example.com
./pressgarden inspect js example.com
./pressgarden inspect runtime example.com --details
./pressgarden baseline status example.com
./pressgarden changes example.com
./pressgarden sites
```

Every existing site-targeting command uses the same resolver. No target, or `all`, uses the normal configured/portable fleet root. Program updates, intelligence updates, config advice and quarantine case IDs are not website-specific operations.

A name resolves to a **local directory**, not a remote scan. Existing recursion, discovery depth/pruning, exclusions and per-check scope remain. A parent directory includes discovered nested installations; `example.com/shop` targets that nested installation's directory. Named lock/unlock displays the count of selected installations before approval. The confirmation default remains no. Account-level checks within a suite remain account-level; a website argument does not turn host cron/SSH checks into site-only checks.

## Resolution and safety

Name lookup first runs fresh structural discovery beneath the configured/default scan root. It recognizes domain folders in common layouts, including `example.com/public_html`, `example.com/httpdocs`, `example.com/htdocs` and `/var/www/example.com`. Plain domain names are lowercased; nested path case is retained. HTTP(S) URLs and trailing slashes may be pasted, but query strings, credentials, ports and traversal segments are rejected. `www.example.com` is not silently treated as `example.com`.

For otherwise unnamed directories, bounded static token reading can recognize plain literal `WP_HOME` or `WP_SITEURL` definitions in that root's `wp-config.php`. It does not execute includes/expressions, load WordPress, invoke WP-CLI, query a database or contact DNS/the website. These names identify local installations; they do not verify the domain's ownership or effective runtime URL. Dynamic definitions, parent-directory configs, IDNs not supplied as punycode, and sites with URLs only in the database can require an explicit alias.

Unknown names, duplicate names, exclusions, malformed alias files and failed discovery refuse selection with exit 2. There is no fuzzy match, first-match selection or fallback from an unknown website to the fleet. An existing relative folder named `example.com` is still treated as a website name; use `./example.com` to explicitly select it as a filesystem directory. Ordinary absolute/relative paths remain supported. The name resolver requires PHP CLI; path-only scanner workflows retain their previous dependency requirements.

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

## Compact PHP environment output

The optional provider comparison shows the most common reported PHP version, consistency/coverage counts, and up to four expanded differences per affected site (expanded detail is limited to the first 20 sites). Additional affected sites retain short review entries. Full option values, per-site groups, provider defaults/ranges and customizations are saved to the private findings/detail report, not discarded. Missing option fields are incomplete reporting, not an assertion that those values match.

The common profile is a statistical reference, not a security policy. Shared customizations are informational. Numeric values and numeric strings compare consistently, empty values stay explicit, boolean spellings are normalized on recognized boolean directives, and only the OPCache megabyte directives normalize `128` with `128M`. Expected `/opt/alt/phpXX/` path differences that precisely track a changed PHP version are grouped with that version difference; additional paths still require review.

Use `inspect runtime example.com --details` or `PRESSGARDEN_PHP_DETAILS=1` for full console values. Runtime inspection includes the existing local CLI/override checks, optional php.net version lookup and optional Hostinger data; it does not refresh vulnerability feeds, bootstrap WordPress or perform remediation. Its per-site API data only covers returned fields, and CLI settings need not equal the site's web/FPM settings. Local/WAF checks and their verdicts are unchanged. Failed provider summary generation returns incomplete; failed detail writes retain the existing report-failure safeguards.
