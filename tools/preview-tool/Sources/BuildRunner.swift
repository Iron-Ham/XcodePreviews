import Foundation

// MARK: - BuildError

public enum BuildError: Error, CustomStringConvertible {
  case buildFailed(exitCode: Int32, output: String)
  case appNotFound(derivedDataPath: String)
  case processError(String)

  public var description: String {
    switch self {
    case .buildFailed(let code, let output):
      let tail = output.split(separator: "\n").suffix(20).joined(separator: "\n")
      return "xcodebuild failed (exit \(code)):\n\(tail)"

    case .appNotFound(let path):
      return "Could not find PreviewHost.app in \(path)"

    case .processError(let msg):
      return "Build process error: \(msg)"
    }
  }
}

// MARK: - BuildRunner

public struct BuildRunner {

  // MARK: Public

  public init() {}

  /// Build the PreviewHost scheme and return the path to the built .app.
  public func build(
    projectPath: String?,
    workspacePath: String?,
    scheme: String,
    simulatorUDID: String,
    derivedDataPath: String,
    packageCachePath: String? = nil,
    clonedSourcePackagesDirPath: String? = nil,
    isVerbose: Bool
  ) throws -> String {
    var arguments = [
      "build",
      "-scheme",
      scheme,
      "-destination",
      "platform=iOS Simulator,id=\(simulatorUDID)",
      "-derivedDataPath",
      derivedDataPath,
    ]

    if let cachePath = packageCachePath {
      arguments += ["-packageCachePath", cachePath]
    }

    if let clonedPath = clonedSourcePackagesDirPath {
      arguments += ["-clonedSourcePackagesDirPath", clonedPath]
    }

    if let workspace = workspacePath {
      arguments += ["-workspace", workspace]
    } else if let project = projectPath {
      arguments += ["-project", project]
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
    } catch {
      throw BuildError.processError(error.localizedDescription)
    }

    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""
    process.waitUntilExit()

    if isVerbose {
      print(output)
    }

    guard process.terminationStatus == 0 else {
      throw BuildError.buildFailed(
        exitCode: process.terminationStatus,
        output: output
      )
    }

    // Find the built .app
    let appPath = findApp(in: derivedDataPath, named: "\(scheme).app")
    guard let appPath else {
      throw BuildError.appNotFound(derivedDataPath: derivedDataPath)
    }

    return appPath
  }

  // MARK: Private

  private func findApp(in derivedData: String, named appName: String) -> String? {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: derivedData) else { return nil }

    while let path = enumerator.nextObject() as? String {
      if path.hasSuffix(appName), path.contains("Build/Products") {
        let full = (derivedData as NSString).appendingPathComponent(path)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
          return full
        }
      }
    }
    return nil
  }
}
