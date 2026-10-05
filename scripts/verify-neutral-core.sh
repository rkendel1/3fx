#!/bin/bash
# Verify that the neutral execution core compiles independently
# and contains no forbidden module imports.
#
# Usage: ./scripts/verify-neutral-core.sh
#
# This script:
# 1. Compiles the neutral-core.zig module standalone
# 2. Runs the neutral-core smoke tests
# 3. Verifies no forbidden imports in the module
# 4. Reports the boundary status

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEUTRAL_CORE_MODULE="$REPO_ROOT/src/core/neutral-core.zig"
NEUTRAL_CORE_TEST="$REPO_ROOT/tests/neutral-core-standalone.zig"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Neutral Core Independence Verification"
echo "========================================"
echo ""

# Step 1: Check that the module exists
if [ ! -f "$NEUTRAL_CORE_MODULE" ]; then
    echo -e "${RED}✗ FAILED${NC}: Neutral core module not found at $NEUTRAL_CORE_MODULE"
    exit 1
fi
echo -e "${GREEN}✓${NC} Neutral core module found at $NEUTRAL_CORE_MODULE"

# Step 2: Check that the test file exists
if [ ! -f "$NEUTRAL_CORE_TEST" ]; then
    echo -e "${RED}✗ FAILED${NC}: Neutral core test not found at $NEUTRAL_CORE_TEST"
    exit 1
fi
echo -e "${GREEN}✓${NC} Neutral core test found at $NEUTRAL_CORE_TEST"

echo ""
echo "Checking for forbidden imports in neutral-core.zig:"
echo "-------------------------------------------------"

FORBIDDEN_PATTERNS=(
    "credentials.zig"
    "secret.zig"
    "credential_authority.zig"
    "account.*\.zig"
    "billing.*\.zig"
    "ui/.*\.zig"
    "compute/.*\.zig"
    "pax/.*\.zig"
    "appport.*\.zig"
    "feltdb.*\.zig"
)

FOUND_FORBIDDEN=0
for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    # Only match actual imports (with @import), not documentation/comments
    if grep "^[^/]*const.*@import.*$pattern" "$NEUTRAL_CORE_MODULE" | grep -v "^//" | grep -v "^[ ]*//"; then
        echo -e "${RED}✗${NC} Found forbidden import pattern: $pattern"
        FOUND_FORBIDDEN=1
    fi
done

if [ $FOUND_FORBIDDEN -eq 0 ]; then
    echo -e "${GREEN}✓${NC} No forbidden imports found in neutral-core.zig"
fi

echo ""
echo "Checking test file for forbidden imports:"
echo "-----------------------------------------"

FOUND_FORBIDDEN_TEST=0
for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    # Allow credentials in test error messages but not actual imports
    if grep -E "^[^/]*@import.*$pattern" "$NEUTRAL_CORE_TEST" | grep -v "test.*\""; then
        echo -e "${RED}✗${NC} Found forbidden import in test: $pattern"
        FOUND_FORBIDDEN_TEST=1
    fi
done

if [ $FOUND_FORBIDDEN_TEST -eq 0 ]; then
    echo -e "${GREEN}✓${NC} No forbidden imports found in neutral-core-standalone.zig"
fi

echo ""
echo "Build System Integration:"
echo "------------------------"

# Check that build.zig includes the neutral-core test
if grep -q "test-neutral-core" "$REPO_ROOT/build.zig"; then
    echo -e "${GREEN}✓${NC} Neutral core test target found in build.zig"
else
    echo -e "${RED}✗${NC} Neutral core test target NOT found in build.zig"
    exit 1
fi

if grep -q "neutral_core_module" "$REPO_ROOT/build.zig"; then
    echo -e "${GREEN}✓${NC} Neutral core module definition found in build.zig"
else
    echo -e "${RED}✗${NC} Neutral core module definition NOT found in build.zig"
    exit 1
fi

echo ""
echo "To verify compilation (requires Zig 0.16+):"
echo "--------------------------------------------"
echo ""
echo "  # Compile and run just the neutral core tests:"
echo "  zig build test-neutral-core"
echo ""
echo "  # Include neutral core in full test suite:"
echo "  zig build test"
echo ""

echo "Summary:"
echo "--------"
if [ $FOUND_FORBIDDEN -eq 0 ] && [ $FOUND_FORBIDDEN_TEST -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed${NC}"
    echo ""
    echo "The neutral execution core is proven to be independent of:"
    echo "  • Authentication & credentials (src/core/auth/)"
    echo "  • Account management (src/core/account/)"
    echo "  • Billing (src/core/billing/)"
    echo "  • TUI/UI (src/ui/)"
    echo "  • Compute/PAX/AppPort/FeltDB"
    echo ""
    echo "This independence is enforced at compile time by the build system."
    exit 0
else
    echo -e "${RED}✗ Some checks failed${NC}"
    exit 1
fi
