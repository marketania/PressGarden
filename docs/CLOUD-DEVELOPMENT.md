# Cloud development

PressGarden can be developed in a Linux cloud checkout independently of the other
Press tools. Bash/PHP development does not require macOS. The application has no
runtime OpenAI dependency; `.codex/config.toml` supplies development defaults only.
Read [repository instructions](../AGENTS.md) and [AI development guidance](AI-DEVELOPMENT.md).

## Set up the development tools

Use a Docker-enabled Linux environment with host `curl` and `sha256sum` with access to Docker Hub, Debian package
repositories and the official WP-CLI builds on `raw.githubusercontent.com`.
No production credentials are needed. From this repository:

```bash
bash dev/run.sh setup
bash dev/run.sh versions
bash dev/run.sh test
```

`setup` installs PHP CLI with zlib/mysqli and common extensions, Bash, Python,
ShellCheck, WP-CLI, MariaDB client/dump utilities, YARA and shell utilities inside
a local development image built from official Debian.
The host operating system, application configuration and sibling checkouts are
not changed. BuildKit metadata
uses a writable temporary directory rather than requiring a writable home. The
administrator-provided Docker/proxy configuration is used without copying or
changing it; proxy build arguments are not saved in the image.

`setup` is an alias for the image build, also available as:

```bash
bash dev/run.sh build
```

The Dockerfile runs `dev/setup.sh`. The Debian base and MySQL integration
image are pinned by digest. WP-CLI is pinned to an official build commit and its
SHA-256 is checked on the host and again inside the build before execution. The
host fetches WP-CLI using its approved TLS/proxy configuration and provides it as
a temporary BuildKit artifact; certificate verification is never disabled. Debian packages receive current signed
security updates when installing; this reproduces the workflow, not an identical
package snapshot. `versions` reports the installed runtime versions; the image also records the
complete package inventory at `/usr/local/share/press-dev-packages.tsv`. Review and
update the pins when adopting newer upstream releases.

Dependency sources: [Debian PHP packages](https://packages.debian.org/trixie/php-cli),
[Debian ShellCheck](https://packages.debian.org/trixie/shellcheck),
[WP-CLI installation](https://make.wordpress.org/cli/handbook/guides/installing/) and
[download verification](https://make.wordpress.org/cli/handbook/guides/verifying-downloads/).

If package installation, image downloads, DNS or Docker access is blocked, report
the failing command and ask the environment administrator to enable the required
capability. Do not change host networking, DNS, access controls or proxy settings.
The setup commands do not bypass those restrictions.

## Local validation and editing

`test` runs the repository CI ShellCheck error diagnostics and documented
`bash tests/run.sh` suite with benign temporary fixtures and mocked external
commands. The checkout is mounted read-only, the container runs as the caller's
UID/GID, and networking is disabled. No application credentials are forwarded through environment variables, and
no host home directory or Docker socket is mounted. Keep private configuration
and client data outside the source checkout. Offline modes also clear
Docker-injected proxy environment variables. Logs are retained in the printed
host temporary directory; fixtures and generated state disappear with the
container. Optional upstream-corpus and PHP version-matrix jobs remain separate
CI checks; passing this command does not imply every CI job passed.

For an interactive Bash/PHP development session:

```bash
bash dev/run.sh shell
```

This session mounts only this checkout writable and runs without networking.
Repository edits persist in the checkout. The shell's home and runtime state are
temporary. The three tools each carry their own setup files; none imports a sibling.

## Disposable WordPress integration

With permission to run local Docker services and download WordPress/plugin
fixtures, use:

```bash
bash dev/run.sh integration
```

This runs the existing `tests/live-wp.sh` against a new MySQL 8 container and fresh
WordPress installations in temporary directories. A private Docker network is
created for the run; the test container shares the database network namespace,
so the test's fixed loopback database address cannot resolve to a host database.
No ports are published, no production site paths or database volumes are mounted,
and no existing service is reused. A fresh test-only database password is generated
for the invocation and never saved in the repository. Network access is needed for
WordPress downloads and, in PressGarden, its LiteSpeed fixture plugin. The runner
never takes an arbitrary site, database name, host, credential or command argument.
Temporary containers and the private network are removed on exit.

PressGarden's actual backup/restore drill remains restricted to its authorized
GitHub CI job. Local fixture coverage includes the mocked recovery-boundary tests;
do not spoof CI authorization variables to run the real restore drill locally.
No local CLI fixture test establishes effective hosting PHP configuration or an
actual LiteSpeed web-cache HIT.

## What a cloud checkout does not transfer

Before leaving another computer, commit and push intended source changes to a
review branch, or transfer a reviewed patch explicitly. Local uncommitted edits,
untracked/private files, editor state, SSH agents, saved browser sessions, service
credentials and running processes are not automatically part of a cloud checkout.
Bring only the nonsecret files needed for development; provision any future
credentials through an approved secret mechanism separately. Test fixtures need
no client data, SQL dumps, threat-feed keys or production configuration.

Git commits, pushes and draft pull requests are separate actions. Use an authorized
GitHub connection; do not copy tokens into source or change repository access.
This development setup does not deploy websites, schedule ongoing fleet work or
provide persistent production workers. Hosting and persistent schedulers require
separately managed infrastructure.
