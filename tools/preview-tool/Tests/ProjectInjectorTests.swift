// NOTE: This test file requires XcodeProj and PathKit to be added as dependencies
// of the PreviewToolTests target in Package.swift. Add these lines to the test target:
//
//   .product(name: "XcodeProj", package: "XcodeProj"),
//   .product(name: "PathKit", package: "XcodeProj"),
//
// Without this change, `import XcodeProj` and `import PathKit` will fail to resolve.

import Foundation
import XCTest
import XcodeProj
import PathKit

@testable import PreviewToolLib

// MARK: - ProjectInjectorTests

final class ProjectInjectorTests: XCTestCase {

  private var tmpDir: String!
  private var projectPath: String!
  private var previewHostDir: String!
  private var swiftFilePath: String!
  private let fm = FileManager.default
  private let injector = ProjectInjector()

  // MARK: Setup / Teardown

  override func setUp() {
    super.setUp()

    tmpDir = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("ProjectInjectorTests_\(UUID().uuidString)")
    try! fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

    projectPath = (tmpDir as NSString).appendingPathComponent("TestProject.xcodeproj")
    previewHostDir = (tmpDir as NSString).appendingPathComponent("PreviewHost")
    try! fm.createDirectory(atPath: previewHostDir, withIntermediateDirectories: true)

    // Create a minimal Swift file to act as the "preview file"
    swiftFilePath = (tmpDir as NSString).appendingPathComponent("ContentView.swift")
    let swiftContent = """
      import SwiftUI

      struct ContentView: View {
        var body: some View {
          Text("Hello")
        }
      }
      """
    try! swiftContent.write(toFile: swiftFilePath, atomically: true, encoding: .utf8)
  }

  override func tearDown() {
    try? fm.removeItem(atPath: tmpDir)
    super.tearDown()
  }

  // MARK: Helpers

  /// Creates a minimal Xcode project on disk with no app targets.
  private func createMinimalProject() throws {
    let mainGroup = PBXGroup(children: [], sourceTree: .group)
    let productsGroup = PBXGroup(children: [], sourceTree: .group, name: "Products")
    mainGroup.children.append(productsGroup)

    let debugConfig = XCBuildConfiguration(name: "Debug", buildSettings: [:])
    let releaseConfig = XCBuildConfiguration(name: "Release", buildSettings: [:])
    let configList = XCConfigurationList(
      buildConfigurations: [debugConfig, releaseConfig],
      defaultConfigurationName: "Debug"
    )

    let project = PBXProject(
      name: "TestProject",
      buildConfigurationList: configList,
      compatibilityVersion: "Xcode 14.0",
      preferredProjectObjectVersion: nil,
      minimizedProjectReferenceProxies: nil,
      mainGroup: mainGroup
    )

    let pbxproj = PBXProj(
      rootObject: project,
      objects: [mainGroup, productsGroup, debugConfig, releaseConfig, configList, project]
    )

    let xcodeproj = XcodeProj(workspace: XCWorkspace(), pbxproj: pbxproj)
    try xcodeproj.write(path: Path(projectPath))
  }

