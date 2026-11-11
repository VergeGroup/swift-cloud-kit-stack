import SwiftSyntax

struct ParsedStringLiteral {
  let source: String
  let value: String
}

struct ParsedCloudSyncedArguments {
  let recordType: ParsedStringLiteral?
  let zoneDomain: ParsedStringLiteral?
  let issues: [ModelIssue]
}

struct ParsedModel {
  let identity: ParsedProperty?
  let fields: [ParsedField]
  let locations: [ParsedLocation]
  let relationships: [ParsedRelationship]
  let assets: [ParsedAsset]
  let wireFields: [ParsedField]
  let defaultedProperties: [DefaultedProperty]
  let issues: [ModelIssue]
}

struct ParsedProperty {
  let nameSource: String
  let typeSource: String
  let baseType: PrimitiveType
  let isOptional: Bool
}

struct ParsedField {
  let property: ParsedProperty
  let key: ParsedStringLiteral

  var nameSource: String { property.nameSource }
  var typeSource: String { property.typeSource }
  var baseType: PrimitiveType { property.baseType }
  var isOptional: Bool { property.isOptional }
}

struct ParsedRelationship {
  let field: ParsedField
  let targetTypeSource: String
  let localKeyPathSource: String
  let localPropertyName: String
  let requirement: ParsedRelationshipRequirement
}

struct ParsedAsset {
  let nameSource: String
  let key: ParsedStringLiteral
}

struct ParsedLocation {
  let key: ParsedStringLiteral
  let latitude: ParsedProperty
  let longitude: ParsedProperty

  var isOptional: Bool { latitude.isOptional }
}

struct DefaultedProperty {
  let nameSource: String
  let expressionSource: String
}

struct ModelIssue {
  let node: Syntax
  let diagnostic: CloudDiagnostic
}

enum PrimitiveType: String {
  case string
  case bool
  case int
  case int64
  case double
  case date
  case data
  case uuid
}

enum ParsedRelationshipRequirement: String {
  case optional
  case eventuallyRequired
}

private enum MarkerKind: Equatable {
  case cloudField
  case cloudLocation
  case cloudRelationship
  case cloudAsset
  case recordName
  case cloudLocal
  case localRelationship
  case transient
}

private enum ParsedLocationComponentKind: String {
  case latitude
  case longitude
}

private struct ParsedLocationComponent {
  let property: ParsedProperty
  let key: ParsedStringLiteral
  let component: ParsedLocationComponentKind
  let attribute: AttributeSyntax
}

private struct DeclaredProperty {
  let variable: VariableDeclSyntax
  let binding: PatternBindingSyntax
  let nameSource: String
  let displayName: String
  let markers: [(kind: MarkerKind, attribute: AttributeSyntax)]
}

private struct ParsedRelationshipArguments {
  let key: ParsedStringLiteral
  let targetTypeSource: String
  let localKeyPathSource: String
  let localKeyPathNode: Syntax
  let localPropertyName: String
  let requirement: ParsedRelationshipRequirement
}

private struct ParsedLocationArguments {
  let key: ParsedStringLiteral
  let component: ParsedLocationComponentKind
}

func parseCloudSyncedArguments(
  from attribute: AttributeSyntax
) -> ParsedCloudSyncedArguments {
  guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
    return ParsedCloudSyncedArguments(
      recordType: nil,
      zoneDomain: nil,
      issues: [
        ModelIssue(node: Syntax(attribute), diagnostic: .recordTypeRequired),
        ModelIssue(node: Syntax(attribute), diagnostic: .zoneDomainRequired),
      ]
    )
  }

  let recordTypeArgument = arguments.first { $0.label?.text == "recordType" }
  let zoneDomainArgument = arguments.first { $0.label?.text == "zoneDomain" }
  var issues: [ModelIssue] = []

  let recordType = parseRequiredLiteral(
    argument: recordTypeArgument,
    attribute: attribute,
    missing: .recordTypeRequired,
    nonliteral: .recordTypeLiteralRequired,
    empty: .emptyRecordType,
    issues: &issues
  )
  let zoneDomain = parseRequiredLiteral(
    argument: zoneDomainArgument,
    attribute: attribute,
    missing: .zoneDomainRequired,
    nonliteral: .zoneDomainLiteralRequired,
    empty: .emptyZoneDomain,
    issues: &issues
  )

  let hasCanonicalArguments =
    arguments.count == 2
    && arguments.first?.label?.text == "recordType"
    && arguments.last?.label?.text == "zoneDomain"
  if recordTypeArgument != nil, zoneDomainArgument != nil, hasCanonicalArguments == false {
    issues.append(
      ModelIssue(node: Syntax(attribute), diagnostic: .invalidCloudSyncedArguments)
    )
  }

  return ParsedCloudSyncedArguments(
    recordType: recordType,
    zoneDomain: zoneDomain,
    issues: issues
  )
}

