#!/bin/bash
#
# preview-minimal.sh - Build minimal preview host for a SwiftUI view
#
# This script creates a minimal app that renders just the specified preview,
# similar to how Xcode's preview system works under the hood.
#
# Usage:
#   preview-minimal.sh <swift-file> [options]
#
# Options:
#   --preview <name>      Name of the preview to render (default: first found)
#   --workspace <path>    Xcode workspace for resolving dependencies
#   --project <path>      Xcode project for resolving dependencies
#   --frameworks <path>   Path to prebuilt frameworks
#   --simulator <name>    Simulator to use (default: iPhone 17 Pro)
#   --output <path>       Output screenshot path
#   --keep                Keep the generated preview project
#   --verbose             Show build output
#
# Examples:
#   # Standalone Swift file (no dependencies)
#   preview-minimal.sh MyView.swift
#
#   # With prebuilt frameworks from an Xcode project
#   preview-minimal.sh Chip.swift --frameworks ~/Project/DerivedData/Build/Products/Debug-iphonesimulator

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/tmp/preview-minimal-$$"
DEFAULT_SIMULATOR="iPhone 17 Pro"
DEFAULT_OUTPUT="/tmp/preview-minimal.png"

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

# Cleanup
cleanup() {
    if [[ "$KEEP" != "true" && -d "$BUILD_DIR" ]]; then
        rm -rf "$BUILD_DIR"
    fi
}
trap cleanup EXIT

# Parse arguments
SWIFT_FILE=""
FRAMEWORKS_PATH=""
SIMULATOR="$DEFAULT_SIMULATOR"
OUTPUT_PATH="$DEFAULT_OUTPUT"
KEEP="false"
VERBOSE="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        --preview|--workspace|--project)
            shift 2
            ;;
        --frameworks)
            FRAMEWORKS_PATH="$2"
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
        --keep)
            KEEP="true"
            shift
            ;;
        --verbose)
            VERBOSE="true"
            shift
            ;;
        --help|-h)
            head -25 "$0" | tail -23
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -z "$SWIFT_FILE" ]]; then
                SWIFT_FILE="$1"
            else
                log_error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate
if [[ -z "$SWIFT_FILE" ]]; then
    log_error "No Swift file specified"
    exit 1
fi

if [[ ! -f "$SWIFT_FILE" ]]; then
    log_error "File not found: $SWIFT_FILE"
    exit 1
fi

SWIFT_FILE="$(cd "$(dirname "$SWIFT_FILE")" && pwd)/$(basename "$SWIFT_FILE")"

log_info "Building minimal preview for: $SWIFT_FILE"

# Find simulator
SIM_UDID=$("$SCRIPT_DIR/preview-helper.rb" find-simulator "$SIMULATOR" 2>/dev/null)
if [[ -z "$SIM_UDID" ]]; then
    log_error "Simulator not found: $SIMULATOR"
    exit 1
fi

# Boot simulator if needed
BOOT_STATE=$("$SCRIPT_DIR/preview-helper.rb" simulator-state "$SIM_UDID" 2>/dev/null)

if [[ "$BOOT_STATE" != "Booted" ]]; then
    log_info "Booting simulator..."
    xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
    sleep 3
fi

# Create build directory
mkdir -p "$BUILD_DIR/PreviewHost"

# Extract imports and analyze dependencies
log_info "Analyzing dependencies..."

IMPORTS=$(grep "^import " "$SWIFT_FILE" | sort -u)
SYSTEM_FRAMEWORKS="SwiftUI UIKit Foundation"
CUSTOM_FRAMEWORKS=""

while IFS= read -r line; do
    module=$(echo "$line" | sed 's/import //')
    if ! echo "$SYSTEM_FRAMEWORKS" | grep -q "$module"; then
        CUSTOM_FRAMEWORKS="$CUSTOM_FRAMEWORKS $module"
    fi
done <<< "$IMPORTS"

if [[ -n "$CUSTOM_FRAMEWORKS" ]]; then
    log_info "Custom frameworks needed:$CUSTOM_FRAMEWORKS"
    if [[ -z "$FRAMEWORKS_PATH" ]]; then
        log_warning "Custom frameworks detected but no --frameworks path provided"
        log_info "The preview may fail to build without the required frameworks"
    fi
fi

# Copy the source file
cp "$SWIFT_FILE" "$BUILD_DIR/PreviewHost/TargetView.swift"

# Remove the @main attribute if present (we'll add our own)
sed -i '' 's/@main//g' "$BUILD_DIR/PreviewHost/TargetView.swift"

