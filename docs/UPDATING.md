# PressGarden update and recovery

The program-only updater uses its own `PRESSGARDEN_REPO` (default `marketania/PressGarden`), `PRESSGARDEN_REF` (default `main`), and optional `PRESSGARDEN_UPDATE_ARCHIVE`. Local archives must have one top-level directory, the correct PRODUCT marker and a full distribution. Links, traversal, sparse/special entries, unsafe archive layout, syntax errors and product mismatches are refused before publication.

A program update lock blocks new operations during replacement. Private config, `var/`, custom state/cache/report directories and portable markers are outside the managed set. Never place private data in `checks/`, `lib/`, `docs/`, `tests/` or other managed program paths. Stop ongoing operations before updating; the lock is not a mechanism for freezing existing WordPress activity.

The updater retains a private pre-update program backup and rolls managed code back on detected replacement failures. Inspect terminal diagnostics and the retained workspace/lock before manual recovery. Do not delete a recovery lock blindly. There is no intelligence refresh in this product.

Updates from a Git working tree are refused by default; development operators use Git. The advanced `PRESSGARDEN_UPDATE_ALLOW_GIT=1` switch is for intentionally disposable test/development trees, not a substitute for Git review.

`uninstall.sh` removes managed program paths, not private configuration, cache, reports or backups. It refuses a Git working tree. Keep the remaining files until recovery and retention requirements are satisfied.
