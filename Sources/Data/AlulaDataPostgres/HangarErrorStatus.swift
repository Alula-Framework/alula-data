import AlulaCore
import Hangar

// How Hangar's errors reach a client, now that Hangar says what they mean.
//
// Hangar cannot depend on Alula, and Alula's web layer cannot depend on
// Hangar; Alula Data depends on both, so it says here which of Hangar's
// errors are a dependency being briefly unavailable (503, `Retry-After`) and
// which are the request asking wrongly (400). Each was an opaque 500.

/// A deadlock, a serialization failure, a lock not available, a statement
/// cancelled, the server starting up or shutting down: running the request
/// again may succeed.
extension DatabaseError: @retroactive TemporarilyUnavailable {
    public var isTemporarilyUnavailable: Bool { isTransient }
    public var retryAfter: Duration? { isTransient ? .seconds(1) : nil }
}

/// The database cannot be reached, or the connection dropped. A refused
/// login or a TLS failure is configuration, and stays a 500.
extension DatabaseConnectionError: @retroactive TemporarilyUnavailable {
    public var isTemporarilyUnavailable: Bool { isTransient }
    public var retryAfter: Duration? { isTransient ? .seconds(5) : nil }
}

/// A dynamic filter on a field that cannot be filtered, or with a value of
/// the wrong type. The message names only what the request itself said —
/// the description names the table, which stays in the log.
extension HangarError: @retroactive RejectedInput {
    public var isRejectedInput: Bool { isClientInput }

    public var rejectionMessage: String {
        switch self {
        case .unknownFilterField(_, let field): "\"\(field)\" is not a field that can be filtered on"
        case .invalidFilterValue(_, let field): "the value for filter \"\(field)\" is not of the field's type"
        default: "the request could not be understood"
        }
    }
}
