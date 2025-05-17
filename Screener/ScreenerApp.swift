//
//  ScreenerApp.swift
//  Screener
//
//  Created by Benjamin Zweig on 5/8/25.
//

import SwiftUI
import UniformTypeIdentifiers // Required for UTType.folder
import AppKit // Import AppKit for NSApplication

@main
struct ScreenerApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Hidden window to handle modal presentations (sheets, file importers)
        Window("Screener Hidden Window", id: "hidden-presenter") {
            // Empty view, window will not be shown to the user
            // but is required for .sheet and .fileImporter to work from MenuBarExtra
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear {
                    // Pass the AppState instance to the AppDelegate once it's available
                    appDelegate.setup(appState: appState)
                }
                .sheet(isPresented: $appState.isShowingApiKeyEditor) {
                    APIKeyEditorView().environmentObject(appState)
                }
                .fileImporter(
                    isPresented: $appState.isShowingFolderPicker,
                    allowedContentTypes: [UTType.folder], // Corrected: Use UTType.folder
                    allowsMultipleSelection: false
                ) { result in
                    appState.handleFolderSelection(result: result)
                }
        }
        .windowStyle(.hiddenTitleBar) // Hide title bar if it ever tries to show
        .windowResizability(.contentSize) // Not user resizable
        // You might want to ensure this window is not directly interactable or visible.
        // For truly hidden, you might need to delve into AppKit lifecycle to hide it post-launch.
        // However, for presentation purposes, this often suffices if its content is nil/empty.
    }
}

class AppState: ObservableObject {
    @AppStorage("apiKey") var apiKey: String = ""
    // Store bookmark data instead of just the path
    @AppStorage("watchedFolderBookmarkData") private var watchedFolderBookmarkData: Data?
    
    // This will be the resolved, security-scoped URL
    private var securityScopedWatchedURL: URL?

    // Public accessor for the path of the watched folder
    public var currentWatchedFolderPath: String? {
        return securityScopedWatchedURL?.path
    }

    @Published var isMonitoring: Bool = false
    private var screenshotObserver: ScreenshotObserver?
    private var monitoringAccessStarted: Bool = false

    @Published var isShowingApiKeyEditor: Bool = false {
        didSet { if isShowingApiKeyEditor { NSApp.activate(ignoringOtherApps: true) } }
    }
    @Published var isShowingFolderPicker: Bool = false {
        didSet { if isShowingFolderPicker { NSApp.activate(ignoringOtherApps: true) } }
    }

    // To prevent re-processing files we just renamed
    private var recentlyProcessedFileOriginalPaths: Set<String> = []
    private var recentlyRenamedToPaths: Set<String> = [] // Tracks the names we assign
    private let pathProcessingLock = NSLock()

    init() {
        resolveBookmarkedURLAndSetupObserver() // Resolve URL and then setup observer
        if !apiKey.isEmpty && securityScopedWatchedURL != nil {
            startMonitoring() // Start if API key and valid bookmarked folder exist
        } else {
            if apiKey.isEmpty {
                print("API Key not set.")
                // self.isShowingApiKeyEditor = true // Optionally prompt
            }
            if securityScopedWatchedURL == nil {
                print("Watched folder not set or bookmark invalid.")
                // self.isShowingFolderPicker = true // Optionally prompt
            }
        }
    }
    
