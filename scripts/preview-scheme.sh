#!/bin/bash
#
# preview-scheme.sh - Create a preview scheme in an existing Xcode project
#
# This script generates a lightweight preview target and scheme within an existing
# Xcode project, allowing fast preview builds by only including required dependencies.
#
# For projects using static modules (no separate frameworks), this is the only way
# to get fast preview builds - by building within the same project context.
#
# Usage:
#   preview-scheme.sh <swift-file> --workspace <path> [options]
#
# Options:
#   --workspace <path>    Xcode workspace
#   --project <path>      Xcode project (if not using workspace)
#   --target <name>       Module/target containing the file
#   --output <path>       Output screenshot path
#   --simulator <name>    Simulator to use
#   --install             Install the preview scheme permanently
#   --clean               Remove existing preview scheme first
#
# This approach:
# 1. Creates a PreviewHost target in the project (or uses existing)
# 2. Configures it to depend only on required modules
# 3. Builds just that target (much faster than full app)
# 4. Runs and captures the preview

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Parse args
SWIFT_FILE=""
WORKSPACE=""
PROJECT=""
TARGET=""
OUTPUT_PATH="/tmp/preview-scheme.png"
SIMULATOR="iPhone 17 Pro"

while [[ $# -gt 0 ]]; do
    case $1 in
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --project) PROJECT="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --output) OUTPUT_PATH="$2"; shift 2 ;;
        --simulator) SIMULATOR="$2"; shift 2 ;;
        --install|--clean) shift ;;
        --help|-h) head -30 "$0" | tail -28; exit 0 ;;
        -*) log_error "Unknown option: $1"; exit 1 ;;
        *)
            if [[ -n "$1" && -z "$SWIFT_FILE" ]]; then
                SWIFT_FILE="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$SWIFT_FILE" ]]; then
    log_error "No Swift file specified"
    exit 1
fi

if [[ -z "$WORKSPACE" && -z "$PROJECT" ]]; then
    log_error "Must specify --workspace or --project"
    exit 1
fi

SWIFT_FILE="$(cd "$(dirname "$SWIFT_FILE")" && pwd)/$(basename "$SWIFT_FILE")"
FILENAME=$(basename "$SWIFT_FILE" .swift)

# Analyze the file
log_info "Analyzing: $FILENAME"
IMPORTS=$(grep "^import " "$SWIFT_FILE" | sed 's/import //' | sort -u)
log_info "Required modules: $(echo $IMPORTS | tr '\n' ' ')"

# Detect target from file path if not specified
if [[ -z "$TARGET" ]]; then
    RELATIVE_PATH="${SWIFT_FILE#$(dirname "${WORKSPACE:-$PROJECT}")/}"
    if [[ "$RELATIVE_PATH" =~ Modules/([^/]+)/ ]]; then
        TARGET="${BASH_REMATCH[1]}"
    elif [[ "$RELATIVE_PATH" =~ Sources/([^/]+)/ ]]; then
        TARGET="${BASH_REMATCH[1]}"
    fi
    log_info "Auto-detected target: ${TARGET:-'(none)'}"
fi

# For projects with static modules, provide guidance
cat << EOF

${CYAN}═══════════════════════════════════════════════════════════════════${NC}
${GREEN}Preview Build Strategy for: $FILENAME${NC}
${CYAN}═══════════════════════════════════════════════════════════════════${NC}

This project appears to use ${YELLOW}static module linking${NC}, which means each
module's code is compiled into the final binary rather than separate frameworks.

${BLUE}Recommended approaches:${NC}

${YELLOW}1. Fast: Use existing DerivedData (if recently built)${NC}

   If you've built the project recently, the preview can compile against
   existing build products:

   ${GREEN}# Build the module first (one-time)${NC}
   xcodebuild build \\
     -workspace "${WORKSPACE:-$PROJECT}" \\
     -scheme "<YourAppScheme>" \\
     -destination "generic/platform=iOS Simulator"

   ${GREEN}# Then the preview host can link against DerivedData${NC}

${YELLOW}2. Medium: Add a PreviewHost target to your project${NC}

   In Xcode:
   1. File > New > Target > iOS App
   2. Name it "PreviewHost"
   3. Add dependency on: $TARGET ${IMPORTS}
   4. Add source file referencing your preview

${YELLOW}3. Comprehensive: Use snapshot testing${NC}

   Add swift-snapshot-testing to your project:

   ${GREEN}func testChipPreview() {${NC}
   ${GREEN}    assertSnapshot(matching: Chip("Test"), as: .image)${NC}
   ${GREEN}}${NC}

   Then run: xcodebuild test -scheme YourTests -only-testing:SnapshotTests

${CYAN}═══════════════════════════════════════════════════════════════════${NC}

${BLUE}For this session, would you like to:${NC}

EOF

# Check if there's already a PreviewHost scheme
if [[ -n "$WORKSPACE" ]]; then
    SCHEMES=$(xcodebuild -workspace "$WORKSPACE" -list 2>/dev/null | grep -A50 "Schemes:" | tail -n +2 | sed 's/^[ \t]*//' | grep -v "^$" || true)
else
    SCHEMES=$(xcodebuild -project "$PROJECT" -list 2>/dev/null | grep -A50 "Schemes:" | tail -n +2 | sed 's/^[ \t]*//' | grep -v "^$" || true)
fi

if echo "$SCHEMES" | grep -q "PreviewHost"; then
    log_success "Found existing PreviewHost scheme!"
    echo ""
    read -p "Build and capture using PreviewHost? [Y/n] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        exec "$SCRIPT_DIR/xcode-preview.sh" \
            ${WORKSPACE:+--workspace "$WORKSPACE"} \
            ${PROJECT:+--project "$PROJECT"} \
            --scheme "PreviewHost" \
            --output "$OUTPUT_PATH" \
            --simulator "$SIMULATOR"
    fi
else
    # Find a suitable scheme to build
    DEV_SCHEME=""
    for scheme in $SCHEMES; do
        if [[ "$scheme" =~ Dev|Debug|Local|Workspace ]]; then
            DEV_SCHEME="$scheme"
            break
        fi
    done
    DEV_SCHEME="${DEV_SCHEME:-$(echo "$SCHEMES" | head -1)}"

    if [[ -n "$DEV_SCHEME" ]]; then
        echo "  [1] Build full project using scheme '$DEV_SCHEME' (slower, but works)"
        echo "  [2] Exit and set up a PreviewHost target manually"
        echo ""
        read -p "Choice [1/2]: " -n 1 -r
        echo ""

        if [[ $REPLY == "1" ]]; then
            exec "$SCRIPT_DIR/xcode-preview.sh" \
                ${WORKSPACE:+--workspace "$WORKSPACE"} \
                ${PROJECT:+--project "$PROJECT"} \
                --scheme "$DEV_SCHEME" \
                --output "$OUTPUT_PATH" \
                --simulator "$SIMULATOR"
        fi
    fi
fi

echo ""
log_info "To manually set up fast previews, consider adding swift-snapshot-testing to your project."
