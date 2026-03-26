# /preview - Build and Capture SwiftUI Preview

Build a SwiftUI view and capture its rendered output for visual analysis.

## Arguments

$ARGUMENTS - File path, or options like --scheme, --workspace, --capture-only

## Instructions

You are the preview capture assistant. Your job is to build SwiftUI previews and analyze their visual output.

**Path Resolution:** Scripts default to `~/XcodePreviews`. If that directory doesn't exist, fall back to `~/Claude-XcodePreviews` (legacy name). The `PREVIEW_BUILD_PATH` environment variable overrides both.

### Unified Entry Point

For most cases, use the unified `preview` script which auto-detects the best approach:

```bash
"${PREVIEW_BUILD_PATH:-$HOME/XcodePreviews}"/scripts/preview \
  "<path-to-file.swift>" \
  --output /tmp/preview.png
```

This will automatically:
1. Detect if the file has a `#Preview` block
2. Find the associated Xcode project or SPM package
3. Use dynamic preview injection for fast builds (~3-4 seconds)
4. Fall back to full scheme builds when needed

### Preview Modes

The unified `preview` script auto-detects the best mode. You can also be explicit:

#### Xcode Project with #Preview (Fastest)

Injects a minimal PreviewHost target, builds only required modules (~3-4 seconds):

```bash
"${PREVIEW_BUILD_PATH:-$HOME/XcodePreviews}"/scripts/preview \
  "<path-to-file.swift>" \
  --project "<path.xcodeproj>" \
  --output /tmp/preview.png
```

#### SPM Package

Auto-detected from Package.swift in parent directories:

```bash
"${PREVIEW_BUILD_PATH:-$HOME/XcodePreviews}"/scripts/preview \
  "<path-to-file.swift>" \
  --output /tmp/preview.png
```

#### Standalone Swift File (No Dependencies)

For Swift files that only use system frameworks (SwiftUI, UIKit, Foundation):

```bash
"${PREVIEW_BUILD_PATH:-$HOME/XcodePreviews}"/scripts/preview \
  "<path-to-file.swift>" \
  --output /tmp/preview.png
```

#### Select a Named Preview

When a file has multiple `#Preview` blocks, select one by name:

```bash
"${PREVIEW_BUILD_PATH:-$HOME/XcodePreviews}"/scripts/preview \
  "<path-to-file.swift>" \
  --project "<path.xcodeproj>" \
  --preview-name "Dark Mode" \
  --output /tmp/preview.png
```

Without `--preview-name`, the first `#Preview` in the file is used.

#### Capture Current Simulator

Just screenshot whatever is currently on screen:

```bash
"${PREVIEW_BUILD_PATH:-$HOME/XcodePreviews}"/scripts/preview \
  --capture \
  --output /tmp/preview.png
```

### After Capture: Analyze the Screenshot

1. Use the Read tool to view the PNG:
```
Read /tmp/preview.png
```

2. Provide analysis:
   - **Layout**: Structure and arrangement
   - **Visual elements**: Buttons, text, images
   - **Styling**: Colors, fonts, spacing
   - **Issues**: Alignment, overflow, accessibility
   - **Suggestions**: Improvements

### Example Workflows

**Preview a component from an Xcode project:**
```
User: /preview ~/MyApp/Modules/Components/Button.swift
→ Auto-detects MyApp.xcodeproj
→ Injects PreviewHost target for fast build (~3 seconds)
→ Capture screenshot showing Button component
→ Analyze visual output
```

**Preview from an SPM package:**
```
User: /preview ~/MyPackage/Sources/UI/Card.swift
→ Detects Package.swift
→ Creates temporary Xcode project with SPM dependency
→ Capture screenshot
→ Analyze visual output
```

**Preview a standalone SwiftUI file:**
```
User: /preview MyView.swift
→ Detects system-only imports
→ Builds minimal host app
→ Capture screenshot
→ Analyze visual output
```

**Just capture current simulator:**
```
User: /preview --capture-only
→ Screenshot current simulator state
→ Analyze what's shown
```

### Error Handling

- **No simulator booted**: Run `sim-manager.sh boot "iPhone 17 Pro"`
- **Build failure**: Show error, suggest fixes, offer to retry
- **Resource bundle crash**: The dynamic script auto-includes Tuist and common bundle patterns
- **Missing imports**: Check if the target module needs to be added to imports
- **Deployment target mismatch**: The scripts auto-detect iOS version from project/package
