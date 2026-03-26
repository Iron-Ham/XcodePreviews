import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - PreviewExtractorError

public enum PreviewExtractorError: Error, CustomStringConvertible {
  case fileNotFound(String)
  case noPreviewFound(String)
  case emptyPreviewBody(String)

  public var description: String {
    switch self {
    case .fileNotFound(let path):
      "File not found: \(path)"
    case .noPreviewFound(let path):
      "No #Preview macro found in \(path)"
    case .emptyPreviewBody(let path):
      "#Preview body is empty in \(path)"
    }
  }
}

// MARK: - PreviewExtractor

public struct PreviewExtractor {

  // MARK: Public

  public init() {}

  /// Extract the body of a `#Preview { ... }` macro from a Swift file.
  /// When `named` is nil, returns the first preview. When `named` is provided,
  /// returns the preview matching that name (e.g., `#Preview("Dark Mode") { ... }`).
  /// Uses SwiftSyntax AST parsing — correctly handles string literals,
  /// comments, and nested braces (fixes issue #10).
  public func extract(from filePath: String, named: String? = nil) throws -> String {
    let source: String
    do {
      source = try String(contentsOfFile: filePath, encoding: .utf8)
    } catch {
      throw PreviewExtractorError.fileNotFound("\(filePath): \(error.localizedDescription)")
    }

    let tree = Parser.parse(source: source)
    let finder = PreviewFinder(viewMode: .sourceAccurate)
    finder.walk(tree)

    let body: String?
    if let named {
      body = finder.previews.first(where: { $0.name == named })?.body
        ?? finder.previews.first(where: { $0.name?.localizedCaseInsensitiveContains(named) == true })?.body
      if body == nil {
        let available = finder.previews.compactMap(\.name)
        let hint = available.isEmpty
          ? "No named previews found"
          : "Available: \(available.joined(separator: ", "))"
        throw PreviewExtractorError.noPreviewFound("\(filePath) (no preview named \"\(named)\"). \(hint)")
      }
    } else {
      body = finder.previews.first?.body
    }

    guard let body else {
      throw PreviewExtractorError.noPreviewFound(filePath)
    }

    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      throw PreviewExtractorError.emptyPreviewBody(filePath)
    }

    return dedent(trimmed)
  }

  /// List all `#Preview` names found in a Swift file. Unnamed previews are nil.
  public func listPreviews(from filePath: String) throws -> [(name: String?, index: Int)] {
    let source: String
    do {
      source = try String(contentsOfFile: filePath, encoding: .utf8)
    } catch {
      throw PreviewExtractorError.fileNotFound("\(filePath): \(error.localizedDescription)")
    }

    let tree = Parser.parse(source: source)
    let finder = PreviewFinder(viewMode: .sourceAccurate)
    finder.walk(tree)

    return finder.previews.enumerated().map { (index, entry) in
      (name: entry.name, index: index)
    }
  }

  /// Extract import statements from a Swift file.
  public func extractImports(from filePath: String) -> [String] {
    let source: String
    do {
      source = try String(contentsOfFile: filePath, encoding: .utf8)
    } catch {
      log(.warning, "Cannot read file for imports: \(filePath): \(error)")
      return []
    }
    let tree = Parser.parse(source: source)
    let visitor = ImportCollector(viewMode: .sourceAccurate)
    visitor.walk(tree)
    return visitor.imports.sorted()
  }

  /// Extract types referenced by a source fragment (e.g. preview body).
  /// Used to seed declaration-level BFS from `#Preview { MyView() }`.
  public func extractReferencedTypes(fromSource source: String) -> Set<String> {
    let tree = Parser.parse(source: source)
    let visitor = DependencyVisitor(viewMode: .sourceAccurate)
    visitor.walk(tree)
    return visitor.referencedTypes
  }

  // MARK: Private

  /// Remove common leading whitespace from all lines.
  private func dedent(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { String($0) }

    let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard !nonEmptyLines.isEmpty else { return text }

    let minIndent = nonEmptyLines.map { line in
      line.prefix(while: { $0 == " " || $0 == "\t" }).count
    }.min() ?? 0

    if minIndent == 0 { return text }

    return lines.map { line in
      if line.count >= minIndent {
        return String(line.dropFirst(minIndent))
      }
      return line
    }.joined(separator: "\n")
  }
}

// MARK: - PreviewFinder

/// Walks the AST to find all `#Preview` macro expansions and extract their
/// names and trailing closure bodies.
private final class PreviewFinder: SyntaxVisitor {
  struct Entry {
    let name: String?
    let body: String
  }

  var previews = [Entry]()

  override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
    if node.macroName.text == "Preview" {
      if let closure = node.trailingClosure {
        let body = closure.statements.trimmedDescription
        let name = extractPreviewName(from: node.arguments)
        previews.append(Entry(name: name, body: body))
      }
    }
    return .skipChildren
  }

  override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.macroName.text == "Preview" {
      if let closure = node.trailingClosure {
        let body = closure.statements.trimmedDescription
        let name = extractPreviewName(from: node.arguments)
        previews.append(Entry(name: name, body: body))
      }
    }
    return .skipChildren
  }

  /// Extract the preview name from the first string literal argument, if any.
  /// e.g., `#Preview("Dark Mode") { ... }` → "Dark Mode"
  private func extractPreviewName(from arguments: LabeledExprListSyntax) -> String? {
    guard let firstArg = arguments.first,
          firstArg.label == nil,
          let stringLiteral = firstArg.expression.as(StringLiteralExprSyntax.self)
    else { return nil }
    // Collect text segments, ignoring interpolation
    return stringLiteral.segments.compactMap { segment -> String? in
      if case .stringSegment(let text) = segment {
        return text.content.text
      }
      return nil
    }.joined()
  }
}

// MARK: - ImportCollector

/// Collects import module names from the AST.
private final class ImportCollector: SyntaxVisitor {
  var imports = [String]()

  override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
    // Use only the first path component (the module name).
    // e.g., `import enum AppFeature.GmailFilter` → "AppFeature"
    if let module = node.path.first?.name.text {
      imports.append(module)
    }
    return .skipChildren
  }
}