  /// Creates an Xcode project on disk that includes an application target with the given name.
  @discardableResult
  private func createProjectWithAppTarget(
    name: String = "TestApp",
    deploymentTarget: String? = nil,
    additionalBuildSettings: BuildSettings = [:]
  ) throws -> PBXNativeTarget {
    let mainGroup = PBXGroup(children: [], sourceTree: .group)
    let productsGroup = PBXGroup(children: [], sourceTree: .group, name: "Products")
    mainGroup.children.append(productsGroup)

    // Project-level build configurations
    let projectDebugConfig = XCBuildConfiguration(name: "Debug", buildSettings: [:])
    let projectReleaseConfig = XCBuildConfiguration(name: "Release", buildSettings: [:])
    let projectConfigList = XCConfigurationList(
      buildConfigurations: [projectDebugConfig, projectReleaseConfig],
      defaultConfigurationName: "Debug"
    )

    let project = PBXProject(
      name: "TestProject",
      buildConfigurationList: projectConfigList,
      compatibilityVersion: "Xcode 14.0",
      preferredProjectObjectVersion: nil,
      minimizedProjectReferenceProxies: nil,
      mainGroup: mainGroup
    )

    // App target build configurations
    var targetBuildSettings: BuildSettings = additionalBuildSettings
    if let dt = deploymentTarget {
      targetBuildSettings["IPHONEOS_DEPLOYMENT_TARGET"] = .string(dt)
    }

    let targetDebugConfig = XCBuildConfiguration(
      name: "Debug",
      buildSettings: targetBuildSettings
    )
    let targetReleaseConfig = XCBuildConfiguration(
      name: "Release",
      buildSettings: targetBuildSettings
    )
    let targetConfigList = XCConfigurationList(
      buildConfigurations: [targetDebugConfig, targetReleaseConfig],
      defaultConfigurationName: "Debug"
    )

    let sourcesPhase = PBXSourcesBuildPhase()

    let appTarget = PBXNativeTarget(
      name: name,
      buildConfigurationList: targetConfigList,
      buildPhases: [sourcesPhase],
      productType: .application
    )
    project.targets.append(appTarget)

    let pbxproj = PBXProj(
      rootObject: project,
      objects: [
        mainGroup, productsGroup,
        projectDebugConfig, projectReleaseConfig, projectConfigList,
        project,
        targetDebugConfig, targetReleaseConfig, targetConfigList,
        sourcesPhase,
        appTarget,
      ]
    )

    let xcodeproj = XcodeProj(workspace: XCWorkspace(), pbxproj: pbxproj)
    try xcodeproj.write(path: Path(projectPath))

    return appTarget
  }

  /// Reads the project back from disk.
  private func openProject() throws -> XcodeProj {
    try XcodeProj(path: Path(projectPath))
  }

  // MARK: 1. Basic injection

