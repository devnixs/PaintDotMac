import Foundation

extension Result {
    /// `Result` has no `success` accessor; the tests in this target use this one to assert
    /// the success value with `try #require(...)` and get a named failure otherwise.
    var success: Success? { try? get() }
}
