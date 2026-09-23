# LiteSpeed Cache Management

PressGarden exposes the complete LiteSpeed Cache for WordPress WP-CLI surface through one guarded interface:

```bash
pressgarden litespeed <area> <action> [arguments] --target <site|all>
```

Use `pressgarden litespeed help` to see the supported areas and actions directly in the terminal.

Omit `--target` to use the configured fleet. Use `--target example.com` for one website. `--site` is accepted as an alias for `--target`.

The existing `pressgarden litespeed-db status|optimize [target]` command remains available for compatibility.

## Fleet status

```bash
pressgarden litespeed status --target all
```

This checks WordPress/WP-CLI bootstrap, LiteSpeed Cache installation and activation, plugin version, and availability of all eight documented LiteSpeed command families.

## Options

```bash
pressgarden litespeed option get cache-priv --target example.com
pressgarden litespeed option all --format=json --target example.com
pressgarden litespeed option set cache-priv false --target example.com
pressgarden litespeed option export --target example.com
pressgarden litespeed option export --filename=/tmp/lscache-options.txt --target example.com
pressgarden litespeed option import /path/options.txt --target example.com
pressgarden litespeed option import-remote https://example.com/options.txt --target example.com
pressgarden litespeed option reset --target example.com
```

PressGarden creates a private pre-change option export before option mutations. Fleet exports without `--filename` create separate private files per site. A single explicit `--filename` is refused for multi-site fleet execution to prevent overwriting exports.

Output that appears to contain API keys, tokens, passwords, secrets, credentials, or private/SSL keys is redacted by default. To intentionally display a sensitive `option get` value, set `PRESSGARDEN_LITESPEED_SHOW_SENSITIVE=1` for that invocation.

## Purge

```bash
pressgarden litespeed purge network-list --target example.com
pressgarden litespeed purge all --target example.com
pressgarden litespeed purge url https://example.com/page/ --target example.com
pressgarden litespeed purge blog 2 --target example.com
pressgarden litespeed purge category 1 3 5 --target example.com
pressgarden litespeed purge tag 1 3 5 --target example.com
pressgarden litespeed purge post-id 10 20 30 --target example.com
```

On WordPress multisite, LiteSpeed documents `purge all` as purging every site in the network for that WordPress installation.

## Presets

```bash
pressgarden litespeed presets backups --target example.com
pressgarden litespeed presets apply basic --target example.com
pressgarden litespeed presets restore 1667485245 --target example.com
```

PressGarden also takes its own private option backup before applying or restoring a preset.

## Image optimization

```bash
pressgarden litespeed image status --target example.com
pressgarden litespeed image push --target example.com
pressgarden litespeed image pull --target example.com
pressgarden litespeed image clean --target example.com
pressgarden litespeed image switch optm --target example.com
pressgarden litespeed image switch orig --target example.com
pressgarden litespeed image remove-backups --target example.com
```

`remove-backups` permanently removes original image backups. Interactive runs require confirmation. Non-interactive execution additionally requires:

```bash
PRESSGARDEN_INTERACTIVE=0 PRESSGARDEN_LITESPEED_DESTRUCTIVE=1 pressgarden litespeed image remove-backups --target example.com
```

## QUIC.cloud online services

```bash
pressgarden litespeed online init --target example.com
pressgarden litespeed online sync --format=json --target example.com
pressgarden litespeed online services --format=table --target example.com
pressgarden litespeed online nodes --format=table --target example.com
pressgarden litespeed online ping img_optm --force --target example.com
pressgarden litespeed online cdn-status --target example.com
```

Supported `ping` services are `img_optm`, `ccss`, `ucss`, `lqip`, and `vpi`.

To link a QUIC.cloud account, keep the API key out of shell history:

```bash
export QC_API_KEY='...'
pressgarden litespeed online link --email=you@example.com --api-key-env=QC_API_KEY --target example.com
```

To initialize QUIC.cloud CDN with Cloudflare Integration:

```bash
export CF_API_TOKEN='...'
pressgarden litespeed online cdn-init --method=cfi --cf-token-env=CF_API_TOKEN --target example.com
```

Other CDN methods are `cname` and `ns`. `--ssl-cert=PATH` and `--ssl-key=PATH` are passed through when supplied.

PressGarden deliberately rejects literal `--api-key=` and `--cf-token=` arguments so credentials are not casually stored in shell history. Command output is redacted for secret-like fields.

## Debug/support report

```bash
pressgarden litespeed debug send --target example.com
```

This sends an environment report to LiteSpeed support. Interactive execution requires confirmation. Non-interactive execution requires both:

```bash
PRESSGARDEN_INTERACTIVE=0 PRESSGARDEN_LITESPEED_EXTERNAL=1 pressgarden litespeed debug send --target example.com
```

## Crawler

```bash
pressgarden litespeed crawler list --target example.com
pressgarden litespeed crawler enable 2 --target example.com
pressgarden litespeed crawler disable 2 --target example.com
pressgarden litespeed crawler run --target example.com
pressgarden litespeed crawler reset --target example.com
```

The LiteSpeed crawler must also be permitted at the server level. PressGarden does not modify LiteSpeed Web Server/Apache server configuration to enable the crawler.

## Database

```bash
pressgarden litespeed database status --target example.com
pressgarden litespeed database clear-posts --target example.com
pressgarden litespeed database clear-comments --target example.com
pressgarden litespeed database clear-trackbacks --target example.com
pressgarden litespeed database clear-transients --target example.com
pressgarden litespeed database optimize-tables --target example.com
pressgarden litespeed database optimize-all --target example.com
```

For WordPress multisite, specify a blog ID:

```bash
pressgarden litespeed database optimize-all --blog=2 --target example.com
```

LiteSpeed documents `litespeed-database` as the exception to its normal WP-CLI behavior: these commands do not accept standard WP-CLI global parameters. PressGarden therefore changes into each WordPress installation and executes the database command without `--path`, `--skip-plugins`, `--skip-themes`, or other global parameters.

`database status` is PressGarden inventory syntax, not a LiteSpeed subcommand. It checks availability using the documented `optimize_all` command and never probes `litespeed-database status`.


## Safety model

Read-only inventory commands do not require confirmation. Mutating commands require confirmation in interactive mode. `PRESSGARDEN_INTERACTIVE=0` is treated as an explicit automation choice, except irreversible image backup removal and support-report upload, which require the additional opt-ins documented above.

Operations are executed sequentially across a fleet to limit database/server load and make per-site failures visible. Sites without active LiteSpeed Cache are skipped. WordPress bootstrap failures or missing LiteSpeed commands are reported as errors rather than successful skips.