func parseModel(_ declaration: ClassDeclSyntax) -> ParsedModel {
  let declaredProperties = collectDeclaredProperties(declaration)
  let propertiesByName = Dictionary(
    uniqueKeysWithValues: declaredProperties.map { ($0.displayName, $0) }
  )

  var identity: ParsedProperty?
  var identityMarkerCount = 0
  var fields: [ParsedField] = []
  var locationComponents: [ParsedLocationComponent] = []
  var relationships: [ParsedRelationship] = []
  var assets: [ParsedAsset] = []
  var wireFields: [ParsedField] = []
  var defaultedProperties: [DefaultedProperty] = []
  var missingDefaults: [DeclaredProperty] = []
  var issues: [ModelIssue] = []
  var wireKeys = Set<String>()
  var localRelationshipNames = Set<String>()
  var referencedLocalRelationshipNames = Set<String>()

  for declaredProperty in declaredProperties {
    let variable = declaredProperty.variable
    let binding = declaredProperty.binding
    let displayName = declaredProperty.displayName

    guard declaredProperty.markers.count <= 1 else {
      issues.append(
        ModelIssue(
          node: Syntax(variable),
          diagnostic: .multipleClassifications(displayName)
        )
      )
      continue
    }
    let marker = declaredProperty.markers.first

    if binding.accessorBlock != nil {
      switch marker?.kind {
      case .cloudField, .cloudRelationship:
        issues.append(
          ModelIssue(
            node: Syntax(variable),
            diagnostic: .computedCloudField(displayName)
          )
        )
      case .cloudLocation:
        issues.append(
          ModelIssue(
            node: Syntax(variable),
            diagnostic: .computedLocationComponent(displayName)
          )
        )
      case .cloudAsset:
        guard let marker else { continue }
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
          issues.append(
            ModelIssue(node: Syntax(variable), diagnostic: .immutableAssetSlot)
          )
          continue
        }
        guard isReadOnlyComputedProperty(binding) else {
          issues.append(
            ModelIssue(
              node: Syntax(variable),
              diagnostic: .writableAssetSlot(displayName)
            )
          )
          continue
        }
        guard let type = binding.typeAnnotation?.type else {
          issues.append(
            ModelIssue(
              node: Syntax(binding),
              diagnostic: .explicitAssetSlotTypeRequired(displayName)
            )
          )
          continue
        }
        guard isCloudAssetSlotType(type) else {
          issues.append(
            ModelIssue(
              node: Syntax(type),
              diagnostic: .invalidAssetSlotType(type.trimmed.description)
            )
          )
          continue
        }
        guard
          let assetKey = parseAssetKey(
            from: marker.attribute,
            issues: &issues
          )
        else {
          continue
        }
        guard wireKeys.insert(assetKey.value).inserted else {
          issues.append(
            ModelIssue(
              node: Syntax(marker.attribute),
              diagnostic: .duplicateWireKey(assetKey.value)
            )
          )
          continue
        }
        assets.append(
          ParsedAsset(nameSource: declaredProperty.nameSource, key: assetKey)
        )
      case .recordName:
        identityMarkerCount += 1
        issues.append(
          ModelIssue(
            node: Syntax(variable),
            diagnostic: .computedIdentity(displayName)
          )
        )
      case .cloudLocal, .localRelationship, .transient, nil:
        break
      }
      continue
    }

    guard let marker else {
      issues.append(
        ModelIssue(
          node: Syntax(variable),
          diagnostic: .unclassified(displayName)
        )
      )
      continue
    }

    if variable.bindingSpecifier.tokenKind == .keyword(.let) {
      issues.append(
        ModelIssue(node: Syntax(variable), diagnostic: .immutableProperty)
      )
      continue
    }

    switch marker.kind {
    case .cloudLocal, .localRelationship, .transient:
      if marker.kind == .cloudLocal, hasArguments(marker.attribute) {
        issues.append(
          ModelIssue(node: Syntax(marker.attribute), diagnostic: .invalidLocalArguments)
        )
        continue
      }
      if let initializer = binding.initializer?.value.trimmed.description {
        defaultedProperties.append(
          DefaultedProperty(
            nameSource: declaredProperty.nameSource,
            expressionSource: initializer
          )
        )
      } else {
        missingDefaults.append(declaredProperty)
      }

    case .cloudAsset:
      issues.append(
        ModelIssue(
          node: Syntax(variable),
          diagnostic: .storedCloudAsset(displayName)
        )
      )

    case .cloudLocation:
      guard let type = binding.typeAnnotation?.type else {
        issues.append(
          ModelIssue(
            node: Syntax(binding),
            diagnostic: .explicitTypeRequired(displayName)
          )
        )
        continue
      }
      guard
        let parsedType = parsePrimitiveType(type),
        parsedType.base == .double
      else {
        issues.append(
          ModelIssue(
            node: Syntax(type),
            diagnostic: .invalidLocationComponentType(type.trimmed.description)
          )
        )
        continue
      }
      guard
        let arguments = parseLocationArguments(
          from: marker.attribute,
          issues: &issues
        )
      else {
        continue
      }
      locationComponents.append(
        ParsedLocationComponent(
          property: ParsedProperty(
            nameSource: declaredProperty.nameSource,
            typeSource: type.trimmed.description,
            baseType: parsedType.base,
            isOptional: parsedType.isOptional
          ),
          key: arguments.key,
          component: arguments.component,
          attribute: marker.attribute
        )
      )

    case .recordName, .cloudField, .cloudRelationship:
      guard let type = binding.typeAnnotation?.type else {
        issues.append(
          ModelIssue(
            node: Syntax(binding),
            diagnostic: .explicitTypeRequired(displayName)
          )
        )
        continue
      }
      guard let parsedType = parsePrimitiveType(type) else {
        let diagnostic: CloudDiagnostic
        switch marker.kind {
        case .recordName:
          diagnostic = .invalidIdentityType
        case .cloudRelationship:
          diagnostic = .invalidRelationshipIdentityType
        case .cloudField:
          diagnostic = .unsupportedType(type.trimmed.description)
        case .cloudAsset, .cloudLocation, .cloudLocal, .localRelationship, .transient:
          continue
        }
        issues.append(ModelIssue(node: Syntax(type), diagnostic: diagnostic))
        if marker.kind == .recordName {
          identityMarkerCount += 1
        }
        continue
      }

      let property = ParsedProperty(
        nameSource: declaredProperty.nameSource,
        typeSource: type.trimmed.description,
        baseType: parsedType.base,
        isOptional: parsedType.isOptional
      )

      switch marker.kind {
      case .recordName:
        identityMarkerCount += 1
        if hasArguments(marker.attribute) {
          issues.append(
            ModelIssue(
              node: Syntax(marker.attribute),
              diagnostic: .invalidIdentityArguments
            )
          )
        } else if identityMarkerCount > 1 {
          issues.append(
            ModelIssue(node: Syntax(variable), diagnostic: .duplicateIdentity)
          )
        } else if property.isOptional
          || (property.baseType != .uuid && property.baseType != .string)
        {
          issues.append(
            ModelIssue(node: Syntax(type), diagnostic: .invalidIdentityType)
          )
        } else {
          identity = property
        }

      case .cloudField:
        guard property.baseType != .uuid else {
          issues.append(
            ModelIssue(
              node: Syntax(type),
              diagnostic: .unsupportedType(type.trimmed.description)
            )
          )
          continue
        }
        guard
          let fieldKey = parseFieldKey(
            from: marker.attribute,
            issues: &issues
          )
        else {
          continue
        }
        guard wireKeys.insert(fieldKey.value).inserted else {
          issues.append(
            ModelIssue(
              node: Syntax(marker.attribute),
              diagnostic: .duplicateWireKey(fieldKey.value)
            )
          )
          continue
        }
        let field = ParsedField(property: property, key: fieldKey)
        fields.append(field)
        wireFields.append(field)

      case .cloudRelationship:
        guard property.baseType == .string else {
          issues.append(
            ModelIssue(node: Syntax(type), diagnostic: .invalidRelationshipIdentityType)
          )
          continue
        }
        guard
          let arguments = parseRelationshipArguments(
            from: marker.attribute,
            className: declaration.name.text,
            issues: &issues
          )
        else {
          continue
        }
        referencedLocalRelationshipNames.insert(arguments.localPropertyName)
        let hasMatchingOptionality: Bool
        switch arguments.requirement {
        case .optional:
          hasMatchingOptionality = property.isOptional
        case .eventuallyRequired:
          hasMatchingOptionality = property.isOptional == false
        }
        guard hasMatchingOptionality else {
          issues.append(
            ModelIssue(
              node: Syntax(type),
              diagnostic: .relationshipRequirementTypeMismatch(
                arguments.requirement.rawValue
              )
            )
          )
          continue
        }
        guard wireKeys.insert(arguments.key.value).inserted else {
          issues.append(
            ModelIssue(
              node: Syntax(marker.attribute),
              diagnostic: .duplicateWireKey(arguments.key.value)
            )
          )
          continue
        }
        guard localRelationshipNames.insert(arguments.localPropertyName).inserted else {
          issues.append(
            ModelIssue(
              node: Syntax(marker.attribute),
              diagnostic: .duplicateRelationshipLocalProperty(
                arguments.localPropertyName
              )
            )
          )
          continue
        }
        guard
          validateLocalRelationship(
            arguments,
            propertiesByName: propertiesByName,
            issues: &issues
          )
        else {
          continue
        }

        let field = ParsedField(property: property, key: arguments.key)
        relationships.append(
          ParsedRelationship(
            field: field,
            targetTypeSource: arguments.targetTypeSource,
            localKeyPathSource: arguments.localKeyPathSource,
            localPropertyName: arguments.localPropertyName,
            requirement: arguments.requirement
          )
        )
        wireFields.append(field)

      case .cloudAsset, .cloudLocation, .cloudLocal, .localRelationship, .transient:
        break
      }
    }
  }

  let locations = parseLocations(
    from: locationComponents,
    wireKeys: &wireKeys,
    issues: &issues
  )

  for property in missingDefaults {
    if property.markers.first?.kind == .localRelationship,
      referencedLocalRelationshipNames.contains(property.displayName)
    {
      defaultedProperties.append(
        DefaultedProperty(
          nameSource: property.nameSource,
          expressionSource: "nil"
        )
      )
    } else {
      issues.append(
        ModelIssue(
          node: Syntax(property.binding),
          diagnostic: .defaultRequired(property.displayName)
        )
      )
    }
  }

  if identityMarkerCount == 0 {
    issues.append(
      ModelIssue(node: Syntax(declaration), diagnostic: .missingIdentity)
    )
  }

  return ParsedModel(
    identity: identity,
    fields: fields,
    locations: locations,
    relationships: relationships,
    assets: assets,
    wireFields: wireFields,
    defaultedProperties: defaultedProperties,
    issues: issues
  )
}

