import Foundation
import XCTest

@testable import PreviewToolLib

// MARK: - PreviewExtractorExtractTests

final class PreviewExtractorExtractTests: XCTestCase {

  private let extractor = PreviewExtractor()
  private let fm = FileManager.default

  // MARK: Helper

  private func writeTempFile(content: String) -> String {
    let path = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("PreviewExtractorTest_\(UUID().uuidString).swift")
    try! content.write(toFile: path, atomically: true, encoding: .utf8)
    return path
  }

  // MARK: 1. Simple #Preview

  func testSimplePreview() throws {
    let path = writeTempFile(content: """
      #Preview {
        Text("Hello")
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path)
    XCTAssertTrue(result.contains("Text(\"Hello\")"))
  }

  // MARK: 2. Multi-line body

  func testMultiLineBody() throws {
    let path = writeTempFile(content: """
      #Preview {
        VStack {
          Text("Line 1")
          Text("Line 2")
          Image(systemName: "star")
        }
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path)
    XCTAssertTrue(result.contains("VStack"))
    XCTAssertTrue(result.contains("Text(\"Line 1\")"))
    XCTAssertTrue(result.contains("Text(\"Line 2\")"))
    XCTAssertTrue(result.contains("Image(systemName: \"star\")"))
  }

  // MARK: 3. Nested braces

  func testNestedBraces() throws {
    let path = writeTempFile(content: """
      #Preview {
        VStack {
          Button("Tap") {
            print("tapped")
          }
        }
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path)
    XCTAssertTrue(result.contains("Button(\"Tap\")"))
    XCTAssertTrue(result.contains("print(\"tapped\")"))
  }

  // MARK: 4. String interpolation

  func testStringInterpolation() throws {
    let path = writeTempFile(content: """
      #Preview {
        let count = 5
        Text("Items: \\(count)")
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path)
    XCTAssertTrue(result.contains("let count = 5"))
    XCTAssertTrue(result.contains("\\(count)"))
  }

  // MARK: 5. String with braces

  func testStringWithBraces() throws {
    let path = writeTempFile(content: """
      #Preview {
        Text("Open { and close }")
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path)
    XCTAssertTrue(result.contains("Text(\"Open { and close }\")"))
  }

  // MARK: 6. Named preview

  func testNamedPreview() throws {
    let path = writeTempFile(content: """
      #Preview("My Title") {
        Text("Named")
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path)
    XCTAssertTrue(result.contains("Text(\"Named\")"))
    // The title itself should NOT be in the extracted body
    XCTAssertFalse(result.contains("My Title"))
  }

  // MARK: 7. Multiple previews — default extracts first

  func testMultiplePreviewsDefaultExtractsFirst() throws {
    let path = writeTempFile(content: """
      #Preview("First") {
        Text("First Preview")
      }

      #Preview("Second") {
        Text("Second Preview")
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path)
    XCTAssertTrue(result.contains("First Preview"))
    XCTAssertFalse(result.contains("Second Preview"))
  }

  // MARK: 7b. Multiple previews — select by name

  func testMultiplePreviewsSelectByName() throws {
    let path = writeTempFile(content: """
      #Preview("Light Mode") {
        Text("Light")
      }

      #Preview("Dark Mode") {
        Text("Dark")
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let light = try extractor.extract(from: path, named: "Light Mode")
    XCTAssertTrue(light.contains("Text(\"Light\")"))
    XCTAssertFalse(light.contains("Text(\"Dark\")"))

    let dark = try extractor.extract(from: path, named: "Dark Mode")
    XCTAssertTrue(dark.contains("Text(\"Dark\")"))
    XCTAssertFalse(dark.contains("Text(\"Light\")"))
  }

  // MARK: 7c. Named preview — case-insensitive fallback

