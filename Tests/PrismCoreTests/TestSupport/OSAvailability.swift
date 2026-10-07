/// Runtime OS checks for `@Test(.enabled(if:))`. A test that needs a newer iOS than the
/// simulator runs is then reported as skipped instead of passing without checking anything.
/// The body still needs its own `guard #available` for the compiler.
enum OSAvailability {
    static let isIOS26: Bool = if #available(iOS 26.0, *) { true } else { false }

    static let isIOS27: Bool = if #available(iOS 27.0, *) { true } else { false }
}