private func parseRequiredLiteral(
  argument: LabeledExprSyntax?,
  attribute: AttributeSyntax,
  missing: CloudDiagnostic,
  nonliteral: CloudDiagnostic,
  empty: CloudDiagnostic,
  issues: inout [ModelIssue]
) -> ParsedStringLiteral? {
  guard let argument else {
    issues.append(ModelIssue(node: Syntax(attribute), diagnostic: missing))
    return nil
  }
  guard let literal = parseStringLiteral(argument.expression) else {
    issues.append(
      ModelIssue(node: Syntax(argument.expression), diagnostic: nonliteral)
    )
    return nil
  }
  guard literal.value.isEmpty == false else {
    issues.append(ModelIssue(node: Syntax(argument.expression), diagnostic: empty))
    return nil
  }
  return literal
}

private func collectDeclaredProperties(
  _ declaration: ClassDeclSyntax
) -> [DeclaredProperty] {
  declaration.memberBlock.members.flatMap { member -> [DeclaredProperty] in
    guard let variable = member.decl.as(VariableDeclSyntax.self) else { return [] }
    guard !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) else {
      return []
    }
    let markers = classificationMarkers(of: variable)
    return variable.bindings.compactMap { binding in
      guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
        return nil
      }
      return DeclaredProperty(
        variable: variable,
        binding: binding,
        nameSource: binding.pattern.trimmed.description,
        displayName: identifier.text,
        markers: markers
      )
    }
  }
}

