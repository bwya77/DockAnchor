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
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@main
struct DockAnchorApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var appSettings = AppSettings()
    @StateObject private var dockMonitor = DockMonitor()
    @StateObject private var menuBarManager = MenuBarManager()
    
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var appDelegate
    private let windowHiderDelegate = WindowHiderDelegate()
    
    var body: some Scene {
        WindowGroup("DockAnchor") {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(appSettings)
                .environmentObject(dockMonitor)
                .onAppear {
                    setupApp()
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
    
    private func setupApp() {
        // Set up app delegate references
        appDelegate.setup(appSettings: appSettings, dockMonitor: dockMonitor, menuBarManager: menuBarManager)
        
        // Initialize the menu bar with current settings
        menuBarManager.setup(appSettings: appSettings, dockMonitor: dockMonitor)
        
        // Set the anchor display from settings
        dockMonitor.changeAnchorDisplay(to: appSettings.selectedDisplayID)
        
        // Ensure main window is visible even when hiding from dock
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if self.appSettings.hideFromDock {
                // Make sure the main window is visible
                for window in NSApp.windows {
                    if window.title == "DockAnchor" || window.contentViewController != nil {
                        window.makeKeyAndOrderFront(nil)
                        break
                    }
                }
            }
        }
        
        // Auto-start monitoring if enabled
        if appSettings.runInBackground {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                dockMonitor.startMonitoring()
            }
        }
    }
}

class ApplicationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var appSettings: AppSettings?
    private var dockMonitor: DockMonitor?
    private var menuBarManager: MenuBarManager?
    
    func setup(appSettings: AppSettings, dockMonitor: DockMonitor, menuBarManager: MenuBarManager) {
        self.appSettings = appSettings
        self.dockMonitor = dockMonitor
        self.menuBarManager = menuBarManager
        
        // Listen for dock visibility changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateDockVisibility),
            name: .dockVisibilityChanged,
            object: nil
        )
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set initial activation policy based on settings
        updateActivationPolicy()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        // Don't terminate when the main window is closed
        return false
    }
    
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Always bring the main window to front when dock icon is clicked
        // This prevents opening multiple instances
        menuBarManager?.showMainWindow()
        return false // Don't let the system handle reopening
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Clean up when app is actually quitting
        dockMonitor?.stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func updateDockVisibility() {
        updateActivationPolicy()
    }
    
    private func updateActivationPolicy() {
        let shouldHideFromDock = appSettings?.hideFromDock ?? false
        let newPolicy: NSApplication.ActivationPolicy = shouldHideFromDock ? .accessory : .regular
        
        // Set the activation policy - this will hide/show the app in dock
        NSApp.setActivationPolicy(newPolicy)
        
        // Force the change to take effect immediately
        DispatchQueue.main.async {
            // Activate the app to trigger the policy change
            NSApp.activate(ignoringOtherApps: false)
            
            // If hiding from dock, ensure menu bar is visible and window is shown
            if shouldHideFromDock {
                self.menuBarManager?.ensureStatusBarVisible()
                
                // Make sure the main window is visible even when hidden from dock
                for window in NSApp.windows {
                    if window.title == "DockAnchor" || window.contentViewController != nil {
                        window.makeKeyAndOrderFront(nil)
                        break
                    }
                }
            }
            
            // Force a dock refresh by sending a notification
            DistributedNotificationCenter.default().post(
                name: NSNotification.Name("com.apple.dock.refresh"),
                object: nil
            )
        }
    }
}

class MenuBarManager: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var appSettings: AppSettings?
    private var dockMonitor: DockMonitor?
    private var cancellables = Set<AnyCancellable>()
    
    deinit {
        removeStatusBar()
        cancellables.removeAll()
    }
    
    func setup(appSettings: AppSettings, dockMonitor: DockMonitor) {
        self.appSettings = appSettings
        self.dockMonitor = dockMonitor
        
        // Always setup the status bar initially (since default is true)
        setupStatusBar()
        
        // Listen for settings changes
        appSettings.$showStatusIcon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] showIcon in
                if showIcon {
                    self?.setupStatusBar()
                } else {
                    self?.removeStatusBar()
                }
            }
            .store(in: &cancellables)
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
                title: display.name + (display.isPrimary ? " (Primary)" : ""),
                action: #selector(selectDisplay(_:)),
                keyEquivalent: ""
            )
            displayItem.target = self
            displayItem.representedObject = display.id
            displayItem.state = display.id == appSettings.selectedDisplayID ? .on : .off
            displaySubmenu.addItem(displayItem)
        }
        
        let displayMenuItem = NSMenuItem(title: "Anchor to Display", action: nil, keyEquivalent: "")
        displayMenuItem.submenu = displaySubmenu
        menu.addItem(displayMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
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
    }
    
    private func updateStatusMenuItem(_ item: NSMenuItem, isActive: Bool) {
        item.title = isActive ? "🟢 Protection Active" : "🔴 Protection Inactive"
    }
    
    private func refreshDisplaySubmenu() {
        guard let menu = statusItem?.menu,
              let displayMenuItem = menu.item(withTitle: "Anchor to Display"),
              let submenu = displayMenuItem.submenu else { return }
        
        // Update checkmarks
        for item in submenu.items {
            if let displayID = item.representedObject as? CGDirectDisplayID {
                item.state = displayID == appSettings?.selectedDisplayID ? .on : .off
            }
        }
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
        guard let displayID = sender.representedObject as? CGDirectDisplayID else { return }
        appSettings?.selectedDisplayID = displayID
    }
    
    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        
        // Find and show the main window
        for window in NSApp.windows {
            if window.title == "DockAnchor" || window.contentViewController != nil {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        
        // If no window found, try to open a new one
        if let url = URL(string: "dockanchor://main") {
            NSWorkspace.shared.open(url)
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