# Create the preview host app
cat > "$BUILD_DIR/PreviewHost/PreviewHostApp.swift" << 'SWIFT_EOF'
import SwiftUI

@main
struct PreviewHostApp: App {
    var body: some Scene {
        WindowGroup {
            PreviewWrapper()
        }
    }
}

struct PreviewWrapper: View {
    var body: some View {
        // Renders the first view found in the imported file
        // The actual preview content is defined in TargetView.swift
        ScrollView {
            VStack {
                Text("Preview Host")
                    .font(.caption)
                    .foregroundColor(.secondary)
                // The preview content would go here
                // For now, we need to manually specify the view
            }
        }
    }
}
SWIFT_EOF

# For views that follow the pattern in the source file, try to instantiate them
VIEW_NAME=$(grep -E "^struct\s+\w+\s*:.*View" "$SWIFT_FILE" | head -1 | awk '{print $2}' | cut -d: -f1 || echo "")

if [[ -n "$VIEW_NAME" && "$VIEW_NAME" != "PreviewHostApp" && "$VIEW_NAME" != "PreviewWrapper" ]]; then
    log_info "Found view: $VIEW_NAME"

    # Check if there's a #Preview that sets up the view with specific configuration
    # Extract preview body, removing first and last lines (macOS compatible)
    PREVIEW_BODY=$(sed -n '/#Preview/,/^}/p' "$SWIFT_FILE" | tail -n +2 | sed '$d')

    if [[ -n "$PREVIEW_BODY" ]]; then
        log_info "Extracting preview configuration..."

        cat > "$BUILD_DIR/PreviewHost/PreviewHostApp.swift" << SWIFT_EOF
import SwiftUI

@main
struct PreviewHostApp: App {
    var body: some Scene {
        WindowGroup {
            PreviewContent()
        }
    }
}

struct PreviewContent: View {
    var body: some View {
$PREVIEW_BODY
    }
}
SWIFT_EOF
    else
        # Simple instantiation
        cat > "$BUILD_DIR/PreviewHost/PreviewHostApp.swift" << SWIFT_EOF
import SwiftUI

@main
struct PreviewHostApp: App {
    var body: some Scene {
        WindowGroup {
            ${VIEW_NAME}()
        }
    }
}
SWIFT_EOF
    fi
fi

# Create Package.swift for building
cat > "$BUILD_DIR/PreviewHost/Package.swift" << 'PACKAGE_EOF'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PreviewHost",
    platforms: [.iOS(.v17)],
    products: [
        .executable(name: "PreviewHost", targets: ["PreviewHost"])
    ],
    targets: [
        .executableTarget(
            name: "PreviewHost",
            path: "."
        )
    ]
)
PACKAGE_EOF

# Build options
BUILD_FLAGS=""
if [[ -n "$FRAMEWORKS_PATH" ]]; then
    BUILD_FLAGS="-F $FRAMEWORKS_PATH"
fi

# Try building with swift build first (for standalone files)
log_info "Building preview host..."

cd "$BUILD_DIR/PreviewHost"

# For iOS, we need to use xcodebuild, not swift build
# Create a minimal Xcode project

mkdir -p "$BUILD_DIR/PreviewHost.xcodeproj"

