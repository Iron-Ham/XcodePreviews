import Foundation
import PreviewToolLib

// MARK: - PreviewArgs

struct PreviewArgs {
  var file = ""
  var project: String?
  var workspace: String?
  var target: String?
  var previewName: String?
  var simulator = "iPhone 17 Pro"
  var output = "/tmp/preview-dynamic.png"
  var keep = false
  var isVerbose = false
}

// MARK: - PreviewSPMArgs

struct PreviewSPMArgs {
  var file = ""
  var packagePath = ""
  var module: String?
  var previewName: String?
  var simulator = "iPhone 17 Pro"
  var output = "/tmp/preview-spm.png"
  var keep = false
  var isVerbose = false
}

// MARK: - ResolveArgs

struct ResolveArgs {
  var start = ""
  var sourcesDir = ""
}

// MARK: - Subcommand

enum Subcommand {
  case preview(PreviewArgs)
  case previewSPM(PreviewSPMArgs)
  case resolve(ResolveArgs)
}

func printUsage() {
  let msg = """
    Usage:
      preview-tool preview --file <path> --project <path> [options]
      preview-tool preview-spm --file <path> [options]
      preview-tool resolve --start <file> --sources-dir <dir>

    Preview options:
      --file <path>         Swift file to preview
      --project <path>      Xcode project file
      --workspace <path>    Xcode workspace file
      --target <name>       Module containing the file (auto-detected)
      --preview-name <name> Select a named #Preview (default: first)
      --simulator <name>    Simulator (default: iPhone 17 Pro)
      --output <path>       Output screenshot path
      --keep                Keep the preview target after capture
      --verbose             Show detailed output

    Preview-spm options:
      --file <path>         Swift file to preview
      --package <path>      Path to Package.swift (auto-detected from file)
      --module <name>       Module name (auto-detected from path)
      --preview-name <name> Select a named #Preview (default: first)
      --simulator <name>    Simulator (default: iPhone 17 Pro)
      --output <path>       Output screenshot path
      --keep                Keep temporary project after capture
      --verbose             Show detailed output

    Resolve options:
      --start <path>        Start file for dependency resolution
      --sources-dir <dir>   Directory to scan for Swift files
    """
  FileHandle.standardError.write(Data(msg.utf8))
}

func parseArgs() -> Subcommand? {
  let args = CommandLine.arguments
  guard args.count >= 2 else { return nil }

  switch args[1] {
  case "preview":
    var pa = PreviewArgs()
    var i = 2
    while i < args.count {
      switch args[i] {
      case "--file":
        i += 1
        guard i < args.count else { return nil }
        pa.file = args[i]

      case "--project":
        i += 1
        guard i < args.count else { return nil }
        pa.project = args[i]

      case "--workspace":
        i += 1
        guard i < args.count else { return nil }
        pa.workspace = args[i]

      case "--target":
        i += 1
        guard i < args.count else { return nil }
        pa.target = args[i]

      case "--preview-name":
        i += 1
        guard i < args.count else { return nil }
        pa.previewName = args[i]

      case "--simulator":
        i += 1
        guard i < args.count else { return nil }
        pa.simulator = args[i]

      case "--output":
        i += 1
        guard i < args.count else { return nil }
        pa.output = args[i]

      case "--keep":
        pa.keep = true

      case "--verbose":
        pa.isVerbose = true

      default:
        log(.warning, "Unknown argument: \(args[i])")
      }
      i += 1
    }
    return .preview(pa)

  case "preview-spm":
    var spa = PreviewSPMArgs()
    var i = 2
    while i < args.count {
      switch args[i] {
      case "--file":
        i += 1
        guard i < args.count else { return nil }
        spa.file = args[i]

      case "--package":
        i += 1
        guard i < args.count else { return nil }
        spa.packagePath = args[i]

      case "--module":
        i += 1
        guard i < args.count else { return nil }
        spa.module = args[i]

      case "--preview-name":
        i += 1
        guard i < args.count else { return nil }
        spa.previewName = args[i]

      case "--simulator":
        i += 1
        guard i < args.count else { return nil }
        spa.simulator = args[i]

      case "--output":
        i += 1
        guard i < args.count else { return nil }
        spa.output = args[i]

      case "--keep":
        spa.keep = true

      case "--verbose":
        spa.isVerbose = true

      default:
        log(.warning, "Unknown argument: \(args[i])")
      }
      i += 1
    }
    return .previewSPM(spa)

  case "resolve":
    var ra = ResolveArgs()
    var i = 2
    while i < args.count {
      switch args[i] {
      case "--start":
        i += 1
        guard i < args.count else { return nil }
        ra.start = args[i]

      case "--sources-dir":
        i += 1
        guard i < args.count else { return nil }
        ra.sourcesDir = args[i]

      default:
        log(.warning, "Unknown argument: \(args[i])")
      }
      i += 1
    }
    return .resolve(ra)

  case "--help", "-h":
    printUsage()
    exit(0)

  default:
    return nil
  }
}

