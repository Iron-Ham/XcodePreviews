#!/bin/bash
#
# preview-module.sh - Build preview for a module with dependencies
#
# This script creates a minimal preview host that links against the required
# module dependencies, building only what's necessary for the preview.
#
# Usage:
#   preview-module.sh <swift-file> --workspace <path> [options]
#   preview-module.sh <swift-file> --project <path> [options]
#   preview-module.sh <swift-file> --package <path> [options]
#
# Options:
#   --workspace <path>    Xcode workspace containing the module
#   --project <path>      Xcode project containing the module
#   --package <path>      Swift package directory
#   --target <name>       Target/module containing the file (auto-detected if omitted)
#   --simulator <name>    Simulator to use (default: iPhone 17 Pro)
#   --output <path>       Output screenshot path
#   --derived-data <path> Path to existing DerivedData (speeds up builds)
#   --verbose             Show build output
#
# Examples:
#   # Module in an Xcode workspace
#   preview-module.sh Chip.swift --workspace MyApp.xcworkspace
#
#   # Module in a Swift package
#   preview-module.sh MyView.swift --package ./MyPackage
#
#   # Single-app target
#   preview-module.sh ContentView.swift --project MyApp.xcodeproj --target MyApp

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/tmp/preview-module-$$"
PREVIEW_HOST_DIR="$BUILD_DIR/PreviewHost"

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

cleanup() {
    if [[ "$KEEP" != "true" && -d "$BUILD_DIR" ]]; then
        rm -rf "$BUILD_DIR"
    fi
}
trap cleanup EXIT

# Parse arguments
SWIFT_FILE=""
WORKSPACE=""
PROJECT=""
PACKAGE=""
TARGET=""
SIMULATOR="iPhone 17 Pro"
OUTPUT_PATH="/tmp/preview-module.png"
DERIVED_DATA=""
VERBOSE="false"
KEEP="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        --workspace)
            WORKSPACE="$2"
            shift 2
            ;;
        --project)
            PROJECT="$2"
            shift 2
            ;;
        --package)
            PACKAGE="$2"
            shift 2
            ;;
        --target)
            TARGET="$2"
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
        --derived-data)
            DERIVED_DATA="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE="true"
            shift
            ;;
        --keep)
            KEEP="true"
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
            # Only set SWIFT_FILE if not empty and not already set
            if [[ -n "$1" && -z "$SWIFT_FILE" ]]; then
                SWIFT_FILE="$1"
            fi
            shift
            ;;
    esac
done

# Validate inputs
if [[ -z "$SWIFT_FILE" ]]; then
    log_error "No Swift file specified"
    exit 1
fi

if [[ ! -f "$SWIFT_FILE" ]]; then
    log_error "File not found: $SWIFT_FILE"
    exit 1
fi

if [[ -z "$WORKSPACE" && -z "$PROJECT" && -z "$PACKAGE" ]]; then
    log_error "Must specify --workspace, --project, or --package"
    exit 1
fi

SWIFT_FILE="$(cd "$(dirname "$SWIFT_FILE")" && pwd)/$(basename "$SWIFT_FILE")"
FILENAME=$(basename "$SWIFT_FILE" .swift)

log_info "Building preview for: $FILENAME"

# Find simulator
SIM_UDID=$("$SCRIPT_DIR/preview-helper.rb" find-simulator "$SIMULATOR" 2>/dev/null)
if [[ -z "$SIM_UDID" ]]; then
    log_error "Simulator not found: $SIMULATOR"
    log_info "Available simulators:"
    xcrun simctl list devices available | grep -E "iPhone|iPad" | head -5
    exit 1
fi

# Boot if needed
BOOT_STATE=$("$SCRIPT_DIR/preview-helper.rb" simulator-state "$SIM_UDID" 2>/dev/null)

if [[ "$BOOT_STATE" != "Booted" ]]; then
    log_info "Booting simulator: $SIMULATOR"
    xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
    sleep 3
fi

# Extract imports from Swift file
log_info "Analyzing imports..."
IMPORTS=$(grep "^import " "$SWIFT_FILE" | sed 's/import //' | sort -u)
log_info "Required modules: $(echo $IMPORTS | tr '\n' ' ')"

