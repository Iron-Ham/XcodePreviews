#!/bin/bash
#
# Test suite for preview-build shell scripts
# Validates bug fixes and expected behaviors without requiring Xcode/simulator
#
# Usage: ./tests/test-scripts.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
ERRORS=""

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: $1"
    echo "  FAIL: $1"
}

section() {
    echo ""
    echo "=== $1 ==="
}

#=============================================================================
# Test: sim-manager.sh defines SCRIPT_DIR (fixes #7)
#=============================================================================
section "sim-manager.sh SCRIPT_DIR definition"

if grep -q 'SCRIPT_DIR=' "$PROJECT_DIR/scripts/sim-manager.sh"; then
    pass "SCRIPT_DIR is defined in sim-manager.sh"
else
    fail "SCRIPT_DIR is NOT defined in sim-manager.sh"
fi

# Verify it uses the standard pattern
if grep -q 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE\[0\]}")" && pwd)"' "$PROJECT_DIR/scripts/sim-manager.sh"; then
    pass "SCRIPT_DIR uses the standard BASH_SOURCE pattern"
else
    fail "SCRIPT_DIR does not use the standard BASH_SOURCE pattern"
fi

#=============================================================================
# Test: preview script forwards --workspace flag (fixes #9)
#=============================================================================
section "preview script --workspace forwarding"

# The exec call for preview-tool preview should include WORKSPACE
# Specifically check the preview-tool exec block (near --project "$PROJECT")
if grep -A5 'PREVIEW_TOOL.*preview' "$PROJECT_DIR/scripts/preview" | grep -q 'WORKSPACE.*--workspace'; then
    pass "preview script forwards --workspace to preview-tool"
else
    fail "preview script does NOT forward --workspace to preview-tool"
fi

#=============================================================================
# Test: preview-module.sh verbose flag logic (fixes #10)
#=============================================================================
section "preview-module.sh verbose flag"

# Should NOT use ${VERBOSE:+-quiet} pattern (the inverted logic)
INVERTED_COUNT=$(grep -c '${VERBOSE:+-quiet}' "$PROJECT_DIR/scripts/preview-module.sh" || true)
if [[ "$INVERTED_COUNT" -eq 0 ]]; then
    pass "No inverted \${VERBOSE:+-quiet} pattern found"
else
    fail "Found $INVERTED_COUNT instances of inverted \${VERBOSE:+-quiet} pattern"
fi

# Verify it uses explicit comparison instead
if grep -q 'VERBOSE.*!=.*true.*&&.*-quiet\|VERBOSE.*!=.*true.*then' "$PROJECT_DIR/scripts/preview-module.sh"; then
    pass "Uses explicit VERBOSE comparison for -quiet flag"
else
    fail "Does not use explicit VERBOSE comparison for -quiet flag"
fi

#=============================================================================
# Test: pipefail is set in scripts (fixes #11)
#=============================================================================
section "pipefail in scripts"

for script in preview preview-build.sh preview-module.sh; do
    if grep -q 'pipefail' "$PROJECT_DIR/scripts/$script"; then
        pass "$script has pipefail set"
    else
        fail "$script does NOT have pipefail set"
    fi
done

#=============================================================================
# Test: preview-module.sh has PIPESTATUS check for SPM build (fixes #11)
#=============================================================================
section "preview-module.sh PIPESTATUS checks"

# Count PIPESTATUS checks - should be at least 3 (SPM + dependency build + preview host)
PIPESTATUS_COUNT=$(grep -c 'PIPESTATUS\[0\]' "$PROJECT_DIR/scripts/preview-module.sh" || true)
if [[ "$PIPESTATUS_COUNT" -ge 3 ]]; then
    pass "preview-module.sh has $PIPESTATUS_COUNT PIPESTATUS checks (expected >= 3)"
else
    fail "preview-module.sh has only $PIPESTATUS_COUNT PIPESTATUS checks (expected >= 3)"
fi

#=============================================================================
# Test: xcode-preview.sh auto-detection uses find, not -f glob (fixes #12)
#=============================================================================
section "xcode-preview.sh auto-detection"

# Should NOT use [[ -f "*.xcworkspace" ]] pattern
if grep -q '\[\[ -f "\*\.xc' "$PROJECT_DIR/scripts/xcode-preview.sh"; then
    fail "xcode-preview.sh still uses broken [[ -f \"*.xc...\" ]] pattern"
else
    pass "xcode-preview.sh does not use broken glob-in-test pattern"
fi

# Should use find or similar for detection
if grep -q 'find.*xcworkspace\|find.*xcodeproj' "$PROJECT_DIR/scripts/xcode-preview.sh"; then
    pass "xcode-preview.sh uses find for auto-detection"
else
    fail "xcode-preview.sh does not use find for auto-detection"
fi

#=============================================================================
# Test: preview-build.sh strips @main from source files (fixes #13)
#=============================================================================
section "preview-build.sh @main stripping"

# The copy to TargetView.swift should use sed to strip @main
if grep -q "sed.*@main.*TargetView" "$PROJECT_DIR/scripts/preview-build.sh"; then
    pass "preview-build.sh strips @main when creating TargetView.swift"
else
    fail "preview-build.sh does NOT strip @main when creating TargetView.swift"
fi

# Verify no dead code (duplicate PreviewHostApp.swift creation)
HOST_APP_COUNT=$(grep -c 'PreviewHostApp.swift' "$PROJECT_DIR/scripts/preview-build.sh" || true)
if [[ "$HOST_APP_COUNT" -le 3 ]]; then
    pass "No duplicate PreviewHostApp.swift creation (count: $HOST_APP_COUNT)"
else
    fail "Possible duplicate PreviewHostApp.swift creation (count: $HOST_APP_COUNT)"
fi

#=============================================================================
# Test: ProjectInjector.swift initializes packageProductDependencies (fixes #8)
#=============================================================================
section "ProjectInjector.swift packageProductDependencies initialization"

if grep -q 'packageProductDependencies.*=.*packageProductDependencies.*??.*\[\]' \
    "$PROJECT_DIR/tools/preview-tool/Sources/ProjectInjector.swift"; then
    pass "packageProductDependencies is nil-coalesced to empty array before use"
else
    fail "packageProductDependencies is NOT initialized before use"
fi

#=============================================================================
# Test: All scripts define SCRIPT_DIR consistently
#=============================================================================
section "Consistent SCRIPT_DIR definitions"

for script in preview preview-build.sh preview-minimal.sh preview-module.sh \
              capture-simulator.sh sim-manager.sh xcode-preview.sh; do
    SCRIPT_PATH="$PROJECT_DIR/scripts/$script"
    if [[ -f "$SCRIPT_PATH" ]]; then
        if grep -q 'SCRIPT_DIR=' "$SCRIPT_PATH"; then
            pass "$script defines SCRIPT_DIR"
        else
            # Not all scripts need SCRIPT_DIR, only flag if they reference it
            if grep -q '$SCRIPT_DIR\|${SCRIPT_DIR}' "$SCRIPT_PATH"; then
                fail "$script references SCRIPT_DIR but does not define it"
            else
                pass "$script does not need SCRIPT_DIR (no references)"
            fi
        fi
    fi
done

#=============================================================================
# Summary
#=============================================================================
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failures:"
    echo -e "$ERRORS"
    echo "================================"
    exit 1
else
    echo "================================"
fi
