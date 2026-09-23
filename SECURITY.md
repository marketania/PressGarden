# Security

Report security defects privately to the maintainer, Mustafa Sharif / Marketania, through a verified private channel. Do not post credentials, real SQL dumps, config backups or client findings in public issues.

PressGarden operates with your shell account permissions; WordPress/WP-CLI/plugin code is trusted executable input, not sandboxed. Keep state outside webroots and avoid root when a site-owned account suffices. Use isolated staging and independently tested backups for high-risk operations. Never use maintenance to erase a suspected compromise.
