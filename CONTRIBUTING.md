# Contributing

Make small reviewed changes on a branch. Run `bash tests/run.sh` before proposing changes. Preserve PHP 7.4 and Bash 4 compatibility. Tests must use temporary fixtures and must not mutate uncontrolled WordPress sites.

Keep PressGarden independent. Do not add sibling runtime imports, credential output, silent fleet fallback, arbitrary deletion, or fabricated verification. Changes to safety boundaries need regression tests.
