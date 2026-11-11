import CloudKit
import CloudKitData
import CoreFoundation
import CoreLocation
import Foundation

enum CloudKitRecordAdapterError: Error, Sendable, Equatable {
  case systemFieldsCannotBeDecoded
  case systemFieldsIdentityMismatch(expected: String, actual: String)
  case systemFieldsRecordTypeMismatch(expected: String, actual: String)
  case descriptorRecordTypeMismatch(expected: String, actual: String)
  case snapshotIdentityMismatch(expected: String, actual: String)
  case unexpectedSnapshotField(String)
  case missingRequiredSnapshotField(String)
  case snapshotFieldKindMismatch(
    key: String,
    expected: CloudFieldKind,
    actual: CloudFieldKind
  )
  case invalidField(key: String, expected: CloudFieldKind)
  case integerOutOfRange(key: String)
  case unexpectedAssetField(String)
  case duplicateAssetMutation(String)
  case missingAssetFile(String)
  case invalidAssetField(String)
}

struct CloudKitDecodedRecord: Sendable, Hashable {
  let snapshot: CloudRecordSnapshot
  let assets: [CloudDataRemoteAssetChange]
}

/// Fixed field conversion between the CK-free snapshot and CKRecord.
enum CloudKitRecordAdapter {
  static func makeRecord(
    from outgoing: CloudDataOutgoingRecord,
    descriptor: CloudModelDescriptor,
    recordID: CKRecord.ID
  ) throws -> CKRecord {
    guard descriptor.recordType == outgoing.recordType else {
      throw CloudKitRecordAdapterError.descriptorRecordTypeMismatch(
        expected: outgoing.recordType,
        actual: descriptor.recordType
      )
    }
    guard outgoing.snapshot.recordName == recordID.recordName else {
      throw CloudKitRecordAdapterError.snapshotIdentityMismatch(
        expected: recordID.recordName,
        actual: outgoing.snapshot.recordName
      )
    }
    try validate(snapshot: outgoing.snapshot, descriptor: descriptor)

    let record: CKRecord
    if let systemFieldsData = outgoing.systemFieldsData {
      guard let restored = Self.record(fromSystemFields: systemFieldsData) else {
        throw CloudKitRecordAdapterError.systemFieldsCannotBeDecoded
      }
      guard restored.recordID == recordID else {
        throw CloudKitRecordAdapterError.systemFieldsIdentityMismatch(
          expected: recordID.recordName,
          actual: restored.recordID.recordName
        )
      }
      guard restored.recordType == outgoing.recordType else {
        throw CloudKitRecordAdapterError.systemFieldsRecordTypeMismatch(
          expected: outgoing.recordType,
          actual: restored.recordType
        )
      }
      record = restored
    } else {
      record = CKRecord(recordType: outgoing.recordType, recordID: recordID)
    }

    // Setting nil for known absent optional fields makes their deletion an
    // explicit changed key while leaving future unknown server fields alone.
    for field in descriptor.wireFields {
      record[field.key] = nil
    }
    for (key, value) in outgoing.snapshot.fields {
      switch value {
      case .string(let value):
        record[key] = value
      case .bool(let value):
        record[key] = value
      case .int(let value):
        record[key] = Int64(value)
      case .int64(let value):
        record[key] = value
      case .double(let value):
        record[key] = value
      case .date(let value):
        record[key] = value
      case .data(let value):
        record[key] = value
      case .location(let value):
        record[key] = CLLocation(
          latitude: value.latitude,
          longitude: value.longitude
        )
      }
    }
    let assetKeys = Set(descriptor.assets.map(\.key))
    var changedAssetKeys = Set<String>()
    for asset in outgoing.assets {
      guard assetKeys.contains(asset.fieldKey) else {
        throw CloudKitRecordAdapterError.unexpectedAssetField(asset.fieldKey)
      }
      guard changedAssetKeys.insert(asset.fieldKey).inserted else {
        throw CloudKitRecordAdapterError.duplicateAssetMutation(asset.fieldKey)
      }
      switch asset.kind {
      case .replace:
        guard let fileURL = asset.stagedFileURL else {
          throw CloudKitRecordAdapterError.missingAssetFile(asset.fieldKey)
        }
        record[asset.fieldKey] = CKAsset(fileURL: fileURL)
      case .remove:
        record[asset.fieldKey] = nil
      }
    }
    return record
  }

  static func snapshot(
    from record: CKRecord,
    descriptor: CloudModelDescriptor
  ) throws -> CloudRecordSnapshot {
    try decodedRecord(from: record, descriptor: descriptor).snapshot
  }