private func classificationMarkers(
  of variable: VariableDeclSyntax
) -> [(kind: MarkerKind, attribute: AttributeSyntax)] {
  variable.attributes.compactMap { element in
    guard case .attribute(let attribute) = element else { return nil }
    let name = attribute.attributeName.trimmed.description
      .split(separator: ".")
      .last
      .map(String.init)

    switch name {
    case "CloudField":
      return (.cloudField, attribute)
    case "CloudLocation":
      return (.cloudLocation, attribute)
    case "CloudRelationship":
      return (.cloudRelationship, attribute)
    case "CloudAsset":
      return (.cloudAsset, attribute)
    case "CloudRecordName":
      return (.recordName, attribute)
    case "CloudLocal":
      return (.cloudLocal, attribute)
    case "Relationship":
      return (.localRelationship, attribute)
    case "Transient":
      return (.transient, attribute)
    default:
      return nil
    }
  }
}

private func parseAssetKey(
  from attribute: AttributeSyntax,
  issues: inout [ModelIssue]
) -> ParsedStringLiteral? {
  guard
    let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
    arguments.count == 1,
    let argument = arguments.first,
    argument.label == nil
  else {
    issues.append(
      ModelIssue(node: Syntax(attribute), diagnostic: .invalidAssetArguments)
    )
    return nil
  }
  guard let literal = parseStringLiteral(argument.expression) else {
    issues.append(
      ModelIssue(
        node: Syntax(argument.expression),
        diagnostic: .assetKeyLiteralRequired
      )
    )
    return nil
  }
  guard literal.value.isEmpty == false else {
    issues.append(
      ModelIssue(node: Syntax(argument.expression), diagnostic: .emptyAssetKey)
    )
    return nil
  }
  return literal
}

