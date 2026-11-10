import SwiftSyntax

func generatedMembers(
  for declaration: ClassDeclSyntax,
  recordType: ParsedStringLiteral,
  zoneDomain: ParsedStringLiteral,
  model: ParsedModel
) -> [DeclSyntax] {
  guard let identity = model.identity else { return [] }

  let access = generatedAccessPrefix(for: declaration)
  let className = declaration.name.trimmed.description
  return [
    DeclSyntax(
      stringLiteral: registrationSource(
        access: access,
        className: className,
        recordType: recordType,
        zoneDomain: zoneDomain,
        identity: identity,
        fields: model.fields,
        locations: model.locations,
        relationships: model.relationships,
        assets: model.assets
      )
    ),
    DeclSyntax(
      stringLiteral: decodedValuesSource(
        identity: identity,
        fields: model.wireFields,
        locations: model.locations
      )
    ),
    DeclSyntax(
      stringLiteral: decodingSource(
        identity: identity,
        fields: model.wireFields,
        locations: model.locations
      )
    ),
    DeclSyntax(
      stringLiteral: materializationSource(
        identity: identity,
        fields: model.wireFields,
        locations: model.locations,
        defaultedProperties: model.defaultedProperties
      )
    ),
    DeclSyntax(
      stringLiteral: snapshotEncodingSource(
        identity: identity,
        fields: model.wireFields,
        locations: model.locations
      )
    ),
    DeclSyntax(
      stringLiteral: mergeSource(
        identity: identity,
        fields: model.wireFields,
        locations: model.locations
      )
    ),
  ]
}

private func registrationSource(
  access: String,
  className: String,
  recordType: ParsedStringLiteral,
  zoneDomain: ParsedStringLiteral,
  identity: ParsedProperty,
  fields: [ParsedField],
  locations: [ParsedLocation],
  relationships: [ParsedRelationship],
  assets: [ParsedAsset]
) -> String {
  let fieldDescriptors =
    fields.map { field in
      let key = field.key.source
      return
        "CloudKitData.CloudFieldDescriptor(key: \(key), kind: .\(field.baseType.rawValue), isOptional: \(field.isOptional))"
    }
    + locations.map { location in
      "CloudKitData.CloudFieldDescriptor(key: \(location.key.source), kind: .location, isOptional: \(location.isOptional))"
    }
  let fieldsSource = arraySource(fieldDescriptors, indentBy: 8)
  let relationshipDescriptors = relationships.map(relationshipDescriptorSource)
  let relationshipDescriptorsSource = arraySource(
    relationshipDescriptors,
    indentBy: 8
  )
  let relationshipRegistrations = relationships.map { relationship in
    relationshipRegistrationSource(
      className: className,
      relationship: relationship
    )
  }
  let relationshipRegistrationsSource = arraySource(
    relationshipRegistrations,
    indentBy: 6
  )
  let assetDescriptors = assets.map { asset in
    "CloudKitData.CloudAssetDescriptor(key: \(asset.key.source), propertyName: \"\(asset.nameSource)\")"
  }
  let assetDescriptorsSource = arraySource(assetDescriptors, indentBy: 8)
  let assetRegistrations = assets.map { asset in
    """
    CloudKitData.CloudAssetRegistration(
      sourceModelType: \(className).self,
      descriptor: CloudKitData.CloudAssetDescriptor(
        key: \(asset.key.source),
        propertyName: "\(asset.nameSource)"
      ),
      slot: \\\(className).\(asset.nameSource)
    )
    """
  }
  let assetRegistrationsSource = arraySource(assetRegistrations, indentBy: 6)

  return """
    /// The generated schema and field-mapping operations for this model.
    \(access)static var cloudModelRegistration: CloudKitData.CloudModelRegistration {
      CloudKitData.CloudModelRegistration(
        modelType: \(className).self,
        descriptor: CloudKitData.CloudModelDescriptor(
          recordType: \(recordType.source),
          zoneDomain: \(zoneDomain.source),
          recordNameKind: .\(identity.baseType.rawValue),
          fields: \(fieldsSource),
          relationships: \(relationshipDescriptorsSource),
          assets: \(assetDescriptorsSource)
        ),
        relationships: \(relationshipRegistrationsSource),
        assets: \(assetRegistrationsSource),
        fetch: { recordName, context in
    \(indent(fetchSource(className: className, identity: identity), by: 6))
        },
        makeSnapshot: { model in
          try model._cloudRecordSnapshot()
        },
        applySnapshot: { model, snapshot in
          try model._applyCloudRecordSnapshot(snapshot)
        },
        materialize: { snapshot in
          try \(className)(_cloudRecordSnapshot: snapshot)
        }
      )
    }
    """
}

