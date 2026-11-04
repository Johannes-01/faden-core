/// Asked right before each paid call. Returns the reservation the call goes out under, or throws to stop
/// before anything is paid for; the pipeline fails the run at that stage with the error's description.
public protocol PaidCallGate: Sendable {
    /// `state` is the lecture's state (nil for the study tools); `reservation` is the one saved from an
    /// earlier attempt, which the gate reuses instead of reserving again.
    func admit(_ step: CostRecord.Step, state: PipelineState?, reservation: String?) async throws -> String
}