private func parseFieldKey(
  from attribute: AttributeSyntax,
  issues: inout [ModelIssue]
) -> ParsedStringLiteral? {
  guard
    let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
    arguments.count == 1,
    let argument = arguments.first,
    argument.label == nil
  else {
    issues.append(
      ModelIssue(node: Syntax(attribute), diagnostic: .invalidFieldArguments)
    )
    return nil
  }
  guard let literal = parseStringLiteral(argument.expression) else {
    issues.append(
      ModelIssue(
        node: Syntax(argument.expression),
        diagnostic: .fieldKeyLiteralRequired
      )
    )
    return nil
  }
  guard literal.value.isEmpty == false else {
    issues.append(
      ModelIssue(node: Syntax(argument.expression), diagnostic: .emptyFieldKey)
    )
    return nil
  }
  return literal
}

private func parseLocationArguments(
  from attribute: AttributeSyntax,
  issues: inout [ModelIssue]
) -> ParsedLocationArguments? {
  guard
    let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
    arguments.count == 2,
    let keyArgument = arguments.first,
    keyArgument.label == nil,
    let componentArgument = arguments.last,
    componentArgument.label?.text == "component"
  else {
    issues.append(
      ModelIssue(
        node: Syntax(attribute),
        diagnostic: .invalidLocationArguments
      )
    )
    return nil
  }
  guard let key = parseStringLiteral(keyArgument.expression) else {
    issues.append(
      ModelIssue(
        node: Syntax(keyArgument.expression),
        diagnostic: .locationKeyLiteralRequired
      )
    )
    return nil
  }
  guard key.value.isEmpty == false else {
    issues.append(
      ModelIssue(
        node: Syntax(keyArgument.expression),
        diagnostic: .emptyLocationKey
      )
    )
    return nil
  }

  let componentSource = componentArgument.expression.trimmed.description
  let component: ParsedLocationComponentKind
  switch componentSource {
  case ".latitude", "CloudLocationComponent.latitude",
    "CloudKitData.CloudLocationComponent.latitude":
    component = .latitude
  case ".longitude", "CloudLocationComponent.longitude",
    "CloudKitData.CloudLocationComponent.longitude":
    component = .longitude
  default:
    issues.append(
      ModelIssue(
        node: Syntax(componentArgument.expression),
        diagnostic: .invalidLocationComponent
      )
    )
    return nil
  }

  return ParsedLocationArguments(key: key, component: component)
}

