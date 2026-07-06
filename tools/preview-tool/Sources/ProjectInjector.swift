import Foundation
import PathKit
import XcodeProj

// MARK: - InjectorError

public enum InjectorError: Error, CustomStringConvertible {
  case projectOpenFailed(String)
  case noAppTarget
  case saveFailed(String)

  public var description: String {
    switch self {
    case .projectOpenFailed(let path):
      "Failed to open Xcode project: \(path)"
    case .noAppTarget:
      "No application target found in project"
    case .saveFailed(let msg):
      "Failed to save project: \(msg)"
    }
  }
}

// MARK: - ProjectInjector

public struct ProjectInjector {

  // MARK: Public

  public init() {}

  /// Inject a PreviewHost target into the project, compile the resolved files,
  /// and create a scheme. Returns the path to the generated PreviewHostApp.swift.
  public func inject(
    swiftFile: String,
    projectPath: String,
    targetName: String?,
    previewHostDir: String,
    previewBody: String,
    imports: [String]
  ) throws {
    let projPath = Path(projectPath)
    let xcodeproj: XcodeProj
    do {
      xcodeproj = try XcodeProj(path: projPath)
    } catch {
      throw InjectorError.projectOpenFailed("\(projectPath): \(error)")
    }

    let pbxproj = xcodeproj.pbxproj
    let projectDir = (projectPath as NSString).deletingLastPathComponent

    // Remove existing PreviewHost target and group
    removeExisting(from: pbxproj)

    // Detect app target
    let appTarget = detectAppTarget(
      in: pbxproj,
      swiftFile: swiftFile,
      projectDir: projectDir
    )
    if let appTarget {
      log(.info, "Detected app target: \(appTarget.name)")
    }

    // Find framework/library dependency targets
    let depTargets = findDependencyTargets(
      in: pbxproj,
      imports: imports,
      targetName: targetName
    )
    if !depTargets.isEmpty {
      log(.info, "Dependencies: \(depTargets.map(\.name).joined(separator: ", "))")
    }

    // Get deployment target
    let deploymentTarget = getDeploymentTarget(
      from: depTargets,
      appTarget: appTarget
    )
    log(.info, "Deployment target: iOS \(deploymentTarget)")

    // Determine if this is an app-target file
    let isAppTargetFile = appTarget != nil &&
      (targetName == nil || targetName?.isEmpty == true || targetName == appTarget?.name)

    // Generate the PreviewHostApp.swift
    let testableModules = Set(depTargets.map(\.name))
    let hostPath = try generateHostApp(
      in: previewHostDir,
      previewBody: previewBody,
      imports: imports,
      appTargetName: isAppTargetFile ? appTarget?.name : nil,
      testableModules: testableModules
    )
    logVerbose("Generated host app: \(hostPath)")

    // Mirror the project's configuration names so PreviewHost and SPM package
    // products build into the same <config>-<platform> products dir. Resolved
    // once here (not inside createTarget) so the scheme below can't diverge
    // from what PreviewHost's own configuration list actually contains.
    let projectConfigList = pbxproj.projects.first?.buildConfigurationList
    let rawConfigNames = projectConfigList?.buildConfigurations.map(\.name) ?? []
    let configNames = rawConfigNames.isEmpty ? ["Debug", "Release"] : rawConfigNames
    let rawDefaultConfig = projectConfigList?.defaultConfigurationName ?? configNames[0]
    let defaultConfigName = configNames.contains(rawDefaultConfig) ? rawDefaultConfig : configNames[0]
    let previewTarget = try createTarget(
      in: pbxproj,
      deploymentTarget: deploymentTarget,
      configurationNames: configNames,
      defaultConfiguration: defaultConfigName
    )
    log(.info, "Created PreviewHost target (configs: \(configNames.joined(separator: ", ")))")

    // Add PreviewHost source files (the generated app)
    let mainGroup = try pbxproj.rootGroup()
    let previewGroup = try mainGroup?.addGroup(named: "PreviewHost").first
    try addPreviewHostSources(
      to: previewTarget,
      group: previewGroup,
      previewHostDir: previewHostDir,
      pbxproj: pbxproj
    )

    // Add target dependencies + link/embed products
    let dynamicFrameworks = depTargets.filter {
      $0.productType == .framework
    }
    let hasDynamicFrameworks = !dynamicFrameworks.isEmpty

    var embedPhase: PBXCopyFilesBuildPhase?
    if hasDynamicFrameworks {
      embedPhase = PBXCopyFilesBuildPhase(
        dstSubfolderSpec: .frameworks,
        name: "Embed Frameworks"
      )
      pbxproj.add(object: embedPhase!)
      previewTarget.buildPhases.append(embedPhase!)
    }

    for dep in depTargets {
      previewTarget.dependencies.append(
        try createDependency(for: dep, in: pbxproj)
      )
      log(.info, "  Added dependency: \(dep.name)")

      if dep.productType == .staticLibrary {
        if let productRef = dep.product {
          let buildFile = PBXBuildFile(file: productRef)
          pbxproj.add(object: buildFile)
          try previewTarget.frameworksBuildPhase()?.files?.append(buildFile)
          logVerbose("  Linked static library: \(dep.name)")
        }
      } else if dep.productType == .framework {
        if let productRef = dep.product, let embedPhase {
          let buildFile = PBXBuildFile(
            file: productRef,
            settings: ["ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]]
          )
          pbxproj.add(object: buildFile)
          embedPhase.files?.append(buildFile)
          logVerbose("  Embedded framework: \(dep.name)")
        }
      }
    }

    // Collect full transitive closure of native-target dependencies (BFS)
    let allTransitiveDeps = collectTransitiveDependencies(from: depTargets)
    if allTransitiveDeps.count > depTargets.count {
      log(.info, "Transitive dependencies: \(allTransitiveDeps.map(\.name).joined(separator: ", "))")
    }

    // Forward SPM package product dependencies from ALL transitive deps
    previewTarget.packageProductDependencies = previewTarget.packageProductDependencies ?? []
    var seenPackages = Set<String>()

    for dep in allTransitiveDeps {
      for pkgDep in dep.packageProductDependencies ?? [] {
        let productName = pkgDep.productName
        guard !seenPackages.contains(productName) else { continue }
        seenPackages.insert(productName)

        let newDep = XCSwiftPackageProductDependency(productName: productName)
        newDep.package = pkgDep.package
        pbxproj.add(object: newDep)
        previewTarget.packageProductDependencies?.append(newDep)
      }
    }

    if let appTarget {
      for pkgDep in appTarget.packageProductDependencies ?? [] {
        let productName = pkgDep.productName
        guard !seenPackages.contains(productName) else { continue }
        seenPackages.insert(productName)

        let newDep = XCSwiftPackageProductDependency(productName: productName)
        newDep.package = pkgDep.package
        pbxproj.add(object: newDep)
        previewTarget.packageProductDependencies?.append(newDep)
      }
    }

    // Ensure the previewed file's OWN owning SPM package is a direct product
    // dependency of PreviewHost -- pbxproj doesn't expose nested local-package
    // edges, so a package reachable only transitively is otherwise invisible.
    if let moduleName = targetName, !moduleName.isEmpty,
       !seenPackages.contains(moduleName),
       let packageDir = findEnclosingPackageDir(for: swiftFile, projectDir: projectDir) {
      let relativePackagePath = relativePath(from: projectDir, to: packageDir)
      let priorChildren = Set(mainGroup?.children.map(\.uuid) ?? [])
      do {
        _ = try pbxproj.rootObject?.addLocalSwiftPackage(
          path: Path(relativePackagePath),
          productName: moduleName,
          targetName: previewTarget.name,
          addFileReference: true
        )
        // addLocalSwiftPackage drops the folder reference it creates at the
        // project root; move it under the PreviewHost group so `removeExisting`
        // cleans it up like everything else this injects, instead of leaking
        // a stray reference into the real project on every run.
        if
          let mainGroup,
          let newRef = mainGroup.children.first(where: { !priorChildren.contains($0.uuid) })
        {
          mainGroup.children.removeAll { $0.uuid == newRef.uuid }
          previewGroup?.children.append(newRef)
        }
        seenPackages.insert(moduleName)
        log(.info, "Added own-package dependency: \(moduleName) (\(relativePackagePath))")
      } catch {
        log(.warning, "Could not add own-package dependency for \(moduleName): \(error)")
      }
    }

    if !seenPackages.isEmpty {
      log(.info, "Added \(seenPackages.count) SPM package dependencies")
    }

    // Find and add resource bundle targets
    try addResourceBundles(
      to: previewTarget,
      allTransitiveDeps: allTransitiveDeps,
      projectName: (projectPath as NSString).lastPathComponent
        .replacingOccurrences(of: ".xcodeproj", with: ""),
      pbxproj: pbxproj
    )

    // Embed dynamically-linked SPM package frameworks. Xcode auto-embeds binary
    // XCFrameworks for our injected target, but leaves source-package dynamic
    // frameworks (BUILT_PRODUCTS_DIR/PackageFrameworks/*) unembedded -> the app
    // crashes at launch ("dyld: Library not loaded: @rpath/<Name>.framework").
    // The build "succeeds" and the capture just shows the home screen. Copy them
    // in and ad-hoc sign (the simulator doesn't enforce signatures, but keep the
    // signature valid anyway).
    let embedScript = PBXShellScriptBuildPhase(
      name: "Embed Package Frameworks",
      shellScript: """
        set -e
        SRC="${BUILT_PRODUCTS_DIR}/PackageFrameworks"
        DST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Frameworks"
        [ -d "$SRC" ] || exit 0
        mkdir -p "$DST"
        for fw in "$SRC"/*.framework; do
          [ -e "$fw" ] || continue
          name=$(basename "$fw")
          rm -rf "$DST/$name"
          cp -R "$fw" "$DST/$name"
          codesign --force --sign - --timestamp=none "$DST/$name" || echo "warning: codesign failed for $name (simulator doesn't enforce signatures, continuing)" >&2
        done
        """
    )
    pbxproj.add(object: embedScript)
    previewTarget.buildPhases.append(embedScript)

    // Save project
    do {
      try xcodeproj.write(path: projPath)
    } catch {
      throw InjectorError.saveFailed(error.localizedDescription)
    }
    log(.info, "Project saved")

    // Create scheme
    let projectFileName = projPath.lastComponent
    let buildableRef = previewTarget.createBuildableReference(projectFileName: projectFileName)
    let scheme = XCScheme(
      name: "PreviewHost",
      lastUpgradeVersion: nil,
      version: nil,
      buildAction: XCScheme.BuildAction(
        buildActionEntries: [
          XCScheme.BuildAction.Entry(
            buildableReference: buildableRef,
            buildFor: XCScheme.BuildAction.Entry.BuildFor.default
          )
        ]
      ),
      testAction: nil,
      launchAction: XCScheme.LaunchAction(
        runnable: XCScheme.Runnable(
          buildableReference: buildableRef
        ),
        buildConfiguration: defaultConfigName
      ),
      profileAction: nil,
      analyzeAction: nil,
      archiveAction: nil
    )

    let schemesDir = projPath + "xcshareddata/xcschemes"
    try? schemesDir.mkpath()
    try scheme.write(path: schemesDir + "PreviewHost.xcscheme", override: true)
    log(.info, "Created scheme: PreviewHost")
  }

  /// Remove PreviewHost target and associated groups/schemes.
  public func cleanup(projectPath: String) throws {
    let projPath = Path(projectPath)
    let xcodeproj: XcodeProj
    do {
      xcodeproj = try XcodeProj(path: projPath)
    } catch {
      throw InjectorError.projectOpenFailed("\(projectPath): \(error)")
    }

    removeExisting(from: xcodeproj.pbxproj)

    do {
      try xcodeproj.write(path: projPath)
    } catch {
      throw InjectorError.saveFailed(error.localizedDescription)
    }

    // Remove scheme file
    let schemePath = projPath + "xcshareddata/xcschemes/PreviewHost.xcscheme"
    try? schemePath.delete()
  }

  // MARK: Private

  private func removeExisting(from pbxproj: PBXProj) {
    // Remove ALL PreviewHost targets — prior buggy cleanups may have left
    // multiple leaked copies, and each new run adds another.
    let targets = pbxproj.nativeTargets.filter { $0.name == "PreviewHost" }
    let productsGroup = (try? pbxproj.rootGroup())?.children.first(where: {
      $0.name == "Products" || $0.path == "Products"
    }) as? PBXGroup

    for target in targets {
      // Build phases own their build files.
      for phase in target.buildPhases {
        for buildFile in phase.files ?? [] {
          pbxproj.delete(object: buildFile)
        }
        pbxproj.delete(object: phase)
      }

      // Configuration list owns its individual configurations.
      if let configList = target.buildConfigurationList {
        for config in configList.buildConfigurations {
          pbxproj.delete(object: config)
        }
        pbxproj.delete(object: configList)
      }

      // Target dependencies + their container item proxies.
      for dep in target.dependencies {
        if let proxy = dep.targetProxy {
          pbxproj.delete(object: proxy)
        }
        pbxproj.delete(object: dep)
      }

      // SPM package product dependency stubs forwarded onto the target.
      for pkgDep in target.packageProductDependencies ?? [] {
        pbxproj.delete(object: pkgDep)
      }

      // Product reference (PreviewHost.app) — also drop from Products group.
      if let product = target.product {
        productsGroup?.children.removeAll { $0 === product }
        pbxproj.delete(object: product)
      }

      // Drop from project's targets list, then delete the target itself.
      for project in pbxproj.projects {
        project.targets.removeAll { $0 === target }
      }
      pbxproj.delete(object: target)
    }

    // Remove ALL "PreviewHost" groups (not just the first) plus their children.
    if let rootGroup = try? pbxproj.rootGroup() {
      removePreviewHostGroups(under: rootGroup, pbxproj: pbxproj)

      // Scrub orphan PreviewHost.app file refs left behind in Products from
      // earlier broken cleanups.
      if let productsGroup {
        let orphans = productsGroup.children.filter {
          ($0 as? PBXFileReference)?.path == "PreviewHost.app"
        }
        for orphan in orphans {
          productsGroup.children.removeAll { $0 === orphan }
          pbxproj.delete(object: orphan)
        }
      }
    }
  }

  private func removePreviewHostGroups(under group: PBXGroup, pbxproj: PBXProj) {
    let matches = group.children.compactMap { $0 as? PBXGroup }
      .filter { $0.name == "PreviewHost" || $0.path == "PreviewHost" }

    for match in matches {
      deleteGroupRecursively(match, pbxproj: pbxproj)
      group.children.removeAll { $0 === match }
    }

    for child in group.children {
      if let subgroup = child as? PBXGroup {
        removePreviewHostGroups(under: subgroup, pbxproj: pbxproj)
      }
    }
  }

  private func deleteGroupRecursively(_ group: PBXGroup, pbxproj: PBXProj) {
    for child in group.children {
      if let subgroup = child as? PBXGroup {
        deleteGroupRecursively(subgroup, pbxproj: pbxproj)
      } else {
        pbxproj.delete(object: child)
      }
    }
    pbxproj.delete(object: group)
  }

  private func detectAppTarget(
    in pbxproj: PBXProj,
    swiftFile: String,
    projectDir: String
  ) -> PBXNativeTarget? {
    // Try matching via source build phase file references
    for target in pbxproj.nativeTargets {
      guard target.productType == .application else { continue }

      if let sourceBuildPhase = try? target.sourcesBuildPhase() {
        for file in sourceBuildPhase.files ?? [] {
          if
            let fileRef = file.file,
            let fullPath = try? fileRef.fullPath(sourceRoot: Path(projectDir)),
            fullPath.string == swiftFile
          {
            return target
          }
        }
      }

      // Check file_system_synchronized_groups (Xcode 16+)
      for group in target.fileSystemSynchronizedGroups ?? [] {
        if let groupPath = group.path {
          let candidate = (projectDir as NSString).appendingPathComponent(groupPath)
          if swiftFile.hasPrefix(candidate) {
            return target
          }
        }
      }
    }

    // Fallback: match by directory convention
    let relative = swiftFile.hasPrefix(projectDir + "/")
      ? String(swiftFile.dropFirst(projectDir.count + 1))
      : swiftFile
    let firstDir = relative.split(separator: "/").first.map(String.init) ?? ""

    if let byDir = pbxproj.nativeTargets.first(where: {
      $0.productType == .application && $0.name == firstDir
    }) {
      return byDir
    }

    // Final fallback: the sole application target. SPM-package-heavy projects
    // (e.g. a thin app shell with all real code in local packages) put the
    // previewed file under a package dir, not under any app target's source
    // dir, so the heuristics above miss it -- but we still need the app
    // target's package product dependencies forwarded to PreviewHost.
    let appTargets = pbxproj.nativeTargets.filter { $0.productType == .application }
    if appTargets.count > 1 {
      log(.warning, "Multiple application targets (\(appTargets.map(\.name).joined(separator: ", "))) and none matched by source/directory heuristics -- app-target package dependencies won't be forwarded. Pass --target to disambiguate.")
    }
    return appTargets.count == 1 ? appTargets.first : nil
  }

  /// Walk up from `filePath` to find the nearest ancestor directory containing a
  /// `Package.swift` -- i.e. the SPM package that owns the previewed file.
  /// Bounded at the project directory's own parent so a sibling `Packages/`
  /// layout still resolves, without walking all the way to the filesystem
  /// root and picking up an unrelated ancestor manifest.
  private func findEnclosingPackageDir(for filePath: String, projectDir: String) -> String? {
    let boundary = (projectDir as NSString).deletingLastPathComponent
    var dir = (filePath as NSString).deletingLastPathComponent
    while dir.count > boundary.count {
      let manifest = (dir as NSString).appendingPathComponent("Package.swift")
      if FileManager.default.fileExists(atPath: manifest) { return dir }
      dir = (dir as NSString).deletingLastPathComponent
    }
    return nil
  }

  /// Relative path from `base` to `target`, using `../` to climb out when
  /// `target` isn't nested under `base` -- unlike a prefix-strip, this stays
  /// relative (required by `addLocalSwiftPackage`) for sibling directories too.
  private func relativePath(from base: String, to target: String) -> String {
    let baseComponents = base.split(separator: "/").map(String.init)
    let targetComponents = target.split(separator: "/").map(String.init)
    var shared = 0
    while
      shared < baseComponents.count, shared < targetComponents.count,
      baseComponents[shared] == targetComponents[shared]
    {
      shared += 1
    }
    let ups = Array(repeating: "..", count: baseComponents.count - shared)
    return (ups + targetComponents[shared...]).joined(separator: "/")
  }

  private func findDependencyTargets(
    in pbxproj: PBXProj,
    imports: [String],
    targetName: String?
  ) -> [PBXNativeTarget] {
    var depTargets = [PBXNativeTarget]()

    for imp in imports {
      if let target = pbxproj.nativeTargets.first(where: { $0.name == imp }) {
        depTargets.append(target)
      }
    }

    if let targetName, !depTargets.contains(where: { $0.name == targetName }) {
      if let mainTarget = pbxproj.nativeTargets.first(where: { $0.name == targetName }) {
        depTargets.append(mainTarget)
      }
    }

    return depTargets
  }

  /// BFS walk to collect all transitive native-target dependencies.
  private func collectTransitiveDependencies(
    from roots: [PBXNativeTarget]
  ) -> [PBXNativeTarget] {
    var visited = Set<String>()
    var result = [PBXNativeTarget]()
    var queue = roots
    var queueIndex = 0
    while queueIndex < queue.count {
      let t = queue[queueIndex]
      queueIndex += 1
      let key = t.uuid
      guard !visited.contains(key) else { continue }
      visited.insert(key)
      result.append(t)
      for dep in t.dependencies {
        if let target = dep.target as? PBXNativeTarget {
          queue.append(target)
        }
      }
    }
    return result
  }

  private func getDeploymentTarget(
    from depTargets: [PBXNativeTarget],
    appTarget: PBXNativeTarget?
  ) -> String {
    let refTarget = depTargets.first ?? appTarget
    if let configs = refTarget?.buildConfigurationList?.buildConfigurations {
      for config in configs {
        if
          let setting = config.buildSettings["IPHONEOS_DEPLOYMENT_TARGET"],
          let dt = setting.stringValue
        {
          return dt
        }
      }
    }
    return "17.0"
  }

  private func generateHostApp(
    in previewHostDir: String,
    previewBody: String,
    imports: [String],
    appTargetName: String?,
    testableModules: Set<String> = []
  ) throws -> String {
    let fm = FileManager.default
    try fm.createDirectory(atPath: previewHostDir, withIntermediateDirectories: true)

    var importStatements = ""
    for imp in imports {
      // When compiling app-target sources directly, skip importing the app module
      if let appName = appTargetName, imp == appName { continue }
      if testableModules.contains(imp) {
        importStatements += "@testable import \(imp)\n"
      } else {
        importStatements += "import \(imp)\n"
      }
    }

    let indentedBody = previewBody
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { "        \($0)" }
      .joined(separator: "\n")

    let content = """
      // Auto-generated PreviewHost

      import SwiftUI
      \(importStatements)
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
      \(indentedBody)
          }
      }
      """

    let path = (previewHostDir as NSString).appendingPathComponent("PreviewHostApp.swift")
    try content.write(toFile: path, atomically: true, encoding: .utf8)
    return path
  }

  private func createTarget(
    in pbxproj: PBXProj,
    deploymentTarget: String,
    configurationNames: [String],
    defaultConfiguration: String
  ) throws -> PBXNativeTarget {
    let buildSettings: BuildSettings = [
      "PRODUCT_NAME": "PreviewHost",
      "PRODUCT_BUNDLE_IDENTIFIER": "com.preview.host",
      "GENERATE_INFOPLIST_FILE": "YES",
      "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
      "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
      "SWIFT_VERSION": "5.0",
      "CODE_SIGN_STYLE": "Automatic",
      "IPHONEOS_DEPLOYMENT_TARGET": .string(deploymentTarget),
      "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
      "SDKROOT": "iphoneos",
      "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    ]

    // configurationNames/defaultConfiguration are pre-resolved by the caller
    // (non-empty, defaultConfiguration guaranteed to be a member) so this
    // target's own config list can't diverge from what the caller uses
    // elsewhere (e.g. the scheme's buildConfiguration).
    let configs = configurationNames.map { name -> XCBuildConfiguration in
      let cfg = XCBuildConfiguration(name: name, buildSettings: buildSettings)
      pbxproj.add(object: cfg)
      return cfg
    }

    let configList = XCConfigurationList(
      buildConfigurations: configs,
      defaultConfigurationName: defaultConfiguration
    )
    pbxproj.add(object: configList)

    let sourcesPhase = PBXSourcesBuildPhase()
    pbxproj.add(object: sourcesPhase)

    let frameworksPhase = PBXFrameworksBuildPhase()
    pbxproj.add(object: frameworksPhase)

    let resourcesPhase = PBXResourcesBuildPhase()
    pbxproj.add(object: resourcesPhase)

    // Create product reference
    let productRef = PBXFileReference(
      sourceTree: .buildProductsDir,
      explicitFileType: "wrapper.application",
      path: "PreviewHost.app",
      includeInIndex: false
    )
    pbxproj.add(object: productRef)

    // Add to Products group
    if
      let productsGroup = try? pbxproj.rootGroup()?.children.first(where: {
        $0.name == "Products" || $0.path == "Products"
      }) as? PBXGroup
    {
      productsGroup.children.append(productRef)
    }

    let target = PBXNativeTarget(
      name: "PreviewHost",
      buildConfigurationList: configList,
      buildPhases: [sourcesPhase, frameworksPhase, resourcesPhase],
      product: productRef,
      productType: .application
    )
    pbxproj.add(object: target)

    // Add to project's targets
    if let project = pbxproj.projects.first {
      project.targets.append(target)
    }

    return target
  }

  private func addPreviewHostSources(
    to target: PBXNativeTarget,
    group: PBXGroup?,
    previewHostDir: String,
    pbxproj: PBXProj
  ) throws {
    let fm = FileManager.default
    let files: [String]
    do {
      files = try fm.contentsOfDirectory(atPath: previewHostDir)
    } catch {
      log(.warning, "Cannot list PreviewHost directory: \(error)")
      return
    }

    for fileName in files where fileName.hasSuffix(".swift") {
      let filePath = (previewHostDir as NSString).appendingPathComponent(fileName)
      let fileRef = PBXFileReference(
        sourceTree: .absolute,
        name: fileName,
        lastKnownFileType: "sourcecode.swift",
        path: filePath
      )
      pbxproj.add(object: fileRef)
      group?.children.append(fileRef)

      let buildFile = PBXBuildFile(file: fileRef)
      pbxproj.add(object: buildFile)
      try target.sourcesBuildPhase()?.files?.append(buildFile)

      logVerbose("  Added source: \(fileName)")
    }
  }

  private func createDependency(
    for dep: PBXNativeTarget,
    in pbxproj: PBXProj
  ) throws -> PBXTargetDependency {
    guard let project = pbxproj.projects.first else {
      throw InjectorError.projectOpenFailed("No project entry found in pbxproj")
    }
    let proxy = PBXContainerItemProxy(
      containerPortal: .project(project),
      remoteGlobalID: .object(dep),
      proxyType: .nativeTarget,
      remoteInfo: dep.name
    )
    pbxproj.add(object: proxy)

    let dependency = PBXTargetDependency(
      name: dep.name,
      target: dep,
      targetProxy: proxy
    )
    pbxproj.add(object: dependency)

    return dependency
  }

  private func addResourceBundles(
    to previewTarget: PBXNativeTarget,
    allTransitiveDeps: [PBXNativeTarget],
    projectName: String,
    pbxproj: PBXProj
  ) throws {
    // allTransitiveDeps is already the full transitive closure
    let allDepNames = Set(allTransitiveDeps.map(\.name))

    // Match bundle targets
    var bundleTargets = [PBXNativeTarget]()
    for target in pbxproj.nativeTargets {
      guard target.productType == .bundle else { continue }
      for depName in allDepNames {
        let patterns = [
          "\(projectName)_\(depName)", // Tuist convention
          "\(depName)_Resources", // Generic _Resources suffix
          "\(depName)Resources", // Generic Resources suffix
          depName, // Direct match
        ]
        if patterns.contains(target.name) {
          if !bundleTargets.contains(where: { $0.name == target.name }) {
            bundleTargets.append(target)
          }
          break
        }
      }
    }

    if !bundleTargets.isEmpty {
      log(.info, "Resource bundles: \(bundleTargets.map(\.name).joined(separator: ", "))")

      let resourcesPhase = previewTarget.buildPhases.first {
        $0 is PBXResourcesBuildPhase
      } as? PBXResourcesBuildPhase

      for bundle in bundleTargets {
        previewTarget.dependencies.append(
          try createDependency(for: bundle, in: pbxproj)
        )
        if let productRef = bundle.product, let resourcesPhase {
          let buildFile = PBXBuildFile(file: productRef)
          pbxproj.add(object: buildFile)
          resourcesPhase.files?.append(buildFile)
          logVerbose("  Copying bundle: \(bundle.name)")
        }
      }
    }
  }
}

// MARK: - XcodeProj helpers

extension PBXNativeTarget {
  fileprivate func createBuildableReference(projectFileName: String) -> XCScheme.BuildableReference {
    XCScheme.BuildableReference(
      referencedContainer: "container:\(projectFileName)",
      blueprint: self,
      buildableName: "\(name).app",
      blueprintName: name
    )
  }
}
