//
//  DockAnchorApp.swift
//  DockAnchor
//
//  Created by Bradley Wyatt on 7/2/25.
//

import SwiftUI
import Cocoa
import Combine

class WindowHiderDelegate: NSObject, NSWindowDelegate {
    private var appSettings: AppSettings?
    
    func setup(appSettings: AppSettings) {
        self.appSettings = appSettings
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        
        // If the setting is enabled, hide the app from dock when window is closed
        if appSettings?.hideFromDock == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.setActivationPolicy(.accessory)
                
                // Force a dock refresh
                DistributedNotificationCenter.default().post(
                    name: NSNotification.Name("com.apple.dock.refresh"),
                    object: nil
                )
            }
        }
        
        return false
    }
}

@main
struct DockAnchorApp: App {
    let persistenceController = PersistenceController.shared

    // Use shared instances so they can be accessed from applicationDidFinishLaunching
    @ObservedObject private var appSettings = AppSettings.shared
    @ObservedObject private var dockMonitor = DockMonitor.shared
    @ObservedObject private var menuBarManager = MenuBarManager.shared
    @ObservedObject private var updateChecker = UpdateChecker.shared

    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var appDelegate
    private let windowHiderDelegate = WindowHiderDelegate()

    var body: some Scene {
        WindowGroup("DockAnchor") {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(appSettings)
                .environmentObject(dockMonitor)
                .environmentObject(updateChecker)
                .preferredColorScheme(appSettings.appTheme.colorScheme)
                .onAppear {
                    // Only set up window-specific things here
                    windowHiderDelegate.setup(appSettings: appSettings)
                }
                .background(WindowAccessor { window in
                    window?.delegate = windowHiderDelegate
                })
                .handlesExternalEvents(preferring: Set(arrayLiteral: "main"), allowing: Set(arrayLiteral: "*"))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: Set(arrayLiteral: "main"))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Show DockAnchor") {
                    menuBarManager.showMainWindow()
                }
                .keyboardShortcut("d", modifiers: [.command, .option])

                Divider()

                Button(dockMonitor.isActive ? "Stop Protection" : "Start Protection") {
                    if dockMonitor.isActive {
                        dockMonitor.stopMonitoring()
                    } else {
                        dockMonitor.startMonitoring()
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
            }
        }
    }
}

class ApplicationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    // Use shared instances directly
    private var appSettings: AppSettings { AppSettings.shared }
    private var dockMonitor: DockMonitor { DockMonitor.shared }
    private var menuBarManager: MenuBarManager { MenuBarManager.shared }
    private var updateChecker: UpdateChecker { UpdateChecker.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CRITICAL: Initialize everything here, not in onAppear
        // This ensures the app works correctly when launched at login
        // even if the window is not immediately visible

        // Listen for dock visibility changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateDockVisibility),
            name: .dockVisibilityChanged,
            object: nil
        )

        // Initialize the menu bar with current settings
        // This is the most critical piece - ensures menu bar icon appears
        menuBarManager.setup(appSettings: appSettings, dockMonitor: dockMonitor, updateChecker: updateChecker)

        // Set the anchor display from settings (using UUID for stable identification)
        dockMonitor.changeAnchorDisplay(toUUID: appSettings.selectedDisplayUUID)

        // Set initial activation policy
        updateActivationPolicy()

        // Auto-start monitoring if enabled (with a small delay for system stability)
        if appSettings.runInBackground {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.dockMonitor.startMonitoring()
            }
        }

        // Auto-relocate dock to anchored display on launch if enabled
        if appSettings.autoRelocateDock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.dockMonitor.relocateDockToAnchoredDisplay()
            }
        }

        // Check for updates after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.updateChecker.checkForUpdates()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        // Don't terminate when the main window is closed
        return false
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Check for updates when app is reopened
        updateChecker.checkForUpdates()

        // If we have visible windows, just bring them to front
        if flag {
            menuBarManager.showMainWindow()
            return false
        }

        // No visible windows - try to find and show an existing window
        for window in NSApp.windows {
            guard window.level == .normal,
                  window.frame.width > 100 && window.frame.height > 100 else {
                continue
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return false
        }

        // No windows found at all - let the system/SwiftUI create a new one
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up when app is actually quitting
        dockMonitor.stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func updateDockVisibility() {
        updateActivationPolicy()
    }

    private func updateActivationPolicy() {
        // Set activation policy based on hideFromDock setting
        let newPolicy: NSApplication.ActivationPolicy = appSettings.hideFromDock ? .accessory : .regular

        // Set the activation policy
        NSApp.setActivationPolicy(newPolicy)

        // Force the change to take effect immediately
        DispatchQueue.main.async { [weak self] in
            // Activate the app to trigger the policy change (only if not hiding)
            if !(self?.appSettings.hideFromDock ?? false) {
                NSApp.activate(ignoringOtherApps: false)
            }

            // Ensure menu bar is visible (especially important when hiding from dock)
            self?.menuBarManager.ensureStatusBarVisible()

            // Force a dock refresh by sending a notification
            DistributedNotificationCenter.default().post(
                name: NSNotification.Name("com.apple.dock.refresh"),
                object: nil
            )
        }
    }
}

