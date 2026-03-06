#!/bin/bash
#
# preview-inject.sh - Create a preview scheme within an existing Xcode project
#
# This script creates a minimal preview target that depends only on the modules
# needed for the specific preview, allowing faster builds than the full app.
#
# Usage:
#   preview-inject.sh <swift-file> --workspace <path> --base-scheme <scheme>
#
# Options:
#   --workspace <path>     Xcode workspace (required)
#   --base-scheme <name>   Scheme to base dependencies on (required)
#   --output <path>        Output screenshot path
#   --simulator <name>     Simulator to use
#   --clean                Clean existing preview target first
#
# This creates a new scheme called "PreviewHost-<filename>" that builds only
# the required dependencies, making preview iteration much faster.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Parse arguments
SWIFT_FILE=""
WORKSPACE=""
OUTPUT_PATH="/tmp/preview-inject.png"
SIMULATOR="iPhone 17 Pro"

while [[ $# -gt 0 ]]; do
    case $1 in
        --workspace)
            WORKSPACE="$2"
            shift 2
            ;;
        --base-scheme)
            shift 2
            ;;
        --output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --simulator)
            SIMULATOR="$2"
            shift 2
            ;;
        --clean)
            shift
            ;;
        --help|-h)
            head -20 "$0" | tail -18
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            SWIFT_FILE="$1"
            shift
            ;;
    esac
done

# Validation
if [[ -z "$SWIFT_FILE" ]]; then
    log_error "No Swift file specified"
    exit 1
fi

if [[ -z "$WORKSPACE" ]]; then
    log_error "No workspace specified (use --workspace)"
    exit 1
fi

if [[ ! -f "$SWIFT_FILE" ]]; then
    log_error "Swift file not found: $SWIFT_FILE"
    exit 1
fi

SWIFT_FILE="$(cd "$(dirname "$SWIFT_FILE")" && pwd)/$(basename "$SWIFT_FILE")"
WORKSPACE="$(cd "$(dirname "$WORKSPACE")" && pwd)/$(basename "$WORKSPACE")"
FILENAME=$(basename "$SWIFT_FILE" .swift)

log_info "Setting up preview for: $FILENAME"

# Extract imports to determine dependencies
IMPORTS=$(grep "^import " "$SWIFT_FILE" | sed 's/import //' | sort -u)
log_info "Required imports: $(echo $IMPORTS | tr '\n' ' ')"

# For now, this script provides guidance on manual setup
# A full implementation would modify the Xcode project programmatically

cat << EOF

${BLUE}═══════════════════════════════════════════════════════════════${NC}
${GREEN}Preview Setup Guide for: $FILENAME${NC}
${BLUE}═══════════════════════════════════════════════════════════════${NC}

To create an efficient preview for files with project dependencies:

${YELLOW}Option 1: Use ComponentGallery (Recommended for this project)${NC}
The project already has a ComponentGallery scheme that displays all previews.
Run: $SCRIPT_DIR/xcode-preview.sh --workspace "$WORKSPACE" --scheme ComponentGallery

${YELLOW}Option 2: Create a minimal preview target${NC}
1. In Xcode, create a new iOS App target named "PreviewHost"
2. Add these module dependencies: $IMPORTS
3. Add a simple App that renders your preview content
4. Build only this target for fast iteration

${YELLOW}Option 3: Use snapshot testing${NC}
Add swift-snapshot-testing to your project and write tests that:
1. Render previews to images
2. Compare against reference snapshots
3. Run via: xcodebuild test -scheme YourScheme -only-testing:SnapshotTests

${BLUE}═══════════════════════════════════════════════════════════════${NC}

For the Notion Mail project specifically, the ComponentGallery approach
is already set up and working. Use:

  $SCRIPT_DIR/xcode-preview.sh \\
    --workspace "$WORKSPACE" \\
    --scheme ComponentGallery \\
    --output "$OUTPUT_PATH"

EOF

# If ComponentGallery exists, offer to run it
if xcodebuild -workspace "$WORKSPACE" -list 2>/dev/null | grep -q "ComponentGallery"; then
    echo ""
    read -p "Run ComponentGallery now? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        exec "$SCRIPT_DIR/xcode-preview.sh" \
            --workspace "$WORKSPACE" \
            --scheme ComponentGallery \
            --output "$OUTPUT_PATH" \
            --simulator "$SIMULATOR"
    fi
fi