  func testBasicInjection() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let proj = try openProject()
    let previewHostTargets = proj.pbxproj.nativeTargets.filter { $0.name == "PreviewHost" }
    XCTAssertEqual(previewHostTargets.count, 1, "PreviewHost target should exist after injection")
  }

  // MARK: 2. Target has correct product type

  func testTargetHasCorrectProductType() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let proj = try openProject()
    let previewHostTarget = proj.pbxproj.nativeTargets.first { $0.name == "PreviewHost" }
    XCTAssertNotNil(previewHostTarget)
    XCTAssertEqual(previewHostTarget?.productType, .application)
  }

  // MARK: 3. PreviewHostApp.swift generated

  func testPreviewHostAppSwiftGenerated() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let hostAppPath = (previewHostDir as NSString).appendingPathComponent("PreviewHostApp.swift")
    XCTAssertTrue(fm.fileExists(atPath: hostAppPath), "PreviewHostApp.swift should be generated")

    let content = try String(contentsOfFile: hostAppPath, encoding: .utf8)
    XCTAssertTrue(content.contains("import SwiftUI"), "Should contain SwiftUI import")
    XCTAssertTrue(content.contains("@main"), "Should contain @main attribute")
    XCTAssertTrue(content.contains("PreviewHostApp"), "Should contain PreviewHostApp struct")
    XCTAssertTrue(content.contains("PreviewContent"), "Should contain PreviewContent view")
    XCTAssertTrue(content.contains("Text(\"Hello\")"), "Should contain the preview body")
  }

  // MARK: 4. Scheme created

  func testSchemeCreated() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let schemePath = (projectPath as NSString).appendingPathComponent(
      "xcshareddata/xcschemes/PreviewHost.xcscheme"
    )
    XCTAssertTrue(fm.fileExists(atPath: schemePath), "PreviewHost.xcscheme should exist")
  }

  // MARK: 5. Cleanup removes target

  func testCleanupRemovesTarget() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    // Verify target exists before cleanup
    let projBefore = try openProject()
    XCTAssertTrue(projBefore.pbxproj.nativeTargets.contains { $0.name == "PreviewHost" })

    try injector.cleanup(projectPath: projectPath)

    let projAfter = try openProject()
    let previewHostTargets = projAfter.pbxproj.nativeTargets.filter { $0.name == "PreviewHost" }
    XCTAssertEqual(previewHostTargets.count, 0, "PreviewHost target should be removed after cleanup")
  }

  // MARK: 6. Cleanup removes scheme

  func testCleanupRemovesScheme() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let schemePath = (projectPath as NSString).appendingPathComponent(
      "xcshareddata/xcschemes/PreviewHost.xcscheme"
    )
    XCTAssertTrue(fm.fileExists(atPath: schemePath), "Scheme should exist before cleanup")

    try injector.cleanup(projectPath: projectPath)

    XCTAssertFalse(fm.fileExists(atPath: schemePath), "Scheme should be deleted after cleanup")
  }

  // MARK: 6b. Cleanup removes orphaned objects (no leaks)

  /// Cleanup must cascade-delete every object the inject created — build phases,
  /// build files, configurations, the configuration list, target dependencies +
  /// proxies, package product deps, and the `PreviewHost.app` product reference
  /// (including its slot in the Products group). Without this, repeated
  /// inject/cleanup cycles leak objects into the pbxproj and the project file
  /// grows without bound.
  func testCleanupLeavesNoOrphanedObjects() throws {
    try createMinimalProject()

    // Run inject + cleanup three times; nothing PreviewHost-related must
    // survive any cleanup pass.
    for _ in 0..<3 {
      try injector.inject(
        swiftFile: swiftFilePath,
        projectPath: projectPath,
        targetName: nil,
        previewHostDir: previewHostDir,
        previewBody: "Text(\"Hello\")",
        imports: ["SwiftUI"]
      )
      try injector.cleanup(projectPath: projectPath)

      let pbxproj = try openProject().pbxproj

      XCTAssertEqual(
        pbxproj.nativeTargets.filter { $0.name == "PreviewHost" }.count,
        0,
        "No PreviewHost targets should remain after cleanup"
      )
      XCTAssertFalse(
        pbxproj.fileReferences.contains { $0.path == "PreviewHost.app" },
        "No PreviewHost.app product references should remain after cleanup"
      )
      XCTAssertFalse(
        pbxproj.groups.contains { $0.name == "PreviewHost" || $0.path == "PreviewHost" },
        "No PreviewHost groups should remain after cleanup"
      )
      XCTAssertFalse(
        pbxproj.buildConfigurations.contains {
          $0.buildSettings["PRODUCT_NAME"]?.stringValue == "PreviewHost"
        },
        "No PreviewHost build configurations should remain after cleanup"
      )
      // Source files generated by inject reference paths under previewHostDir;
      // those refs must also be gone.
      XCTAssertFalse(
        pbxproj.fileReferences.contains {
          ($0.name ?? "") == "PreviewHostApp.swift" ||
            ($0.path ?? "").hasSuffix("/PreviewHostApp.swift")
        },
        "No PreviewHostApp.swift file refs should remain after cleanup"
      )
    }
  }

  // MARK: 7. Idempotent injection

  func testIdempotentInjection() throws {
    try createMinimalProject()

    // Inject twice
    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"World\")",
      imports: ["SwiftUI"]
    )

    let proj = try openProject()
    let previewHostTargets = proj.pbxproj.nativeTargets.filter { $0.name == "PreviewHost" }
    XCTAssertEqual(previewHostTargets.count, 1, "Should have exactly one PreviewHost target after double injection")
  }

  // MARK: 8. Deployment target propagated

  func testDeploymentTargetPropagated() throws {
    try createProjectWithAppTarget(name: "TestApp", deploymentTarget: "16.0")

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: "TestApp",
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let proj = try openProject()
    let previewHostTarget = proj.pbxproj.nativeTargets.first { $0.name == "PreviewHost" }
    XCTAssertNotNil(previewHostTarget)

    let configs = previewHostTarget?.buildConfigurationList?.buildConfigurations ?? []
    XCTAssertFalse(configs.isEmpty, "PreviewHost should have build configurations")

    for config in configs {
      let dt = config.buildSettings["IPHONEOS_DEPLOYMENT_TARGET"]
      XCTAssertNotNil(dt, "IPHONEOS_DEPLOYMENT_TARGET should be set on \(config.name)")
      // The injector looks at dependency targets first, then falls back to app target.
      // When targetName matches an app target and there are no framework dependencies,
      // the fallback is to the app target's deployment target.
      XCTAssertEqual(
        dt?.stringValue, "16.0",
        "PreviewHost should inherit deployment target from app target"
      )
    }
  }

  // MARK: 9. Import statements in generated app

  func testImportStatementsInGeneratedApp() throws {
    try createMinimalProject()

    let imports = ["SwiftUI", "Foundation", "Combine"]

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: imports
    )

    let hostAppPath = (previewHostDir as NSString).appendingPathComponent("PreviewHostApp.swift")
    let content = try String(contentsOfFile: hostAppPath, encoding: .utf8)

    for imp in imports {
      XCTAssertTrue(
        content.contains("import \(imp)"),
        "Generated app should contain 'import \(imp)'"
      )
    }
  }

  // MARK: 10. App target module excluded from imports

  func testAppTargetModuleExcludedFromImports() throws {
    try createProjectWithAppTarget(name: "MyApp")

    // When the swift file is in an app target directory and targetName matches the app,
    // the import for the app module itself should be skipped.
    let appDir = (tmpDir as NSString).appendingPathComponent("MyApp")
    try fm.createDirectory(atPath: appDir, withIntermediateDirectories: true)
    let appSwiftFile = (appDir as NSString).appendingPathComponent("SomeView.swift")
    try "struct SomeView {}".write(toFile: appSwiftFile, atomically: true, encoding: .utf8)

    try injector.inject(
      swiftFile: appSwiftFile,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "SomeView()",
      imports: ["SwiftUI", "MyApp"]
    )

    let hostAppPath = (previewHostDir as NSString).appendingPathComponent("PreviewHostApp.swift")
    let content = try String(contentsOfFile: hostAppPath, encoding: .utf8)

    XCTAssertTrue(content.contains("import SwiftUI"), "SwiftUI import should be present")
    XCTAssertFalse(
      content.contains("import MyApp"),
      "App target module import should be excluded when file belongs to that target"
    )
  }

  // MARK: 11. PreviewHost sources added

  func testPreviewHostSourcesAdded() throws {
    try createMinimalProject()

    // Place additional Swift files in the previewHostDir before injection
    let extraFile1 = (previewHostDir as NSString).appendingPathComponent("ResolvedTypes.swift")
    try "struct ResolvedType {}".write(toFile: extraFile1, atomically: true, encoding: .utf8)

    let extraFile2 = (previewHostDir as NSString).appendingPathComponent("Helpers.swift")
    try "func helper() {}".write(toFile: extraFile2, atomically: true, encoding: .utf8)

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let proj = try openProject()
    let previewHostTarget = proj.pbxproj.nativeTargets.first { $0.name == "PreviewHost" }
    XCTAssertNotNil(previewHostTarget)

    let sourcesPhase = try previewHostTarget?.sourcesBuildPhase()
    let sourceFiles = sourcesPhase?.files ?? []

    // Should have at least the pre-existing files plus the generated PreviewHostApp.swift
    // The pre-existing files (ResolvedTypes.swift, Helpers.swift) were in the directory
    // before injection. The injection also generates PreviewHostApp.swift.
    let sourceFileNames = sourceFiles.compactMap { $0.file?.name }
    XCTAssertTrue(
      sourceFileNames.contains("ResolvedTypes.swift"),
      "ResolvedTypes.swift should be added as a build phase file"
    )
    XCTAssertTrue(
      sourceFileNames.contains("Helpers.swift"),
      "Helpers.swift should be added as a build phase file"
    )
    XCTAssertTrue(
      sourceFileNames.contains("PreviewHostApp.swift"),
      "PreviewHostApp.swift should be added as a build phase file"
    )
  }

  // MARK: 12. Invalid project path

  func testInvalidProjectPath() throws {
    let bogusPath = (tmpDir as NSString).appendingPathComponent("DoesNotExist.xcodeproj")

    XCTAssertThrowsError(
      try injector.inject(
        swiftFile: swiftFilePath,
        projectPath: bogusPath,
        targetName: nil,
        previewHostDir: previewHostDir,
        previewBody: "Text(\"Hello\")",
        imports: ["SwiftUI"]
      )
    ) { error in
      guard let injectorError = error as? InjectorError else {
        XCTFail("Expected InjectorError but got \(type(of: error))")
        return
      }
      if case .projectOpenFailed = injectorError {
        // Expected
      } else {
        XCTFail("Expected .projectOpenFailed but got \(injectorError)")
      }
    }
  }

  // MARK: 13. Preview body with special characters

  func testPreviewBodyWithSpecialCharacters() throws {
    try createMinimalProject()

    let previewBody = """
      VStack {
        Text("Hello \\"World\\"")
        Text("Line1\\nLine2")
        Text("Path: C:\\\\Users\\\\test")
      }
      """

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: previewBody,
      imports: ["SwiftUI"]
    )

    let hostAppPath = (previewHostDir as NSString).appendingPathComponent("PreviewHostApp.swift")
    XCTAssertTrue(fm.fileExists(atPath: hostAppPath), "PreviewHostApp.swift should be generated")

    let content = try String(contentsOfFile: hostAppPath, encoding: .utf8)
    XCTAssertTrue(content.contains("VStack"), "Should contain VStack from preview body")
    XCTAssertTrue(content.contains("PreviewContent"), "Should contain PreviewContent struct")
    // The body should be present with its special characters preserved
    XCTAssertTrue(
      content.contains("\\\"World\\\""),
      "Should preserve escaped quotes in preview body"
    )
  }

  // MARK: - Additional integration tests

  func testCleanupWithInvalidProjectPathThrows() throws {
    let bogusPath = (tmpDir as NSString).appendingPathComponent("Nonexistent.xcodeproj")

    XCTAssertThrowsError(
      try injector.cleanup(projectPath: bogusPath)
    ) { error in
      guard let injectorError = error as? InjectorError else {
        XCTFail("Expected InjectorError but got \(type(of: error))")
        return
      }
      if case .projectOpenFailed = injectorError {
        // Expected
      } else {
        XCTFail("Expected .projectOpenFailed but got \(injectorError)")
      }
    }
  }

  func testCleanupOnProjectWithNoPreviewHost() throws {
    try createMinimalProject()

    // Cleanup on a project that was never injected should not throw
    XCTAssertNoThrow(try injector.cleanup(projectPath: projectPath))
  }

  func testPreviewHostBuildSettings() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let proj = try openProject()
    let previewHostTarget = proj.pbxproj.nativeTargets.first { $0.name == "PreviewHost" }
    let configs = previewHostTarget?.buildConfigurationList?.buildConfigurations ?? []
    XCTAssertFalse(configs.isEmpty)

    for config in configs {
      let settings = config.buildSettings
      XCTAssertEqual(settings["PRODUCT_NAME"]?.stringValue, "PreviewHost")
      XCTAssertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"]?.stringValue, "com.preview.host")
      XCTAssertEqual(settings["SWIFT_VERSION"]?.stringValue, "5.0")
      XCTAssertEqual(settings["SDKROOT"]?.stringValue, "iphoneos")
    }
  }

  func testDefaultDeploymentTargetWhenNoAppTarget() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let proj = try openProject()
    let previewHostTarget = proj.pbxproj.nativeTargets.first { $0.name == "PreviewHost" }
    let configs = previewHostTarget?.buildConfigurationList?.buildConfigurations ?? []

    for config in configs {
      let dt = config.buildSettings["IPHONEOS_DEPLOYMENT_TARGET"]
      XCTAssertEqual(
        dt?.stringValue, "17.0",
        "Should default to 17.0 when no app target provides a deployment target"
      )
    }
  }

  func testPreviewHostAddedToProjectTargets() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let proj = try openProject()
    let project = proj.pbxproj.projects.first
    XCTAssertNotNil(project)

    let targetNames = project?.targets.compactMap { ($0 as? PBXNativeTarget)?.name } ?? []
    XCTAssertTrue(
      targetNames.contains("PreviewHost"),
      "PreviewHost should be listed in the project's targets"
    )
  }

  func testPreviewHostGroupCreated() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let proj = try openProject()
    let rootGroup = try proj.pbxproj.rootGroup()
    let previewGroup = rootGroup?.children.first {
      $0.name == "PreviewHost" || $0.path == "PreviewHost"
    }
    XCTAssertNotNil(previewGroup, "A PreviewHost group should be created in the project")
  }

  func testCleanupRemovesPreviewHostGroup() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    try injector.cleanup(projectPath: projectPath)

    let proj = try openProject()
    let rootGroup = try proj.pbxproj.rootGroup()
    let previewGroup = rootGroup?.children.first {
      $0.name == "PreviewHost" || $0.path == "PreviewHost"
    }
    XCTAssertNil(previewGroup, "PreviewHost group should be removed after cleanup")
  }

  func testProductReferenceAddedToProductsGroup() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let proj = try openProject()
    let rootGroup = try proj.pbxproj.rootGroup()
    let productsGroup = rootGroup?.children.first {
      $0.name == "Products"
    } as? PBXGroup

    XCTAssertNotNil(productsGroup)
    let productRef = productsGroup?.children.first {
      ($0 as? PBXFileReference)?.path == "PreviewHost.app"
    }
    XCTAssertNotNil(productRef, "PreviewHost.app product reference should be in Products group")
  }

  func testBuildPhasesPresent() throws {
    try createMinimalProject()

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: "Text(\"Hello\")",
      imports: ["SwiftUI"]
    )

    let proj = try openProject()
    let previewHostTarget = proj.pbxproj.nativeTargets.first { $0.name == "PreviewHost" }
    XCTAssertNotNil(previewHostTarget)

    let phases = previewHostTarget?.buildPhases ?? []
    let hasSources = phases.contains { $0 is PBXSourcesBuildPhase }
    let hasFrameworks = phases.contains { $0 is PBXFrameworksBuildPhase }
    let hasResources = phases.contains { $0 is PBXResourcesBuildPhase }

    XCTAssertTrue(hasSources, "PreviewHost should have a sources build phase")
    XCTAssertTrue(hasFrameworks, "PreviewHost should have a frameworks build phase")
    XCTAssertTrue(hasResources, "PreviewHost should have a resources build phase")
  }

  func testGeneratedAppStructure() throws {
    try createMinimalProject()

    let previewBody = """
      VStack {
        Text("Line 1")
        Text("Line 2")
      }
      """

    try injector.inject(
      swiftFile: swiftFilePath,
      projectPath: projectPath,
      targetName: nil,
      previewHostDir: previewHostDir,
      previewBody: previewBody,
      imports: ["SwiftUI"]
    )

    let hostAppPath = (previewHostDir as NSString).appendingPathComponent("PreviewHostApp.swift")
    let content = try String(contentsOfFile: hostAppPath, encoding: .utf8)

    // Verify the overall structure: @main App containing WindowGroup with PreviewContent
    XCTAssertTrue(content.contains("@main"))
    XCTAssertTrue(content.contains("struct PreviewHostApp: App"))
    XCTAssertTrue(content.contains("WindowGroup"))
    XCTAssertTrue(content.contains("PreviewContent()"))
    XCTAssertTrue(content.contains("struct PreviewContent: View"))
    // The multiline body should be indented inside PreviewContent
    XCTAssertTrue(content.contains("VStack"))
    XCTAssertTrue(content.contains("Line 1"))
    XCTAssertTrue(content.contains("Line 2"))
  }
}
