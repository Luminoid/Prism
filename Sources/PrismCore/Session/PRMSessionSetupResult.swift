/// The result of a camera session setup attempt.
public enum PRMSessionSetupResult: Sendable, Equatable {
    /// The session was configured successfully.
    case success
    /// Camera access has not been granted by the user.
    case notAuthorized
    /// Session configuration failed (e.g., no compatible camera found).
    case configurationFailed
}