# Create build directory
mkdir -p "$PREVIEW_HOST_DIR"

# Detect project type and set up build
if [[ -n "$PACKAGE" ]]; then
    #==========================================================================
    # SWIFT PACKAGE
    #==========================================================================
    PACKAGE="$(cd "$PACKAGE" && pwd)"
    log_info "Building as Swift Package dependency"

    # Find the module containing our file
    if [[ -z "$TARGET" ]]; then
        # Try to detect from Package.swift or file path
        TARGET=$(basename "$(dirname "$SWIFT_FILE")")
        log_info "Auto-detected target: $TARGET"
    fi

    # Create a preview package that depends on the target package
    cat > "$PREVIEW_HOST_DIR/Package.swift" << PKGEOF
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PreviewHost",
    platforms: [.iOS(.v17)],
    dependencies: [
        .package(path: "$PACKAGE")
    ],
    targets: [
        .executableTarget(
            name: "PreviewHost",
            dependencies: [
                .product(name: "$TARGET", package: "$(basename "$PACKAGE")")
            ],
            path: "Sources"
        )
    ]
)
PKGEOF

    mkdir -p "$PREVIEW_HOST_DIR/Sources"

    # Copy source and create host
    cp "$SWIFT_FILE" "$PREVIEW_HOST_DIR/Sources/TargetView.swift"

    # Extract preview body
    PREVIEW_BODY=$(sed -n '/#Preview/,/^}/p' "$SWIFT_FILE" | tail -n +2 | sed '$d')

    cat > "$PREVIEW_HOST_DIR/Sources/PreviewHostApp.swift" << SWIFTEOF
import SwiftUI
$(for imp in $IMPORTS; do echo "import $imp"; done)

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
SWIFTEOF

    # Build with xcodebuild (swift build doesn't support iOS)
    log_info "Building preview host..."
    cd "$PREVIEW_HOST_DIR"

    # Generate Xcode project from package
    swift package generate-xcodeproj 2>/dev/null || true

    if [[ -d "PreviewHost.xcodeproj" ]]; then
        xcodebuild build \
            -project PreviewHost.xcodeproj \
            -scheme PreviewHost \
            -destination "platform=iOS Simulator,id=$SIM_UDID" \
            -derivedDataPath "$BUILD_DIR/DerivedData" \
            "$( [[ "$VERBOSE" != "true" ]] && echo "-quiet" )" 2>&1 | while read line; do log_verbose "$line"; done

        BUILD_EXIT=${PIPESTATUS[0]}
        if [[ $BUILD_EXIT -ne 0 ]]; then
            log_error "Failed to build preview host from package"
            if [[ "$KEEP" != "true" ]]; then
                log_info "Use --keep to preserve build artifacts for debugging"
            fi
            exit 1
        fi
    else
        log_error "Failed to generate Xcode project from package"
        exit 1
    fi