private func parseLocations(
  from components: [ParsedLocationComponent],
  wireKeys: inout Set<String>,
  issues: inout [ModelIssue]
) -> [ParsedLocation] {
  var orderedKeys: [String] = []
  var componentsByKey: [String: [ParsedLocationComponent]] = [:]
  for component in components {
    if componentsByKey[component.key.value] == nil {
      orderedKeys.append(component.key.value)
    }
    componentsByKey[component.key.value, default: []].append(component)
  }

  return orderedKeys.compactMap { key in
    guard let components = componentsByKey[key] else { return nil }
    var latitude: ParsedLocationComponent?
    var longitude: ParsedLocationComponent?
    var hasDuplicateComponent = false

    for component in components {
      switch component.component {
      case .latitude:
        if latitude == nil {
          latitude = component
        } else {
          hasDuplicateComponent = true
          issues.append(
            ModelIssue(
              node: Syntax(component.attribute),
              diagnostic: .duplicateLocationComponent(
                key: key,
                component: component.component.rawValue
              )
            )
          )
        }
      case .longitude:
        if longitude == nil {
          longitude = component
        } else {
          hasDuplicateComponent = true
          issues.append(
            ModelIssue(
              node: Syntax(component.attribute),
              diagnostic: .duplicateLocationComponent(
                key: key,
                component: component.component.rawValue
              )
            )
          )
        }
      }
    }

    guard hasDuplicateComponent == false else { return nil }
    guard let latitude, let longitude else {
      let missing = latitude == nil ? "latitude" : "longitude"
      issues.append(
        ModelIssue(
          node: Syntax(components[0].attribute),
          diagnostic: .missingLocationComponent(key: key, component: missing)
        )
      )
      return nil
    }
    guard latitude.property.isOptional == longitude.property.isOptional else {
      issues.append(
        ModelIssue(
          node: Syntax(longitude.attribute),
          diagnostic: .locationOptionalityMismatch(key)
        )
      )
      return nil
    }
    guard wireKeys.insert(key).inserted else {
      issues.append(
        ModelIssue(
          node: Syntax(latitude.attribute),
          diagnostic: .duplicateWireKey(key)
        )
      )
      return nil
    }
    return ParsedLocation(
      key: latitude.key,
      latitude: latitude.property,
      longitude: longitude.property
    )
  }
}

private func parseRelationshipArguments(
  from attribute: AttributeSyntax,
  className: String,
  issues: inout [ModelIssue]
) -> ParsedRelationshipArguments? {
  guard
    let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
    arguments.count == 4,
    let keyArgument = arguments.first,
    keyArgument.label == nil,
    arguments[arguments.index(after: arguments.startIndex)].label?.text == "target",
    arguments[arguments.index(arguments.startIndex, offsetBy: 2)].label?.text == "local",
    arguments.last?.label?.text == "requirement"
  else {
    issues.append(
      ModelIssue(
        node: Syntax(attribute),
        diagnostic: .invalidRelationshipArguments
      )
    )
    return nil
  }

  guard let key = parseStringLiteral(keyArgument.expression) else {
    issues.append(
      ModelIssue(
        node: Syntax(keyArgument.expression),
        diagnostic: .relationshipKeyLiteralRequired
      )
    )
    return nil
  }
  guard key.value.isEmpty == false else {
    issues.append(
      ModelIssue(
        node: Syntax(keyArgument.expression),
        diagnostic: .emptyRelationshipKey
      )
    )
    return nil
  }

  let targetArgument = arguments[arguments.index(after: arguments.startIndex)]
  guard
    let targetExpression = targetArgument.expression.as(MemberAccessExprSyntax.self),
    targetExpression.declName.baseName.text == "self",
    let targetBase = targetExpression.base
  else {
    issues.append(
      ModelIssue(
        node: Syntax(targetArgument.expression),
        diagnostic: .relationshipTargetTypeRequired
      )
    )
    return nil
  }
  let targetTypeSource = targetBase.trimmed.description
  guard targetTypeSource.isEmpty == false else {
    issues.append(
      ModelIssue(
        node: Syntax(targetArgument.expression),
        diagnostic: .relationshipTargetTypeRequired
      )
    )
    return nil
  }

  let localArgument = arguments[arguments.index(arguments.startIndex, offsetBy: 2)]
  guard
    let keyPath = localArgument.expression.as(KeyPathExprSyntax.self),
    keyPath.root?.trimmed.description == className,
    keyPath.components.count == 1,
    let component = keyPath.components.first,
    case .property(let propertyComponent) = component.component
  else {
    issues.append(
      ModelIssue(
        node: Syntax(localArgument.expression),
        diagnostic: .relationshipLocalKeyPathRequired(className)
      )
    )
    return nil
  }
  let localPropertyName = propertyComponent.declName.baseName.text

  let requirementArgument = arguments.last!
  let requirement: ParsedRelationshipRequirement
  switch requirementArgument.expression.trimmed.description {
  case ".optional":
    requirement = .optional
  case ".eventuallyRequired":
    requirement = .eventuallyRequired
  default:
    issues.append(
      ModelIssue(
        node: Syntax(requirementArgument.expression),
        diagnostic: .invalidRelationshipRequirement
      )
    )
    return nil
  }

  return ParsedRelationshipArguments(
    key: key,
    targetTypeSource: targetTypeSource,
    localKeyPathSource: localArgument.expression.trimmed.description,
    localKeyPathNode: Syntax(localArgument.expression),
    localPropertyName: localPropertyName,
    requirement: requirement
  )
}