private func relationshipDescriptorSource(
  _ relationship: ParsedRelationship
) -> String {
  """
  CloudKitData.CloudRelationshipDescriptor(
  \(indent(relationshipDescriptorArgumentsSource(relationship), by: 2))
  )
  """
}

private func relationshipRegistrationSource(
  className: String,
  relationship: ParsedRelationship
) -> String {
  """
  CloudKitData.CloudRelationshipRegistration(
    sourceModelType: \(className).self,
    targetModelType: \(relationship.targetTypeSource).self,
    descriptor: CloudKitData.CloudRelationshipDescriptor(
  \(indent(relationshipDescriptorArgumentsSource(relationship), by: 4))
    ),
    targetRecordName: { source in source.\(relationship.field.nameSource) },
    local: \(relationship.localKeyPathSource)
  )
  """
}

private func relationshipDescriptorArgumentsSource(
  _ relationship: ParsedRelationship
) -> String {
  """
  key: \(relationship.field.key.source),
  targetModelType: \(relationship.targetTypeSource).self,
  localPropertyName: "\(relationship.localPropertyName)",
  storage: .recordName,
  requirement: .\(relationship.requirement.rawValue),
  isOptional: \(relationship.field.isOptional)
  """
}

private func fetchSource(
  className: String,
  identity: ParsedProperty
) -> String {
  let identitySource: String
  switch identity.baseType {
  case .uuid:
    identitySource = """
      guard let _cloudIdentity = Foundation.UUID(uuidString: recordName) else {
        throw CloudKitData.CloudRecordSnapshotError.invalidRecordName(recordName)
      }
      """
  case .string:
    identitySource = "let _cloudIdentity = recordName"
  case .bool, .int, .int64, .double, .date, .data:
    identitySource = ""
  }

  return """
    \(identitySource)
    var descriptor = SwiftData.FetchDescriptor<\(className)>(
      predicate: #Predicate<\(className)> { model in
        model.\(identity.nameSource) == _cloudIdentity
      }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
    """
}

private func decodedValuesSource(
  identity: ParsedProperty,
  fields: [ParsedField],
  locations: [ParsedLocation]
) -> String {
  let properties =
    ["let \(identity.nameSource): \(identity.typeSource)"]
    + fields.map { field in
      "let \(field.nameSource): \(field.typeSource)"
    }
    + locations.flatMap { location in
      [
        "let \(location.latitude.nameSource): \(location.latitude.typeSource)",
        "let \(location.longitude.nameSource): \(location.longitude.typeSource)",
      ]
    }
  return """
    private struct _CloudDecodedValues {
    \(indent(properties.joined(separator: "\n"), by: 2))
    }
    """
}

private func decodingSource(
  identity: ParsedProperty,
  fields: [ParsedField],
  locations: [ParsedLocation]
) -> String {
  let identitySource: String
  switch identity.baseType {
  case .uuid:
    identitySource = """
      guard let _cloudIdentity = Foundation.UUID(uuidString: snapshot.recordName) else {
        throw CloudKitData.CloudRecordSnapshotError.invalidRecordName(snapshot.recordName)
      }
      """
  case .string:
    identitySource = "let _cloudIdentity = snapshot.recordName"
  case .bool, .int, .int64, .double, .date, .data:
    identitySource = ""
  }

  let fieldSources = fields.enumerated().map { index, field in
    decodedFieldSource(index: index, field: field)
  }
  let locationSources = locations.enumerated().map { index, location in
    decodedLocationSource(index: index, location: location)
  }
  let arguments =
    ["\(identity.nameSource): _cloudIdentity"]
    + fields.enumerated().map { index, field in
      "\(field.nameSource): _cloudField\(index)"
    }
    + locations.enumerated().flatMap { index, location in
      [
        "\(location.latitude.nameSource): _cloudLocation\(index)Latitude",
        "\(location.longitude.nameSource): _cloudLocation\(index)Longitude",
      ]
    }

  return """
    private static func _decodeCloudRecordSnapshot(
      _ snapshot: CloudKitData.CloudRecordSnapshot
    ) throws -> _CloudDecodedValues {
    \(indent(identitySource, by: 2))
    \(indent((fieldSources + locationSources).joined(separator: "\n"), by: 2))
      return _CloudDecodedValues(
    \(indent(arguments.joined(separator: ",\n"), by: 4))
      )
    }
    """
}