    private func resolveBookmarkedURLAndSetupObserver() {
        guard let bookmarkData = watchedFolderBookmarkData else {
            print("No bookmark data found for watched folder.")
            setupObserver(path: nil) // Setup with nil path if no bookmark
            return
        }
        var isStale = false
        do {
            let resolvedUrl = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                print("Bookmark is stale, trying to refresh it.")
                // If stale, try to create a new bookmark from the resolved URL and save it again.
                // This requires the user to have previously granted access, and the resource to still be available.
                handleFolderSelectionSuccess(url: resolvedUrl, isBookmarkRefresh: true)
                // The handleFolderSelectionSuccess will call setupObserver again after refreshing
                return 
            }
            self.securityScopedWatchedURL = resolvedUrl
            print("Successfully resolved bookmarked URL: \(resolvedUrl.path)")
            setupObserver(path: resolvedUrl.path)
        } catch {
            print("Error resolving bookmark data: \(error.localizedDescription). Clearing stale bookmark.")
            watchedFolderBookmarkData = nil
            securityScopedWatchedURL = nil
            setupObserver(path: nil)
        }
    }

    private func setupObserver(path: String?) {
        screenshotObserver?.stop()
        if let validPath = path,
           FileManager.default.fileExists(atPath: validPath),
           FileManager.default.isDirectory(atPath: validPath) {
            screenshotObserver = ScreenshotObserver(path: validPath, callback: handleNewScreenshot)
        } else {
            screenshotObserver = nil
            print("Watched folder path (\(path ?? "nil")) is invalid or not set. Observer not created.")
        }
    }

    func toggleMonitoring() {
        if isMonitoring {
            stopMonitoring()
        } else {
            guard !apiKey.isEmpty else {
                print("API Key is missing. Cannot start monitoring.")
                self.isShowingApiKeyEditor = true // This will now trigger activation
                return
            }
            guard securityScopedWatchedURL != nil else {
                print("Watched folder not set or bookmark invalid.")
                self.isShowingFolderPicker = true
                return
            }
            startMonitoring()
        }
    }

    func startMonitoring() {
        guard !apiKey.isEmpty else { 
            print("Cannot start: API Key missing.")
            self.isShowingApiKeyEditor = true // This will now trigger activation
            return
        }
        guard let url = securityScopedWatchedURL, FileManager.default.fileExists(atPath: url.path), FileManager.default.isDirectory(atPath: url.path) else {
            print("Cannot start: Watched folder path is invalid or not set.")
            self.isShowingFolderPicker = true
            return
        }
        
        // Set up the observer before starting access
        setupObserver(path: url.path)

        guard screenshotObserver != nil else {
            isMonitoring = false
            print("Failed to start monitoring: Observer not initialized.")
            return
        }

        monitoringAccessStarted = url.startAccessingSecurityScopedResource()
        if monitoringAccessStarted {
            screenshotObserver?.start()
            isMonitoring = true
            print("Screenshot monitoring started for path: \(url.path).")
        } else {
            isMonitoring = false
            screenshotObserver = nil
            print("Failed to start monitoring: Could not access folder.")
            self.isShowingFolderPicker = true
        }
    }

    func stopMonitoring() {
        screenshotObserver?.stop()
        if monitoringAccessStarted, let url = securityScopedWatchedURL {
            url.stopAccessingSecurityScopedResource()
            monitoringAccessStarted = false
            print("Stopped accessing security scoped resource: \(url.path)")
        }
        isMonitoring = false
        print("Screenshot monitoring stopped.")
    }
    
    private func handleFolderSelectionSuccess(url: URL, isBookmarkRefresh: Bool = false) {
        // Stop accessing the old URL if it exists and is different
        if let oldURL = self.securityScopedWatchedURL, oldURL != url {
            oldURL.stopAccessingSecurityScopedResource()
            print("AppState: Stopped accessing old security scoped resource: \(oldURL.path)")
        }

        var newBookmarkData: Data? = nil
        var accessStartedForBookmarkCreation = false

        // For the URL obtained directly from the file picker, start access before creating a bookmark.
        // This is crucial for sandboxed apps.
        if url.isFileURL { // Ensure it's a file URL
            accessStartedForBookmarkCreation = url.startAccessingSecurityScopedResource()
            if !accessStartedForBookmarkCreation {
                print("AppState: Warning - Could not start security access for \(url.path) prior to creating bookmark. Bookmark creation may fail.")
            }
        }

        do {
            newBookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            print("AppState: Successfully created bookmark data for: \(url.path)")
        } catch {
            print("AppState: Error creating bookmark for \(url.path): \(error.localizedDescription)")
            // If bookmark creation failed, ensure we don't leave an orphaned access started.
            if accessStartedForBookmarkCreation {
                url.stopAccessingSecurityScopedResource()
                print("AppState: Stopped security access for \(url.path) after failed bookmark creation.")
            }
            // Do not proceed if bookmark creation failed.
            // Optionally, inform the user.
            return
        }
        
        // If we started access specifically for bookmark creation, stop it now.
        // The bookmark itself will be used for future access.
        if accessStartedForBookmarkCreation {
            url.stopAccessingSecurityScopedResource()
            print("AppState: Stopped initial security access for \(url.path) after successful bookmark creation.")
        }

        // If bookmark data was successfully created, update AppStorage and internal state.
        self.watchedFolderBookmarkData = newBookmarkData
        // It's important to set securityScopedWatchedURL to the *original* URL from the picker,
        // not one derived from immediately re-resolving the new bookmarkData here.
        // The resolveBookmarkedURLAndSetupObserver will handle resolving from bookmarkData on next launch/need.
        self.securityScopedWatchedURL = url 

        if !isBookmarkRefresh {
            if isMonitoring {
                stopMonitoring() // This will call stopAccessing on any *previously* bookmarked URL
                startMonitoring() // This will resolve the new bookmark and start access
            } else {
                // Resolve and setup observer for the new URL, this will also attempt to start access
                resolveBookmarkedURLAndSetupObserver() 
            }
        } else {
            print("AppState: Bookmark refreshed. Caller (resolveBookmarkedURLAndSetupObserver) will re-setup observer.")
            // Ensure resolveBookmarkedURLAndSetupObserver can correctly re-initialize with the new URL
            // by re-calling it, as it contains the logic to start access and setup the observer.
            resolveBookmarkedURLAndSetupObserver()
        }
    }

    func handleFolderSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                if FileManager.default.isDirectory(atPath: url.path) {
                    handleFolderSelectionSuccess(url: url)
                } else {
                    print("Selected item is not a directory: \(url.path)")
                }
            }
        case .failure(let error):
            print("Failed to select folder: \(error.localizedDescription)")
        }
    }

    func handleNewScreenshot(filePath: String) {
        pathProcessingLock.lock()
        // If this filePath is one we just renamed *to*, ignore it.
        if recentlyRenamedToPaths.contains(filePath) {
            print("AppState: Ignoring event for already processed (renamed-to) file path: \(filePath)")
            // We can remove it now, as we've seen the event for it.
            recentlyRenamedToPaths.remove(filePath)
            pathProcessingLock.unlock()
            return
        }
        // If this filePath is an original path we are currently processing or just processed,
        // and haven't yet registered its renamed form, also be wary (though primary check is above)
        // This specific check might be less critical if the recentlyRenamedToPaths check is robust.
        if recentlyProcessedFileOriginalPaths.contains(filePath) && !recentlyRenamedToPaths.isEmpty {
             // This situation should ideally be caught by the debounce/polling of the renamed file itself.
             // Or if the rename was so fast it didn't trigger a new FSEvent cycle for the new name yet.
            print("AppState: Warning - event for original path \(filePath) while its renamed form might be pending or just processed.")
        }
        recentlyProcessedFileOriginalPaths.insert(filePath) // Mark this original path as being processed
        pathProcessingLock.unlock()

        print("AppState: New screenshot to process: \(filePath)")
        guard !apiKey.isEmpty else {
            print("AppState: API Key is missing. Cannot process screenshot.")
            // Clean up original path if we bail early
            pathProcessingLock.lock()
            recentlyProcessedFileOriginalPaths.remove(filePath)
            pathProcessingLock.unlock()
            return
        }
        
        print("AppState: Calling OpenAI to analyze: \(filePath)")
        OpenAIService.shared.analyzeImage(filePath: filePath, apiKey: apiKey) { [weak self] result in
            guard let self = self else { return }
            
            self.pathProcessingLock.lock()
            // Done with this original path, remove it from active processing list.
            self.recentlyProcessedFileOriginalPaths.remove(filePath)
            self.pathProcessingLock.unlock()

            switch result {
            case .success(let description):
                print("AppState: LLM description: \(description)")
                let sanitizedDescription = description.replacingOccurrences(of: "[^a-zA-Z0-9_-]+", with: "_", options: .regularExpression)
                                                    .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                self.renameFile(originalPath: filePath, newNameSuggestion: sanitizedDescription)
            case .failure(let error):
                print("AppState: LLM analysis failed for \(filePath): \(error)")
            }
        }
    }

    func renameFile(originalPath: String, newNameSuggestion: String) {
        let fileManager = FileManager.default
        let originalURL = URL(fileURLWithPath: originalPath)
        let directory = originalURL.deletingLastPathComponent()
        let fileExtension = originalURL.pathExtension
        let sanitizedName = String(newNameSuggestion.prefix(100))
        
        let newFileName = "\(sanitizedName).\(fileExtension)"
        let newPath = directory.appendingPathComponent(newFileName).path
        
        if newPath == originalPath {
            print("AppState: Suggested new name is same as original or file already named as such. No rename needed for \(originalPath).")
            return
        }

        do {
            try fileManager.moveItem(atPath: originalPath, toPath: newPath)
            print("AppState: File renamed from \(originalPath) to: \(newPath)")
            
            pathProcessingLock.lock()
            recentlyRenamedToPaths.insert(newPath)
            pathProcessingLock.unlock()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self else { return }
                self.pathProcessingLock.lock()
                if self.recentlyRenamedToPaths.remove(newPath) != nil {
                    print("AppState: Removed \(newPath) from recentlyRenamedToPaths after delay.")
                }
                self.pathProcessingLock.unlock()
            }

        } catch {
            print("AppState: Error renaming file from \(originalPath) to \(newPath): \(error.localizedDescription)")
            pathProcessingLock.lock()
            recentlyProcessedFileOriginalPaths.remove(originalPath)
            pathProcessingLock.unlock()
        }
    }
    
    // Method for AppDelegate to call during applicationWillTerminate
    func performDeinitEquivalentCleanup() {
        if let url = securityScopedWatchedURL {
            url.stopAccessingSecurityScopedResource()
            print("AppState: Cleaned up - Stopped accessing security scoped resource: \(url.path)")
        }
        screenshotObserver?.stop() // Ensure observer is stopped
        print("AppState: Performed deinit equivalent cleanup.")
    }

    // Deinit is still useful for safety, though AppDelegate will also call cleanup
    deinit {
        performDeinitEquivalentCleanup() 
    }
}

struct APIKeyEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var editableApiKey: String = ""

    var body: some View {
        VStack(spacing: 15) {
            Text("Edit OpenAI API Key")
                .font(.title2)
            SecureField("Enter your OpenAI API Key", text: $editableApiKey)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    appState.apiKey = editableApiKey
                    if !appState.apiKey.isEmpty && !appState.isMonitoring {
                        // Corrected check for folder path validity
                        let folderPath = appState.currentWatchedFolderPath
                        if let path = folderPath, !path.isEmpty, FileManager.default.isDirectory(atPath: path) {
                             appState.startMonitoring()
                        } else if let path = folderPath, !path.isEmpty {
                            print("API Key saved. Watched folder (\(path)) is invalid or not a directory. Please set a valid folder.")
                            // Optionally trigger folder picker: appState.isShowingFolderPicker = true
                        } else {
                             print("API Key saved. Watched folder not set. Please set a folder.")
                             // Optionally trigger folder picker: appState.isShowingFolderPicker = true
                        }
                    }
                    dismiss()
                }
                .disabled(editableApiKey.isEmpty)
            }
        }
        .padding()
        .frame(width: 350, height: 150)
        .onAppear {
            editableApiKey = appState.apiKey
        }
    }
}

extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