class MenuBarManager: NSObject, ObservableObject {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private var appSettings: AppSettings?
    private var dockMonitor: DockMonitor?
    private var updateChecker: UpdateChecker?
    private var cancellables = Set<AnyCancellable>()
    
    deinit {
        removeStatusBar()
        cancellables.removeAll()
    }
    
    func setup(appSettings: AppSettings, dockMonitor: DockMonitor, updateChecker: UpdateChecker) {
        self.appSettings = appSettings
        self.dockMonitor = dockMonitor
        self.updateChecker = updateChecker

        // Setup status bar based on current setting
        if appSettings.showStatusIcon {
            setupStatusBar()
        }

        // Listen for future settings changes (dropFirst to skip initial value we already handled)
        appSettings.$showStatusIcon
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] showIcon in
                if showIcon {
                    self?.setupStatusBar()
                } else {
                    self?.removeStatusBar()
                }
            }
            .store(in: &cancellables)

        // Listen for display changes via notification (backup for Combine)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDisplaysChanged),
            name: .displaysDidChange,
            object: nil
        )
    }

    @objc private func handleDisplaysChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateDisplaySubmenu()
        }
    }
    
    private func setupStatusBar() {
        // Remove existing status item first
        removeStatusBar()
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockAnchor")
            button.toolTip = "DockAnchor - Click to open"
            button.action = #selector(statusItemClicked)
            button.target = self
        }
        
        setupStatusMenu()
    }
    
    private func removeStatusBar() {
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }
    
    private func setupStatusMenu() {
        guard let dockMonitor = dockMonitor, let appSettings = appSettings else { return }
        
        let menu = NSMenu()
        
        // Status indicator
        let statusMenuItem = NSMenuItem()
        updateStatusMenuItem(statusMenuItem, isActive: dockMonitor.isActive)
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        // Current anchor display
        let anchorMenuItem = NSMenuItem()
        anchorMenuItem.title = "📍 \(dockMonitor.anchoredDisplay)"
        anchorMenuItem.isEnabled = false
        menu.addItem(anchorMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Toggle protection
        let toggleMenuItem = NSMenuItem(
            title: dockMonitor.isActive ? "Stop Protection" : "Start Protection",
            action: #selector(toggleProtection),
            keyEquivalent: ""
        )
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quick display selection submenu
        let displaySubmenu = NSMenu()
        for display in dockMonitor.availableDisplays {
            let displayItem = NSMenuItem(
                title: display.name, // Don't add (Primary) here since it's already in display.name
                action: #selector(selectDisplay(_:)),
                keyEquivalent: ""
            )
            displayItem.target = self
            displayItem.representedObject = display.uuid  // Use UUID for stable identification
            displayItem.state = display.uuid == appSettings.selectedDisplayUUID ? .on : .off
            displaySubmenu.addItem(displayItem)
        }
        
        let displayMenuItem = NSMenuItem(title: "Anchor to Display", action: nil, keyEquivalent: "")
        displayMenuItem.submenu = displaySubmenu
        menu.addItem(displayMenuItem)

        // Theme submenu
        let themeSubmenu = NSMenu()
        for theme in AppTheme.allCases {
            let themeItem = NSMenuItem(
                title: theme.rawValue,
                action: #selector(selectTheme(_:)),
                keyEquivalent: ""
            )
            themeItem.target = self
            themeItem.representedObject = theme
            themeItem.state = theme == appSettings.appTheme ? .on : .off
            themeSubmenu.addItem(themeItem)
        }

        let themeMenuItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeMenuItem.submenu = themeSubmenu
        menu.addItem(themeMenuItem)

        // Profiles submenu
        let profilesSubmenu = NSMenu()
        if appSettings.profiles.isEmpty {
            let noProfilesItem = NSMenuItem(title: "No Profiles", action: nil, keyEquivalent: "")
            noProfilesItem.isEnabled = false
            profilesSubmenu.addItem(noProfilesItem)
        } else {
            for profile in appSettings.profiles {
                // Show bolt icon for auto-activate profiles
                let title = profile.autoActivate ? "⚡ \(profile.name)" : profile.name
                let profileItem = NSMenuItem(
                    title: title,
                    action: #selector(selectProfile(_:)),
                    keyEquivalent: ""
                )
                profileItem.target = self
                profileItem.representedObject = profile.id
                profileItem.state = profile.id == appSettings.activeProfileID ? .on : .off
                profilesSubmenu.addItem(profileItem)
            }
        }

        let profilesMenuItem = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
        profilesMenuItem.submenu = profilesSubmenu
        menu.addItem(profilesMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Check for updates
        let updateMenuItem = NSMenuItem(
            title: "Check for Updates",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateMenuItem.target = self
        menu.addItem(updateMenuItem)

        // Buy Me a Coffee
        let coffeeMenuItem = NSMenuItem(
            title: "Buy Me a Coffee ☕",
            action: #selector(openBuyMeACoffee),
            keyEquivalent: ""
        )
        coffeeMenuItem.target = self
        menu.addItem(coffeeMenuItem)

        // Feedback & Issues
        let feedbackMenuItem = NSMenuItem(
            title: "Feedback & Issues",
            action: #selector(openFeedback),
            keyEquivalent: ""
        )
        feedbackMenuItem.target = self
        menu.addItem(feedbackMenuItem)

        // Show main window
        let showMenuItem = NSMenuItem(
            title: "Show DockAnchor",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showMenuItem.target = self
        menu.addItem(showMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitMenuItem = NSMenuItem(
            title: "Quit DockAnchor",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)
        
        statusItem?.menu = menu
        
        // Update menu when monitor status changes
        dockMonitor.$isActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.updateStatusMenuItem(statusMenuItem, isActive: isActive)
                toggleMenuItem.title = isActive ? "Stop Protection" : "Start Protection"
            }
            .store(in: &cancellables)
        
        // Update anchor display in menu
        dockMonitor.$anchoredDisplay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] displayName in
                anchorMenuItem.title = "📍 \(displayName)"
                self?.refreshDisplaySubmenu()
            }
            .store(in: &cancellables)
        
        // Update tooltip with status
        dockMonitor.$statusMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.statusItem?.button?.toolTip = "DockAnchor - \(message)"
            }
            .store(in: &cancellables)
        
        // Update display submenu when available displays change
        dockMonitor.$availableDisplays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateDisplaySubmenu()
            }
            .store(in: &cancellables)

        // Update profiles submenu when profiles change
        appSettings.$profiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshProfilesSubmenu()
            }
            .store(in: &cancellables)

        // Update profiles submenu when active profile changes
        appSettings.$activeProfileID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshProfilesSubmenu()
            }
            .store(in: &cancellables)
    }
    
    private func updateStatusMenuItem(_ item: NSMenuItem, isActive: Bool) {
        item.title = isActive ? "🟢 Protection Active" : "🔴 Protection Inactive"
    }
    
    private func refreshDisplaySubmenu() {
        guard let menu = statusItem?.menu,
              let displayMenuItem = menu.item(withTitle: "Anchor to Display"),
              let submenu = displayMenuItem.submenu else { return }

        // Update checkmarks using UUID
        for item in submenu.items {
            if let displayUUID = item.representedObject as? String {
                item.state = displayUUID == appSettings?.selectedDisplayUUID ? .on : .off
            }
        }
    }

    private func updateDisplaySubmenu() {
        guard let menu = statusItem?.menu,
              let displayMenuItem = menu.item(withTitle: "Anchor to Display"),
              let dockMonitor = dockMonitor,
              let appSettings = appSettings else { return }

        // Create new submenu with updated displays
        let newSubmenu = NSMenu()
        for display in dockMonitor.availableDisplays {
            let displayItem = NSMenuItem(
                title: display.name, // Don't add (Primary) here since it's already in display.name
                action: #selector(selectDisplay(_:)),
                keyEquivalent: ""
            )
            displayItem.target = self
            displayItem.representedObject = display.uuid  // Use UUID for stable identification
            displayItem.state = display.uuid == appSettings.selectedDisplayUUID ? .on : .off
            newSubmenu.addItem(displayItem)
        }

        // Replace the submenu
        displayMenuItem.submenu = newSubmenu
    }
    
    @objc private func statusItemClicked() {
        showMainWindow()
    }
    
    @objc private func toggleProtection() {
        guard let dockMonitor = dockMonitor else { return }
        if dockMonitor.isActive {
            dockMonitor.stopMonitoring()
        } else {
            dockMonitor.startMonitoring()
        }
    }
    
    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let displayUUID = sender.representedObject as? String else { return }
        appSettings?.selectedDisplayUUID = displayUUID
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let theme = sender.representedObject as? AppTheme else { return }
        appSettings?.appTheme = theme
        refreshThemeSubmenu()
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? UUID,
              let profile = appSettings?.profiles.first(where: { $0.id == profileID }) else { return }
        appSettings?.switchToProfile(profile)
        refreshProfilesSubmenu()
    }

    private func refreshProfilesSubmenu() {
        guard let menu = statusItem?.menu,
              let profilesMenuItem = menu.item(withTitle: "Profiles"),
              let appSettings = appSettings else { return }

        let newSubmenu = NSMenu()
        if appSettings.profiles.isEmpty {
            let noProfilesItem = NSMenuItem(title: "No Profiles", action: nil, keyEquivalent: "")
            noProfilesItem.isEnabled = false
            newSubmenu.addItem(noProfilesItem)
        } else {
            for profile in appSettings.profiles {
                // Show bolt icon for auto-activate profiles
                let title = profile.autoActivate ? "⚡ \(profile.name)" : profile.name
                let profileItem = NSMenuItem(
                    title: title,
                    action: #selector(selectProfile(_:)),
                    keyEquivalent: ""
                )
                profileItem.target = self
                profileItem.representedObject = profile.id
                profileItem.state = profile.id == appSettings.activeProfileID ? .on : .off
                newSubmenu.addItem(profileItem)
            }
        }
        profilesMenuItem.submenu = newSubmenu
    }

    private func refreshThemeSubmenu() {
        guard let menu = statusItem?.menu,
              let themeMenuItem = menu.item(withTitle: "Theme"),
              let submenu = themeMenuItem.submenu else { return }

        for item in submenu.items {
            if let theme = item.representedObject as? AppTheme {
                item.state = theme == appSettings?.appTheme ? .on : .off
            }
        }
    }

    @objc private func checkForUpdates() {
        updateChecker?.checkForUpdates(isManual: true)
    }

    @objc private func openBuyMeACoffee() {
        if let url = URL(string: "https://buymeacoffee.com/bwya77") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openFeedback() {
        if let url = URL(string: "https://github.com/bwya77/DockAnchor") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func showMainWindow() {
        // Always restore the dock icon when showing the window (unless hideFromDock is set)
        if !(appSettings?.hideFromDock ?? false) {
            NSApp.setActivationPolicy(.regular)
        }

        // Activate the app - this is crucial for bringing it to foreground
        NSApp.activate(ignoringOtherApps: true)

        // Force a dock refresh
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name("com.apple.dock.refresh"),
            object: nil
        )

        // Find and show the main window - look for any suitable window
        for window in NSApp.windows {
            // Skip windows that are clearly not our main window (like status bar menus, panels)
            guard window.level == .normal,
                  window.className.contains("NSWindow") || window.className.contains("SwiftUI") else {
                continue
            }

            // Skip tiny windows (likely not our main window)
            guard window.frame.width > 100 && window.frame.height > 100 else {
                continue
            }

            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // If no window found, the window may have been closed and SwiftUI released it
        // Post a notification that the app can listen for to recreate the window
        NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)

        // Give SwiftUI a moment then try again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.level == .normal && window.frame.width > 100 {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
    
    @objc private func quitApp() {
        dockMonitor?.stopMonitoring()
        NSApp.terminate(nil)
    }
    
    func ensureStatusBarVisible() {
        // Ensure the status bar is visible when hiding from dock
        if statusItem == nil && (appSettings?.showStatusIcon ?? true) {
            setupStatusBar()
        }
    }
}

// Helper to access the NSWindow from SwiftUI
struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.callback(view.window)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
