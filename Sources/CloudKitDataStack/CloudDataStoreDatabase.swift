import CloudKitData
import Foundation
import SwiftData

struct CloudDataPendingChange: Sendable, Hashable {
  let recordName: String
  let recordType: String
  let kind: CloudDataMutationKind
  let revision: String
  let enqueuedAt: Date
}

struct CloudDataOutgoingAsset: Sendable, Hashable {
  let fieldKey: String
  let kind: CloudDataAssetMutationKind
  let stagedFileURL: URL?
}

struct CloudDataOutgoingRecord: Sendable {
  let recordType: String
  let snapshot: CloudRecordSnapshot
  let systemFieldsData: Data?
  let revision: String
  let assets: [CloudDataOutgoingAsset]

  init(
    recordType: String,
    snapshot: CloudRecordSnapshot,
    systemFieldsData: Data?,
    revision: String = UUID().uuidString,
    assets: [CloudDataOutgoingAsset] = []
  ) {
    self.recordType = recordType
    self.snapshot = snapshot
    self.systemFieldsData = systemFieldsData
    self.revision = revision
    self.assets = assets
  }
}

enum CloudDataRemoteAssetAction: Sendable, Hashable {
  case replace(systemFileURL: URL)
  case remove
}

struct CloudDataRemoteAssetChange: Sendable, Hashable {
  let fieldKey: String
  let action: CloudDataRemoteAssetAction
}

private struct CloudDataPreparedAssetInstall: Sendable {
  let identity: String
  let revision: String
  let reference: CloudDataAssetReference
  let action: CloudDataIncomingAssetAction
  let stagedFileID: String?
}

private struct CloudDataAssetInstallOperation: Sendable {
  let revision: String
  let task: Task<Void, Error>
}

enum CloudDataRemoteImportOutcome: Sendable, Hashable {
  case inserted
  case merged
  case keptLocalPending
  case absent
}

enum CloudDataStoreRuntimeError: Error, Sendable, Equatable {
  case corruptMutationKind(recordName: String, rawValue: String)
  case corruptAssetMutationKind(recordName: String, fieldKey: String, rawValue: String)
  case missingMutationRevision(recordName: String)
  case unknownRecordType(String)
  case missingModelForPendingSave(recordType: String, recordName: String)
  case pendingSnapshotIdentityMismatch(expected: String, actual: String)
  case recordNameCollision(
    recordName: String,
    existingRecordType: String,
    requestedRecordType: String
  )
  case relationshipTargetRegistrationMissing(
    sourceRecordType: String,
    key: String,
    targetModelType: String
  )
  case relationshipOperationMissing(sourceRecordType: String, key: String)
  case emptyRelationshipTargetRecordName(sourceRecordType: String, key: String)
  case assetOperationMissing(recordType: String, key: String)
  case assetMutationRevisionMismatch(recordName: String, fieldKey: String)
  case assetStagedFileMissing(recordName: String, fieldKey: String)
  case corruptAssetTransferDirection(fileID: String, rawValue: String)
  case remoteSavePolicyRequiresExistingModel(recordType: String, recordName: String)
}

struct CloudDataSavedRecordAcknowledgement: Sendable {
  let metrics: CloudDataStoreMetrics
  let didConsumePendingMutation: Bool

  var pendingCount: Int { metrics.pendingCount }
}

struct CloudDataDeletedRecordAcknowledgement: Sendable {
  let metrics: CloudDataStoreMetrics
  let didConsumePendingMutation: Bool

  var pendingCount: Int { metrics.pendingCount }
}

