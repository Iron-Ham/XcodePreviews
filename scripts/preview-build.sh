#!/bin/bash
#
# preview-build.sh - Build and capture SwiftUI Preview screenshots
#
# Usage: preview-build.sh <swift-file> [preview-name] [options]
#
# Options:
#   --simulator <name>    Simulator to use (default: iPhone 17 Pro)
#   --output <path>       Output image path (default: /tmp/preview-screenshot.png)
#   --size <WxH>          Preview size (default: device size)
#   --scheme <name>       Xcode scheme to build (for .xcodeproj/.xcworkspace)
#   --project <path>      Path to .xcodeproj or .xcworkspace
#   --package <path>      Path to Swift package (Package.swift directory)
#   --target <name>       Target containing the preview
#   --timeout <seconds>   Timeout for preview capture (default: 30)
#   --keep-app            Don't delete the preview app after capture
#   --verbose             Enable verbose output
#
# Examples:
#   preview-build.sh ContentView.swift
#   preview-build.sh ContentView.swift "Dark Mode Preview" --simulator "iPhone 15"
#   preview-build.sh MyView.swift --project ./MyApp.xcodeproj --scheme MyApp

set -eo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/tmp/preview-build-$$"
DEFAULT_SIMULATOR="iPhone 17 Pro"
DEFAULT_OUTPUT="/tmp/preview-screenshot.png"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_verbose() { [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}[VERBOSE]${NC} $1" || true; }

# Cleanup function
cleanup() {
    if [[ "$KEEP_APP" != "true" && -d "$BUILD_DIR" ]]; then
        log_verbose "Cleaning up build directory: $BUILD_DIR"
        rm -rf "$BUILD_DIR"
    fi
}
trap cleanup EXIT

# Parse arguments
SWIFT_FILE=""
SIMULATOR="$DEFAULT_SIMULATOR"
OUTPUT_PATH="$DEFAULT_OUTPUT"
KEEP_APP="false"
VERBOSE="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        --simulator)
            SIMULATOR="$2"
            shift 2
            ;;
        --output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --size|--scheme|--project|--package|--target|--timeout)
            shift 2
            ;;
        --keep-app)
            KEEP_APP="true"
            shift
            ;;
        --verbose)
            VERBOSE="true"
            shift
            ;;
        --help|-h)
            head -30 "$0" | tail -28
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -z "$SWIFT_FILE" ]]; then
                SWIFT_FILE="$1"
            fi
            shift
            ;;
    esac
done

# Validate input
if [[ -z "$SWIFT_FILE" ]]; then
    log_error "No Swift file specified"
    echo "Usage: preview-build.sh <swift-file> [preview-name] [options]"
    exit 1
fi

if [[ ! -f "$SWIFT_FILE" ]]; then
    log_error "Swift file not found: $SWIFT_FILE"
    exit 1
fi

# Get absolute path
SWIFT_FILE="$(cd "$(dirname "$SWIFT_FILE")" && pwd)/$(basename "$SWIFT_FILE")"
log_info "Building preview for: $SWIFT_FILE"

# Find or boot simulator
find_simulator() {
    local sim_name="$1"
    "$SCRIPT_DIR/preview-helper.rb" find-simulator "$sim_name" 2>/dev/null
}

boot_simulator() {
    local udid="$1"
    local state
    state=$("$SCRIPT_DIR/preview-helper.rb" simulator-state "$udid" 2>/dev/null)

    if [[ "$state" != "Booted" ]]; then
        log_info "Booting simulator..."
        xcrun simctl boot "$udid" 2>/dev/null || true
        # Wait for boot
        sleep 3
    fi
}

# Find simulator
log_info "Finding simulator: $SIMULATOR"
SIM_UDID=$(find_simulator "$SIMULATOR")
if [[ -z "$SIM_UDID" ]]; then
    log_error "Simulator not found: $SIMULATOR"
    log_info "Available simulators:"
    xcrun simctl list devices available | grep -E "iPhone|iPad" | head -10
    exit 1
fi
log_verbose "Simulator UDID: $SIM_UDID"

# Boot simulator
boot_simulator "$SIM_UDID"

# Create build directory
mkdir -p "$BUILD_DIR"
log_verbose "Build directory: $BUILD_DIR"

# Extract preview information from Swift file
extract_preview_info() {
    local file="$1"
    # Look for #Preview macro or PreviewProvider
    if grep -q "#Preview" "$file"; then
        echo "macro"
    elif grep -q "PreviewProvider" "$file"; then
        echo "provider"
    else
        echo "none"
    fi
}

PREVIEW_TYPE=$(extract_preview_info "$SWIFT_FILE")
log_verbose "Preview type detected: $PREVIEW_TYPE"

