# Shell Scripts

A collection of shell scripts for Ubuntu systems. Run any script directly via `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/kavinjebastin/shell-scripts/main/scripts/<category>/<script>.sh | bash
```

To pin to a specific release:

```bash
curl -fsSL https://raw.githubusercontent.com/kavinjebastin/shell-scripts/v1.0.0/scripts/<category>/<script>.sh | bash
```

## Verify Checksums

```bash
SCRIPT="scripts/dev/example.sh"
curl -fsSL "https://raw.githubusercontent.com/kavinjebastin/shell-scripts/main/$SCRIPT" -o script.sh
curl -fsSL "https://raw.githubusercontent.com/kavinjebastin/shell-scripts/main/checksums/SHA256SUMS" | grep "$SCRIPT" | sha256sum -c -
bash script.sh
```

## Structure

```
scripts/
├── dev/        # Developer tooling
├── system/     # System configuration
└── docker/     # Container tooling
lib/
└── common.sh   # Shared utilities (colors, logging, OS detection, dependency management)
```

## Adding a Script

1. Create your script in the appropriate `scripts/<category>/` directory
2. Source `lib/common.sh` using the pattern below
3. Use `require_ubuntu`, `require_cmd`, `require_root` as needed
4. Ensure idempotency — safe to run multiple times
5. Run `shellcheck` locally before committing
6. Run `./generate-checksums.sh` to update checksums before tagging a release

### Script Template

```bash
#!/usr/bin/env bash
set -euo pipefail

COMMON_URL="https://raw.githubusercontent.com/kavinjebastin/shell-scripts/main/lib/common.sh"
LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"
if [[ -f "$LIB_PATH" ]]; then
    source "$LIB_PATH"
else
    eval "$(curl -fsSL "$COMMON_URL")"
fi

require_ubuntu

# your logic here
```