/// Background SwiftData access for one store's transport work.
actor CloudDataStoreDatabase: ModelActor {
  nonisolated let modelExecutor: any ModelExecutor
  nonisolated let modelContainer: ModelContainer

  private let registry: CloudDataModelRegistry
  private let storeID: CloudDataStoreID
  private let assetStore: CloudDataAssetStore?
  private let storePolicy: CloudDataStorePolicy
  private let assetFileStore: CloudDataAssetFileStore
  private let storeLock: CloudDataStoreLock
  private var assetInstallOperations: [String: CloudDataAssetInstallOperation] = [:]
  private var inFlightAssetFileIDs = Set<String>()
  private var deferredAssetFileDeletions = Set<String>()

  init(
    modelContainer: ModelContainer,
    registry: CloudDataModelRegistry,
    storeID: CloudDataStoreID,
    assetStore: CloudDataAssetStore?,
    storePolicy: CloudDataStorePolicy,
    assetFileStore: CloudDataAssetFileStore,
    storeLock: CloudDataStoreLock
  ) {
    self.modelContainer = modelContainer
    self.registry = registry
    self.storeID = storeID
    self.assetStore = assetStore
    self.storePolicy = storePolicy
    self.assetFileStore = assetFileStore
    self.storeLock = storeLock
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
  }

  /// Returns durable pending work and optionally clears stale pre-crash stages.
  func pendingChanges(resetStaging: Bool) throws -> [CloudDataPendingChange] {
    try storeLock.withLock {
      do {
        refreshModelContext()
        var descriptor = FetchDescriptor<CloudDataPendingMutation>(
          sortBy: [
            SortDescriptor(\.enqueuedAt),
            SortDescriptor(\.recordName),
          ]
        )
        descriptor.includePendingChanges = true
        let mutations = try modelContext.fetch(descriptor)
        var result: [CloudDataPendingChange] = []
        result.reserveCapacity(mutations.count)
        var didChange = false

        for mutation in mutations {
          guard let kind = mutation.kind else {
            throw CloudDataStoreRuntimeError.corruptMutationKind(
              recordName: mutation.recordName,
              rawValue: mutation.kindRawValue
            )
          }
          let revision: String
          if let existing = mutation.revisionRawValue {
            revision = existing
          } else {
            revision = UUID().uuidString
            mutation.revisionRawValue = revision
            didChange = true
          }
          if resetStaging {
            mutation.stagedAt = nil
            mutation.stagedRevisionRawValue = nil
            didChange = true
          }
          result.append(
            CloudDataPendingChange(
              recordName: mutation.recordName,
              recordType: mutation.recordType,
              kind: kind,
              revision: revision,
              enqueuedAt: mutation.enqueuedAt
            )
          )
        }
        if didChange {
          try modelContext.save()
        }
        return result
      } catch {
        if resetStaging {
          modelContext.rollback()
        }
        throw error
      }
    }
  }

  func pendingChange(recordName: String) throws -> CloudDataPendingChange? {
    try storeLock.withLock {
      refreshModelContext()
      guard let mutation = try fetchPending(recordName: recordName) else { return nil }
      guard let kind = mutation.kind else {
        throw CloudDataStoreRuntimeError.corruptMutationKind(
          recordName: mutation.recordName,
          rawValue: mutation.kindRawValue
        )
      }
      let revision: String
      if let existing = mutation.revisionRawValue {
        revision = existing
      } else {
        revision = UUID().uuidString
        mutation.revisionRawValue = revision
        try modelContext.save()
      }
      return CloudDataPendingChange(
        recordName: mutation.recordName,
        recordType: mutation.recordType,
        kind: kind,
        revision: revision,
        enqueuedAt: mutation.enqueuedAt
      )
    }
  }

  /// Rebuilds the current payload and marks exactly that save as staged.
  func prepareOutgoingSave(
    recordName: String,
    stagedAt: Date = .now
  ) throws -> CloudDataOutgoingRecord? {
    try storeLock.withLock {
      do {
        refreshModelContext()
        guard let pending = try fetchPending(recordName: recordName) else { return nil }
        guard pending.kind == .save else { return nil }
        guard let registration = registry.registrationsByRecordType[pending.recordType] else {
          throw CloudDataStoreRuntimeError.unknownRecordType(pending.recordType)
        }
        guard
          let model = try registration.fetch(
            recordName: recordName,
            in: modelContext
          )
        else {
          throw CloudDataStoreRuntimeError.missingModelForPendingSave(
            recordType: pending.recordType,
            recordName: recordName
          )
        }

        let snapshot = try registration.makeSnapshot(from: model)
        guard snapshot.recordName == recordName else {
          throw CloudDataStoreRuntimeError.pendingSnapshotIdentityMismatch(
            expected: recordName,
            actual: snapshot.recordName
          )
        }
        let metadata = try fetchMetadata(recordName: recordName)
        if let metadata {
          try validateRecordType(
            metadata.recordType,
            requestedRecordType: pending.recordType,
            recordName: recordName
          )
        }
        guard let revision = pending.revisionRawValue else {
          throw CloudDataStoreRuntimeError.missingMutationRevision(
            recordName: recordName
          )
        }
        let assets = try outgoingAssets(
          recordType: pending.recordType,
          recordName: recordName,
          revision: revision,
          registration: registration
        )
        pending.stagedAt = stagedAt
        pending.stagedRevisionRawValue = revision
        pending.latestErrorCategoryRawValue = nil
        pending.latestErrorMessage = nil
        pending.latestErrorAt = nil
        try modelContext.save()

        return CloudDataOutgoingRecord(
          recordType: pending.recordType,
          snapshot: snapshot,
          systemFieldsData: metadata?.systemFieldsData,
          revision: revision,
          assets: assets
        )
      } catch {
        modelContext.rollback()
        throw error
      }
    }
  }

  /// Marks a delete only when it is actually selected for an outgoing batch.
  func stageDelete(recordName: String, at date: Date = .now) throws -> String? {
    try storeLock.withLock {
      do {
        refreshModelContext()
        guard
          let pending = try fetchPending(recordName: recordName),
          pending.kind == .delete
        else {
          return nil
        }
        guard let revision = pending.revisionRawValue else {
          throw CloudDataStoreRuntimeError.missingMutationRevision(
            recordName: recordName
          )
        }
        pending.stagedAt = date
        pending.stagedRevisionRawValue = revision
        pending.latestErrorCategoryRawValue = nil
        pending.latestErrorMessage = nil
        pending.latestErrorAt = nil
        try modelContext.save()
        return revision
      } catch {
        modelContext.rollback()
        throw error
      }
    }
  }

  /// Applies a fetched scalar record without producing a local outbox echo.
  func applyRemoteSave(
    recordType: String,
    snapshot: CloudRecordSnapshot,
    systemFieldsData: Data,
    assets: [CloudDataRemoteAssetChange] = [],
    acceptedAt: Date = .now
  ) async throws -> CloudDataRemoteImportOutcome {
    var newlyStagedFileIDs = Set<String>()
    var obsoleteFileIDs = Set<String>()
    let outcome: CloudDataRemoteImportOutcome = try storeLock.withLock {
      do {
        refreshModelContext()
        guard let registration = registry.registrationsByRecordType[recordType] else {
          throw CloudDataStoreRuntimeError.unknownRecordType(recordType)
        }
        let pending = try fetchPending(recordName: snapshot.recordName)
        if let pending {
          try validateRecordType(
            pending.recordType,
            requestedRecordType: recordType,
            recordName: snapshot.recordName
          )
        }
        try upsertMetadata(
          recordType: recordType,
          recordName: snapshot.recordName,
          systemFieldsData: systemFieldsData,
          acceptedAt: acceptedAt
        )

        if pending != nil {
          // The generic scalar policy is record-level local-pending-wins. The
          // accepted server shell still advances so the retry has its tag.
          guard
            let localModel = try registration.fetch(
              recordName: snapshot.recordName,
              in: modelContext
            )
          else {
            throw CloudDataStoreRuntimeError.missingModelForPendingSave(
              recordType: recordType,
              recordName: snapshot.recordName
            )
          }
          try reconcileRelationships(
            source: localModel,
            registration: registration,
            sourceRecordName: snapshot.recordName,
            attemptedAt: acceptedAt
          )
          try repairUnresolvedRelationships(
            targetingRecordType: recordType,
            targetRecordName: snapshot.recordName,
            target: localModel,
            attemptedAt: acceptedAt
          )
          try enqueueRemoteAssets(
            assets,
            for: localModel,
            registration: registration,
            recordName: snapshot.recordName,
            observedAt: acceptedAt,
            newlyStagedFileIDs: &newlyStagedFileIDs,
            obsoleteFileIDs: &obsoleteFileIDs
          )
          try modelContext.save()
          return .keptLocalPending
        }

        let existing = try registration.fetch(
          recordName: snapshot.recordName,
          in: modelContext
        )
        let action = try storePolicy.prepareSave(
          CloudDataRemoteSavePolicyContext(
            storeID: storeID,
            recordType: recordType,
            snapshot: snapshot,
            acceptedAt: acceptedAt,
            modelContext: modelContext,
            existingModel: existing
          )
        )

        let model: any PersistentModel
        let outcome: CloudDataRemoteImportOutcome
        switch action {
        case .apply(let resolvedSnapshot):
          if let existing {
            try registration.apply(resolvedSnapshot, to: existing)
            model = existing
            outcome = .merged
          } else {
            model = try registration.materialize(resolvedSnapshot)
            modelContext.insert(model)
            outcome = .inserted
          }

        case .preserveExisting:
          guard let existing else {
            throw CloudDataStoreRuntimeError.remoteSavePolicyRequiresExistingModel(
              recordType: recordType,
              recordName: snapshot.recordName
            )
          }
          model = existing
          outcome = .merged
        }

        try reconcileRelationships(
          source: model,
          registration: registration,
          sourceRecordName: snapshot.recordName,
          attemptedAt: acceptedAt
        )
        try repairUnresolvedRelationships(
          targetingRecordType: recordType,
          targetRecordName: snapshot.recordName,
          target: model,
          attemptedAt: acceptedAt
        )
        try enqueueRemoteAssets(
          assets,
          for: model,
          registration: registration,
          recordName: snapshot.recordName,
          observedAt: acceptedAt,
          newlyStagedFileIDs: &newlyStagedFileIDs,
          obsoleteFileIDs: &obsoleteFileIDs
        )
        try storePolicy.didApplySave(
          CloudDataAppliedRemoteSaveContext(
            storeID: storeID,
            recordType: recordType,
            recordName: snapshot.recordName,
            acceptedAt: acceptedAt,
            modelContext: modelContext,
            model: model,
            wasInserted: outcome == .inserted
          )
        )
        try modelContext.save()
        return outcome
      } catch {
        modelContext.rollback()
        for fileID in newlyStagedFileIDs {
          removeAssetFileWhenUnused(fileID: fileID)
        }
        throw error
      }
    }
    for fileID in obsoleteFileIDs {
      removeAssetFileWhenUnused(fileID: fileID)
    }
    try await processPendingAssetInstalls(recordName: snapshot.recordName)
    return outcome
  }

  /// Applies a remote tombstone unless local durable work explicitly recreates it.
  ///
  /// Asset-slot removals are committed as durable install work with the model
  /// deletion, then delivered to the consumer before this operation returns.
  func applyRemoteDelete(
    recordType: String,
    recordName: String,
    observedAt: Date = .now
  ) async throws -> CloudDataRemoteImportOutcome {
    var newlyStagedFileIDs = Set<String>()
    var filesToDelete = Set<String>()
    let outcome: CloudDataRemoteImportOutcome = try storeLock.withLock {
      do {
        refreshModelContext()
        guard let registration = registry.registrationsByRecordType[recordType] else {
          throw CloudDataStoreRuntimeError.unknownRecordType(recordType)
        }
        let pending = try fetchPending(recordName: recordName)
        if let pending {
          try validateRecordType(
            pending.recordType,
            requestedRecordType: recordType,
            recordName: recordName
          )
        }
        if let metadata = try fetchMetadata(recordName: recordName) {
          try validateRecordType(
            metadata.recordType,
            requestedRecordType: recordType,
            recordName: recordName
          )
          modelContext.delete(metadata)
        }
        let existingModel = try registration.fetch(
          recordName: recordName,
          in: modelContext
        )
        switch try storePolicy.applyDelete(
          CloudDataRemoteDeletePolicyContext(
            storeID: storeID,
            recordType: recordType,
            recordName: recordName,
            observedAt: observedAt,
            hasPendingMutation: pending != nil,
            modelContext: modelContext,
            existingModel: existingModel
          )
        ) {
        case .applyDefault:
          break

        case .handled(let discardPendingMutation):
          try deleteUnresolvedRelationships(
            recordType: recordType,
            recordName: recordName
          )
          if discardPendingMutation {
            try discardPendingMutationAndAssets(
              recordName: recordName,
              filesToDelete: &filesToDelete
            )
          }
          try modelContext.save()
          return existingModel == nil ? .absent : .merged
        }
        if pending != nil {
          try deletePendingAssetInstalls(
            recordName: recordName,
            filesToDelete: &filesToDelete
          )
          try modelContext.save()
          return .keptLocalPending
        }

        try deleteUnresolvedRelationships(
          recordType: recordType,
          recordName: recordName
        )

        guard let model = try registration.fetch(recordName: recordName, in: modelContext) else {
          try supersedePendingAssetInstallsWithRemovals(
            recordType: recordType,
            recordName: recordName,
            observedAt: observedAt,
            filesToDelete: &filesToDelete
          )
          try modelContext.save()
          return .absent
        }
        try enqueueRemoteAssets(
          registration.assets.map {
            CloudDataRemoteAssetChange(
              fieldKey: $0.descriptor.key,
              action: .remove
            )
          },
          for: model,
          registration: registration,
          recordName: recordName,
          observedAt: observedAt,
          newlyStagedFileIDs: &newlyStagedFileIDs,
          obsoleteFileIDs: &filesToDelete
        )
        modelContext.delete(model)
        try modelContext.save()
        return .merged
      } catch {
        modelContext.rollback()
        for fileID in newlyStagedFileIDs {
          removeAssetFileWhenUnused(fileID: fileID)
        }
        throw error
      }
    }
    for fileID in filesToDelete {
      removeAssetFileWhenUnused(fileID: fileID)
    }
    try await processPendingAssetInstalls(recordName: recordName)
    return outcome
  }

  /// Commits server metadata and consumes only the exact staged save revision.
  func acknowledgeSavedRecord(
    recordType: String,
    recordName: String,
    stagedRevision: String,
    systemFieldsData: Data,
    acceptedAt: Date = .now
  ) throws -> CloudDataSavedRecordAcknowledgement {
    var filesToDelete = Set<String>()
    let acknowledgement = try storeLock.withLock {
      do {
        refreshModelContext()
        try upsertMetadata(
          recordType: recordType,
          recordName: recordName,
          systemFieldsData: systemFieldsData,
          acceptedAt: acceptedAt
        )
        var didConsumePendingMutation = false
        if let pending = try fetchPending(recordName: recordName) {
          try validateRecordType(
            pending.recordType,
            requestedRecordType: recordType,
            recordName: recordName
          )
          if pending.kind == .save,
            pending.revisionRawValue == stagedRevision,
            pending.stagedRevisionRawValue == stagedRevision
          {
            try deletePendingAssetMutations(
              recordName: recordName,
              mutationRevision: stagedRevision
            )
            modelContext.delete(pending)
            didConsumePendingMutation = true
          }
        }
        try pruneOutgoingStagedFiles(
          recordName: recordName,
          filesToDelete: &filesToDelete
        )
        let metrics = try metricsUnlocked()
        try modelContext.save()
        return CloudDataSavedRecordAcknowledgement(
          metrics: metrics,
          didConsumePendingMutation: didConsumePendingMutation
        )
      } catch {
        modelContext.rollback()
        throw error
      }
    }
    for fileID in filesToDelete {
      removeAssetFileWhenUnused(fileID: fileID)
    }
    return acknowledgement
  }

  /// Consumes only a staged delete and removes its obsolete system-field shell.
  func acknowledgeDeletedRecord(
    recordName: String,
    stagedRevision: String
  ) throws -> CloudDataDeletedRecordAcknowledgement {
    var filesToDelete = Set<String>()
    let acknowledgement = try storeLock.withLock {
      do {
        refreshModelContext()
        var didConsumePendingMutation = false
        if let pending = try fetchPending(recordName: recordName),
          pending.kind == .delete,
          pending.revisionRawValue == stagedRevision,
          pending.stagedRevisionRawValue == stagedRevision
        {
          modelContext.delete(pending)
          didConsumePendingMutation = true
        }
        if let metadata = try fetchMetadata(recordName: recordName) {
          modelContext.delete(metadata)
        }
        try pruneOutgoingStagedFiles(
          recordName: recordName,
          filesToDelete: &filesToDelete
        )
        let metrics = try metricsUnlocked()
        try modelContext.save()
        return CloudDataDeletedRecordAcknowledgement(
          metrics: metrics,
          didConsumePendingMutation: didConsumePendingMutation
        )
      } catch {
        modelContext.rollback()
        throw error
      }
    }
    for fileID in filesToDelete {
      removeAssetFileWhenUnused(fileID: fileID)
    }
    return acknowledgement
  }

  func forgetMetadata(recordName: String) throws {
    try storeLock.withLock {
      do {
        if let metadata = try fetchMetadata(recordName: recordName) {
          modelContext.delete(metadata)
          try modelContext.save()
        }
      } catch {
        modelContext.rollback()
        throw error
      }
    }
  }

  func recordPendingFailure(
    recordName: String,
    error: CloudDataErrorSummary
  ) throws {
    try storeLock.withLock {
      do {
        guard let pending = try fetchPending(recordName: recordName) else { return }
        pending.latestErrorCategoryRawValue = error.category.rawValue
        pending.latestErrorMessage = error.message
        pending.latestErrorAt = error.occurredAt
        try modelContext.save()
      } catch {
        modelContext.rollback()
        throw error
      }
    }
  }

  /// Reconciles durable rows with package files, removes abandoned staging,
  /// and replays every incomplete incoming installation.
  func recoverAssetTransfers() async throws {
    var filesToDelete = Set<String>()
    let retainedFileIDs = try storeLock.withLock {
      do {
        var mutationDescriptor = FetchDescriptor<CloudDataPendingAssetMutation>()
        mutationDescriptor.includePendingChanges = true
        let mutations = try modelContext.fetch(mutationDescriptor)

        var installDescriptor = FetchDescriptor<CloudDataPendingAssetInstall>()
        installDescriptor.includePendingChanges = true
        let installs = try modelContext.fetch(installDescriptor)

        let referencedFileIDs = Set(
          mutations.compactMap(\.stagedFileID)
            + installs.compactMap(\.stagedFileID)
        )

        var fileDescriptor = FetchDescriptor<CloudDataStagedAssetFile>()
        fileDescriptor.includePendingChanges = true
        let files = try modelContext.fetch(fileDescriptor)
        let rowsByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })

        for fileID in referencedFileIDs {
          guard rowsByID[fileID] != nil else {
            throw CloudDataAssetTransferError.stagedFileMissing(fileID: fileID)
          }
          _ = try assetFileStore.requireFileURL(fileID: fileID)
        }
        for file in files where referencedFileIDs.contains(file.id) == false {
          filesToDelete.insert(file.id)
          modelContext.delete(file)
        }

        if filesToDelete.isEmpty == false {
          try modelContext.save()
        }
        return referencedFileIDs
      } catch {
        modelContext.rollback()
        throw error
      }
    }

    for fileID in filesToDelete {
      removeAssetFileWhenUnused(fileID: fileID)
    }
    try assetFileStore.removeUntrackedFiles(
      retaining: retainedFileIDs.union(inFlightAssetFileIDs)
    )
    try await processPendingAssetInstalls(recordName: nil)
  }

  private func outgoingAssets(
    recordType: String,
    recordName: String,
    revision: String,
    registration: CloudModelRegistration
  ) throws -> [CloudDataOutgoingAsset] {
    var descriptor = FetchDescriptor<CloudDataPendingAssetMutation>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.includePendingChanges = true
    let mutations = try modelContext.fetch(descriptor)
    let descriptorsByKey = Dictionary(
      uniqueKeysWithValues: registration.assets.map { ($0.descriptor.key, $0.descriptor) }
    )

    return
      try mutations
      .sorted { $0.fieldKey < $1.fieldKey }
      .map { mutation in
        try validateRecordType(
          mutation.recordType,
          requestedRecordType: recordType,
          recordName: recordName
        )
        guard descriptorsByKey[mutation.fieldKey] != nil else {
          throw CloudDataStoreRuntimeError.assetOperationMissing(
            recordType: recordType,
            key: mutation.fieldKey
          )
        }
        guard mutation.mutationRevision == revision else {
          throw CloudDataStoreRuntimeError.assetMutationRevisionMismatch(
            recordName: recordName,
            fieldKey: mutation.fieldKey
          )
        }
        guard let kind = mutation.kind else {
          throw CloudDataStoreRuntimeError.corruptAssetMutationKind(
            recordName: recordName,
            fieldKey: mutation.fieldKey,
            rawValue: mutation.kindRawValue
          )
        }

        switch kind {
        case .replace:
          guard
            let fileID = mutation.stagedFileID,
            let file = try fetchStagedAssetFile(id: fileID),
            file.direction == .outgoing,
            file.recordName == recordName,
            file.fieldKey == mutation.fieldKey
          else {
            throw CloudDataStoreRuntimeError.assetStagedFileMissing(
              recordName: recordName,
              fieldKey: mutation.fieldKey
            )
          }
          return CloudDataOutgoingAsset(
            fieldKey: mutation.fieldKey,
            kind: kind,
            stagedFileURL: try assetFileStore.requireFileURL(fileID: fileID)
          )

        case .remove:
          return CloudDataOutgoingAsset(
            fieldKey: mutation.fieldKey,
            kind: kind,
            stagedFileURL: nil
          )
        }
      }
  }

  private func enqueueRemoteAssets(
    _ changes: [CloudDataRemoteAssetChange],
    for model: any PersistentModel,
    registration: CloudModelRegistration,
    recordName: String,
    observedAt: Date,
    newlyStagedFileIDs: inout Set<String>,
    obsoleteFileIDs: inout Set<String>
  ) throws {
    var seenKeys = Set<String>()
    for change in changes {
      guard seenKeys.insert(change.fieldKey).inserted else {
        throw CloudDataStoreRuntimeError.assetOperationMissing(
          recordType: registration.descriptor.recordType,
          key: change.fieldKey
        )
      }
      guard
        let asset = registration.assets.first(where: {
          $0.descriptor.key == change.fieldKey
        })
      else {
        throw CloudDataStoreRuntimeError.assetOperationMissing(
          recordType: registration.descriptor.recordType,
          key: change.fieldKey
        )
      }

      let identity = CloudDataPendingAssetMutation.makeIdentity(
        recordName: recordName,
        fieldKey: change.fieldKey
      )
      if try fetchPendingAssetMutation(identity: identity) != nil {
        try deletePendingAssetInstall(
          identity: identity,
          obsoleteFileIDs: &obsoleteFileIDs
        )
        continue
      }

      let slot = try asset.slot(from: model)
      guard slot.localIdentifier.isEmpty == false else {
        throw CloudDataAssetTransferError.emptyLocalIdentifier(
          recordType: registration.descriptor.recordType,
          fieldKey: change.fieldKey
        )
      }

      let kind: CloudDataAssetMutationKind
      let stagedFileID: String?
      switch change.action {
      case .replace(let systemFileURL):
        kind = .replace
        let fileID = try assetFileStore.stageIncoming(from: systemFileURL)
        stagedFileID = fileID
        newlyStagedFileIDs.insert(fileID)
        modelContext.insert(
          CloudDataStagedAssetFile(
            id: fileID,
            direction: .incoming,
            recordName: recordName,
            fieldKey: change.fieldKey,
            createdAt: observedAt
          )
        )
      case .remove:
        kind = .remove
        stagedFileID = nil
      }

      let installRevision = UUID().uuidString
      if let install = try fetchPendingAssetInstall(identity: identity) {
        if let previousFileID = install.stagedFileID,
          previousFileID != stagedFileID
        {
          if let file = try fetchStagedAssetFile(id: previousFileID) {
            modelContext.delete(file)
          }
          obsoleteFileIDs.insert(previousFileID)
        }
        install.recordType = registration.descriptor.recordType
        install.localIdentifier = slot.localIdentifier
        install.kind = kind
        install.installRevision = installRevision
        install.stagedFileID = stagedFileID
        install.observedAt = observedAt
        install.latestErrorMessage = nil
        install.latestErrorAt = nil
      } else {
        modelContext.insert(
          CloudDataPendingAssetInstall(
            recordType: registration.descriptor.recordType,
            recordName: recordName,
            fieldKey: change.fieldKey,
            localIdentifier: slot.localIdentifier,
            kind: kind,
            installRevision: installRevision,
            stagedFileID: stagedFileID,
            observedAt: observedAt
          )
        )
      }
    }
  }

  private func processPendingAssetInstalls(recordName: String?) async throws {
    while let pending = try nextPendingAssetInstall(recordName: recordName) {
      let operation: CloudDataAssetInstallOperation
      if let existing = assetInstallOperations[pending.identity] {
        operation = existing
      } else {
        let task = Task {
          try await self.performAssetInstall(pending)
        }
        operation = CloudDataAssetInstallOperation(
          revision: pending.revision,
          task: task
        )
        assetInstallOperations[pending.identity] = operation
      }

      do {
        try await operation.task.value
      } catch {
        clearAssetInstallOperation(
          identity: pending.identity,
          revision: operation.revision
        )
        if try assetInstallWasSuperseded(
          identity: pending.identity,
          revision: operation.revision
        ) {
          continue
        }
        throw error
      }
      clearAssetInstallOperation(
        identity: pending.identity,
        revision: operation.revision
      )
    }
  }

  private func performAssetInstall(
    _ pending: CloudDataPreparedAssetInstall
  ) async throws {
    guard let assetStore else {
      throw CloudDataAssetTransferError.assetStoreUnavailable
    }
    if let stagedFileID = pending.stagedFileID {
      inFlightAssetFileIDs.insert(stagedFileID)
    }
    defer {
      finishUsingAssetFile(fileID: pending.stagedFileID)
    }

    do {
      try await assetStore.installIncoming(
        pending.reference,
        action: pending.action
      )
    } catch {
      try recordAssetInstallFailure(
        identity: pending.identity,
        revision: pending.revision,
        error: error
      )
      throw error
    }

    let completedFileID = try completeAssetInstall(
      identity: pending.identity,
      revision: pending.revision
    )
    if let completedFileID {
      removeAssetFileWhenUnused(fileID: completedFileID)
    }
  }

  private func clearAssetInstallOperation(
    identity: String,
    revision: String
  ) {
    guard assetInstallOperations[identity]?.revision == revision else { return }
    assetInstallOperations.removeValue(forKey: identity)
  }

  private func assetInstallWasSuperseded(
    identity: String,
    revision: String
  ) throws -> Bool {
    try storeLock.withLock {
      guard let install = try fetchPendingAssetInstall(identity: identity) else {
        return true
      }
      return install.installRevision != revision
    }
  }

  private func removeAssetFileWhenUnused(fileID: String) {
    guard inFlightAssetFileIDs.contains(fileID) == false else {
      deferredAssetFileDeletions.insert(fileID)
      return
    }
    try? assetFileStore.removeFile(fileID: fileID)
  }

  private func finishUsingAssetFile(fileID: String?) {
    guard let fileID else { return }
    inFlightAssetFileIDs.remove(fileID)
    guard deferredAssetFileDeletions.remove(fileID) != nil else { return }
    try? assetFileStore.removeFile(fileID: fileID)
  }

  private func nextPendingAssetInstall(
    recordName: String?
  ) throws -> CloudDataPreparedAssetInstall? {
    try storeLock.withLock {
      var descriptor = FetchDescriptor<CloudDataPendingAssetInstall>(
        sortBy: [
          SortDescriptor(\.observedAt),
          SortDescriptor(\.identity),
        ]
      )
      descriptor.includePendingChanges = true
      guard
        let install = try modelContext.fetch(descriptor).first(where: {
          recordName == nil || $0.recordName == recordName
        })
      else {
        return nil
      }
      guard let kind = install.kind else {
        throw CloudDataStoreRuntimeError.corruptAssetMutationKind(
          recordName: install.recordName,
          fieldKey: install.fieldKey,
          rawValue: install.kindRawValue
        )
      }

      let action: CloudDataIncomingAssetAction
      switch kind {
      case .replace:
        guard let fileID = install.stagedFileID else {
          throw CloudDataStoreRuntimeError.assetStagedFileMissing(
            recordName: install.recordName,
            fieldKey: install.fieldKey
          )
        }
        action = .replace(
          packageFileURL: try assetFileStore.requireFileURL(fileID: fileID)
        )
      case .remove:
        action = .remove
      }

      return CloudDataPreparedAssetInstall(
        identity: install.identity,
        revision: install.installRevision,
        reference: CloudDataAssetReference(
          storeID: storeID,
          recordType: install.recordType,
          recordName: install.recordName,
          fieldKey: install.fieldKey,
          localIdentifier: install.localIdentifier
        ),
        action: action,
        stagedFileID: install.stagedFileID
      )
    }
  }

  private func recordAssetInstallFailure(
    identity: String,
    revision: String,
    error: Error
  ) throws {
    try storeLock.withLock {
      do {
        guard
          let install = try fetchPendingAssetInstall(identity: identity),
          install.installRevision == revision
        else {
          return
        }
        install.latestErrorMessage = String(error.localizedDescription.prefix(500))
        install.latestErrorAt = .now
        try modelContext.save()
      } catch {
        modelContext.rollback()
        throw error
      }
    }
  }

  private func completeAssetInstall(
    identity: String,
    revision: String
  ) throws -> String? {
    try storeLock.withLock {
      do {
        guard
          let install = try fetchPendingAssetInstall(identity: identity),
          install.installRevision == revision
        else {
          return nil
        }
        let fileID = install.stagedFileID
        if let fileID, let file = try fetchStagedAssetFile(id: fileID) {
          modelContext.delete(file)
        }
        modelContext.delete(install)
        try modelContext.save()
        return fileID
      } catch {
        modelContext.rollback()
        throw error
      }
    }
  }

  /// Retries every durable out-of-order relationship in this exact store and
  /// remote-zone route.
  @discardableResult
  func repairUnresolvedRelationships(
    attemptedAt: Date = .now
  ) throws -> Int {
    try storeLock.withLock {
      do {
        var descriptor = FetchDescriptor<CloudDataUnresolvedRelationship>(
          sortBy: [
            SortDescriptor(\.sourceRecordType),
            SortDescriptor(\.sourceRecordName),
            SortDescriptor(\.relationshipKey),
          ]
        )
        descriptor.includePendingChanges = true
        let unresolved = try modelContext.fetch(descriptor)
        var reconciledSources = Set<String>()

        for relationship in unresolved {
          let sourceIdentity = CloudDataUnresolvedRelationship.makeIdentity(
            sourceRecordType: relationship.sourceRecordType,
            sourceRecordName: relationship.sourceRecordName,
            relationshipKey: ""
          )
          guard reconciledSources.insert(sourceIdentity).inserted else { continue }
          guard
            let registration = registry.registrationsByRecordType[
              relationship.sourceRecordType
            ]
          else {
            throw CloudDataStoreRuntimeError.unknownRecordType(
              relationship.sourceRecordType
            )
          }
          guard
            let source = try registration.fetch(
              recordName: relationship.sourceRecordName,
              in: modelContext
            )
          else {
            try deleteUnresolvedRelationships(
              sourceRecordType: relationship.sourceRecordType,
              sourceRecordName: relationship.sourceRecordName
            )
            continue
          }
          try reconcileRelationships(
            source: source,
            registration: registration,
            sourceRecordName: relationship.sourceRecordName,
            attemptedAt: attemptedAt
          )
        }

        try modelContext.save()
        return try unresolvedRelationshipCountUnlocked()
      } catch {
        modelContext.rollback()
        throw error
      }
    }
  }

  func unresolvedRelationshipCount() throws -> Int {
    try storeLock.withLock {
      try unresolvedRelationshipCountUnlocked()
    }
  }

  func pendingAssetMutationCount() throws -> Int {
    try storeLock.withLock {
      var descriptor = FetchDescriptor<CloudDataPendingAssetMutation>()
      descriptor.includePendingChanges = true
      return try modelContext.fetchCount(descriptor)
    }
  }

  func pendingAssetInstallCount() throws -> Int {
    try storeLock.withLock {
      var descriptor = FetchDescriptor<CloudDataPendingAssetInstall>()
      descriptor.includePendingChanges = true
      return try modelContext.fetchCount(descriptor)
    }
  }

  func stagedAssetFileCount() throws -> Int {
    try storeLock.withLock {
      var descriptor = FetchDescriptor<CloudDataStagedAssetFile>()
      descriptor.includePendingChanges = true
      return try modelContext.fetchCount(descriptor)
    }
  }

  func metrics() throws -> CloudDataStoreMetrics {
    try storeLock.withLock {
      try metricsUnlocked()
    }
  }

  private func metricsUnlocked() throws -> CloudDataStoreMetrics {
    var descriptor = FetchDescriptor<CloudDataPendingMutation>()
    descriptor.includePendingChanges = true
    let mutations = try modelContext.fetch(descriptor)
    var assetMutationDescriptor = FetchDescriptor<CloudDataPendingAssetMutation>()
    assetMutationDescriptor.includePendingChanges = true
    var assetInstallDescriptor = FetchDescriptor<CloudDataPendingAssetInstall>()
    assetInstallDescriptor.includePendingChanges = true
    return CloudDataStoreMetrics(
      pendingCount: mutations.count,
      stagedCount: mutations.count { $0.stagedAt != nil },
      pendingAssetTransferCount:
        try modelContext.fetchCount(assetMutationDescriptor)
        + modelContext.fetchCount(assetInstallDescriptor)
    )
  }

  private func unresolvedRelationshipCountUnlocked() throws -> Int {
    var descriptor = FetchDescriptor<CloudDataUnresolvedRelationship>()
    descriptor.includePendingChanges = true
    return try modelContext.fetchCount(descriptor)
  }

  private func reconcileRelationships(
    source: any PersistentModel,
    registration: CloudModelRegistration,
    sourceRecordName: String,
    attemptedAt: Date
  ) throws {
    for relationship in registration.relationships {
      let relationshipDescriptor = relationship.descriptor
      guard
        let targetRegistration = registry.registration(
          for: relationship.targetModelType
        )
      else {
        throw CloudDataStoreRuntimeError.relationshipTargetRegistrationMissing(
          sourceRecordType: registration.descriptor.recordType,
          key: relationshipDescriptor.key,
          targetModelType: String(reflecting: relationship.targetModelType)
        )
      }

      guard
        let targetRecordName = try relationship.targetRecordName(from: source)
      else {
        switch relationshipDescriptor.requirement {
        case .optional:
          try relationship.assignTarget(nil, to: source)
          try deleteUnresolvedRelationship(
            sourceRecordType: registration.descriptor.recordType,
            sourceRecordName: sourceRecordName,
            relationshipKey: relationshipDescriptor.key
          )
          continue
        case .eventuallyRequired:
          throw CloudDataStoreRuntimeError.emptyRelationshipTargetRecordName(
            sourceRecordType: registration.descriptor.recordType,
            key: relationshipDescriptor.key
          )
        }
      }
      guard targetRecordName.isEmpty == false else {
        throw CloudDataStoreRuntimeError.emptyRelationshipTargetRecordName(
          sourceRecordType: registration.descriptor.recordType,
          key: relationshipDescriptor.key
        )
      }

      if let target = try targetRegistration.fetch(
        recordName: targetRecordName,
        in: modelContext
      ) {
        try relationship.assignTarget(target, to: source)
        try deleteUnresolvedRelationship(
          sourceRecordType: registration.descriptor.recordType,
          sourceRecordName: sourceRecordName,
          relationshipKey: relationshipDescriptor.key
        )
      } else {
        try relationship.assignTarget(nil, to: source)
        try upsertUnresolvedRelationship(
          sourceRecordType: registration.descriptor.recordType,
          sourceRecordName: sourceRecordName,
          relationship: relationshipDescriptor,
          targetRecordType: targetRegistration.descriptor.recordType,
          targetRecordName: targetRecordName,
          attemptedAt: attemptedAt
        )
      }
    }
  }

  private func repairUnresolvedRelationships(
    targetingRecordType targetRecordType: String,
    targetRecordName: String,
    target: any PersistentModel,
    attemptedAt: Date
  ) throws {
    var descriptor = FetchDescriptor<CloudDataUnresolvedRelationship>(
      predicate: #Predicate {
        $0.targetRecordType == targetRecordType
          && $0.targetRecordName == targetRecordName
      }
    )
    descriptor.includePendingChanges = true
    let unresolved = try modelContext.fetch(descriptor)

    for pending in unresolved {
      guard
        let sourceRegistration = registry.registrationsByRecordType[
          pending.sourceRecordType
        ]
      else {
        throw CloudDataStoreRuntimeError.unknownRecordType(
          pending.sourceRecordType
        )
      }
      guard
        let relationship = sourceRegistration.relationships.first(where: {
          $0.descriptor.key == pending.relationshipKey
        })
      else {
        throw CloudDataStoreRuntimeError.relationshipOperationMissing(
          sourceRecordType: pending.sourceRecordType,
          key: pending.relationshipKey
        )
      }
      guard
        let source = try sourceRegistration.fetch(
          recordName: pending.sourceRecordName,
          in: modelContext
        )
      else {
        modelContext.delete(pending)
        continue
      }

      let currentTargetRecordName = try relationship.targetRecordName(from: source)
      guard currentTargetRecordName == pending.targetRecordName else {
        try reconcileRelationships(
          source: source,
          registration: sourceRegistration,
          sourceRecordName: pending.sourceRecordName,
          attemptedAt: attemptedAt
        )
        continue
      }
      try relationship.assignTarget(target, to: source)
      modelContext.delete(pending)
    }
  }

  private func upsertUnresolvedRelationship(
    sourceRecordType: String,
    sourceRecordName: String,
    relationship: CloudRelationshipDescriptor,
    targetRecordType: String,
    targetRecordName: String,
    attemptedAt: Date
  ) throws {
    let identity = CloudDataUnresolvedRelationship.makeIdentity(
      sourceRecordType: sourceRecordType,
      sourceRecordName: sourceRecordName,
      relationshipKey: relationship.key
    )
    if let unresolved = try fetchUnresolvedRelationship(identity: identity) {
      unresolved.targetRecordType = targetRecordType
      unresolved.targetRecordName = targetRecordName
      unresolved.lastAttemptedAt = attemptedAt
    } else {
      modelContext.insert(
        CloudDataUnresolvedRelationship(
          sourceRecordType: sourceRecordType,
          sourceRecordName: sourceRecordName,
          relationshipKey: relationship.key,
          targetRecordType: targetRecordType,
          targetRecordName: targetRecordName,
          observedAt: attemptedAt
        )
      )
    }
  }

  private func deleteUnresolvedRelationship(
    sourceRecordType: String,
    sourceRecordName: String,
    relationshipKey: String
  ) throws {
    let identity = CloudDataUnresolvedRelationship.makeIdentity(
      sourceRecordType: sourceRecordType,
      sourceRecordName: sourceRecordName,
      relationshipKey: relationshipKey
    )
    if let unresolved = try fetchUnresolvedRelationship(identity: identity) {
      modelContext.delete(unresolved)
    }
  }

  private func deleteUnresolvedRelationships(
    sourceRecordType: String,
    sourceRecordName: String
  ) throws {
    var descriptor = FetchDescriptor<CloudDataUnresolvedRelationship>(
      predicate: #Predicate {
        $0.sourceRecordType == sourceRecordType
          && $0.sourceRecordName == sourceRecordName
      }
    )
    descriptor.includePendingChanges = true
    for relationship in try modelContext.fetch(descriptor) {
      modelContext.delete(relationship)
    }
  }

  private func deleteUnresolvedRelationships(
    recordType: String,
    recordName: String
  ) throws {
    var descriptor = FetchDescriptor<CloudDataUnresolvedRelationship>()
    descriptor.includePendingChanges = true
    for relationship in try modelContext.fetch(descriptor)
    where
      (relationship.sourceRecordType == recordType
      && relationship.sourceRecordName == recordName)
      || (relationship.targetRecordType == recordType
        && relationship.targetRecordName == recordName)
    {
      modelContext.delete(relationship)
    }
  }

  private func fetchUnresolvedRelationship(
    identity: String
  ) throws -> CloudDataUnresolvedRelationship? {
    var descriptor = FetchDescriptor<CloudDataUnresolvedRelationship>(
      predicate: #Predicate { $0.identity == identity }
    )
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = true
    return try modelContext.fetch(descriptor).first
  }

  private func upsertMetadata(
    recordType: String,
    recordName: String,
    systemFieldsData: Data,
    acceptedAt: Date
  ) throws {
    if let metadata = try fetchMetadata(recordName: recordName) {
      try validateRecordType(
        metadata.recordType,
        requestedRecordType: recordType,
        recordName: recordName
      )
      metadata.systemFieldsData = systemFieldsData
      metadata.acceptedAt = acceptedAt
    } else {
      modelContext.insert(
        CloudDataSyncMetadata(
          recordName: recordName,
          recordType: recordType,
          systemFieldsData: systemFieldsData,
          acceptedAt: acceptedAt
        )
      )
    }
  }

  private func validateRecordType(
    _ existingRecordType: String,
    requestedRecordType: String,
    recordName: String
  ) throws {
    guard existingRecordType != requestedRecordType else { return }
    throw CloudDataStoreRuntimeError.recordNameCollision(
      recordName: recordName,
      existingRecordType: existingRecordType,
      requestedRecordType: requestedRecordType
    )
  }

  private func fetchPending(recordName: String) throws -> CloudDataPendingMutation? {
    var descriptor = FetchDescriptor<CloudDataPendingMutation>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func fetchPendingAssetMutation(
    identity: String
  ) throws -> CloudDataPendingAssetMutation? {
    var descriptor = FetchDescriptor<CloudDataPendingAssetMutation>(
      predicate: #Predicate { $0.identity == identity }
    )
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = true
    return try modelContext.fetch(descriptor).first
  }

  private func fetchPendingAssetInstall(
    identity: String
  ) throws -> CloudDataPendingAssetInstall? {
    var descriptor = FetchDescriptor<CloudDataPendingAssetInstall>(
      predicate: #Predicate { $0.identity == identity }
    )
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = true
    return try modelContext.fetch(descriptor).first
  }

  private func fetchStagedAssetFile(id: String) throws -> CloudDataStagedAssetFile? {
    var descriptor = FetchDescriptor<CloudDataStagedAssetFile>(
      predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1
    descriptor.includePendingChanges = true
    return try modelContext.fetch(descriptor).first
  }

  private func deletePendingAssetInstall(
    identity: String,
    obsoleteFileIDs: inout Set<String>
  ) throws {
    guard let install = try fetchPendingAssetInstall(identity: identity) else {
      return
    }
    if let fileID = install.stagedFileID {
      if let file = try fetchStagedAssetFile(id: fileID) {
        modelContext.delete(file)
      }
      obsoleteFileIDs.insert(fileID)
    }
    modelContext.delete(install)
  }

  private func deletePendingAssetInstalls(
    recordName: String,
    filesToDelete: inout Set<String>
  ) throws {
    var descriptor = FetchDescriptor<CloudDataPendingAssetInstall>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.includePendingChanges = true
    for install in try modelContext.fetch(descriptor) {
      if let fileID = install.stagedFileID {
        if let file = try fetchStagedAssetFile(id: fileID) {
          modelContext.delete(file)
        }
        filesToDelete.insert(fileID)
      }
      modelContext.delete(install)
    }
  }

  private func supersedePendingAssetInstallsWithRemovals(
    recordType: String,
    recordName: String,
    observedAt: Date,
    filesToDelete: inout Set<String>
  ) throws {
    var descriptor = FetchDescriptor<CloudDataPendingAssetInstall>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.includePendingChanges = true
    for install in try modelContext.fetch(descriptor) {
      try validateRecordType(
        install.recordType,
        requestedRecordType: recordType,
        recordName: recordName
      )
      if let fileID = install.stagedFileID {
        if let file = try fetchStagedAssetFile(id: fileID) {
          modelContext.delete(file)
        }
        filesToDelete.insert(fileID)
      }
      install.kind = .remove
      install.installRevision = UUID().uuidString
      install.stagedFileID = nil
      install.observedAt = observedAt
      install.latestErrorMessage = nil
      install.latestErrorAt = nil
    }
  }

  private func deletePendingAssetMutations(
    recordName: String,
    mutationRevision: String
  ) throws {
    var descriptor = FetchDescriptor<CloudDataPendingAssetMutation>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.includePendingChanges = true
    for mutation in try modelContext.fetch(descriptor)
    where mutation.mutationRevision == mutationRevision {
      modelContext.delete(mutation)
    }
  }

  private func discardPendingMutationAndAssets(
    recordName: String,
    filesToDelete: inout Set<String>
  ) throws {
    if let pending = try fetchPending(recordName: recordName) {
      modelContext.delete(pending)
    }
    try deletePendingAssetInstalls(
      recordName: recordName,
      filesToDelete: &filesToDelete
    )

    var mutationDescriptor = FetchDescriptor<CloudDataPendingAssetMutation>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    mutationDescriptor.includePendingChanges = true
    for mutation in try modelContext.fetch(mutationDescriptor) {
      if let fileID = mutation.stagedFileID {
        filesToDelete.insert(fileID)
        if let stagedFile = try fetchStagedAssetFile(id: fileID) {
          modelContext.delete(stagedFile)
        }
      }
      modelContext.delete(mutation)
    }

    var stagedFileDescriptor = FetchDescriptor<CloudDataStagedAssetFile>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    stagedFileDescriptor.includePendingChanges = true
    for stagedFile in try modelContext.fetch(stagedFileDescriptor) {
      filesToDelete.insert(stagedFile.id)
      modelContext.delete(stagedFile)
    }
  }

  private func pruneOutgoingStagedFiles(
    recordName: String,
    filesToDelete: inout Set<String>
  ) throws {
    var mutationDescriptor = FetchDescriptor<CloudDataPendingAssetMutation>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    mutationDescriptor.includePendingChanges = true
    let retainedFileIDs = Set(
      try modelContext.fetch(mutationDescriptor).compactMap(\.stagedFileID)
    )

    var fileDescriptor = FetchDescriptor<CloudDataStagedAssetFile>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    fileDescriptor.includePendingChanges = true
    for file in try modelContext.fetch(fileDescriptor) {
      guard let direction = file.direction else {
        throw CloudDataStoreRuntimeError.corruptAssetTransferDirection(
          fileID: file.id,
          rawValue: file.directionRawValue
        )
      }
      guard direction == .outgoing else { continue }
      guard retainedFileIDs.contains(file.id) == false else { continue }
      filesToDelete.insert(file.id)
      modelContext.delete(file)
    }
  }

  private func fetchMetadata(recordName: String) throws -> CloudDataSyncMetadata? {
    var descriptor = FetchDescriptor<CloudDataSyncMetadata>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  /// Discards this actor context's registered snapshots before a coordinated
  /// transaction reads a store that another app-group process may have changed.
  private func refreshModelContext() {
    modelContext.rollback()
    modelContext.processPendingChanges()
  }
}
