import Foundation
import CoreServices

class ScreenshotObserver {
    private var stream: FSEventStreamRef?
    private let callback: (String) -> Void
    private let path: String
    private let dispatchQueue = DispatchQueue(label: "com.screener.fsEventStreamQueue", qos: .utility)

    // Main debounce timer for initial event coalescing
    private var debounceTimer: Timer?
    private var lastProcessedFileForDebounce: String? // Renamed for clarity

    // Polling mechanism properties
    private var pollingTimers: [String: Timer] = [:]
    private var lastKnownSizes: [String: Int64] = [:]
    private var pollingAttempts: [String: Int] = [:]
    private let maxPollingAttempts = 12 // e.g., 12 attempts * 250ms = 3 seconds timeout
    private let pollingInterval: TimeInterval = 0.25 // 250ms polling interval

    init(path: String = NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first ?? "~/Desktop", callback: @escaping (String) -> Void) {
        // Ensure the path is standardized (e.g., resolve tilde)
        self.path = (path as NSString).expandingTildeInPath
        self.callback = callback
        print("Monitoring path: \(self.path)")
    }

    func start() {
        guard stream == nil else { 
            print("FSEventStream already started or not properly cleaned up.")
            return
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)

        guard let streamRef = FSEventStreamCreate(
            nil,
            eventStreamCallback,
            &context,
            [self.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, // Latency
            flags
        ) else {
            print("Failed to create FSEventStream")
            return
        }
        
        self.stream = streamRef
        FSEventStreamSetDispatchQueue(streamRef, dispatchQueue) // Use dispatch queue

        if !FSEventStreamStart(streamRef) {
            print("Failed to start FSEventStream")
            // Clean up if start fails
            FSEventStreamInvalidate(streamRef)
            FSEventStreamRelease(streamRef)
            self.stream = nil
        } else {
            print("FSEventStream started successfully on dispatch queue.")
        }
    }

    func stop() {
        guard let streamRef = self.stream else { return }
        FSEventStreamStop(streamRef)
        FSEventStreamInvalidate(streamRef) // Invalidate before release
        FSEventStreamRelease(streamRef) // Release the stream
        self.stream = nil
        // Ensure debounce timer is invalidated on the correct queue if it was scheduled there,
        // or ensure it's scheduled on a queue that allows Timer (like main or a custom runloop queue)
        // For simplicity, if debounceTimer is always on main, this is fine.
        // If FSEvent callbacks schedule timers on `dispatchQueue`, they should be `DispatchSourceTimer`.
        // Current Timer is scheduled on CFRunLoopGetCurrent() in the callback, which might be the dispatchQueue's underlying thread if not careful.
        // Let's assume the Timer is meant for the main thread for UI related debouncing or simple tasks.
        DispatchQueue.main.async {
            self.debounceTimer?.invalidate()
            self.debounceTimer = nil
            // Invalidate all ongoing polling timers
            for (_, timer) in self.pollingTimers {
                timer.invalidate()
            }
            self.pollingTimers.removeAll()
            self.lastKnownSizes.removeAll()
            self.pollingAttempts.removeAll()
        }
        print("FSEventStream stopped.")
    }

    private let eventStreamCallback: FSEventStreamCallback = {
        (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in

        guard let observer = clientCallBackInfo.map({ Unmanaged<ScreenshotObserver>.fromOpaque($0).takeUnretainedValue() }) else { return }
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

        for i in 0..<numEvents {
            let filePath = paths[i]
            let flags = eventFlags[i]

            // Ignore hidden files (starting with a dot)
            if (filePath as NSString).lastPathComponent.hasPrefix(".") {
                print("ScreenshotObserver: Ignoring hidden/temporary file: \(filePath)")
                continue
            }

            // Check for item creation, renaming, or modification in the monitored directory itself.
            // We're interested in files ending with common screenshot extensions.
            // kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemModified
            // Screenshots often trigger a created and then a modified event as data is written.
            // We also check kFSEventStreamEventFlagItemIsFile to make sure it's a file.
            if (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)) != 0 &&
               ((flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)) != 0 ||
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0 ||
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)) != 0) {
                
                // Debounce logic - ensure Timer is handled on main thread if it interacts with UI or @Published vars
                DispatchQueue.main.async {
                    // If a new event comes for the same file that is currently being debounced,
                    // reset the debounce timer and any polling associated with its *previous* debounce cycle.
                    if observer.lastProcessedFileForDebounce == filePath && observer.debounceTimer != nil {
                        observer.debounceTimer?.invalidate() 
                        // No need to call clearPollingState here, as the old debounce timer didn't fire to start polling yet.
                        // Polling state is per filePath and gets reset when tryProcessFileWithPolling is called.
                    }
                    observer.lastProcessedFileForDebounce = filePath
                    
                    observer.debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak observer] _ in
                        guard let strongObserver = observer else { return }
                        strongObserver.debounceTimer = nil // Main debounce timer has fired
                        
                        if strongObserver.isValidScreenshot(filePath: filePath) {
                             print("ScreenshotObserver: Debounced event for \(filePath) (flags: \(flags)). Starting polling for size.")
                             strongObserver.tryProcessFileWithPolling(filePath: filePath)
                        } else {
                            // print("ScreenshotObserver: Invalid screenshot after debounce: \(filePath)") // Can be verbose
                        }
                    }
                }
            }
        }
    }
    
    private func tryProcessFileWithPolling(filePath: String) {
        // Clear any existing polling for this file before starting a new sequence
        clearPollingState(for: filePath, cancelTimer: true)
        
        pollingAttempts[filePath] = 0
        lastKnownSizes[filePath] = -1 // Initialize with a value that won't match a valid size
        print("ScreenshotObserver: [Polling] Starting for \(filePath)")
        scheduleNextPoll(for: filePath)
    }

    private func scheduleNextPoll(for filePath: String) {
        // Ensure this timer is also scheduled on the main run loop
        let timer = Timer(timeInterval: pollingInterval, repeats: false) { [weak self] _ in
            self?.pollFileSize(for: filePath)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimers[filePath] = timer
    }

    private func pollFileSize(for filePath: String) {
        pollingTimers.removeValue(forKey: filePath) // Timer has fired, remove it
        
        var currentAttempts = pollingAttempts[filePath] ?? 0
        currentAttempts += 1
        pollingAttempts[filePath] = currentAttempts

        guard currentAttempts <= maxPollingAttempts else {
            print("ScreenshotObserver: [Polling] Max polling attempts (\(maxPollingAttempts)) reached for \(filePath). Aborting.")
            clearPollingState(for: filePath, cancelTimer: false) // Timer already fired or removed
            return
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
            let currentSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1

            if currentSize > 0 {
                let previousSize = lastKnownSizes[filePath]
                if previousSize == currentSize { // Deliberately check if previousSize was set and matches currentSize
                    print("ScreenshotObserver: [Polling] File \(filePath) size \(currentSize) bytes, stable. Processing.")
                    clearPollingState(for: filePath, cancelTimer: false)
                    // Ensure callback is on main thread if it updates UI or AppState @Published vars
                    DispatchQueue.main.async {
                        self.callback(filePath)
                    }
                } else {
                    print("ScreenshotObserver: [Polling] File \(filePath) attempt \(currentAttempts)/\(maxPollingAttempts), size \(currentSize) bytes. Polling again.")
                    lastKnownSizes[filePath] = currentSize
                    scheduleNextPoll(for: filePath)
                }
            } else if currentSize == 0 {
                print("ScreenshotObserver: [Polling] File \(filePath) attempt \(currentAttempts)/\(maxPollingAttempts), is empty (0 bytes). Polling again.")
                lastKnownSizes[filePath] = 0 
                scheduleNextPoll(for: filePath)
            } else { // currentSize == -1 (error getting attributes or size)
                print("ScreenshotObserver: [Polling] Error getting size for \(filePath) or file disappeared during poll attempt \(currentAttempts). Aborting.")
                clearPollingState(for: filePath, cancelTimer: false)
            }
        } catch {
            print("ScreenshotObserver: [Polling] Error getting attributes for \(filePath) on attempt \(currentAttempts): \(error.localizedDescription). Aborting.")
            clearPollingState(for: filePath, cancelTimer: false)
        }
    }

    private func clearPollingState(for filePath: String, cancelTimer: Bool) {
        if cancelTimer {
            pollingTimers[filePath]?.invalidate()
        }
        pollingTimers.removeValue(forKey: filePath)
        lastKnownSizes.removeValue(forKey: filePath)
        pollingAttempts.removeValue(forKey: filePath)
    }

    private func isValidScreenshot(filePath: String) -> Bool {
        let url = URL(fileURLWithPath: filePath)
        let standardizedPath = url.path
        let fileExists = FileManager.default.fileExists(atPath: standardizedPath)
        let fileExtension = (standardizedPath as NSString).pathExtension.lowercased()
        let imageExtensions = ["png", "jpg", "jpeg", "tiff", "bmp", "gif"]
        let hasImageExtension = imageExtensions.contains(fileExtension)
        return fileExists && hasImageExtension
    }


    deinit {
        stop()
    }
} 