private func validateLocalRelationship(
  _ relationship: ParsedRelationshipArguments,
  propertiesByName: [String: DeclaredProperty],
  issues: inout [ModelIssue]
) -> Bool {
  guard let localProperty = propertiesByName[relationship.localPropertyName] else {
    issues.append(
      ModelIssue(
        node: relationship.localKeyPathNode,
        diagnostic: .relationshipLocalPropertyMissing(
          relationship.localPropertyName
        )
      )
    )
    return false
  }
  guard
    localProperty.markers.count == 1,
    localProperty.markers.first?.kind == .localRelationship
  else {
    issues.append(
      ModelIssue(
        node: Syntax(localProperty.variable),
        diagnostic: .relationshipLocalPropertyRequiresRelationship(
          relationship.localPropertyName
        )
      )
    )
    return false
  }
  guard
    localProperty.binding.accessorBlock == nil,
    localProperty.variable.bindingSpecifier.tokenKind == .keyword(.var),
    let localType = localProperty.binding.typeAnnotation?.type,
    let optionalType = localType.as(OptionalTypeSyntax.self),
    optionalType.wrappedType.trimmed.description == relationship.targetTypeSource
  else {
    issues.append(
      ModelIssue(
        node: Syntax(localProperty.variable),
        diagnostic: .relationshipLocalPropertyTypeMismatch(
          name: relationship.localPropertyName,
          targetType: relationship.targetTypeSource
        )
      )
    )
    return false
  }
  return true
}

private func parseStringLiteral(_ expression: ExprSyntax) -> ParsedStringLiteral? {
  guard
    let literal = expression.as(StringLiteralExprSyntax.self),
    let value = literal.representedLiteralValue
  else {
    return nil
  }
  return ParsedStringLiteral(
    source: expression.trimmed.description,
    value: value
  )
}

private func hasArguments(_ attribute: AttributeSyntax) -> Bool {
  guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
    return false
  }
  return arguments.isEmpty == false
}

private func parsePrimitiveType(
  _ type: TypeSyntax
) -> (base: PrimitiveType, isOptional: Bool)? {
  if let optional = type.as(OptionalTypeSyntax.self) {
    guard let wrapped = parsePrimitiveType(optional.wrappedType), !wrapped.isOptional else {
      return nil
    }
    return (
      base: wrapped.base,
      isOptional: true
    )
  }

  let source = type.trimmed.description
  let primitive: PrimitiveType?
  switch source {
  case "String", "Swift.String":
    primitive = .string
  case "Bool", "Swift.Bool":
    primitive = .bool
  case "Int", "Swift.Int":
    primitive = .int
  case "Int64", "Swift.Int64":
    primitive = .int64
  case "Double", "Swift.Double":
    primitive = .double
  case "Date", "Foundation.Date":
    primitive = .date
  case "Data", "Foundation.Data":
    primitive = .data
  case "UUID", "Foundation.UUID":
    primitive = .uuid
  default:
    primitive = nil
  }
  guard let primitive else { return nil }
  return (base: primitive, isOptional: false)
}

private func isCloudAssetSlotType(_ type: TypeSyntax) -> Bool {
  switch type.trimmed.description {
  case "CloudAssetSlot", "CloudKitData.CloudAssetSlot":
    return true
  default:
    return false
  }
}

private func isReadOnlyComputedProperty(
  _ binding: PatternBindingSyntax
) -> Bool {
  guard let accessorBlock = binding.accessorBlock else { return false }
  switch accessorBlock.accessors {
  case .getter:
    return true
  case .accessors(let accessors):
    return accessors.allSatisfy {
      let specifier = $0.accessorSpecifier.text
      return specifier == "get" || specifier == "_read"
    }
  }
}
