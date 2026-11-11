import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct CloudKitDataPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    CloudMarkerMacro.self,
    CloudSyncedMacro.self,
  ]
}
