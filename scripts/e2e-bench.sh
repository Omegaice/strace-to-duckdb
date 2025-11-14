#!/usr/bin/env bash
# End-to-end benchmark using hyperfine
# Measures actual performance on the full workload

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACE_DIR="${TRACE_DIR:-$PROJECT_ROOT/../large-trace}"
OUTPUT_DB="/tmp/claude/e2e-bench.db"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if trace directory exists
if [ ! -d "$TRACE_DIR" ]; then
    echo -e "${RED}Error: Trace directory not found: $TRACE_DIR${NC}"
    echo "Set TRACE_DIR environment variable to point to your trace files"
    echo "Example: TRACE_DIR=/path/to/traces $0"
    exit 1
fi

# Count trace files
TRACE_COUNT=$(find "$TRACE_DIR" -type f | wc -l)
if [ "$TRACE_COUNT" -eq 0 ]; then
    echo -e "${RED}Error: No trace files found in $TRACE_DIR${NC}"
    exit 1
fi

echo -e "${GREEN}=== End-to-End Benchmark ===${NC}"
echo "Project root: $PROJECT_ROOT"
echo "Trace directory: $TRACE_DIR"
echo "Trace files: $TRACE_COUNT"
echo "Output database: $OUTPUT_DB"
echo ""

# Build the binary in ReleaseFast mode
echo -e "${YELLOW}Building binary (ReleaseFast)...${NC}"
cd "$PROJECT_ROOT"
zig build -Doptimize=ReleaseFast

BINARY="$PROJECT_ROOT/zig-out/bin/strace-to-duckdb"

if [ ! -x "$BINARY" ]; then
    echo -e "${RED}Error: Binary not found at $BINARY${NC}"
    exit 1
fi

echo -e "${GREEN}Binary built successfully${NC}"
echo ""

# Prepare output directory
mkdir -p /tmp/claude

# Run hyperfine
echo -e "${YELLOW}Running hyperfine benchmark...${NC}"
echo ""

hyperfine \
    --warmup 1 \
    --runs 3 \
    --prepare "rm -f $OUTPUT_DB" \
    "$BINARY -o $OUTPUT_DB $TRACE_DIR/*"

echo ""
echo -e "${GREEN}=== Benchmark Complete ===${NC}"