private func decodedLocationSource(
  index: Int,
  location: ParsedLocation
) -> String {
  let key = location.key.source
  if location.isOptional {
    return """
      let _cloudLocation\(index)Latitude: Double?
      let _cloudLocation\(index)Longitude: Double?
      if let _cloudValueLocation\(index) = snapshot.fields[\(key)] {
        guard case .location(let _cloudLocation\(index)) = _cloudValueLocation\(index) else {
          throw CloudKitData.CloudRecordSnapshotError.missingOrInvalidField(
            key: \(key),
            expected: .location
          )
        }
        _cloudLocation\(index)Latitude = _cloudLocation\(index).latitude
        _cloudLocation\(index)Longitude = _cloudLocation\(index).longitude
      } else {
        _cloudLocation\(index)Latitude = nil
        _cloudLocation\(index)Longitude = nil
      }
      """
  }

  return """
    guard let _cloudValueLocation\(index) = snapshot.fields[\(key)] else {
      throw CloudKitData.CloudRecordSnapshotError.missingOrInvalidField(
        key: \(key),
        expected: .location
      )
    }
    guard case .location(let _cloudLocation\(index)) = _cloudValueLocation\(index) else {
      throw CloudKitData.CloudRecordSnapshotError.missingOrInvalidField(
        key: \(key),
        expected: .location
      )
    }
    let _cloudLocation\(index)Latitude = _cloudLocation\(index).latitude
    let _cloudLocation\(index)Longitude = _cloudLocation\(index).longitude
    """
}

private func decodedFieldSource(index: Int, field: ParsedField) -> String {
  let key = field.key.source
  let expected = field.baseType.rawValue
  if field.isOptional {
    return """
      let _cloudField\(index): \(field.typeSource)
      if let _cloudValue\(index) = snapshot.fields[\(key)] {
        guard case .\(expected)(let _cloudDecodedValue\(index)) = _cloudValue\(index) else {
          throw CloudKitData.CloudRecordSnapshotError.missingOrInvalidField(
            key: \(key),
            expected: .\(expected)
          )
        }
        _cloudField\(index) = _cloudDecodedValue\(index)
      } else {
        _cloudField\(index) = nil
      }
      """
  }

  return """
    guard let _cloudValue\(index) = snapshot.fields[\(key)] else {
      throw CloudKitData.CloudRecordSnapshotError.missingOrInvalidField(
        key: \(key),
        expected: .\(expected)
      )
    }
    guard case .\(expected)(let _cloudField\(index)) = _cloudValue\(index) else {
      throw CloudKitData.CloudRecordSnapshotError.missingOrInvalidField(
        key: \(key),
        expected: .\(expected)
      )
    }
    """
}

private func materializationSource(
  identity: ParsedProperty,
  fields: [ParsedField],
  locations: [ParsedLocation],
  defaultedProperties: [DefaultedProperty]
) -> String {
  let decodedAssignments =
    [
      "self.\(identity.nameSource) = values.\(identity.nameSource)"
    ]
    + fields.map { field in
      "self.\(field.nameSource) = values.\(field.nameSource)"
    }
    + locations.flatMap { location in
      [
        "self.\(location.latitude.nameSource) = values.\(location.latitude.nameSource)",
        "self.\(location.longitude.nameSource) = values.\(location.longitude.nameSource)",
      ]
    }
  let defaultAssignments = defaultedProperties.map { property in
    "self.\(property.nameSource) = \(property.expressionSource)"
  }

  return """
    private init(
      _cloudRecordSnapshot snapshot: CloudKitData.CloudRecordSnapshot
    ) throws {
      let values = try Self._decodeCloudRecordSnapshot(snapshot)
    \(indent((decodedAssignments + defaultAssignments).joined(separator: "\n"), by: 2))
    }
    """
}

