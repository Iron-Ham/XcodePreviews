#!/bin/bash
#
# xcode-preview.sh - Build and capture preview from an Xcode project
#
# This script builds your Xcode project, runs it in a simulator, and captures
# a screenshot of the initial view. For SwiftUI apps, this captures what would
# be shown by your preview.
#
# Usage: xcode-preview.sh [options]
#
# Options:
#   --project <path>       Path to .xcodeproj file
#   --workspace <path>     Path to .xcworkspace file
#   --scheme <name>        Scheme to build (required)
#   --simulator <name>     Simulator name (default: iPhone 17 Pro)
#   --output <path>        Output screenshot path (default: /tmp/preview.png)
#   --wait <seconds>       Wait time after launch before capture (default: 3)
#   --clean                Clean build before building
#   --derived-data <path>  Custom derived data path
#   --verbose              Show build output
#
# Examples:
#   xcode-preview.sh --project MyApp.xcodeproj --scheme MyApp
#   xcode-preview.sh --workspace MyApp.xcworkspace --scheme MyApp --simulator "iPhone 15"

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
PROJECT=""
WORKSPACE=""
SCHEME=""
SIMULATOR="iPhone 17 Pro"
OUTPUT_PATH="/tmp/preview.png"
WAIT_TIME=3
CLEAN_BUILD="false"
DERIVED_DATA="/tmp/xcode-preview-derived-data"
VERBOSE="false"

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
log_verbose() { [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}[BUILD]${NC} $1" || true; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --project)
            PROJECT="$2"
            shift 2
            ;;
        --workspace)
            WORKSPACE="$2"
            shift 2
            ;;
        --scheme)
            SCHEME="$2"
            shift 2
            ;;
        --simulator)
            SIMULATOR="$2"
            shift 2
            ;;
        --output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --wait)
            WAIT_TIME="$2"
            shift 2
            ;;
        --clean)
            CLEAN_BUILD="true"
            shift
            ;;
        --derived-data)
            DERIVED_DATA="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE="true"
            shift
            ;;
        --help|-h)
            head -30 "$0" | tail -28
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validation
if [[ -z "$PROJECT" && -z "$WORKSPACE" ]]; then
    # Try to auto-detect
    FOUND_WS=$(find . -maxdepth 1 -name "*.xcworkspace" -type d 2>/dev/null | grep -v ".xcodeproj" | head -1)
    FOUND_PROJ=$(find . -maxdepth 1 -name "*.xcodeproj" -type d 2>/dev/null | head -1)
    if [[ -n "$FOUND_WS" ]]; then
        WORKSPACE="$FOUND_WS"
        log_info "Auto-detected workspace: $WORKSPACE"
    elif [[ -n "$FOUND_PROJ" ]]; then
        PROJECT="$FOUND_PROJ"
        log_info "Auto-detected project: $PROJECT"
    else
        log_error "No project or workspace specified and none found in current directory"
        exit 1
    fi
fi

if [[ -z "$SCHEME" ]]; then
    log_error "No scheme specified (use --scheme)"
    exit 1
fi

# Find simulator
find_simulator() {
    local sim_name="$1"
    "$SCRIPT_DIR/preview-helper.rb" find-simulator "$sim_name" 2>/dev/null
}

boot_simulator() {
    local udid="$1"
    local state
    state=$("$SCRIPT_DIR/preview-helper.rb" simulator-state "$udid" 2>/dev/null)

    if [[ "$state" != "Booted" ]]; then
        log_info "Booting simulator: $SIMULATOR"
        xcrun simctl boot "$udid" 2>/dev/null || true
        sleep 5
    else
        log_info "Simulator already booted"
    fi
}

# Get bundle ID from build settings
get_bundle_id() {
    local build_args=()
    if [[ -n "$WORKSPACE" ]]; then
        build_args+=("-workspace" "$WORKSPACE")
    else
        build_args+=("-project" "$PROJECT")
    fi
    build_args+=("-scheme" "$SCHEME" "-showBuildSettings")

    xcodebuild "${build_args[@]}" 2>/dev/null | \
        grep "^\s*PRODUCT_BUNDLE_IDENTIFIER = " | \
        head -1 | \
        sed 's/.*= //'
}

# Main
main() {
    log_info "Starting Xcode preview capture"

    # Find and boot simulator
    log_info "Finding simulator: $SIMULATOR"
    SIM_UDID=$(find_simulator "$SIMULATOR")
    if [[ -z "$SIM_UDID" ]]; then
        log_error "Simulator not found: $SIMULATOR"
        log_info "Available simulators:"
        xcrun simctl list devices available | grep -E "iPhone|iPad" | head -10
        exit 1
    fi
    log_verbose "Simulator UDID: $SIM_UDID"

    boot_simulator "$SIM_UDID"

    # Build
    log_info "Building project..."
    BUILD_ARGS=()
    if [[ -n "$WORKSPACE" ]]; then
        BUILD_ARGS+=("-workspace" "$WORKSPACE")
    else
        BUILD_ARGS+=("-project" "$PROJECT")
    fi
    BUILD_ARGS+=("-scheme" "$SCHEME")
    BUILD_ARGS+=("-destination" "platform=iOS Simulator,id=$SIM_UDID")
    BUILD_ARGS+=("-derivedDataPath" "$DERIVED_DATA")

    if [[ "$CLEAN_BUILD" == "true" ]]; then
        BUILD_ARGS+=("clean")
    fi
    BUILD_ARGS+=("build")

    if [[ "$VERBOSE" == "true" ]]; then
        xcodebuild "${BUILD_ARGS[@]}"
    else
        xcodebuild "${BUILD_ARGS[@]}" -quiet 2>&1 | while read -r line; do
            log_verbose "$line"
        done
    fi

    BUILD_EXIT=${PIPESTATUS[0]}
    if [[ "$BUILD_EXIT" -ne 0 ]]; then
        log_error "Build failed with exit code $BUILD_EXIT"
        exit 1
    fi
    log_success "Build completed"

    # Get bundle ID
    log_info "Finding bundle identifier..."
    BUNDLE_ID=$(get_bundle_id)
    if [[ -z "$BUNDLE_ID" ]]; then
        log_error "Could not determine bundle identifier"
        exit 1
    fi
    log_info "Bundle ID: $BUNDLE_ID"

    # Find and install the app
    APP_PATH=$(find "$DERIVED_DATA" -name "*.app" -type d | grep -v "\.dSYM" | head -1)
    if [[ -z "$APP_PATH" ]]; then
        log_error "Could not find built app"
        exit 1
    fi
    log_verbose "App path: $APP_PATH"

    log_info "Installing app..."
    xcrun simctl install "$SIM_UDID" "$APP_PATH"

    # Launch
    log_info "Launching app..."
    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"

    # Wait for render
    log_info "Waiting ${WAIT_TIME}s for app to render..."
    sleep "$WAIT_TIME"

    # Capture
    log_info "Capturing screenshot..."
    mkdir -p "$(dirname "$OUTPUT_PATH")"
    xcrun simctl io "$SIM_UDID" screenshot "$OUTPUT_PATH"

    # Terminate
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

    if [[ -f "$OUTPUT_PATH" ]]; then
        FILE_SIZE=$(ls -lh "$OUTPUT_PATH" | awk '{print $5}')
        log_success "Preview captured: $OUTPUT_PATH ($FILE_SIZE)"
        echo ""
        echo "PREVIEW_PATH=$OUTPUT_PATH"
    else
        log_error "Failed to capture preview"
        exit 1
    fi
}

main
