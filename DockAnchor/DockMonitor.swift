//
//  DockMonitor.swift
//  DockAnchor
//
//  Created by Bradley Wyatt on 7/2/25.
//

import Foundation
import Cocoa
import ApplicationServices
import Carbon
import CoreGraphics
import Combine

class DockMonitor: NSObject, ObservableObject {
    @Published var isActive = false
    @Published var anchoredDisplay: String = "Primary"
    @Published var statusMessage = "Dock Anchor Ready"
    @Published var availableDisplays: [DisplayInfo] = []
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isMonitoring = false
    private var anchorDisplayID: CGDirectDisplayID = 0
    private var dockPosition: DockPosition = .bottom
    private var cancellables = Set<AnyCancellable>()
    
    enum DockPosition {
        case bottom, left, right
    }
    
    struct DisplayInfo: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let frame: CGRect
        let name: String
        let isPrimary: Bool
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
        
        static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
            return lhs.id == rhs.id
        }
    }
    
    override init() {
        super.init()
        setupInitialState()
        setupNotificationObservers()
    }
    
    private func setupInitialState() {
        anchorDisplayID = CGMainDisplayID()
        updateAvailableDisplays()
        detectCurrentDockPosition()
        _ = requestAccessibilityPermissions()
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: .anchorDisplayChanged)
            .compactMap { $0.object as? CGDirectDisplayID }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newDisplayID in
                self?.changeAnchorDisplay(to: newDisplayID)
            }
            .store(in: &cancellables)
    }
    
    func updateAvailableDisplays() {
        availableDisplays = getAllDisplays()
        updateAnchoredDisplayName()
    }
    
    private func updateAnchoredDisplayName() {
        if let display = availableDisplays.first(where: { $0.id == anchorDisplayID }) {
            anchoredDisplay = display.name
        }
    }
    
    func changeAnchorDisplay(to displayID: CGDirectDisplayID) {
        anchorDisplayID = displayID
        updateAnchoredDisplayName()
        
        statusMessage = "Anchor changed to \(anchoredDisplay)"
        
        // Reset status message after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if self.isActive {
                self.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
            } else {
                self.statusMessage = "Dock Anchor Ready"
            }
        }
    }
    
    private func detectCurrentDockPosition() {
        let orientation = UserDefaults.standard.string(forKey: "com.apple.dock.orientation") ?? "bottom"
        switch orientation {
        case "left":
            dockPosition = .left
        case "right":
            dockPosition = .right
        default:
            dockPosition = .bottom
        }
    }
    
    func requestAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if !trusted {
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Accessibility permissions required"
            }
        }
        
        return trusted
    }
    
    func startMonitoring() {
        guard requestAccessibilityPermissions() else {
            statusMessage = "Please grant accessibility permissions in System Preferences"
            return
        }
        
        guard !isMonitoring else { return }
        
        updateAvailableDisplays()
        
        let eventMask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let monitor = Unmanaged<DockMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handleMouseEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            statusMessage = "Failed to create event tap"
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        isMonitoring = true
        DispatchQueue.main.async { [weak self] in
            self?.isActive = true
            self?.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
        }
    }
    
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        isMonitoring = false
        
        // Safely disable and clean up event tap
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        
        // Safely remove run loop source
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.isActive = false
            self?.statusMessage = "Dock Anchor Stopped"
        }
    }
    
    private func handleMouseEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .mouseMoved else {
            return Unmanaged.passUnretained(event)
        }
        
        let location = event.location
        
        // Check if mouse is approaching dock trigger zone on non-anchor displays
        if shouldBlockDockMovement(at: location) {
            // Block the event by not passing it through
            return nil
        }
        
        return Unmanaged.passUnretained(event)
    }
    
    private func shouldBlockDockMovement(at location: CGPoint) -> Bool {
        // Check if mouse is in dock trigger zone of non-anchor displays
        for display in availableDisplays {
            if display.id == anchorDisplayID { continue }
            
            let triggerZone = getDockTriggerZone(for: display)
            if triggerZone.contains(location) {
                DispatchQueue.main.async { [weak self] in
                    self?.statusMessage = "Blocked dock movement attempt to \(display.name)"
                    
                    // Reset status message after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self = self else { return }
                        self.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
                    }
                }
                return true
            }
        }
        
        return false
    }
    
    private func getDockTriggerZone(for display: DisplayInfo) -> CGRect {
        switch dockPosition {
        case .bottom:
            return CGRect(
                x: display.frame.minX,
                y: display.frame.maxY - 10,
                width: display.frame.width,
                height: 10
            )
        case .left:
            return CGRect(
                x: display.frame.minX,
                y: display.frame.minY,
                width: 10,
                height: display.frame.height
            )
        case .right:
            return CGRect(
                x: display.frame.maxX - 10,
                y: display.frame.minY,
                width: 10,
                height: display.frame.height
            )
        }
    }
    
    private func getAllDisplays() -> [DisplayInfo] {
        var displays: [DisplayInfo] = []
        
        let maxDisplays: UInt32 = 16
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        
        let result = CGGetActiveDisplayList(maxDisplays, &displayIDs, &displayCount)
        
        guard result == .success else { return displays }
        
        let mainDisplayID = CGMainDisplayID()
        
        for i in 0..<Int(displayCount) {
            let displayID = displayIDs[i]
            let frame = CGDisplayBounds(displayID)
            let name = getDisplayName(for: displayID)
            let isPrimary = displayID == mainDisplayID
            
            displays.append(DisplayInfo(id: displayID, frame: frame, name: name, isPrimary: isPrimary))
        }
        
        // Sort so primary display is first
        displays.sort { $0.isPrimary && !$1.isPrimary }
        
        return displays
    }
    
    private func getDisplayName(for displayID: CGDirectDisplayID) -> String {
        let mainDisplayID = CGMainDisplayID()
        
        // Get the actual display name from the system
        if let displayName = getSystemDisplayName(for: displayID) {
            let isPrimary = displayID == mainDisplayID
            return isPrimary ? "\(displayName) (Primary)" : displayName
        }
        
        // Fallback to generic names if we can't get the system name
        if displayID == mainDisplayID {
            return "Primary Display"
        } else {
            // Try to get a more descriptive name based on position
            let frame = CGDisplayBounds(displayID)
            let mainFrame = CGDisplayBounds(mainDisplayID)
            
            if frame.minX > mainFrame.maxX {
                return "Right Display"
            } else if frame.maxX < mainFrame.minX {
                return "Left Display"
            } else if frame.minY > mainFrame.maxY {
                return "Bottom Display"
            } else if frame.maxY < mainFrame.minY {
                return "Top Display"
            } else {
                return "Secondary Display"
            }
        }
    }
    
    private func getSystemDisplayName(for displayID: CGDirectDisplayID) -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = ["SPDisplaysDataType"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            // Parse the output to find display names
            let lines = output.components(separatedBy: .newlines)
            var currentDisplayName: String?
            
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                
                // Look for display names (lines ending with ":")
                if trimmedLine.hasSuffix(":") && !trimmedLine.contains(":") {
                    let displayName = String(trimmedLine.dropLast()) // Remove the ":"
                    
                    // Skip sidecar displays
                    if displayName.lowercased().contains("sidecar") {
                        currentDisplayName = nil
                        continue
                    }
                    
                    currentDisplayName = displayName
                }
                
                // Look for resolution info to help identify the display
                if trimmedLine.contains("Resolution:") && currentDisplayName != nil {
                    // Try to match by resolution and position
                    let frame = CGDisplayBounds(displayID)
                    let resolution = "\(Int(frame.width)) x \(Int(frame.height))"
                    
                    if trimmedLine.contains(resolution) {
                        return currentDisplayName
                    }
                }
            }
            
            // If we found a display name but couldn't match by resolution, return it
            return currentDisplayName
        } catch {
            print("Error getting system display info: \(error)")
            return nil
        }
    }
    
    func refreshDisplays() {
        let maxDisplays: UInt32 = 16
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        
        let result = CGGetActiveDisplayList(maxDisplays, &displayIDs, &displayCount)
        
        guard result == .success else {
            print("Failed to get display list: \(result)")
            return
        }
        
        var newDisplays: [DisplayInfo] = []
        
        for i in 0..<displayCount {
            let displayID = displayIDs[Int(i)]
            let frame = CGDisplayBounds(displayID)
            
            // Skip displays with zero size or sidecar displays
            if frame.width == 0 || frame.height == 0 {
                continue
            }
            
            // Skip sidecar displays by checking if they're virtual/AirPlay
            if let displayName = getSystemDisplayName(for: displayID) {
                if displayName.lowercased().contains("sidecar") {
                    continue
                }
            }
            
            let name = getDisplayName(for: displayID)
            let isPrimary = displayID == CGMainDisplayID()
            
            newDisplays.append(DisplayInfo(
                id: displayID,
                frame: frame,
                name: name,
                isPrimary: isPrimary
            ))
        }
        
        // Sort displays: primary first, then by position
        newDisplays.sort { display1, display2 in
            if display1.isPrimary { return true }
            if display2.isPrimary { return false }
            return display1.frame.minX < display2.frame.minX
        }
        
        DispatchQueue.main.async {
            self.availableDisplays = newDisplays
            
            // Update current anchor display
            self.updateCurrentAnchorDisplay()
        }
    }
    
    private func updateCurrentAnchorDisplay() {
        // Get the current dock position and determine which display it's on
        let dockPosition = getCurrentDockPosition()
        let currentDisplayID = getDisplayForDockPosition(dockPosition)
        
        // Find the display name for the current anchor
        if let display = availableDisplays.first(where: { $0.id == currentDisplayID }) {
            DispatchQueue.main.async {
                self.anchoredDisplay = display.name
            }
        }
    }
    
    private func getCurrentDockPosition() -> DockPosition {
        // Get the current dock position from system preferences
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", "com.apple.dock", "orientation"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let orientation = output.trimmingCharacters(in: .whitespacesAndNewlines)
            
            switch orientation {
            case "left":
                return .left
            case "right":
                return .right
            default:
                return .bottom
            }
        } catch {
            return .bottom
        }
    }
    
    private func getDisplayForDockPosition(_ position: DockPosition) -> CGDirectDisplayID {
        // For bottom dock, find which display the dock is currently on
        if position == .bottom {
            // Get the current mouse position to determine which display the dock is on
            let mouseLocation = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { screen in
                let frame = screen.frame
                return mouseLocation.x >= frame.minX && mouseLocation.x <= frame.maxX &&
                       mouseLocation.y >= frame.minY && mouseLocation.y <= frame.maxY
            }
            
            if let screen = screen {
                return CGDirectDisplayID(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0)
            }
        }
        
        // Fallback to main display
        return CGMainDisplayID()
    }
    
    deinit {
        // Ensure we're on the main thread for cleanup
        if Thread.isMainThread {
            stopMonitoring()
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.stopMonitoring()
            }
        }
        
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)
    }
} 