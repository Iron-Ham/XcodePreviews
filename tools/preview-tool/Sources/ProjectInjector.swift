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

    // Create PreviewHost target
    let previewTarget = try createTarget(
      in: pbxproj,
      deploymentTarget: deploymentTarget
    )
    log(.info, "Created PreviewHost target")

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

    // Forward SPM package product dependencies
    previewTarget.packageProductDependencies = previewTarget.packageProductDependencies ?? []
    var seenPackages = Set<String>()

    for dep in depTargets {
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

    if !seenPackages.isEmpty {
      log(.info, "Added \(seenPackages.count) SPM package dependencies")
    }

    // Find and add resource bundle targets
    try addResourceBundles(
      to: previewTarget,
      depTargets: depTargets,
      projectName: (projectPath as NSString).lastPathComponent
        .replacingOccurrences(of: ".xcodeproj", with: ""),
      pbxproj: pbxproj
    )

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
        buildConfiguration: "Debug"
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
    // Remove target
    if let existing = pbxproj.nativeTargets.first(where: { $0.name == "PreviewHost" }) {
      pbxproj.delete(object: existing)
    }
    // Remove group
    if
      let rootGroup = try? pbxproj.rootGroup(),
      let previewGroup = rootGroup.children.first(where: {
        $0.name == "PreviewHost" || $0.path == "PreviewHost"
      })
    {
      rootGroup.children.removeAll { $0 === previewGroup }
    }
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

    return pbxproj.nativeTargets.first {
      $0.productType == .application && $0.name == firstDir
    }
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
    deploymentTarget: String
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
    ]

    let debugConfig = XCBuildConfiguration(name: "Debug", buildSettings: buildSettings)
    let releaseConfig = XCBuildConfiguration(name: "Release", buildSettings: buildSettings)
    pbxproj.add(object: debugConfig)
    pbxproj.add(object: releaseConfig)

    let configList = XCConfigurationList(
      buildConfigurations: [debugConfig, releaseConfig],
      defaultConfigurationName: "Debug"
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
    depTargets: [PBXNativeTarget],
    projectName: String,
    pbxproj: PBXProj
  ) throws {
    // Collect all transitive dependency names (BFS, index-based)
    var allDepNames = Set<String>()
    var queue = depTargets
    var queueIndex = 0
    while queueIndex < queue.count {
      let t = queue[queueIndex]
      queueIndex += 1
      guard !allDepNames.contains(t.name) else { continue }
      allDepNames.insert(t.name)
      for dep in t.dependencies {
        if let target = dep.target as? PBXNativeTarget {
          queue.append(target)
        }
      }
    }

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