cat > "$BUILD_DIR/PreviewHost.xcodeproj/project.pbxproj" << 'PBXPROJ_EOF'
// !$*UTF8*$!
{
    archiveVersion = 1;
    classes = {};
    objectVersion = 56;
    objects = {
        ROOT = {
            isa = PBXProject;
            buildConfigurationList = CFGLIST;
            compatibilityVersion = "Xcode 14.0";
            developmentRegion = en;
            hasScannedForEncodings = 0;
            knownRegions = (en, Base);
            mainGroup = MAIN;
            productRefGroup = PRODUCTS;
            projectDirPath = "";
            projectRoot = "";
            targets = (TARGET);
        };
        MAIN = {
            isa = PBXGroup;
            children = (SRC, PRODUCTS);
            sourceTree = "<group>";
        };
        SRC = {
            isa = PBXGroup;
            children = (FILE1, FILE2);
            path = PreviewHost;
            sourceTree = "<group>";
        };
        PRODUCTS = {
            isa = PBXGroup;
            children = (PRODUCT);
            name = Products;
            sourceTree = "<group>";
        };
        FILE1 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PreviewHostApp.swift; sourceTree = "<group>";};
        FILE2 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TargetView.swift; sourceTree = "<group>";};
        PRODUCT = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = PreviewHost.app; sourceTree = BUILT_PRODUCTS_DIR;};
        TARGET = {
            isa = PBXNativeTarget;
            buildConfigurationList = TARGETCFG;
            buildPhases = (SOURCES);
            buildRules = ();
            dependencies = ();
            name = PreviewHost;
            productName = PreviewHost;
            productReference = PRODUCT;
            productType = "com.apple.product-type.application";
        };
        SOURCES = {
            isa = PBXSourcesBuildPhase;
            buildActionMask = 2147483647;
            files = (SRCFILE1, SRCFILE2);
            runOnlyForDeploymentPostprocessing = 0;
        };
        SRCFILE1 = {isa = PBXBuildFile; fileRef = FILE1;};
        SRCFILE2 = {isa = PBXBuildFile; fileRef = FILE2;};
        CFGLIST = {
            isa = XCConfigurationList;
            buildConfigurations = (CFG);
            defaultConfigurationIsVisible = 0;
            defaultConfigurationName = Debug;
        };
        CFG = {
            isa = XCBuildConfiguration;
            buildSettings = {
                SDKROOT = iphoneos;
                SUPPORTED_PLATFORMS = "iphonesimulator iphoneos";
                SWIFT_VERSION = 5.0;
            };
            name = Debug;
        };
        TARGETCFG = {
            isa = XCConfigurationList;
            buildConfigurations = (TARGETDEBUG);
            defaultConfigurationIsVisible = 0;
            defaultConfigurationName = Debug;
        };
        TARGETDEBUG = {
            isa = XCBuildConfiguration;
            buildSettings = {
                ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
                CODE_SIGN_STYLE = Automatic;
                CURRENT_PROJECT_VERSION = 1;
                GENERATE_INFOPLIST_FILE = YES;
                INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
                INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
                INFOPLIST_KEY_UILaunchScreen_Generation = YES;
                INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait";
                LD_RUNPATH_SEARCH_PATHS = "@executable_path/Frameworks";
                MARKETING_VERSION = 1.0;
                PRODUCT_BUNDLE_IDENTIFIER = com.preview.host;
                PRODUCT_NAME = "$(TARGET_NAME)";
                SDKROOT = iphoneos;
                SUPPORTED_PLATFORMS = "iphonesimulator iphoneos";
                SWIFT_EMIT_LOC_STRINGS = YES;
                SWIFT_VERSION = 5.0;
                TARGETED_DEVICE_FAMILY = 1;
            };
            name = Debug;
        };
    };
    rootObject = ROOT;
}
PBXPROJ_EOF

# Build
cd "$BUILD_DIR"

if [[ "$VERBOSE" == "true" ]]; then
    xcodebuild build \
        -project PreviewHost.xcodeproj \
        -scheme PreviewHost \
        -destination "platform=iOS Simulator,id=$SIM_UDID" \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        $BUILD_FLAGS
else
    xcodebuild build \
        -project PreviewHost.xcodeproj \
        -scheme PreviewHost \
        -destination "platform=iOS Simulator,id=$SIM_UDID" \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        $BUILD_FLAGS \
        -quiet 2>&1
fi

BUILD_EXIT=$?
if [[ $BUILD_EXIT -ne 0 ]]; then
    log_error "Build failed"
    if [[ "$KEEP" != "true" ]]; then
        log_info "Use --keep to preserve build directory for debugging"
    fi
    exit 1
fi

log_success "Build completed"

# Find and install the app
APP_PATH=$(find "$BUILD_DIR/DerivedData" -name "PreviewHost.app" -type d | head -1)
if [[ -z "$APP_PATH" ]]; then
    log_error "Could not find built app"
    exit 1
fi

log_info "Installing preview app..."
xcrun simctl install "$SIM_UDID" "$APP_PATH"

log_info "Launching preview..."
xcrun simctl launch "$SIM_UDID" "com.preview.host"

sleep 3

log_info "Capturing screenshot..."
mkdir -p "$(dirname "$OUTPUT_PATH")"
xcrun simctl io "$SIM_UDID" screenshot "$OUTPUT_PATH"

xcrun simctl terminate "$SIM_UDID" "com.preview.host" 2>/dev/null || true

if [[ -f "$OUTPUT_PATH" ]]; then
    SIZE=$(ls -lh "$OUTPUT_PATH" | awk '{print $5}')
    log_success "Preview captured: $OUTPUT_PATH ($SIZE)"
    echo ""
    echo "PREVIEW_PATH=$OUTPUT_PATH"
else
    log_error "Failed to capture preview"
    exit 1
fi
