# PressGarden runtime. No sibling application is required.
_PRESSGARDEN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_PRESSGARDEN_LIB_DIR/env-discovery.sh"
. "$_PRESSGARDEN_LIB_DIR/progress.sh"
. "$_PRESSGARDEN_LIB_DIR/reports.sh"
. "$_PRESSGARDEN_LIB_DIR/ui.sh"
. "$_PRESSGARDEN_LIB_DIR/wp.sh"
. "$_PRESSGARDEN_LIB_DIR/operations.sh"
unset _PRESSGARDEN_LIB_DIR
