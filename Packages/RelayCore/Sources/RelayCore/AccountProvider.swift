import Foundation

/// The device's iCloud account, as reported by `CKContainer.accountStatus()` and
/// `userRecordID()`. Users are identified by their opaque CloudKit user record name.
public enum ICloudAccount: Sendable, Equatable {
    case available(user: String)
    case noAccount
    /// Parental controls or device management block iCloud.
    case restricted
    /// Signed in, but not ready for CloudKit yet. Apple: don't delete cached data, don't
    /// enqueue CloudKit operations, and wait for `CKAccountChanged`.
    case temporarilyUnavailable
    /// The status couldn't be determined, for example because the user record id
    /// couldn't be fetched while offline.
    case couldNotDetermine(reason: String)
}

/// Determines the current iCloud account. Production uses `CloudKitAccountProvider`.
/// Tests use a fake whose answer they control.
public protocol AccountProvider: Sendable {
    func currentAccount() async -> ICloudAccount
    /// Drops any cached identity. Called whenever the account may have changed.
    func invalidate()
}