  static func decodedRecord(
    from record: CKRecord,
    descriptor: CloudModelDescriptor
  ) throws -> CloudKitDecodedRecord {
    var fields: [String: CloudFieldValue] = [:]
    fields.reserveCapacity(descriptor.wireFields.count)

    for field in descriptor.wireFields {
      let rawValue: (any CKRecordValueProtocol)? = record[field.key]
      guard let rawValue else { continue }
      fields[field.key] = try fieldValue(
        from: rawValue,
        field: field
      )
    }
    let assets = try descriptor.assets.map { asset in
      guard let value = record[asset.key] else {
        return CloudDataRemoteAssetChange(fieldKey: asset.key, action: .remove)
      }
      guard
        let cloudAsset = value as? CKAsset,
        let fileURL = cloudAsset.fileURL
      else {
        throw CloudKitRecordAdapterError.invalidAssetField(asset.key)
      }
      return CloudDataRemoteAssetChange(
        fieldKey: asset.key,
        action: .replace(systemFileURL: fileURL)
      )
    }
    return CloudKitDecodedRecord(
      snapshot: CloudRecordSnapshot(
        recordName: record.recordID.recordName,
        fields: fields
      ),
      assets: assets
    )
  }

  static func encodeSystemFields(of record: CKRecord) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }

  static func record(fromSystemFields data: Data) -> CKRecord? {
    guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
      return nil
    }
    unarchiver.requiresSecureCoding = true
    defer { unarchiver.finishDecoding() }
    return CKRecord(coder: unarchiver)
  }

  private static func fieldValue(
    from rawValue: any CKRecordValueProtocol,
    field: CloudFieldDescriptor
  ) throws -> CloudFieldValue {
    switch field.kind {
    case .string:
      guard let value = rawValue as? String else {
        throw invalid(field)
      }
      return .string(value)

    case .bool:
      if let value = rawValue as? Bool {
        return .bool(value)
      }
      // CKRecord's Swift overlay normalizes a locally-assigned Bool to an
      // Int64 payload. The generated descriptor supplies the missing schema
      // category, so only the canonical 0/1 values are accepted here.
      if let value = rawValue as? Int64, value == 0 || value == 1 {
        return .bool(value == 1)
      }
      guard
        let value = rawValue as? NSNumber,
        CFGetTypeID(value) == CFBooleanGetTypeID()
          || value.doubleValue == 0
          || value.doubleValue == 1
      else {
        throw invalid(field)
      }
      return .bool(value.boolValue)

    case .int:
      let integer = try signedInteger(from: rawValue, field: field)
      guard let value = Int(exactly: integer) else {
        throw CloudKitRecordAdapterError.integerOutOfRange(key: field.key)
      }
      return .int(value)

    case .int64:
      return .int64(try signedInteger(from: rawValue, field: field))

    case .double:
      if let value = rawValue as? Double {
        return .double(value)
      }
      guard
        let value = rawValue as? NSNumber,
        CFGetTypeID(value) != CFBooleanGetTypeID()
      else {
        throw invalid(field)
      }
      return .double(value.doubleValue)

    case .date:
      guard let value = rawValue as? Date else {
        throw invalid(field)
      }
      return .date(value)

    case .data:
      guard let value = rawValue as? Data else {
        throw invalid(field)
      }
      return .data(value)

    case .location:
      guard
        let value = rawValue as? CLLocation,
        let location = CloudLocationValue(
          latitude: value.coordinate.latitude,
          longitude: value.coordinate.longitude
        )
      else {
        throw invalid(field)
      }
      return .location(location)
    }
  }

  private static func signedInteger(
    from rawValue: any CKRecordValueProtocol,
    field: CloudFieldDescriptor
  ) throws -> Int64 {
    if let value = rawValue as? Int64 {
      return value
    }
    if let value = rawValue as? Int {
      return Int64(value)
    }
    guard
      let number = rawValue as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
      throw invalid(field)
    }
    let value = number.int64Value
    guard number.doubleValue == Double(value) else {
      throw invalid(field)
    }
    return value
  }

  private static func invalid(
    _ field: CloudFieldDescriptor
  ) -> CloudKitRecordAdapterError {
    .invalidField(key: field.key, expected: field.kind)
  }

  private static func validate(
    snapshot: CloudRecordSnapshot,
    descriptor: CloudModelDescriptor
  ) throws {
    let fieldsByKey = Dictionary(
      uniqueKeysWithValues: descriptor.wireFields.map { ($0.key, $0) }
    )
    for field in descriptor.wireFields where field.isOptional == false {
      guard snapshot.fields[field.key] != nil else {
        throw CloudKitRecordAdapterError.missingRequiredSnapshotField(
          field.key
        )
      }
    }
    for (key, value) in snapshot.fields {
      guard let field = fieldsByKey[key] else {
        throw CloudKitRecordAdapterError.unexpectedSnapshotField(key)
      }
      guard field.kind == value.kind else {
        throw CloudKitRecordAdapterError.snapshotFieldKindMismatch(
          key: key,
          expected: field.kind,
          actual: value.kind
        )
      }
    }
  }
}
