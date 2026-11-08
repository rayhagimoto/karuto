import Testing
@testable import Karuto

struct CaptureWindowPolicyTests {
    @Test func onlyRegisteredOwnSettingsWindowIsSelectableAndExcepted() {
        let policy = CaptureWindowPolicy(ownProcessID: 41, capturableOwnWindowIDs: [101])
        #expect(policy.canSelect(windowID: 101, ownerProcessID: 41))
        #expect(policy.isOwnException(windowID: 101, ownerProcessID: 41))
        // Overlay, controls, preview, and future windows stay excluded.
        for id: UInt32 in [102, 103, 104, 105] {
            #expect(!policy.canSelect(windowID: id, ownerProcessID: 41))
            #expect(!policy.isOwnException(windowID: id, ownerProcessID: 41))
        }
    }

    @Test func foreignOwnerAndMissingOwnerCannotBecomeSelfExceptions() {
        let policy = CaptureWindowPolicy(ownProcessID: 41, capturableOwnWindowIDs: [101])
        #expect(policy.canSelect(windowID: 101, ownerProcessID: 42))
        #expect(!policy.isOwnException(windowID: 101, ownerProcessID: 42))
        #expect(!policy.canSelect(windowID: 101, ownerProcessID: nil))
        #expect(!policy.isOwnException(windowID: 101, ownerProcessID: nil))
    }

    @Test func clearingWindowRegistrationRestoresFullSelfExclusion() {
        let policy = CaptureWindowPolicy(ownProcessID: 41, capturableOwnWindowIDs: [])
        #expect(!policy.canSelect(windowID: 101, ownerProcessID: 41))
        #expect(!policy.isOwnException(windowID: 101, ownerProcessID: 41))
        #expect(policy.canSelect(windowID: 202, ownerProcessID: 42))
    }
}