// MARK: - Resolve subcommand (backward compat)

func runResolve(_ args: ResolveArgs) {
  guard !args.start.isEmpty, !args.sourcesDir.isEmpty else {
    printUsage()
    exit(1)
  }

  let resolver = DependencyResolver()
  do {
    let result = try resolver.resolve(startFile: args.start, sourcesDir: args.sourcesDir)
    let output: [String: Any] = [
      "resolvedFiles": result.resolvedFiles,
      "excludedEntryPoints": result.excludedEntryPoints,
      "stats": [
        "totalScanned": result.totalScanned,
        "resolved": result.resolvedFiles.count,
      ],
    ]
    do {
      let data = try JSONSerialization.data(
        withJSONObject: output,
        options: [.prettyPrinted, .sortedKeys]
      )
      if let json = String(data: data, encoding: .utf8) {
        print(json)
      } else {
        log(.error, "Failed to encode JSON as UTF-8")
        exit(1)
      }
    } catch {
      log(.error, "Failed to serialize output: \(error)")
      exit(1)
    }
  } catch {
    log(.error, "\(error)")
    exit(1)
  }
}

// MARK: - Preview subcommand

func runPreview(_ args: PreviewArgs) {
  guard !args.file.isEmpty else {
    log(.error, "No Swift file specified (--file)")
    exit(1)
  }

  let fm = FileManager.default
  guard fm.fileExists(atPath: args.file) else {
    log(.error, "File not found: \(args.file)")
    exit(1)
  }

  guard args.project != nil || args.workspace != nil else {
    log(.error, "Must specify --project or --workspace")
    exit(1)
  }

  verbose = args.isVerbose

  let swiftFile = resolveAbsolutePath(args.file)
  let filename = (swiftFile as NSString).lastPathComponent
    .replacingOccurrences(of: ".swift", with: "")

  // Find project path — prefer explicit --project, fall back to workspace discovery
  let projectPath: String
  if let project = args.project {
    projectPath = resolveAbsolutePath(project)
  } else if let workspace = args.workspace {
    let wsDir = (workspace as NSString).deletingLastPathComponent
    if let found = findFirstXcodeproj(in: wsDir) {
      projectPath = found
    } else {
      log(.error, "No .xcodeproj found near workspace")
      exit(1)
    }
  } else {
    log(.error, "Either --project or --workspace is required")
    exit(1)
  }
  let projectDir = (projectPath as NSString).deletingLastPathComponent

  log(.info, "Preview: \(filename)")
  log(.info, "Project: \(projectPath)")

  // Extract imports
  let extractor = PreviewExtractor()
  let imports = extractor.extractImports(from: swiftFile)
  log(.info, "Imports: \(imports.joined(separator: " "))")

  // Auto-detect target from file path
  var targetName = args.target
  if targetName == nil {
    let relative = swiftFile.hasPrefix(projectDir + "/")
      ? String(swiftFile.dropFirst(projectDir.count + 1))
      : swiftFile

    if let range = relative.range(of: #"Modules/([^/]+)/"#, options: .regularExpression) {
      let match = relative[range]
      let parts = match.split(separator: "/")
      if parts.count >= 2 {
        targetName = String(parts[1])
      }
    } else if let range = relative.range(of: #"Sources/([^/]+)/"#, options: .regularExpression) {
      let match = relative[range]
      let parts = match.split(separator: "/")
      if parts.count >= 2 {
        targetName = String(parts[1])
      }
    }
    if let t = targetName {
      log(.info, "Auto-detected target: \(t)")
    }
  }

  // Add target module to imports if not already present
  var allImports = imports
  if let t = targetName, !imports.contains(t) {
    allImports.append(t)
    log(.info, "Added import for target module: \(t)")
  }

  // Extract preview body
  if let name = args.previewName {
    log(.info, "Selecting preview: \"\(name)\"")
  }
  let previewBody: String
  do {
    previewBody = try extractor.extract(from: swiftFile, named: args.previewName)
  } catch {
    log(.error, "\(error)")
    exit(1)
  }

  // Find simulator
  let sim = SimulatorManager()
  let simUDID: String
  do {
    simUDID = try sim.findSimulator(name: args.simulator)
  } catch {
    log(.error, "\(error)")
    exit(1)
  }

  // Boot simulator
  do {
    try sim.boot(udid: simUDID)
  } catch {
    log(.error, "\(error)")
    exit(1)
  }

  // PID-isolated derived data
  let derivedDataPath = "/tmp/preview-dynamic-dd-\(ProcessInfo.processInfo.processIdentifier)"
  let previewDir = (projectDir as NSString).appendingPathComponent(
    ".preview-host-\(ProcessInfo.processInfo.processIdentifier)"
  )
  do {
    try FileManager.default.createDirectory(atPath: previewDir, withIntermediateDirectories: true)
  } catch {
    log(.error, "Failed to create PreviewHost directory: \(error)")
    exit(1)
  }

  // Run declaration-level resolver for app-target files
  let isAppTargetFile = (targetName == nil || targetName?.isEmpty == true)

  if isAppTargetFile {
    let previewRefTypes = extractor.extractReferencedTypes(fromSource: previewBody)
    logVerbose("Preview references: \(previewRefTypes.sorted().joined(separator: ", "))")

    let sourceDir = detectSourceDir(
      projectPath: projectPath,
      projectDir: projectDir,
      swiftFile: swiftFile
    )
    if let sourceDir {
      log(.info, "Running declaration resolver on \(sourceDir)...")
      do {
        let resolver = DeclarationResolver()
        let result = try resolver.resolve(
          startFile: swiftFile,
          sourcesDir: sourceDir,
          previewReferencedTypes: previewRefTypes
        )
        let genPath = (previewDir as NSString).appendingPathComponent("_PreviewGenerated.swift")
        try result.generatedSource.write(toFile: genPath, atomically: true, encoding: .utf8)
        log(.info, "Resolver: \(result.resolvedDeclarations) declarations from \(result.contributingFiles.count) files")
        logVerbose("Contributing files: \(result.contributingFiles.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
      } catch {
        log(.warning, "declaration-resolver failed: \(error). Falling back to start file.")
        writeFallbackGenerated(from: swiftFile, to: previewDir)
      }
    } else {
      writeFallbackGenerated(from: swiftFile, to: previewDir)
    }
  }

  // Inject target
  log(.info, "Injecting PreviewHost target...")
  let injector = ProjectInjector()
  do {
    try injector.inject(
      swiftFile: swiftFile,
      projectPath: projectPath,
      targetName: targetName,
      previewHostDir: previewDir,
      previewBody: previewBody,
      imports: allImports
    )
  } catch {
    log(.error, "Failed to inject target: \(error)")
    exit(1)
  }
  log(.success, "Target injected")

  /// Cleanup closure
  func cleanupAndExit(_ code: Int32) -> Never {
    if !args.keep {
      log(.info, "Cleaning up...")
      do { try fm.removeItem(atPath: previewDir) } catch {
        log(.warning, "Failed to remove PreviewHost directory: \(error)")
      }
      do { try injector.cleanup(projectPath: projectPath) } catch {
        log(.warning, "Failed to clean up project: \(error)")
      }
    }
    do { try fm.removeItem(atPath: derivedDataPath) } catch {
      logVerbose("Failed to remove derived data: \(error)")
    }
    exit(code)
  }

  // Auto-detect workspace alongside project for better SPM resolution
  var workspacePath = args.workspace
  if workspacePath == nil {
    workspacePath = findWorkspaceAlongsideProject(projectPath)
    if let ws = workspacePath {
      log(.info, "Auto-detected workspace: \(ws)")
    }
  }

  // Find existing SourcePackages directory for SPM dependency resolution
  let clonedSourcePackagesDir = findClonedSourcePackagesDir(
    projectDir: projectDir,
    projectPath: projectPath
  )
  if let dir = clonedSourcePackagesDir {
    log(.info, "Using existing source packages: \(dir)")
  }

  // Build
  log(.info, "Building PreviewHost...")
  let builder = BuildRunner()
  let appPath: String
  do {
    appPath = try builder.build(
      projectPath: workspacePath == nil ? projectPath : nil,
      workspacePath: workspacePath,
      scheme: "PreviewHost",
      simulatorUDID: simUDID,
      derivedDataPath: derivedDataPath,
      clonedSourcePackagesDirPath: clonedSourcePackagesDir,
      isVerbose: args.isVerbose
    )
  } catch {
    log(.error, "\(error)")
    cleanupAndExit(1)
  }
  log(.success, "Build completed")

  // Install and launch
  log(.info, "Installing and launching...")
  let bundleID = "com.preview.host"

  sim.terminate(udid: simUDID, bundleID: bundleID)

  do {
    try sim.install(udid: simUDID, appPath: appPath)
  } catch {
    log(.error, "\(error)")
    cleanupAndExit(1)
  }

  // Open Simulator.app
  let openProcess = Process()
  openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  openProcess.arguments = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", simUDID]
  do {
    try openProcess.run()
    openProcess.waitUntilExit()
  } catch {
    log(.warning, "Failed to open Simulator.app: \(error)")
  }
  Thread.sleep(forTimeInterval: 1)

  do {
    try sim.launch(udid: simUDID, bundleID: bundleID)
  } catch {
    log(.error, "\(error)")
    cleanupAndExit(1)
  }

  // Wait for SwiftUI layout
  Thread.sleep(forTimeInterval: 3)

  // Re-launch to bring to foreground (no-op if already running)
  do { try sim.launch(udid: simUDID, bundleID: bundleID) } catch {
    logVerbose("Re-launch (foreground): \(error)")
  }
  Thread.sleep(forTimeInterval: 1)

  // Capture screenshot
  log(.info, "Capturing screenshot...")
  let outputDir = (args.output as NSString).deletingLastPathComponent
  do {
    try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
  } catch {
    log(.error, "Failed to create output directory: \(error)")
    cleanupAndExit(1)
  }

  do {
    try sim.screenshot(udid: simUDID, outputPath: args.output)
  } catch {
    log(.error, "Build succeeded but screenshot capture failed: \(error)")
    // Exit code 2 = capture failure (distinct from exit 1 = build failure)
    cleanupAndExit(2)
  }

  sim.terminate(udid: simUDID, bundleID: bundleID)

  if fm.fileExists(atPath: args.output) {
    if
      let attrs = try? fm.attributesOfItem(atPath: args.output),
      let size = attrs[.size] as? UInt64
    {
      let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
      log(.success, "Preview captured: \(args.output) (\(sizeStr))")
    } else {
      log(.success, "Preview captured: \(args.output)")
    }
    print("")
    print("PREVIEW_PATH=\(args.output)")
    cleanupAndExit(0)
  } else {
    log(.error, "Build succeeded but screenshot file not found")
    // Exit code 2 = capture failure
    cleanupAndExit(2)
  }
}

// MARK: - Fallback generated file

/// Write a fallback _PreviewGenerated.swift by stripping #Preview and @main
/// from the start file. Avoids duplicate @main conflicts with PreviewHostApp.
func writeFallbackGenerated(from swiftFile: String, to previewDir: String) {
  let startContent: String
  do {
    startContent = try String(contentsOfFile: swiftFile, encoding: .utf8)
  } catch {
    log(.error, "Cannot read start file: \(swiftFile): \(error)")
    exit(1)
  }
  let collector = DeclarationCollector()
  let result = collector.collect(source: startContent, filePath: swiftFile)
  var output = ""
  for imp in result.imports.sorted() {
    output += "import \(imp)\n"
  }
  if !result.imports.isEmpty {
    output += "\n"
  }
  for decl in result.declarations where !decl.hasEntryPoint {
    output += decl.source
    output += "\n\n"
  }
  let genPath = (previewDir as NSString).appendingPathComponent("_PreviewGenerated.swift")
  do {
    try output.write(toFile: genPath, atomically: true, encoding: .utf8)
  } catch {
    log(.error, "Failed to write generated source: \(error)")
    exit(1)
  }
}

// MARK: - Utilities

func resolveAbsolutePath(_ path: String) -> String {
  if path.hasPrefix("/") { return path }
  let cwd = FileManager.default.currentDirectoryPath
  return (cwd as NSString).appendingPathComponent(path)
}

func findFirstXcodeproj(in directory: String) -> String? {
  let fm = FileManager.default
  let contents: [String]
  do {
    contents = try fm.contentsOfDirectory(atPath: directory)
  } catch {
    log(.warning, "Cannot list directory \(directory): \(error)")
    return nil
  }
  return contents
    .first { $0.hasSuffix(".xcodeproj") }
    .map { (directory as NSString).appendingPathComponent($0) }
}

/// Detect the app target's source directory using path-component-based
/// common prefix (fix issue #9 — string prefix was too broad).
func detectSourceDir(
  projectPath _: String,
  projectDir: String,
  swiftFile: String
) -> String? {
  // Heuristic 1: directory matching typical patterns relative to the project
  let relative = swiftFile.hasPrefix(projectDir + "/")
    ? String(swiftFile.dropFirst(projectDir.count + 1))
    : swiftFile
  let firstDir = relative.split(separator: "/").first.map(String.init)

  if let firstDir {
    let candidate = (projectDir as NSString).appendingPathComponent(firstDir)
    if FileManager.default.fileExists(atPath: candidate) {
      return candidate
    }
  }

  // Heuristic 2: walk up from the swift file until we hit project dir
  var dir = (swiftFile as NSString).deletingLastPathComponent
  while dir.hasPrefix(projectDir), dir != projectDir {
    let parent = (dir as NSString).deletingLastPathComponent
    if parent == projectDir {
      return dir
    }
    dir = parent
  }

  return nil
}

/// Find a workspace file alongside the project for better SPM resolution.
///
/// NOTE: The SourcePackages discovery logic below is intentionally duplicated
/// in scripts/preview (lines ~289-308). Keep both in sync when changing.
func findWorkspaceAlongsideProject(_ projectPath: String) -> String? {
  let projectDir = (projectPath as NSString).deletingLastPathComponent
  let fm = FileManager.default
  guard let contents = try? fm.contentsOfDirectory(atPath: projectDir) else { return nil }

  let projectName = ((projectPath as NSString).lastPathComponent as NSString)
    .deletingPathExtension

  var candidates = [String]()
  for item in contents where item.hasSuffix(".xcworkspace") {
    // Skip workspaces embedded inside .xcodeproj bundles
    if item.contains(".xcodeproj") { continue }
    candidates.append(item)
  }

  // Prefer workspace whose name matches the project (e.g., MyApp.xcworkspace for MyApp.xcodeproj)
  if let match = candidates.first(where: {
    ($0 as NSString).deletingPathExtension == projectName
  }) {
    return (projectDir as NSString).appendingPathComponent(match)
  }

  // Fall back to first non-Pods workspace
  if let fallback = candidates.first(where: { !$0.hasPrefix("Pods") }) {
    return (projectDir as NSString).appendingPathComponent(fallback)
  }

  return candidates.first.map { (projectDir as NSString).appendingPathComponent($0) }
}

/// Search for an existing cloned SourcePackages directory from prior builds.
func findClonedSourcePackagesDir(projectDir: String, projectPath: String) -> String? {
  let fm = FileManager.default

  // 1. Check workspace-adjacent SourcePackages/
  let sourcePackages = (projectDir as NSString).appendingPathComponent("SourcePackages")
  if fm.fileExists(atPath: sourcePackages) {
    return sourcePackages
  }

  // 2. Check Tuist/.build/ (Tuist 4.x SPM resolution)
  let tuistBuild = (projectDir as NSString).appendingPathComponent("Tuist/.build")
  if fm.fileExists(atPath: tuistBuild) {
    return tuistBuild
  }

  // 3. Search default DerivedData for matching project
  let projectName = ((projectPath as NSString).lastPathComponent as NSString)
    .deletingPathExtension
  let defaultDD = (NSHomeDirectory() as NSString).appendingPathComponent(
    "Library/Developer/Xcode/DerivedData"
  )
  if let items = try? fm.contentsOfDirectory(atPath: defaultDD) {
    for item in items where item.hasPrefix("\(projectName)-") {
      let candidate = (defaultDD as NSString).appendingPathComponent(item)
      let spDir = (candidate as NSString).appendingPathComponent("SourcePackages")
      if fm.fileExists(atPath: spDir) {
        return spDir
      }
    }
  }

  return nil
}

// MARK: - Preview SPM subcommand

func runPreviewSPM(_ args: PreviewSPMArgs) {
  guard !args.file.isEmpty else {
    log(.error, "No Swift file specified (--file)")
    exit(1)
  }

  verbose = args.isVerbose

  let fm = FileManager.default
  let swiftFile = resolveAbsolutePath(args.file)

  guard fm.fileExists(atPath: swiftFile) else {
    log(.error, "File not found: \(swiftFile)")
    exit(1)
  }
  let filename = (swiftFile as NSString).lastPathComponent
    .replacingOccurrences(of: ".swift", with: "")

  // Find Package.swift
  var packagePath = args.packagePath
  if packagePath.isEmpty {
    var dir = (swiftFile as NSString).deletingLastPathComponent
    while dir != "/" {
      let candidate = (dir as NSString).appendingPathComponent("Package.swift")
      logVerbose("Checking for Package.swift in: \(dir)")
      if fm.fileExists(atPath: candidate) {
        packagePath = candidate
        log(.info, "Auto-detected Package.swift: \(candidate)")
        break
      }
      dir = (dir as NSString).deletingLastPathComponent
    }
  }

  guard !packagePath.isEmpty, fm.fileExists(atPath: packagePath) else {
    log(.error, "Could not find Package.swift. Use --package <path>")
    exit(1)
  }

  packagePath = resolveAbsolutePath(packagePath)
  let packageDir = (packagePath as NSString).deletingLastPathComponent

  log(.info, "Preview: \(filename)")
  log(.info, "Package: \(packageDir)")

  // Auto-detect module from file path (Sources/ModuleName/...)
  var moduleName = args.module
  if moduleName == nil {
    let relative = swiftFile.hasPrefix(packageDir + "/")
      ? String(swiftFile.dropFirst(packageDir.count + 1))
      : swiftFile

    if let range = relative.range(of: #"Sources/([^/]+)/"#, options: .regularExpression) {
      let match = relative[range]
      let parts = match.split(separator: "/")
      if parts.count >= 2 {
        moduleName = String(parts[1])
      }
    }

    if moduleName == nil {
      logVerbose("Could not auto-detect module from path: \(relative)")
      logVerbose("Expected path pattern: Sources/<ModuleName>/...")
    }
  }

  guard let moduleName, !moduleName.isEmpty else {
    log(.error, "Could not detect module from file path. Use --module <name>")
    exit(1)
  }

  log(.info, "Module: \(moduleName)")

  // Extract preview body
  let extractor = PreviewExtractor()
  if let name = args.previewName {
    log(.info, "Selecting preview: \"\(name)\"")
  }
  let previewBody: String
  do {
    previewBody = try extractor.extract(from: swiftFile, named: args.previewName)
  } catch {
    log(.error, "\(error)")
    exit(1)
  }

  // Extract imports
  let imports = extractor.extractImports(from: swiftFile)
  log(.info, "Imports: \(imports.joined(separator: " "))")

  // Parse deployment target from Package.swift
  let deploymentTarget = SPMProjectCreator.parseDeploymentTarget(packagePath: packagePath)
  log(.info, "iOS Deployment Target: \(deploymentTarget)")

  // Find simulator
  let sim = SimulatorManager()
  let simUDID: String
  do {
    simUDID = try sim.findSimulator(name: args.simulator)
  } catch {
    log(.error, "\(error)")
    exit(1)
  }

  // Boot simulator
  do {
    try sim.boot(udid: simUDID)
  } catch {
    log(.error, "\(error)")
    exit(1)
  }

  // Create temp directory
  let tempDir = "/tmp/preview-spm-\(ProcessInfo.processInfo.processIdentifier)"
  let previewHostDir = (tempDir as NSString).appendingPathComponent("PreviewHost")
  let derivedDataPath = (tempDir as NSString).appendingPathComponent("DerivedData")
  let packageCachePath = (tempDir as NSString).appendingPathComponent("PackageCache")

  do {
    try fm.createDirectory(atPath: previewHostDir, withIntermediateDirectories: true)
  } catch {
    log(.error, "Failed to create temp directory: \(error)")
    exit(1)
  }

  /// Cleanup closure
  func cleanupAndExit(_ code: Int32) -> Never {
    if !args.keep {
      do { try fm.removeItem(atPath: tempDir) } catch {
        log(.warning, "Failed to remove temp directory \(tempDir): \(error)")
      }
    } else {
      log(.info, "Temporary project kept at: \(tempDir)")
    }
    exit(code)
  }

  // Create project
  log(.info, "Creating temporary Xcode project...")
  let creator = SPMProjectCreator()
  let projectPaths: SPMProjectCreator.ProjectPaths
  do {
    projectPaths = try creator.createProject(
      tempDir: tempDir,
      previewHostDir: previewHostDir,
      packageDir: packageDir,
      moduleName: moduleName,
      deploymentTarget: deploymentTarget,
      previewBody: previewBody,
      imports: imports
    )
  } catch {
    log(.error, "\(error)")
    cleanupAndExit(1)
  }

  // Build
  log(.info, "Building PreviewHost...")
  let builder = BuildRunner()
  let appPath: String
  do {
    appPath = try builder.build(
      projectPath: projectPaths.projectPath,
      workspacePath: nil,
      scheme: "PreviewHost",
      simulatorUDID: simUDID,
      derivedDataPath: derivedDataPath,
      packageCachePath: packageCachePath,
      isVerbose: args.isVerbose
    )
  } catch {
    log(.error, "\(error)")
    cleanupAndExit(1)
  }
  log(.success, "Build completed")

  // Install and launch
  log(.info, "Installing and launching...")
  let bundleID = "com.preview.spm.host"

  sim.terminate(udid: simUDID, bundleID: bundleID)

  do {
    try sim.install(udid: simUDID, appPath: appPath)
  } catch {
    log(.error, "\(error)")
    cleanupAndExit(1)
  }

  // Open Simulator.app
  let openProcess = Process()
  openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  openProcess.arguments = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", simUDID]
  do {
    try openProcess.run()
    openProcess.waitUntilExit()
    if openProcess.terminationStatus != 0 {
      log(.warning, "Simulator.app exited with status \(openProcess.terminationStatus)")
    }
  } catch {
    log(.warning, "Failed to open Simulator.app: \(error)")
  }
  Thread.sleep(forTimeInterval: 1)

  do {
    try sim.launch(udid: simUDID, bundleID: bundleID)
  } catch {
    log(.error, "\(error)")
    cleanupAndExit(1)
  }

  // Wait for SwiftUI layout
  Thread.sleep(forTimeInterval: 3)

  // Re-launch to bring to foreground
  do { try sim.launch(udid: simUDID, bundleID: bundleID) } catch {
    log(.warning, "Re-launch to foreground failed: \(error)")
  }
  Thread.sleep(forTimeInterval: 1)

  // Capture screenshot
  log(.info, "Capturing screenshot...")
  let outputDir = (args.output as NSString).deletingLastPathComponent
  do {
    try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
  } catch {
    log(.error, "Failed to create output directory: \(error)")
    cleanupAndExit(1)
  }

  do {
    try sim.screenshot(udid: simUDID, outputPath: args.output)
  } catch {
    log(.error, "Build succeeded but screenshot capture failed: \(error)")
    // Exit code 2 = capture failure (distinct from exit 1 = build failure)
    cleanupAndExit(2)
  }

  sim.terminate(udid: simUDID, bundleID: bundleID)

  if fm.fileExists(atPath: args.output) {
    if
      let attrs = try? fm.attributesOfItem(atPath: args.output),
      let size = attrs[.size] as? UInt64
    {
      let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
      log(.success, "Preview captured: \(args.output) (\(sizeStr))")
    } else {
      log(.success, "Preview captured: \(args.output)")
    }
    print("")
    print("PREVIEW_PATH=\(args.output)")
    cleanupAndExit(0)
  } else {
    log(.error, "Build succeeded but screenshot file not found")
    // Exit code 2 = capture failure
    cleanupAndExit(2)
  }
}

// MARK: - Entry point

guard let command = parseArgs() else {
  printUsage()
  exit(1)
}

switch command {
case .preview(let args):
  runPreview(args)
case .previewSPM(let args):
  runPreviewSPM(args)
case .resolve(let args):
  runResolve(args)
}
