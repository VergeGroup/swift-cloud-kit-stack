import Foundation

/// Package-internal decision for one account event.
///
/// A matching sign-in is an engine-state re-establishment for local data that
/// the application already authorized. Every other transition remains behind
/// the consumer's fail-closed data-policy gate.
enum CloudDataAccountChangeDisposition: Sendable, Equatable {
  case reestablished
  case requiresResolution(CloudDataAccountChange)
}

/// Reduces CKSyncEngine account facts against the durable local-data owner.
enum CloudDataAccountAuthorization {
  static func disposition(
    for change: CloudDataAccountChange,
    authorizedAccount: CloudDataAccountIdentifier?
  ) -> CloudDataAccountChangeDisposition {
    switch change {
    case .signIn(let current):
      guard let authorizedAccount else {
        return .requiresResolution(change)
      }
      guard authorizedAccount == current else {
        return .requiresResolution(
          .switchAccounts(previous: authorizedAccount, current: current)
        )
      }
      return .reestablished

    case .signOut, .switchAccounts:
      return .requiresResolution(change)
    }
  }

  /// Returns the account that may receive retained local rows after policy.
  static func authorizedAccount(
    afterResolving change: CloudDataAccountChange,
    existingAccount: CloudDataAccountIdentifier?
  ) -> CloudDataAccountIdentifier {
    switch change {
    case .signIn(let current), .switchAccounts(_, let current):
      return current
    case .signOut(let previous):
      return existingAccount ?? previous
    }
  }
}
