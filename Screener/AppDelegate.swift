import SwiftUI
import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, ObservableObject {
    private var statusItem: NSStatusItem?
    private var appState: AppState? 
    private var cancellables = Set<AnyCancellable>()

    private var activeImage: NSImage?
    private var disabledImage: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppState will be provided by ScreenerApp via the setup method.
    }

    func setup(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let symbolName = "camera.viewfinder"
        let symbolPointSize = NSStatusBar.system.thickness * 0.75 
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
        
        // Active Image (Template)
        if let originalActiveImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Screener App")?.withSymbolConfiguration(symbolConfig) {
            self.activeImage = originalActiveImage.copy() as? NSImage
            self.activeImage?.isTemplate = true
        }
        
        // Disabled Image (Pre-rendered Gray, Non-Template)
        if let sourceSymbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Screener App")?.withSymbolConfiguration(symbolConfig) {
            let imageSize = sourceSymbolImage.size
            // You can adjust this color for the desired grayness of the disabled icon
            let colorForDisabled = NSColor.tertiaryLabelColor // Example: Or NSColor.gray.withAlphaComponent(0.65)
            
            let preRenderedDisabledImage = NSImage(size: imageSize, flipped: false) { (dstRect) -> Bool in
                // Fill a background with the desired color
                colorForDisabled.setFill()
                dstRect.fill()
                
                // Draw the SF Symbol as a template, using it as a mask (destinationIn)
                sourceSymbolImage.isTemplate = true // Ensure it acts as a mask
                sourceSymbolImage.draw(in: dstRect, from: .zero, operation: .destinationIn, fraction: 1.0)
                return true
            }
            self.disabledImage = preRenderedDisabledImage
        }

        // Fallbacks if image creation somehow failed
        if activeImage == nil {
            activeImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Screener App")
            activeImage?.isTemplate = true
            print("AppDelegate: Warning - Could not create custom active image, using basic SF Symbol.")
        }
        if disabledImage == nil {
            disabledImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Screener App")
            disabledImage?.isTemplate = true 
            print("AppDelegate: Warning - Could not create custom disabled image, using template fallback.")
        }

        if let button = statusItem?.button {
            updateIconColor(isMonitoring: appState.isMonitoring) // Set initial image
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        appState.$isMonitoring
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isMonitoring in
                self?.updateIconColor(isMonitoring: isMonitoring)
            }
            .store(in: &cancellables)
    }
        
    @objc func statusItemClicked(_ sender: Any?) {
        guard let appState = self.appState, let event = NSApp.currentEvent else {
            print("AppDelegate: AppState not available or event missing.")
            return
        }
        if event.modifierFlags.contains(.option) {
            appState.toggleMonitoring()
        } else if event.type == .leftMouseUp || event.type == .rightMouseUp {
            // If statusItem.menu is already set, a direct click might show it automatically.
            // To be safe and ensure our constructed menu is shown, and we can clear it after:
            if statusItem?.menu == nil { // Only construct and show if no menu is currently set (or just shown)
                let menu = constructMenu()
                menu.delegate = self // Set delegate to know when it closes
                statusItem?.menu = menu
                statusItem?.button?.performClick(nil) // Programmatically click to show the menu
                // Note: statusItem.menu will be set to nil in menuDidClose
            } else {
                // If a menu is already set (e.g., from a rapid double click before menuDidClose fires),
                // we might not want to do anything, or explicitly re-show.
                // For now, this logic assumes menuDidClose will clear it promptly.
                 print("AppDelegate: Menu might already be visible or about to be cleared.")
            }
        }
    }
    
    private func constructMenu() -> NSMenu {
        guard let appState = self.appState else { return NSMenu() } // Return empty menu if no appState
        let menu = NSMenu()
        let toggleItemTitle = appState.isMonitoring ? "Stop Watching" : "Start Watching"
        let toggleItem = NSMenuItem(title: toggleItemTitle, action: #selector(toggleMonitoringAction), keyEquivalent: "")
        toggleItem.target = self; toggleItem.state = appState.isMonitoring ? .on : .off
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        let apiKeyItem = NSMenuItem(title: "Edit API Key...", action: #selector(editAPIKeyAction), keyEquivalent: "")
        apiKeyItem.target = self; menu.addItem(apiKeyItem)
        let folderItem = NSMenuItem(title: "Set Screenshots Folder...", action: #selector(setFolderAction), keyEquivalent: "")
        folderItem.target = self; menu.addItem(folderItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Screener", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        return menu
    }

    // NSMenuDelegate method
    func menuDidClose(_ menu: NSMenu) {
        // Important: Clear the menu from the status item so that our statusItemClicked action
        // is triggered again for the next click, rather than the system just re-showing the same menu.
        if statusItem?.menu == menu {
            statusItem?.menu = nil
            print("AppDelegate: Menu closed and cleared from status item.")
        }
    }
    
    func updateIconColor(isMonitoring: Bool) {
        DispatchQueue.main.async { 
            if let button = self.statusItem?.button {
                if isMonitoring {
                    button.image = self.activeImage 
                    button.contentTintColor = nil // Ensures template activeImage uses system default color
                } else {
                    button.image = self.disabledImage
                    button.contentTintColor = nil // For pre-rendered disabledImage, contentTintColor has no effect
                }
                button.needsDisplay = true
            }
        }
    }

    @objc func toggleMonitoringAction() { appState?.toggleMonitoring() }
    @objc func editAPIKeyAction() { NSApp.activate(ignoringOtherApps: true); appState?.isShowingApiKeyEditor = true }
    @objc func setFolderAction() { NSApp.activate(ignoringOtherApps: true); appState?.isShowingFolderPicker = true }
    func applicationWillTerminate(_ notification: Notification) { appState?.performDeinitEquivalentCleanup() }
} 
