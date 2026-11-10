import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct CloudSyncedMacro: MemberMacro, ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let classDeclaration = declaration.as(ClassDeclSyntax.self) else {
      context.diagnose(
        Diagnostic(node: Syntax(declaration), message: CloudDiagnostic.classOnly)
      )
      return []
    }
    guard
      classDeclaration.modifiers.contains(where: {
        $0.name.tokenKind == .keyword(.final)
      })
    else {
      context.diagnose(
        Diagnostic(
          node: Syntax(classDeclaration.name),
          message: CloudDiagnostic.finalClassRequired
        )
      )
      return []
    }

    let arguments = parseCloudSyncedArguments(from: node)
    let model = parseModel(classDeclaration)
    for issue in arguments.issues + model.issues {
      context.diagnose(
        Diagnostic(node: issue.node, message: issue.diagnostic)
      )
    }
    guard
      let recordType = arguments.recordType,
      let zoneDomain = arguments.zoneDomain,
      model.identity != nil,
      arguments.issues.isEmpty,
      model.issues.isEmpty
    else {
      return []
    }

    return generatedMembers(
      for: classDeclaration,
      recordType: recordType,
      zoneDomain: zoneDomain,
      model: model
    )
  }

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    guard let classDeclaration = declaration.as(ClassDeclSyntax.self) else { return [] }
    guard
      classDeclaration.modifiers.contains(where: {
        $0.name.tokenKind == .keyword(.final)
      })
    else {
      return []
    }

    let arguments = parseCloudSyncedArguments(from: node)
    let model = parseModel(classDeclaration)
    guard
      arguments.recordType != nil,
      arguments.zoneDomain != nil,
      model.identity != nil,
      arguments.issues.isEmpty,
      model.issues.isEmpty
    else {
      return []
    }

    return [
      try ExtensionDeclSyntax(
        "extension \(type.trimmed): CloudKitData.CloudSyncedModel {}"
      )
    ]
  }
}