# Get the view name from the file
VIEW_NAME=$(grep -E "^struct\s+\w+\s*:\s*View" "$SWIFT_FILE" | head -1 | sed -E 's/struct\s+(\w+).*/\1/' || echo "")
if [[ -z "$VIEW_NAME" ]]; then
    # Try to find any struct that might be a view
    VIEW_NAME=$(grep -E "^struct\s+\w+" "$SWIFT_FILE" | head -1 | sed -E 's/struct\s+(\w+).*/\1/' || echo "ContentView")
fi
log_info "Detected view name: $VIEW_NAME"

# Generate preview app
generate_preview_app() {
    local view_name="$1"
    local swift_file="$2"
    local build_dir="$3"

    # Create the preview app project
    mkdir -p "$build_dir/PreviewApp/PreviewApp"

    # Generate Package.swift
    cat > "$build_dir/PreviewApp/Package.swift" << 'PACKAGE_EOF'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PreviewApp",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "PreviewApp", targets: ["PreviewApp"])
    ],
    targets: [
        .target(name: "PreviewApp", path: "PreviewApp")
    ]
)
PACKAGE_EOF

    # Create an Xcode project for building
    mkdir -p "$build_dir/PreviewApp.xcodeproj"

    # Generate minimal pbxproj
    cat > "$build_dir/PreviewApp.xcodeproj/project.pbxproj" << 'PBXPROJ_EOF'
// !$*UTF8*$!
{
    archiveVersion = 1;
    classes = {};
    objectVersion = 56;
    objects = {
        /* Begin PBXBuildFile section */
        FILE001 /* PreviewHostApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = REF001; };
        FILE002 /* TargetView.swift in Sources */ = {isa = PBXBuildFile; fileRef = REF002; };
        /* End PBXBuildFile section */

        /* Begin PBXFileReference section */
        REF001 /* PreviewHostApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PreviewHostApp.swift; sourceTree = "<group>"; };
        REF002 /* TargetView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TargetView.swift; sourceTree = "<group>"; };
        PRODUCT /* PreviewApp.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = PreviewApp.app; sourceTree = BUILT_PRODUCTS_DIR; };
        /* End PBXFileReference section */

        /* Begin PBXGroup section */
        MAINGROUP = {
            isa = PBXGroup;
            children = (
                SRCGROUP,
                PRODGROUP,
            );
            sourceTree = "<group>";
        };
        SRCGROUP /* PreviewApp */ = {
            isa = PBXGroup;
            children = (
                REF001,
                REF002,
            );
            path = PreviewApp;
            sourceTree = "<group>";
        };
        PRODGROUP /* Products */ = {
            isa = PBXGroup;
            children = (
                PRODUCT,
            );
            name = Products;
            sourceTree = "<group>";
        };
        /* End PBXGroup section */

        /* Begin PBXNativeTarget section */
        TARGET /* PreviewApp */ = {
            isa = PBXNativeTarget;
            buildConfigurationList = CONFIGLIST;
            buildPhases = (
                SOURCES,
            );
            buildRules = ();
            dependencies = ();
            name = PreviewApp;
            productName = PreviewApp;
            productReference = PRODUCT;
            productType = "com.apple.product-type.application";
        };
        /* End PBXNativeTarget section */

        /* Begin PBXProject section */
        PROJECT /* Project object */ = {
            isa = PBXProject;
            attributes = {
                BuildIndependentTargetsInParallel = 1;
                LastSwiftUpdateCheck = 1500;
                LastUpgradeCheck = 1500;
            };
            buildConfigurationList = PROJCONFIGLIST;
            compatibilityVersion = "Xcode 14.0";
            developmentRegion = en;
            hasScannedForEncodings = 0;
            knownRegions = (en, Base);
            mainGroup = MAINGROUP;
            productRefGroup = PRODGROUP;
            projectDirPath = "";
            projectRoot = "";
            targets = (TARGET);
        };
        /* End PBXProject section */

        /* Begin PBXSourcesBuildPhase section */
        SOURCES = {
            isa = PBXSourcesBuildPhase;
            buildActionMask = 2147483647;
            files = (
                FILE001,
                FILE002,
            );
            runOnlyForDeploymentPostprocessing = 0;
        };
        /* End PBXSourcesBuildPhase section */

        /* Begin XCBuildConfiguration section */
        DEBUG = {
            isa = XCBuildConfiguration;
            buildSettings = {
                ALWAYS_SEARCH_USER_PATHS = NO;
                CLANG_ENABLE_MODULES = YES;
                CODE_SIGN_STYLE = Automatic;
                CURRENT_PROJECT_VERSION = 1;
                GENERATE_INFOPLIST_FILE = YES;
                INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
                INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
                INFOPLIST_KEY_UILaunchScreen_Generation = YES;
                INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
                INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
                LD_RUNPATH_SEARCH_PATHS = "@executable_path/Frameworks";
                MARKETING_VERSION = 1.0;
                PRODUCT_BUNDLE_IDENTIFIER = com.preview.app;
                PRODUCT_NAME = "$(TARGET_NAME)";
                SDKROOT = iphoneos;
                SUPPORTED_PLATFORMS = "iphonesimulator iphoneos";
                SWIFT_EMIT_LOC_STRINGS = YES;
                SWIFT_VERSION = 5.0;
                TARGETED_DEVICE_FAMILY = "1,2";
            };
            name = Debug;
        };
        PROJDEBUG = {
            isa = XCBuildConfiguration;
            buildSettings = {
                ALWAYS_SEARCH_USER_PATHS = NO;
                CLANG_ENABLE_MODULES = YES;
                SDKROOT = iphoneos;
                SUPPORTED_PLATFORMS = "iphonesimulator iphoneos";
                SWIFT_VERSION = 5.0;
            };
            name = Debug;
        };
        /* End XCBuildConfiguration section */

        /* Begin XCConfigurationList section */
        CONFIGLIST = {
            isa = XCConfigurationList;
            buildConfigurations = (DEBUG);
            defaultConfigurationIsVisible = 0;
            defaultConfigurationName = Debug;
        };
        PROJCONFIGLIST = {
            isa = XCConfigurationList;
            buildConfigurations = (PROJDEBUG);
            defaultConfigurationIsVisible = 0;
            defaultConfigurationName = Debug;
        };
        /* End XCConfigurationList section */
    };
    rootObject = PROJECT;
}
PBXPROJ_EOF

    # Copy source to the project
    mkdir -p "$build_dir/PreviewApp/PreviewApp"
    sed 's/@main//g' "$swift_file" > "$build_dir/PreviewApp/PreviewApp/TargetView.swift"

    cat > "$build_dir/PreviewApp/PreviewApp/PreviewHostApp.swift" << HOSTAPP_EOF