private func snapshotEncodingSource(
  identity: ParsedProperty,
  fields: [ParsedField],
  locations: [ParsedLocation]
) -> String {
  let recordName: String
  switch identity.baseType {
  case .uuid:
    recordName = "self.\(identity.nameSource).uuidString"
  case .string:
    recordName = "self.\(identity.nameSource)"
  case .bool, .int, .int64, .double, .date, .data:
    recordName = "\"\""
  }

  let assignments = fields.map { field -> String in
    let key = field.key.source
    let value = "CloudKitData.CloudFieldValue.\(field.baseType.rawValue)"
    if field.isOptional {
      return """
        if let value = self.\(field.nameSource) {
          fields[\(key)] = \(value)(value)
        }
        """
    }
    return "fields[\(key)] = \(value)(self.\(field.nameSource))"
  }
  let locationAssignments = locations.map(encodedLocationSource)

  return """
    private func _cloudRecordSnapshot() throws -> CloudKitData.CloudRecordSnapshot {
      var fields: [String: CloudKitData.CloudFieldValue] = [:]
    \(indent((assignments + locationAssignments).joined(separator: "\n"), by: 2))
      return CloudKitData.CloudRecordSnapshot(
        recordName: \(recordName),
        fields: fields
      )
    }
    """
}

private func encodedLocationSource(_ location: ParsedLocation) -> String {
  let key = location.key.source
  let latitude = "self.\(location.latitude.nameSource)"
  let longitude = "self.\(location.longitude.nameSource)"
  if location.isOptional {
    return """
      if let latitude = \(latitude), let longitude = \(longitude) {
        guard let location = CloudKitData.CloudLocationValue(
          latitude: latitude,
          longitude: longitude
        ) else {
          throw CloudKitData.CloudRecordSnapshotError.invalidLocation(key: \(key))
        }
        fields[\(key)] = .location(location)
      } else if \(latitude) != nil || \(longitude) != nil {
        throw CloudKitData.CloudRecordSnapshotError.incompleteLocation(key: \(key))
      }
      """
  }

  return """
    guard let location = CloudKitData.CloudLocationValue(
      latitude: \(latitude),
      longitude: \(longitude)
    ) else {
      throw CloudKitData.CloudRecordSnapshotError.invalidLocation(key: \(key))
    }
    fields[\(key)] = .location(location)
    """
}

private func mergeSource(
  identity: ParsedProperty,
  fields: [ParsedField],
  locations: [ParsedLocation]
) -> String {
  let expectedRecordName: String
  switch identity.baseType {
  case .uuid:
    expectedRecordName = "self.\(identity.nameSource).uuidString"
  case .string:
    expectedRecordName = "self.\(identity.nameSource)"
  case .bool, .int, .int64, .double, .date, .data:
    expectedRecordName = "\"\""
  }
  let assignments =
    fields.map { field in
      "self.\(field.nameSource) = values.\(field.nameSource)"
    }
    + locations.flatMap { location in
      [
        "self.\(location.latitude.nameSource) = values.\(location.latitude.nameSource)",
        "self.\(location.longitude.nameSource) = values.\(location.longitude.nameSource)",
      ]
    }

  return """
    private func _applyCloudRecordSnapshot(
      _ snapshot: CloudKitData.CloudRecordSnapshot
    ) throws {
      let expectedRecordName = \(expectedRecordName)
      guard snapshot.recordName == expectedRecordName else {
        throw CloudKitData.CloudRecordSnapshotError.recordNameMismatch(
          expected: expectedRecordName,
          actual: snapshot.recordName
        )
      }
      let values = try Self._decodeCloudRecordSnapshot(snapshot)
    \(indent(assignments.joined(separator: "\n"), by: 2))
    }
    """
}

private func generatedAccessPrefix(for declaration: ClassDeclSyntax) -> String {
  if declaration.modifiers.contains(where: {
    $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.open)
  }) {
    return "public "
  }
  if declaration.modifiers.contains(where: { $0.name.tokenKind == .keyword(.package) }) {
    return "package "
  }
  return ""
}

private func arraySource(_ elements: [String], indentBy spaces: Int) -> String {
  guard elements.isEmpty == false else { return "[]" }
  return """
    [
    \(indent(elements.joined(separator: ",\n"), by: spaces))
    \(String(repeating: " ", count: max(0, spaces - 2)))]
    """
}

private func indent(_ text: String, by spaces: Int) -> String {
  guard text.isEmpty == false else { return text }
  let prefix = String(repeating: " ", count: spaces)
  return
    text
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map { prefix + $0 }
    .joined(separator: "\n")
}
