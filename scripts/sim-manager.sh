#!/bin/bash
#
# sim-manager.sh - Simulator management utilities
#
# Usage:
#   sim-manager.sh list              List available simulators
#   sim-manager.sh booted            Show booted simulators
#   sim-manager.sh boot <name>       Boot a simulator
#   sim-manager.sh shutdown <name>   Shutdown a simulator
#   sim-manager.sh shutdown-all      Shutdown all simulators

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ACTION="${1:-list}"
TARGET="$2"

case $ACTION in
    list)
        echo -e "${BLUE}Available iOS Simulators:${NC}"
        xcrun simctl list devices available | grep -E "^--|iPhone|iPad" | head -30
        ;;

    booted)
        echo -e "${BLUE}Booted Simulators:${NC}"
        BOOTED=$(xcrun simctl list devices booted | grep -E "iPhone|iPad" || echo "None")
        if [[ "$BOOTED" == "None" ]]; then
            echo -e "${YELLOW}No simulators currently booted${NC}"
        else
            echo "$BOOTED"
        fi
        ;;

    boot)
        if [[ -z "$TARGET" ]]; then
            echo "Usage: sim-manager.sh boot <simulator-name>"
            echo "Example: sim-manager.sh boot 'iPhone 17 Pro'"
            exit 1
        fi
        echo -e "${BLUE}Booting simulator: $TARGET${NC}"
        xcrun simctl boot "$TARGET" 2>/dev/null || {
            # Try to find by name using Ruby helper
            UDID=$("$SCRIPT_DIR/preview-helper.rb" find-simulator "$TARGET" 2>/dev/null)
            if [[ -n "$UDID" ]]; then
                xcrun simctl boot "$UDID"
            else
                echo "Could not find simulator: $TARGET"
                exit 1
            fi
        }
        echo -e "${GREEN}Simulator booted successfully${NC}"
        ;;

    shutdown)
        if [[ -z "$TARGET" ]]; then
            echo "Usage: sim-manager.sh shutdown <simulator-name>"
            exit 1
        fi
        echo -e "${BLUE}Shutting down simulator: $TARGET${NC}"
        xcrun simctl shutdown "$TARGET" 2>/dev/null || echo "Simulator may already be shut down"
        echo -e "${GREEN}Done${NC}"
        ;;

    shutdown-all)
        echo -e "${BLUE}Shutting down all simulators...${NC}"
        xcrun simctl shutdown all
        echo -e "${GREEN}All simulators shut down${NC}"
        ;;

    *)
        echo "Unknown action: $ACTION"
        echo "Available actions: list, booted, boot, shutdown, shutdown-all"
        exit 1
        ;;
esac