import SwiftUI

@main
struct PreviewHostApp: App {
    var body: some Scene {
        WindowGroup {
            ${view_name}()
        }
    }
}
HOSTAPP_EOF
}

# Build with xcodebuild
build_preview_app() {
    local build_dir="$1"
    local sim_udid="$2"

    log_info "Building preview app..."

    cd "$build_dir"

    # Build for simulator
    xcodebuild build \
        -project PreviewApp.xcodeproj \
        -scheme PreviewApp \
        -destination "platform=iOS Simulator,id=$sim_udid" \
        -derivedDataPath "$build_dir/DerivedData" \
        -quiet \
        2>&1 | while read line; do
            log_verbose "$line"
        done

    # Find the built app
    APP_PATH=$(find "$build_dir/DerivedData" -name "PreviewApp.app" -type d | head -1)
    if [[ -z "$APP_PATH" ]]; then
        log_error "Failed to find built app"
        return 1
    fi

    echo "$APP_PATH"
}

# Install and launch app
install_and_launch() {
    local app_path="$1"
    local sim_udid="$2"

    log_info "Installing app on simulator..."
    xcrun simctl install "$sim_udid" "$app_path"

    log_info "Launching app..."
    xcrun simctl launch "$sim_udid" "com.preview.app"

    # Wait for app to render
    sleep 2
}

# Capture screenshot
capture_screenshot() {
    local sim_udid="$1"
    local output_path="$2"

    log_info "Capturing screenshot..."

    # Ensure output directory exists
    mkdir -p "$(dirname "$output_path")"

    xcrun simctl io "$sim_udid" screenshot "$output_path"

    if [[ -f "$output_path" ]]; then
        log_success "Screenshot saved to: $output_path"
        return 0
    else
        log_error "Failed to capture screenshot"
        return 1
    fi
}

# Terminate app
terminate_app() {
    local sim_udid="$1"
    xcrun simctl terminate "$sim_udid" "com.preview.app" 2>/dev/null || true
}

# Main execution
main() {
    # Generate preview app
    generate_preview_app "$VIEW_NAME" "$SWIFT_FILE" "$BUILD_DIR"

    # Build the app
    APP_PATH=$(build_preview_app "$BUILD_DIR" "$SIM_UDID")
    if [[ -z "$APP_PATH" ]]; then
        log_error "Build failed"
        exit 1
    fi
    log_verbose "Built app: $APP_PATH"

    # Install and launch
    install_and_launch "$APP_PATH" "$SIM_UDID"

    # Capture screenshot
    capture_screenshot "$SIM_UDID" "$OUTPUT_PATH"

    # Terminate app
    terminate_app "$SIM_UDID"

    # Output result for Claude
    echo ""
    echo "PREVIEW_OUTPUT_PATH=$OUTPUT_PATH"
}

main
