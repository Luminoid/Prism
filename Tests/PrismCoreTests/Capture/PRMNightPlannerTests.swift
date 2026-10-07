import Foundation
import Testing
@testable import PrismCore

/// `PRMNightPlanner`: exposure per frame from auto exposure's target, the shutter cap by
/// focal length and stability, and the capture length.
struct PRMNightPlannerTests {
    /// A dark room on a 24 mm main lens: auto exposure is at 1/15 s, ISO 3200 and still a stop
    /// short of its target.
    private let darkRoom = PRMNightPlanInput(
        exposureDuration: 1.0 / 15.0,
        iso: 3200,
        targetOffset: -1,
        minISO: 50,
        maxISO: 6400,
        minExposureDuration: 1.0 / 40000,
        maxExposureDuration: 1,
        focalLength35mm: 24,
        isStable: false
    )

    @Test
    func `Handheld frames stop at 1/8 s on the main lens and reach auto exposure's target`() {
        let plan = PRMNightPlanner.plan(darkRoom, duration: .automatic)
        #expect(abs(plan.frameDuration - 0.125) < 1e-9)
        // Target 1/15 × 3200 × 2 = 426.7, less 0.3 EV, over 1/8 s.
        let expectedISO = (1.0 / 15.0) * 3200 * 2 * pow(2, -0.3) / 0.125
        #expect(abs(Double(plan.iso) - expectedISO) < 1)
        #expect(plan.duration == 3)
        #expect(plan.frameCount == 24)
    }

    @Test
    func `A stable phone takes longer frames at lower ISO, for longer`() {
        var input = darkRoom
        input.isStable = true
        let plan = PRMNightPlanner.plan(input, duration: .automatic)
        #expect(plan.frameDuration == 0.5)
        #expect(plan.iso < 1000)
        #expect(plan.duration == 10)
        #expect(plan.frameCount == 20)
    }

    @Test
    func `A telephoto shortens the shutter and caps ISO and the frame count`() {
        var input = darkRoom
        input.focalLength35mm = 120
        let plan = PRMNightPlanner.plan(input, duration: .automatic)
        #expect(abs(plan.frameDuration - 0.025) < 1e-9)
        #expect(plan.iso == 6400)
        #expect(plan.frameCount == PRMNightPlanner.maxFrames)
    }

    @Test
    func `Bright scenes get a short shutter at minimum ISO and one second`() {
        let bright = PRMNightPlanInput(
            exposureDuration: 1.0 / 120,
            iso: 50,
            targetOffset: 0,
            minISO: 50,
            maxISO: 6400,
            minExposureDuration: 1.0 / 40000,
            maxExposureDuration: 1,
            focalLength35mm: 24,
            isStable: false
        )
        let plan = PRMNightPlanner.plan(bright, duration: .automatic)
        #expect(plan.iso == 50)
        #expect(plan.frameDuration < 1.0 / 120)
        #expect(plan.duration == 1)
        #expect(plan.frameCount == PRMNightPlanner.maxFrames)
    }

    @Test
    func `Requested durations are clamped and frames never drop below three`() {
        #expect(PRMNightPlanner.plan(darkRoom, duration: .seconds(5)).duration == 5)
        #expect(PRMNightPlanner.plan(darkRoom, duration: .seconds(100)).duration == 30)
        var stable = darkRoom
        stable.isStable = true
        let short = PRMNightPlanner.plan(stable, duration: .seconds(0.1))
        #expect(short.duration == 0.5)
        #expect(short.frameCount == PRMNightPlanner.minFrames)
    }

    @Test
    func `The format's longest shutter caps a stable frame`() {
        var input = darkRoom
        input.isStable = true
        input.maxExposureDuration = 1.0 / 3.0
        #expect(abs(PRMNightPlanner.plan(input, duration: .automatic).frameDuration - 1.0 / 3.0) < 1e-9)
    }

    @Test
    func `Overexposure and missing offsets keep auto exposure's level`() {
        var over = darkRoom
        over.targetOffset = 2
        var unknown = darkRoom
        unknown.targetOffset = .nan
        var none = darkRoom
        none.targetOffset = 0
        let reference = PRMNightPlanner.plan(none, duration: .automatic)
        #expect(PRMNightPlanner.plan(over, duration: .automatic) == reference)
        #expect(PRMNightPlanner.plan(unknown, duration: .automatic) == reference)
    }

    @Test
    func `Automatic duration follows the light the scene needs`() {
        #expect(PRMNightPlanner.automaticDuration(targetExposure: 800, isStable: false) == 3)
        #expect(PRMNightPlanner.automaticDuration(targetExposure: 150, isStable: false) == 2)
        #expect(PRMNightPlanner.automaticDuration(targetExposure: 20, isStable: false) == 1)
        #expect(PRMNightPlanner.automaticDuration(targetExposure: 800, isStable: true) == 10)
        #expect(PRMNightPlanner.automaticDuration(targetExposure: 150, isStable: true) == 6)
        #expect(PRMNightPlanner.automaticDuration(targetExposure: 20, isStable: true) == 3)
    }
}
