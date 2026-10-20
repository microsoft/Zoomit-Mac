import Foundation

struct ZoomAnimation {
    private(set) var currentZoom = 1.0
    private(set) var targetZoom = 1.0
    private(set) var isActive = false
    private var startZoom = 1.0
    private var startTime: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var startVelocity = 0.0

    static func duration(from currentZoom: Double, to targetZoom: Double, firstStepWasImmediate: Bool) -> TimeInterval {
        guard currentZoom.isFinite, targetZoom.isFinite,
              currentZoom > 0, targetZoom > 0, currentZoom != targetZoom else { return 0 }

        var steppedZoom = currentZoom
        var steps = 0
        if targetZoom > currentZoom {
            while steppedZoom < targetZoom {
                steppedZoom *= 1.1
                steps += 1
            }
        } else {
            while steppedZoom > targetZoom {
                steppedZoom *= 0.8
                steps += 1
            }
        }
        if firstStepWasImmediate, steps > 0 {
            steps -= 1
        }
        // Match PowerToys' 40 ms telescope cadence extended by 50 percent.
        return Double(steps) * 0.060
    }

    mutating func start(from currentZoom: Double, to targetZoom: Double, at time: TimeInterval, duration: TimeInterval) {
        startZoom = currentZoom
        self.currentZoom = currentZoom
        self.targetZoom = targetZoom
        startTime = time
        self.duration = duration
        startVelocity = 0
        isActive = currentZoom > 0 && targetZoom > 0 && currentZoom != targetZoom && duration > 0
        if !isActive {
            self.currentZoom = targetZoom
        }
    }

    @discardableResult
    mutating func retarget(to targetZoom: Double, at time: TimeInterval, duration: TimeInterval) -> Double {
        var velocity = 0.0
        if isActive {
            let progress = min(1, max(0, time - startTime) / self.duration)
            velocity = (
                (6 * progress * progress - 6 * progress) * log(startZoom)
                + (3 * progress * progress - 4 * progress + 1) * self.duration * startVelocity
                + (-6 * progress * progress + 6 * progress) * log(self.targetZoom)
            ) / self.duration
        }

        let currentZoom = sample(at: time)
        start(from: currentZoom, to: targetZoom, at: time, duration: duration)
        if isActive {
            let distance = log(targetZoom) - log(currentZoom)
            if velocity * distance > 0 {
                let maximumVelocity = 3 * abs(distance) / duration
                startVelocity = min(max(velocity, -maximumVelocity), maximumVelocity)
            }
        }
        return self.currentZoom
    }

    @discardableResult
    mutating func sample(at time: TimeInterval) -> Double {
        guard isActive else { return currentZoom }
        let elapsed = max(0, time - startTime)
        guard elapsed < duration else {
            currentZoom = targetZoom
            isActive = false
            return currentZoom
        }

        let progress = elapsed / duration
        let squared = progress * progress
        let cubed = squared * progress
        let startWeight = 2 * cubed - 3 * squared + 1
        let velocityWeight = cubed - 2 * squared + progress
        let targetWeight = -2 * cubed + 3 * squared
        currentZoom = exp(
            startWeight * log(startZoom)
                + velocityWeight * duration * startVelocity
                + targetWeight * log(targetZoom)
        )
        return currentZoom
    }

    mutating func stop(at zoom: Double) {
        startZoom = zoom
        currentZoom = zoom
        targetZoom = zoom
        duration = 0
        startVelocity = 0
        isActive = false
    }
}
