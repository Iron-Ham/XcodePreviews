import Foundation

// MARK: - SimulatorError

public enum SimulatorError: Error, CustomStringConvertible {
  case notFound(name: String)
  case bootFailed(String)
  case installFailed(String)
  case launchFailed(String)
  case screenshotFailed(String)
  case simctlFailed(String)

  // MARK: Public

  public var description: String {
    switch self {
    case .notFound(let name):
      "Simulator not found: \(name)"
    case .bootFailed(let msg):
      "Failed to boot simulator: \(msg)"
    case .installFailed(let msg):
      "Failed to install app: \(msg)"
    case .launchFailed(let msg):
      "Failed to launch app: \(msg)"
    case .screenshotFailed(let msg):
      "Failed to capture screenshot: \(msg)"
    case .simctlFailed(let msg):
      "simctl error: \(msg)"
    }
  }
}

// MARK: - SimulatorManager

public struct SimulatorManager {

  // MARK: Public

  public init() {}

  /// Find a simulator UDID by device name, preferring the latest runtime version.
  public func findSimulator(name: String) throws -> String {
    let (output, _, _) = try runSimctl(["list", "devices", "available", "-j"])

    guard
      let data = output.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let devices = json["devices"] as? [String: [[String: Any]]]
    else {
      throw SimulatorError.simctlFailed("Could not parse device list")
    }

    // Collect all matching devices with their runtime version
    var matches = [(udid: String, runtime: String)]()

    for (runtime, deviceList) in devices {
      for device in deviceList {
        guard
          let deviceName = device["name"] as? String,
          let udid = device["udid"] as? String,
          let isAvailable = device["isAvailable"] as? Bool,
          isAvailable,
          deviceName == name
        else { continue }
        matches.append((udid: udid, runtime: runtime))
      }
    }

    guard !matches.isEmpty else {
      throw SimulatorError.notFound(name: name)
    }

    // Sort by runtime version descending to pick the latest
    matches.sort { a, b in
      compareVersions(extractVersion(from: a.runtime), extractVersion(from: b.runtime))
    }

    return matches[0].udid
  }

  /// Boot a simulator. Succeeds silently if already booted.
  public func boot(udid: String) throws {
    do {
      try runSimctlChecked(["boot", udid])
    } catch SimulatorError.simctlFailed(let msg) {
      // "Unable to boot device in current state: Booted" is fine
      if msg.contains("Booted") || msg.contains("already booted") {
        return
      }
      throw SimulatorError.bootFailed(msg)
    }
  }

  public func install(udid: String, appPath: String) throws {
    do {
      try runSimctlChecked(["install", udid, appPath])
    } catch SimulatorError.simctlFailed(let msg) {
      throw SimulatorError.installFailed(msg)
    }
  }

  public func launch(udid: String, bundleID: String) throws {
    do {
      try runSimctlChecked(["launch", udid, bundleID])
    } catch SimulatorError.simctlFailed(let msg) {
      throw SimulatorError.launchFailed(msg)
    }
  }

  public func screenshot(udid: String, outputPath: String, retries: Int = 3, delaySeconds: UInt32 = 2) throws {
    var lastError: String = ""
    for attempt in 1...retries {
      do {
        try runSimctlChecked(["io", udid, "screenshot", outputPath])
        return
      } catch SimulatorError.simctlFailed(let msg) {
        lastError = msg
        if attempt < retries {
          logVerbose("Screenshot attempt \(attempt)/\(retries) failed, retrying in \(delaySeconds)s...")
          sleep(delaySeconds)
        }
      }
    }
    throw SimulatorError.screenshotFailed(lastError)
  }

  public func terminate(udid: String, bundleID: String) {
    _ = try? runSimctl(["terminate", udid, bundleID])
  }

  // MARK: Private

  /// Compare two version arrays lexicographically.
  private func compareVersions(_ a: [Int], _ b: [Int]) -> Bool {
    for i in 0..<max(a.count, b.count) {
      let av = i < a.count ? a[i] : 0
      let bv = i < b.count ? b[i] : 0
      if av != bv { return av > bv }
    }
    return false
  }

  private func extractVersion(from runtime: String) -> [Int] {
    // e.g. "com.apple.CoreSimulator.SimRuntime.iOS-18-2" → [18, 2]
    let parts = runtime.split(separator: "-")
    return parts.compactMap { Int($0) }
  }

  @discardableResult
  private func runSimctl(_ arguments: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl"] + arguments

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    try process.run()

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let stdout = String(data: outData, encoding: .utf8) ?? ""
    let stderr = String(data: errData, encoding: .utf8) ?? ""

    return (stdout, stderr, process.terminationStatus)
  }

  private func runSimctlChecked(_ arguments: [String]) throws {
    let (stdout, stderr, exitCode) = try runSimctl(arguments)
    if exitCode != 0 {
      // simctl puts errors on either stdout or stderr depending on the command
      let combined = [stdout, stderr]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      throw SimulatorError.simctlFailed(combined)
    }
  }
}
