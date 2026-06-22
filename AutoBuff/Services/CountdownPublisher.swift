import Foundation

final class CountdownPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "cc.juanwang.AutoBuff.countdown",
        qos: .utility
    )
    
    private var deadlines: [Int: TimeInterval] = [:]
    private var timer: DispatchSourceTimer?
    private var generation = UUID()
    private var onUpdate: (([Int: Int]) -> Void)?
    
    func start(onUpdate: @escaping ([Int: Int]) -> Void) {
        stop()
        let currentGeneration = UUID()
        let source = DispatchSource.makeTimerSource(queue: queue)
        
        lock.lock()
        generation = currentGeneration
        self.onUpdate = onUpdate
        timer = source
        lock.unlock()
        
        source.schedule(deadline: .now(), repeating: .milliseconds(250))
        source.setEventHandler { [weak self] in
            self?.publish(generation: currentGeneration)
        }
        source.resume()
    }
    
    func replaceDeadlines(_ deadlines: [Int: TimeInterval], now: TimeInterval? = nil) {
        lock.lock()
        self.deadlines = deadlines
        let currentGeneration = generation
        lock.unlock()
        
        if let now {
            publish(generation: currentGeneration, now: now)
        }
    }
    
    func stop() {
        lock.lock()
        let source = timer
        timer = nil
        deadlines = [:]
        onUpdate = nil
        generation = UUID()
        lock.unlock()
        source?.setEventHandler {}
        source?.cancel()
    }
    
    private func publish(
        generation expectedGeneration: UUID,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        lock.lock()
        guard generation == expectedGeneration, timer != nil else {
            lock.unlock()
            return
        }
        let snapshot = deadlines.mapValues {
            CountdownTiming.remainingSeconds(until: $0, now: now)
        }
        let callback = onUpdate
        lock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(expectedGeneration) else { return }
            callback?(snapshot)
        }
    }
    
    private func isCurrent(_ expectedGeneration: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == expectedGeneration && timer != nil
    }
}
