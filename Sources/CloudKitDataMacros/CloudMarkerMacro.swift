import SwiftSyntax
import SwiftSyntaxMacros

/// A metadata-only marker. The enclosing `@CloudSynced` macro reads the
/// original source declaration and owns all validation and generation.
public struct CloudMarkerMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    []
  }
}