  func testNamedPreviewCaseInsensitiveFallback() throws {
    let path = writeTempFile(content: """
      #Preview("My Custom View") {
        Text("Found")
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path, named: "my custom")
    XCTAssertTrue(result.contains("Text(\"Found\")"))
  }

  // MARK: 7d. Named preview — not found error

  func testNamedPreviewNotFound() throws {
    let path = writeTempFile(content: """
      #Preview("Existing") {
        Text("Here")
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    XCTAssertThrowsError(try extractor.extract(from: path, named: "Nonexistent")) { error in
      let desc = "\(error)"
      XCTAssertTrue(desc.contains("Nonexistent"))
      XCTAssertTrue(desc.contains("Available: Existing"))
    }
  }

  // MARK: 7e. List previews

  func testListPreviews() throws {
    let path = writeTempFile(content: """
      #Preview("Alpha") {
        Text("A")
      }

      #Preview {
        Text("Unnamed")
      }

      #Preview("Beta") {
        Text("B")
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let list = try extractor.listPreviews(from: path)
    XCTAssertEqual(list.count, 3)
    XCTAssertEqual(list[0].name, "Alpha")
    XCTAssertNil(list[1].name)
    XCTAssertEqual(list[2].name, "Beta")
  }

  // MARK: 8. No preview found

  func testNoPreviewFound() throws {
    let path = writeTempFile(content: """
      struct MyView: View {
        var body: some View { Text("No preview") }
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    XCTAssertThrowsError(try extractor.extract(from: path)) { error in
      guard let extractorError = error as? PreviewExtractorError else {
        XCTFail("Expected PreviewExtractorError, got \(type(of: error))")
        return
      }
      if case .noPreviewFound = extractorError {
        // Expected
      } else {
        XCTFail("Expected .noPreviewFound, got \(extractorError)")
      }
    }
  }

  // MARK: 9. File not found

  func testFileNotFound() {
    let fakePath = "/nonexistent/path/\(UUID().uuidString).swift"

    XCTAssertThrowsError(try extractor.extract(from: fakePath)) { error in
      guard let extractorError = error as? PreviewExtractorError else {
        XCTFail("Expected PreviewExtractorError, got \(type(of: error))")
        return
      }
      if case .fileNotFound = extractorError {
        // Expected
      } else {
        XCTFail("Expected .fileNotFound, got \(extractorError)")
      }
    }
  }

  // MARK: 10. Empty preview body

  func testEmptyPreviewBody() throws {
    let path = writeTempFile(content: """
      #Preview {
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    XCTAssertThrowsError(try extractor.extract(from: path)) { error in
      guard let extractorError = error as? PreviewExtractorError else {
        XCTFail("Expected PreviewExtractorError, got \(type(of: error))")
        return
      }
      if case .emptyPreviewBody = extractorError {
        // Expected
      } else {
        XCTFail("Expected .emptyPreviewBody, got \(extractorError)")
      }
    }
  }

  // MARK: 11. Complex SwiftUI body

  func testComplexSwiftUIBody() throws {
    let path = writeTempFile(content: """
      #Preview {
        NavigationStack {
          List {
            ForEach(0..<5) { index in
              Text("Row \\(index)")
            }
          }
          .sheet(isPresented: .constant(false)) {
            Text("Sheet")
          }
        }
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path)
    XCTAssertTrue(result.contains("NavigationStack"))
    XCTAssertTrue(result.contains("List"))
    XCTAssertTrue(result.contains("ForEach"))
    XCTAssertTrue(result.contains(".sheet"))
  }

  // MARK: 12. Preview with trailing modifier chain

  func testPreviewWithTrailingModifiers() throws {
    let path = writeTempFile(content: """
      #Preview {
        Text("Styled")
          .padding()
          .frame(width: 100)
          .background(Color.blue)
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path)
    XCTAssertTrue(result.contains("Text(\"Styled\")"))
    XCTAssertTrue(result.contains(".padding()"))
    XCTAssertTrue(result.contains(".frame(width: 100)"))
    XCTAssertTrue(result.contains(".background(Color.blue)"))
  }

  // MARK: 13. Preview body with comments

  func testPreviewBodyWithComments() throws {
    let path = writeTempFile(content: """
      #Preview {
        // This is a line comment
        VStack {
          /* Block comment */
          Text("Commented")
        }
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path)
    XCTAssertTrue(result.contains("VStack"))
    XCTAssertTrue(result.contains("Text(\"Commented\")"))
  }

  // MARK: 14. Preview body with if/else

  func testPreviewBodyWithIfElse() throws {
    let path = writeTempFile(content: """
      #Preview {
        let showDetail = true
        if showDetail {
          Text("Detail")
        } else {
          Text("Summary")
        }
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path)
    XCTAssertTrue(result.contains("let showDetail = true"))
    XCTAssertTrue(result.contains("if showDetail"))
    XCTAssertTrue(result.contains("Text(\"Detail\")"))
    XCTAssertTrue(result.contains("Text(\"Summary\")"))
  }

  // MARK: 15. Dedent behavior

  func testDedentBehavior() throws {
    let path = writeTempFile(content: """
      #Preview {
          Text("Indented")
          VStack {
              Text("More Indented")
          }
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = try extractor.extract(from: path)

    // After dedent, the common leading whitespace should be removed.
    // The first non-empty line ("Text(\"Indented\")") should start at column 0.
    let lines = result.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard let firstLine = nonEmptyLines.first else {
      XCTFail("Expected non-empty output")
      return
    }
    // The first non-empty line should have no leading whitespace after dedent
    XCTAssertEqual(firstLine, firstLine.trimmingCharacters(in: .init(charactersIn: " \t")),
                   "First non-empty line should have no leading whitespace after dedent")
  }
}

// MARK: - PreviewExtractorImportsTests

final class PreviewExtractorImportsTests: XCTestCase {

  private let extractor = PreviewExtractor()
  private let fm = FileManager.default

  // MARK: Helper

  private func writeTempFile(content: String) -> String {
    let path = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("PreviewExtractorImportsTest_\(UUID().uuidString).swift")
    try! content.write(toFile: path, atomically: true, encoding: .utf8)
    return path
  }

  // MARK: 16. Basic imports

  func testBasicImports() {
    let path = writeTempFile(content: """
      import Foundation
      import SwiftUI

      struct MyView: View {
        var body: some View { Text("Hi") }
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = extractor.extractImports(from: path)
    // extractImports returns sorted array
    XCTAssertEqual(result, ["Foundation", "SwiftUI"])
  }

  // MARK: 17. No imports

  func testNoImports() {
    let path = writeTempFile(content: """
      struct PlainStruct {
        let value: Int
      }
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = extractor.extractImports(from: path)
    XCTAssertTrue(result.isEmpty)
  }

  // MARK: 18. Submodule imports

  func testSubmoduleImports() {
    let path = writeTempFile(content: """
      import UIKit.UIView
      import Foundation

      struct Wrapper {}
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = extractor.extractImports(from: path)
    // Sorted: "Foundation" < "UIKit.UIView"
    XCTAssertEqual(result, ["Foundation", "UIKit.UIView"])
  }

  // MARK: 19. Import with @testable

  func testTestableImport() {
    // @testable is an attribute on the import decl; the ImportCollector
    // collects the module path, not the attribute. Verify it extracts the module name.
    let path = writeTempFile(content: """
      @testable import MyModule
      import Foundation
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = extractor.extractImports(from: path)
    XCTAssertTrue(result.contains("MyModule"))
    XCTAssertTrue(result.contains("Foundation"))
  }

  // MARK: 20. File not found returns empty array

  func testFileNotFoundReturnsEmptyArray() {
    let fakePath = "/nonexistent/path/\(UUID().uuidString).swift"
    let result = extractor.extractImports(from: fakePath)
    XCTAssertTrue(result.isEmpty)
  }

  // MARK: 21. Duplicate imports

  func testDuplicateImports() {
    let path = writeTempFile(content: """
      import Foundation
      import Foundation
      import SwiftUI
      """)
    defer { try? fm.removeItem(atPath: path) }

    let result = extractor.extractImports(from: path)
    // The ImportCollector appends each import it visits, so duplicates are kept
    XCTAssertEqual(result.filter { $0 == "Foundation" }.count, 2)
    XCTAssertEqual(result.filter { $0 == "SwiftUI" }.count, 1)
  }
}