elif [[ -n "$WORKSPACE" || -n "$PROJECT" ]]; then
    #==========================================================================
    # XCODE WORKSPACE/PROJECT
    #==========================================================================

    if [[ -n "$WORKSPACE" ]]; then
        WORKSPACE="$(cd "$(dirname "$WORKSPACE")" && pwd)/$(basename "$WORKSPACE")"
        BUILD_SOURCE="workspace"
        BUILD_PATH="$WORKSPACE"
    else
        PROJECT="$(cd "$(dirname "$PROJECT")" && pwd)/$(basename "$PROJECT")"
        BUILD_SOURCE="project"
        BUILD_PATH="$PROJECT"
    fi

    log_info "Building with Xcode $BUILD_SOURCE"

    # Find the target containing our file if not specified
    if [[ -z "$TARGET" ]]; then
        # Try to find target from file path
        # Common patterns: Modules/<ModuleName>/..., Sources/<ModuleName>/...
        RELATIVE_PATH="${SWIFT_FILE#$(dirname "$BUILD_PATH")/}"

        if [[ "$RELATIVE_PATH" =~ Modules/([^/]+)/ ]]; then
            TARGET="${BASH_REMATCH[1]}"
        elif [[ "$RELATIVE_PATH" =~ Sources/([^/]+)/ ]]; then
            TARGET="${BASH_REMATCH[1]}"
        else
            # List targets and try to match by import
            log_warning "Could not auto-detect target. Checking available targets..."
            TARGETS=$(xcodebuild -${BUILD_SOURCE} "$BUILD_PATH" -list 2>/dev/null | grep -A100 "Targets:" | grep -B100 "Schemes:" | grep -v "Targets:\|Schemes:" | sed 's/^[ \t]*//' | grep -v "^$")

            # Try to find a target that matches one of our imports
            for imp in $IMPORTS; do
                if echo "$TARGETS" | grep -q "^${imp}$"; then
                    TARGET="$imp"
                    break
                fi
            done
        fi

        if [[ -n "$TARGET" ]]; then
            log_info "Auto-detected target: $TARGET"
        else
            log_error "Could not detect target. Please specify with --target"
            exit 1
        fi
    fi

    # Look for existing DerivedData
    PROJECT_DIR=$(dirname "$BUILD_PATH")

    # Check common DerivedData locations
    EXISTING_DERIVED=""
    for dd_path in \
        "$PROJECT_DIR/DerivedData" \
        "$PROJECT_DIR/build/DerivedData" \
        ~/Library/Developer/Xcode/DerivedData/*; do
        if [[ -d "$dd_path/Build/Products/Debug-iphonesimulator" ]]; then
            # Check if it has our required modules
            has_modules=true
            for imp in $IMPORTS; do
                if [[ "$imp" != "SwiftUI" && "$imp" != "Foundation" && "$imp" != "UIKit" ]]; then
                    if [[ ! -d "$dd_path/Build/Products/Debug-iphonesimulator/${imp}.swiftmodule" ]]; then
                        has_modules=false
                        break
                    fi
                fi
            done
            if [[ "$has_modules" == "true" ]]; then
                EXISTING_DERIVED="$dd_path"
                break
            fi
        fi
    done

    if [[ -n "$EXISTING_DERIVED" ]]; then
        log_info "Found existing DerivedData with required modules: $EXISTING_DERIVED"
        DERIVED_DATA="$EXISTING_DERIVED"
    elif [[ -n "$DERIVED_DATA" ]]; then
        log_info "Using provided DerivedData: $DERIVED_DATA"
    else
        # Need to build - find a scheme that builds our dependencies
        DERIVED_DATA="$BUILD_DIR/DerivedData"

        # Find a scheme that we can build
        AVAILABLE_SCHEMES=$(xcodebuild -${BUILD_SOURCE} "$BUILD_PATH" -list 2>/dev/null | grep -A50 "Schemes:" | tail -n +2 | sed 's/^[ \t]*//' | grep -v "^$")

        # Prefer a dev/debug scheme
        BUILD_SCHEME=""
        for scheme in $AVAILABLE_SCHEMES; do
            if [[ "$scheme" =~ Dev|Debug|Local ]]; then
                BUILD_SCHEME="$scheme"
                break
            fi
        done

        # Fall back to first scheme if no dev scheme found
        if [[ -z "$BUILD_SCHEME" ]]; then
            BUILD_SCHEME=$(echo "$AVAILABLE_SCHEMES" | head -1)
        fi

        if [[ -z "$BUILD_SCHEME" ]]; then
            log_error "No buildable scheme found"
            exit 1
        fi

        log_info "Building dependencies using scheme: $BUILD_SCHEME"
        log_info "This may take a while on first run..."

        BUILD_ARGS=("-${BUILD_SOURCE}" "$BUILD_PATH")
        BUILD_ARGS+=("-scheme" "$BUILD_SCHEME")
        BUILD_ARGS+=("-destination" "platform=iOS Simulator,id=$SIM_UDID")
        BUILD_ARGS+=("-derivedDataPath" "$DERIVED_DATA")
        BUILD_ARGS+=("build")

        if [[ "$VERBOSE" != "true" ]]; then
            BUILD_ARGS+=("-quiet")
        fi

        xcodebuild "${BUILD_ARGS[@]}" 2>&1 | while read line; do log_verbose "$line"; done

        BUILD_EXIT=${PIPESTATUS[0]}
        if [[ $BUILD_EXIT -ne 0 ]]; then
            log_error "Failed to build dependencies"
            exit 1
        fi

        log_success "Dependencies built"
    fi

    # Find the built frameworks/modules
    FRAMEWORKS_DIR="$DERIVED_DATA/Build/Products/Debug-iphonesimulator"

    if [[ ! -d "$FRAMEWORKS_DIR" ]]; then
        log_error "Build products not found at: $FRAMEWORKS_DIR"
        exit 1
    fi

    log_info "Using frameworks from: $FRAMEWORKS_DIR"

    # Create the preview host project
    log_info "Creating preview host..."

    mkdir -p "$PREVIEW_HOST_DIR/PreviewHost"

    # Copy source file (remove any @main attributes)
    sed 's/@main//g' "$SWIFT_FILE" > "$PREVIEW_HOST_DIR/PreviewHost/TargetView.swift"

    # Also remove #Preview if we're going to inline it
    # Extract preview body
    PREVIEW_BODY=$(sed -n '/#Preview/,/^}/p' "$SWIFT_FILE" | tail -n +2 | sed '$d')

    # Generate imports
    IMPORT_STATEMENTS=""
    for imp in $IMPORTS; do
        IMPORT_STATEMENTS="${IMPORT_STATEMENTS}import $imp
