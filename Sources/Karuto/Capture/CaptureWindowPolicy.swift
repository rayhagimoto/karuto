/// Only explicitly registered application windows may escape self-exclusion.
/// The owner check prevents a stale/reused window ID from becoming an exception
/// for another process (which ScreenCaptureKit would otherwise exclude).
struct CaptureWindowPolicy: Sendable {
    let ownProcessID: Int32
    let capturableOwnWindowIDs: Set<UInt32>

    func canSelect(windowID: UInt32, ownerProcessID: Int32?) -> Bool {
        guard let ownerProcessID else { return false }
        return ownerProcessID != ownProcessID || isOwnException(windowID: windowID, ownerProcessID: ownerProcessID)
    }

    func isOwnException(windowID: UInt32, ownerProcessID: Int32?) -> Bool {
        ownerProcessID == ownProcessID && capturableOwnWindowIDs.contains(windowID)
    }
}
