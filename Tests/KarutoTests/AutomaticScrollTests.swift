import Testing
import AppKit
import CoreGraphics
import Carbon.HIToolbox
import Synchronization
@testable import Karuto

struct AutomaticScrollTests {
    @MainActor @Test func directedScrollCarriesWindowAndPaneCoordinates() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 80, y: 120, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let frame = CGRect(x: window.frame.minX, y: CGDisplayBounds(CGMainDisplayID()).height - window.frame.maxY,
                           width: window.frame.width, height: window.frame.height)
        let point = CGPoint(x: frame.minX + 93, y: frame.minY + 56)
        let cg = try #require(ScrollCaptureDriver.windowScrollEvent(-48, at: point, windowID: UInt32(window.windowNumber), windowFrame: frame))
        let event = try #require(NSEvent(cgEvent: cg))
        #expect(event.type == .scrollWheel)
        #expect(event.windowNumber == window.windowNumber)
        #expect(event.locationInWindow == CGPoint(x: 93, y: frame.height - 56))
        #expect(cg.location == point)
        #expect(event.scrollingDeltaY == -48)
    }

    @Test func endConfirmationAdaptsToRedrawSpeed() {
        var timing = AutomaticScrollTiming()
        for _ in 0..<8 { timing.record(stepDuration: .milliseconds(32)) }
        #expect(timing.quietInterval == .milliseconds(220))
        timing.record(stepDuration: .milliseconds(190))
        #expect(timing.quietInterval == .milliseconds(570))
    }

    @Test func automaticStepsWaitForTheRequestedDistanceInRetinaPixels() {
        var progress = AutomaticScrollProgress()
        func frame(_ height: Int, _ disposition: Int) -> StitchProgress {
            StitchProgress(height: height, message: "", accepted: disposition == 0, disposition: disposition,
                           viewportHeight: 800, sourceSize: CGSize(width: 800, height: 1000))
        }
        progress.observe(frame(0, 4))
        #expect(progress.scrollStep(sourceHeight: 500, retrying: false) == 48)
        progress.observe(frame(900, 0))
        let before = progress
        let step = before.scrollStep(sourceHeight: 500, retrying: false)
        #expect(step == 200)
        progress.observe(frame(940, 0))
        #expect(!progress.covered(step: step, since: before, sourceHeight: 500))
        progress.observe(frame(1300, 0))
        #expect(progress.covered(step: step, since: before, sourceHeight: 500))
        #expect(progress.scrollStep(sourceHeight: 500, retrying: true) == 48)
    }

    @Test func smallViewportKeepsTheMinimumStitchOverlap() {
        var progress = AutomaticScrollProgress()
        progress.observe(StitchProgress(height: 40, message: "", accepted: true, viewportHeight: 32,
                                        sourceSize: CGSize(width: 100, height: 32)))
        #expect(progress.scrollStep(sourceHeight: 32, retrying: false) == 8)
    }

    @Test func queuedFramesAreBoundedAndDrainInCaptureOrder() async {
        let processed = Mutex<[Int]>([])
        let release = DispatchSemaphore(value: 0)
        let secondCopied = DispatchSemaphore(value: 0)
        let thirdCopied = DispatchSemaphore(value: 0)
        let receiver = FrameReceiver { frame in
            let number = Int(frame.data[0])
            if number == 0 { release.wait() }
            processed.withLock { $0.append(number) }
        }
        receiver.queue.async {
            for number in 0..<3 {
                receiver.enqueue {
                    if number == 1 { secondCopied.signal() }
                    if number == 2 { thirdCopied.signal() }
                    return PixelFrame(data: Data([UInt8(number)]), width: 1, height: 1, bytesPerRow: 1)
                }
            }
        }
        let bounded = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let copiedTwo = secondCopied.wait(timeout: .now() + 2) == .success
                let heldThird = thirdCopied.wait(timeout: .now() + 0.05) == .timedOut
                continuation.resume(returning: copiedTwo && heldThird)
            }
        }
        #expect(bounded)
        release.signal()
        await receiver.drain(disableAfterCapture: true)
        #expect(processed.withLock { $0 } == [0, 1, 2])
        receiver.queue.async {
            receiver.enqueue { Issue.record("Frame copied after shutdown"); return nil }
        }
        await receiver.drain()
    }

    @Test func wheelBurstKeepsOverlapUntilAnotherFrameArrives() throws {
        var pacing = ManualScrollPacing()
        func delivered(_ delta: Int32) throws -> Int64 {
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                             wheel1: delta, wheel2: 3, wheel3: 0))
            event.timestamp = 1_000_000
            let horizontal = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
            pacing.apply(to: event, budget: 60)
            #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == horizontal)
            #expect(event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 2)
            return event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        }
        #expect(try delivered(-20) == -20)
        #expect(try delivered(-80) == -40)
        #expect(try delivered(-10) == 0)
        pacing.receivedFrame()
        #expect(try delivered(-25) == -25)
        #expect(try delivered(50) == 50)
    }

    @MainActor @Test func manualArrowsScrollOncePerPressOrRepeatAndConsumeTheirRelease() {
        let keys = ManualScrollInput()
        var steps: [Int32] = []
        func press(_ code: Int, flags: CGEventFlags = []) -> Bool {
            keys.handle(type: .keyDown, code: code, flags: flags) { steps.append($0); return true }
        }
        #expect(press(kVK_DownArrow, flags: .maskSecondaryFn))
        #expect(press(kVK_DownArrow))
        #expect(keys.handle(type: .keyUp, code: kVK_DownArrow, flags: []) { _ in false })
        #expect(press(kVK_UpArrow))
        #expect(!press(kVK_DownArrow, flags: .maskShift))
        #expect(!press(kVK_LeftArrow))
        #expect(steps == [-1, -1, 1])
        keys.stop()
        #expect(!keys.handle(type: .keyUp, code: kVK_UpArrow, flags: []) { _ in false })
        // If the destination lost focus, let its normal key handling take over.
        #expect(!keys.handle(type: .keyDown, code: kVK_DownArrow, flags: []) { _ in false })
        #expect(!keys.handle(type: .keyUp, code: kVK_DownArrow, flags: []) { _ in false })
    }

    @Test func mouseWheelKeepsLineUnitsAndRecoversAfterAPause() throws {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                         wheel1: -12, wheel2: 0, wheel3: 0))
        var pacing = ManualScrollPacing()
        pacing.apply(to: event, budget: 40)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -40)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) < 0)
        #expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0)
        event.timestamp += 300_000_000
        pacing.apply(to: event, budget: 40)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -40)
    }

    @Test func calibrationIsNotGrowthAndReplayUsesMovingViewportHeight() {
        var evidence = AutomaticScrollProgress()
        evidence.observe(StitchProgress(height: 0, message: "", accepted: false, disposition: 4))
        #expect(evidence.hasFrame)
        #expect(evidence.isCalibrating)
        #expect(!evidence.hasExtended)
        evidence.observe(StitchProgress(height: 844, message: "", accepted: true, disposition: 0,
                                        contentRect: CGRect(x: 100, y: 60, width: 800, height: 700),
                                        viewportHeight: 700, sourceSize: CGSize(width: 1000, height: 800)))
        #expect(!evidence.isCalibrating)
        #expect(evidence.hasExtended)
        #expect(evidence.firstHeight == 700)
        #expect(evidence.viewportFraction == 0.875)
    }

    @Test func onlyAcceptedVerticalGrowthCanComplete() {
        var evidence = AutomaticScrollProgress()
        #expect(!evidence.hasFrame)
        evidence.observe(StitchProgress(height: 600, message: "", accepted: true, disposition: 0))
        #expect(evidence.hasFrame)
        #expect(!evidence.hasExtended)
        evidence.observe(StitchProgress(height: 600, message: "", accepted: false, disposition: 1))
        #expect(!evidence.hasExtended)
        evidence.observe(StitchProgress(height: 900, message: "", accepted: false, disposition: 2))
        #expect(evidence.rejectedFrames == 1)
        #expect(!evidence.hasExtended)
        evidence.observe(StitchProgress(height: 800, message: "", accepted: true, disposition: 0))
        #expect(evidence.hasExtended)
        #expect(evidence.height == 800)
    }
}