"
    done

    # Create preview host app
    cat > "$PREVIEW_HOST_DIR/PreviewHost/PreviewHostApp.swift" << SWIFTEOF
import SwiftUI
${IMPORT_STATEMENTS}
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
${PREVIEW_BODY}
    }
}
SWIFTEOF

    # Create Xcode project that links against built frameworks
    mkdir -p "$PREVIEW_HOST_DIR/PreviewHost.xcodeproj"


    # Generate project.pbxproj
    cat > "$PREVIEW_HOST_DIR/PreviewHost.xcodeproj/project.pbxproj" << 'PBXEOF'
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
PBXEOF

    # Add framework search path
    echo "                FRAMEWORK_SEARCH_PATHS = \"$FRAMEWORKS_DIR\";" >> "$PREVIEW_HOST_DIR/PreviewHost.xcodeproj/project.pbxproj"
    echo "                SWIFT_INCLUDE_PATHS = \"$FRAMEWORKS_DIR\";" >> "$PREVIEW_HOST_DIR/PreviewHost.xcodeproj/project.pbxproj"

    cat >> "$PREVIEW_HOST_DIR/PreviewHost.xcodeproj/project.pbxproj" << 'PBXEOF'
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
PBXEOF

    # Add framework search path to target config too
    echo "                FRAMEWORK_SEARCH_PATHS = \"$FRAMEWORKS_DIR\";" >> "$PREVIEW_HOST_DIR/PreviewHost.xcodeproj/project.pbxproj"
    echo "                SWIFT_INCLUDE_PATHS = \"$FRAMEWORKS_DIR\";" >> "$PREVIEW_HOST_DIR/PreviewHost.xcodeproj/project.pbxproj"

    cat >> "$PREVIEW_HOST_DIR/PreviewHost.xcodeproj/project.pbxproj" << 'PBXEOF'
            };
            name = Debug;
        };
    };
    rootObject = ROOT;
}
PBXEOF

    # Build the preview host
    log_info "Building preview host..."
    cd "$PREVIEW_HOST_DIR"

    xcodebuild build \
        -project PreviewHost.xcodeproj \
        -scheme PreviewHost \
        -destination "platform=iOS Simulator,id=$SIM_UDID" \
        -derivedDataPath "$BUILD_DIR/PreviewDerivedData" \
        "$( [[ "$VERBOSE" != "true" ]] && echo "-quiet" )" 2>&1 | while read line; do log_verbose "$line"; done

    BUILD_EXIT=${PIPESTATUS[0]}
    if [[ $BUILD_EXIT -ne 0 ]]; then
        log_error "Failed to build preview host"
        if [[ "$KEEP" != "true" ]]; then
            log_info "Use --keep to preserve build artifacts for debugging"
        fi
        exit 1
    fi
fi

log_success "Build completed"

# Find and install the app
APP_PATH=$(find "$BUILD_DIR" -name "PreviewHost.app" -type d 2>/dev/null | head -1)
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
