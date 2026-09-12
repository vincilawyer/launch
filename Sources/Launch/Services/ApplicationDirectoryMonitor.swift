import CoreServices
import Foundation

/// Recursively monitors application directories and coalesces bursts of file
/// changes into one rescan request.
public final class ApplicationDirectoryMonitor: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable () -> Void

    public let searchRoots: [URL]
    public let debounceInterval: TimeInterval

    private let eventLatency: CFTimeInterval
    private let eventQueue = DispatchQueue(
        label: "com.launch.application-directory-monitor",
        qos: .utility
    )
    private let eventQueueKey = DispatchSpecificKey<UInt8>()
    private let stateLock = NSLock()

    private var stream: FSEventStreamRef?
    private var changeHandler: ChangeHandler?
    private var pendingWorkItem: DispatchWorkItem?
    private var eventRevision: UInt64 = 0

    public init(
        searchRoots: [URL] = AppScanner.defaultSearchRoots,
        debounceInterval: TimeInterval = 0.35,
        eventLatency: TimeInterval = 0.15
    ) {
        self.searchRoots = searchRoots
        self.debounceInterval = max(0, debounceInterval)
        self.eventLatency = max(0, eventLatency)
        eventQueue.setSpecific(key: eventQueueKey, value: 1)
    }

    /// Starts monitoring. Calling this again replaces the previous handler and
    /// stream rather than installing duplicate observers.
    @discardableResult
    public func start(onChange: @escaping ChangeHandler) -> Bool {
        stop()

        let paths = searchRoots
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        guard !paths.isEmpty else { return false }

        stateLock.lock()
        changeHandler = onChange
        stateLock.unlock()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )

        guard let createdStream = FSEventStreamCreate(
            nil,
            applicationDirectoryEventCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            eventLatency,
            flags
        ) else {
            stateLock.lock()
            changeHandler = nil
            stateLock.unlock()
            return false
        }

        FSEventStreamSetDispatchQueue(createdStream, eventQueue)

        stateLock.lock()
        stream = createdStream
        stateLock.unlock()

        guard FSEventStreamStart(createdStream) else {
            stop()
            return false
        }
        return true
    }

    /// Stops callbacks and cancels a change that is still inside the debounce
    /// window. Safe to call repeatedly and from any thread.
    public func stop() {
        stateLock.lock()
        let oldStream = stream
        let oldWorkItem = pendingWorkItem
        stream = nil
        pendingWorkItem = nil
        changeHandler = nil
        eventRevision &+= 1
        stateLock.unlock()

        oldWorkItem?.cancel()
        if let oldStream {
            FSEventStreamStop(oldStream)
            FSEventStreamInvalidate(oldStream)

            // The stream context contains an unretained pointer to this monitor.
            // Drain callbacks already submitted to its serial queue before the
            // owner is allowed to release the monitor.
            if DispatchQueue.getSpecific(key: eventQueueKey) == nil {
                eventQueue.sync {}
            }
            FSEventStreamRelease(oldStream)
        }
    }

    deinit {
        stop()
    }

    fileprivate func receivedFileSystemEvent() {
        stateLock.lock()
        guard changeHandler != nil else {
            stateLock.unlock()
            return
        }

        pendingWorkItem?.cancel()
        eventRevision &+= 1
        let revision = eventRevision
        let workItem = DispatchWorkItem { [weak self] in
            self?.deliverChange(for: revision)
        }
        pendingWorkItem = workItem
        stateLock.unlock()

        eventQueue.asyncAfter(
            deadline: .now() + debounceInterval,
            execute: workItem
        )
    }

    private func deliverChange(for revision: UInt64) {
        stateLock.lock()
        guard revision == eventRevision,
              let handler = changeHandler else {
            stateLock.unlock()
            return
        }
        pendingWorkItem = nil
        stateLock.unlock()
        handler()
    }

    /// Deterministic entry point for the core debounce check. Production events
    /// enter through the same method from the FSEvents callback.
    func simulateFileSystemEventForTesting() {
        receivedFileSystemEvent()
    }
}

private let applicationDirectoryEventCallback: FSEventStreamCallback = {
    _, clientInfo, eventCount, _, _, _ in
    guard eventCount > 0, let clientInfo else { return }
    let monitor = Unmanaged<ApplicationDirectoryMonitor>
        .fromOpaque(clientInfo)
        .takeUnretainedValue()
    monitor.receivedFileSystemEvent()
}
