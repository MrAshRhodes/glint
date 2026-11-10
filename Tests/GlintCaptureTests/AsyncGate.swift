/// Parks callers until `open()`, so a test decides when the code under test may go on.
actor AsyncGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let parked = waiting
        waiting = []
        parked.forEach { $0.resume() }
    }
}
