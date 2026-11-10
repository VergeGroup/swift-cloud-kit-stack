import Foundation

/// A fixed remote field category supported by the generated wire schema.
///
/// The closed enum intentionally prevents applications from adding arbitrary
/// stored codecs through protocol conformances. Composite cases such as
/// ``location`` still originate from source-written SwiftData primitives.
public enum CloudFieldKind: String, CaseIterable, Sendable, Hashable {
  /// A Swift `String` value.
  case string

  /// A Swift `Bool` value.
  case bool

  /// A platform-width Swift `Int` value.
  case int

  /// A fixed-width Swift `Int64` value.
  case int64

  /// A Swift `Double` value.
  case double

  /// A Foundation `Date` value.
  case date

  /// A Foundation `Data` value.
  case data

  /// A latitude/longitude pair transported as one native CloudKit location.
  case location
}

/// A validated, transport-neutral geographic coordinate.
///
/// Applications continue to persist latitude and longitude as separate native
/// SwiftData columns. This value exists only in the package snapshot between
/// generated model mapping and the concrete CloudKit adapter.
public struct CloudLocationValue: Sendable, Hashable {
  /// Latitude in degrees in the closed interval `-90...90`.
  public let latitude: Double

  /// Longitude in degrees in the closed interval `-180...180`.
  public let longitude: Double

  /// Creates a coordinate only when both components form a valid geographic
  /// location.
  public init?(latitude: Double, longitude: Double) {
    guard
      latitude.isFinite,
      longitude.isFinite,
      (-90...90).contains(latitude),
      (-180...180).contains(longitude)
    else {
      return nil
    }
    self.latitude = latitude
    self.longitude = longitude
  }
}

/// A transport-neutral field value produced from an application model.
///
/// CloudKit adapters translate this closed representation at the transport
/// boundary. An absent dictionary entry represents an absent optional field.
public enum CloudFieldValue: Sendable, Hashable {
  /// A synchronized String payload.
  case string(String)

  /// A synchronized Boolean payload.
  case bool(Bool)

  /// A synchronized platform-width integer payload.
  case int(Int)

  /// A synchronized fixed-width integer payload.
  case int64(Int64)

  /// A synchronized double-precision floating-point payload.
  case double(Double)

  /// A synchronized timestamp payload.
  case date(Date)

  /// A synchronized inline binary payload.
  case data(Data)

  /// A synchronized native-location payload.
  case location(CloudLocationValue)

  /// The schema category corresponding to this value.
  public var kind: CloudFieldKind {
    switch self {
    case .string:
      .string
    case .bool:
      .bool
    case .int:
      .int
    case .int64:
      .int64
    case .double:
      .double
    case .date:
      .date
    case .data:
      .data
    case .location:
      .location
    }
  }
}
