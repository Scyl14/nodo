#!/bin/bash
# Same installer as ../install.sh
exec "$(cd "$(dirname "$0")/.." && pwd)/install.sh" "$@"
