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
import IOKit

// MARK: - EDID Serial Number Extraction

/// Extracts the physical serial number from a display's EDID data
/// This provides rock-solid identification even when swapping ports or with identical monitors
private func getDisplaySerialNumber(for displayID: CGDirectDisplayID) -> UInt32? {
    // Get the vendor and product info from IOKit
    var iterator: io_iterator_t = 0
    let matching = IOServiceMatching("IODisplayConnect")

    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        return nil
    }
    defer { IOObjectRelease(iterator) }

    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }

        // Get the display info dictionary
        if let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any] {
            // Check if this is the right display by matching vendor/product
            if let vendorID = info[kDisplayVendorID] as? Int,
               let productID = info[kDisplayProductID] as? Int,
               let serialNumber = info[kDisplaySerialNumber] as? Int {

                // Verify this matches our display
                let displayVendor = CGDisplayVendorNumber(displayID)
                let displayProduct = CGDisplayModelNumber(displayID)
                let displaySerial = CGDisplaySerialNumber(displayID)

                if UInt32(vendorID) == displayVendor && UInt32(productID) == displayProduct {
                    // Return EDID serial if available, otherwise display serial
                    if serialNumber != 0 {
                        return UInt32(serialNumber)
                    } else if displaySerial != 0 {
                        return displaySerial
                    }
                }
            }
        }
    }

    // Fallback: Try CGDisplaySerialNumber directly
    let serial = CGDisplaySerialNumber(displayID)
    return serial != 0 ? serial : nil
}

/// Creates a stable display fingerprint combining UUID and serial number
private func createStableDisplayFingerprint(for displayID: CGDirectDisplayID) -> String {
    // Get UUID
    var uuidString = "DisplayID-\(displayID)"
    if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) {
        let uuidRef = uuid.takeRetainedValue()
        uuidString = CFUUIDCreateString(nil, uuidRef) as String
    }

    // Get serial number for additional stability
    if let serialNumber = getDisplaySerialNumber(for: displayID), serialNumber != 0 {
        return "\(uuidString)-SN\(serialNumber)"
    }

    // Get vendor/model as additional fallback identifiers
    let vendor = CGDisplayVendorNumber(displayID)
    let model = CGDisplayModelNumber(displayID)
    if vendor != 0 || model != 0 {
        return "\(uuidString)-V\(vendor)M\(model)"
    }

    return uuidString
}

class DockMonitor: NSObject, ObservableObject {
    static let shared = DockMonitor()

    @Published var isActive = false
    @Published var anchoredDisplay: String = "Primary"
    @Published var statusMessage = "Dock Anchor Ready"
    @Published var availableDisplays: [DisplayInfo] = []
    @Published var needsPermissionReset = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isMonitoring = false
    private var anchorDisplayUUID: String = ""  // Hardware UUID for stable anchor tracking
    private var dockPosition: DockPosition = .bottom
    private var cancellables = Set<AnyCancellable>()
    private var permissionCheckTimer: Timer?

    /// Gets the current anchor display ID (derived from UUID)
    private var anchorDisplayID: CGDirectDisplayID {
        return availableDisplays.first { $0.uuid == anchorDisplayUUID }?.id ?? CGMainDisplayID()
    }

    /// Flag to suppress user mouse input during dock relocation
    private var isRelocating = false

    /// Magic value to identify our synthetic events (so we don't block our own events)
    private let syntheticEventMarker: Int64 = 0xD0C4A5C4 // "DOCKASCR" in hex-ish
    
    enum DockPosition {
        case bottom, left, right
    }
    
    struct DisplayInfo: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let uuid: String  // Stable fingerprint combining UUID + serial number
        let serialNumber: UInt32?  // Physical serial number from EDID
        let frame: CGRect
        let name: String
        let isPrimary: Bool

        func hash(into hasher: inout Hasher) {
            hasher.combine(uuid)
            hasher.combine(frame.origin.x)
            hasher.combine(frame.origin.y)
            hasher.combine(frame.size.width)
            hasher.combine(frame.size.height)
        }

        static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
            return lhs.uuid == rhs.uuid &&
                   lhs.frame.origin.x == rhs.frame.origin.x &&
                   lhs.frame.origin.y == rhs.frame.origin.y &&
                   lhs.frame.size.width == rhs.frame.size.width &&
                   lhs.frame.size.height == rhs.frame.size.height
        }
    }

    /// Creates a stable display identifier combining UUID and physical serial number
    /// This ensures rock-solid identification even when swapping ports or with identical monitors
    private static func getDisplayUUID(for displayID: CGDirectDisplayID) -> String {
        return createStableDisplayFingerprint(for: displayID)
    }

    /// Gets just the serial number for a display (for display in UI if needed)
    private static func getSerialNumber(for displayID: CGDirectDisplayID) -> UInt32? {
        return getDisplaySerialNumber(for: displayID)
    }

    /// Gets the display ID for a given UUID (public interface for AppSettings)
    /// Uses flexible matching to handle migration from old UUID-only format to new UUID+Serial format
    func getDisplayID(forUUID uuid: String) -> CGDirectDisplayID? {
        // First try exact match
        if let exactMatch = availableDisplays.first(where: { $0.uuid == uuid }) {
            return exactMatch.id
        }
        // Try flexible matching - extract base UUID
        let baseUUID = extractBaseUUID(from: uuid)
        return availableDisplays.first { extractBaseUUID(from: $0.uuid) == baseUUID }?.id
    }

    /// Gets the UUID for a given display ID (public interface for AppSettings)
    func getDisplayUUID(forID displayID: CGDirectDisplayID) -> String? {
        return availableDisplays.first { $0.id == displayID }?.uuid
    }

    /// Checks if a display with the given UUID is available (flexible matching)
    func isDisplayAvailable(uuid: String) -> Bool {
        // First try exact match
        if availableDisplays.contains(where: { $0.uuid == uuid }) {
            return true
        }
        // Try flexible matching
        let baseUUID = extractBaseUUID(from: uuid)
        return availableDisplays.contains { extractBaseUUID(from: $0.uuid) == baseUUID }
    }

    /// Gets the current UUID for a display that matches the given UUID (may have different suffix)
    func getCurrentUUID(matching uuid: String) -> String? {
        // First try exact match
        if let exactMatch = availableDisplays.first(where: { $0.uuid == uuid }) {
            return exactMatch.uuid
        }
        // Try flexible matching
        let baseUUID = extractBaseUUID(from: uuid)
        return availableDisplays.first { extractBaseUUID(from: $0.uuid) == baseUUID }?.uuid
    }

    /// Extracts the base UUID portion from a fingerprint (removes -SN or -V suffixes)
    private func extractBaseUUID(from fingerprint: String) -> String {
        if let snRange = fingerprint.range(of: "-SN") {
            return String(fingerprint[..<snRange.lowerBound])
        }
        if let vRange = fingerprint.range(of: "-V") {
            return String(fingerprint[..<vRange.lowerBound])
        }
        return fingerprint
    }
    
    override init() {
        super.init()
        setupInitialState()
        setupNotificationObservers()
    }
    
    private func setupInitialState() {
        // Initialize with main display UUID
        anchorDisplayUUID = Self.getDisplayUUID(for: CGMainDisplayID())
        updateAvailableDisplays()
        detectCurrentDockPosition()
        setupDisplayConfigurationMonitoring()
        _ = requestAccessibilityPermissions()
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: .anchorDisplayChanged)
            .compactMap { $0.object as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newDisplayUUID in
                self?.changeAnchorDisplay(toUUID: newDisplayUUID)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .defaultAnchorDisplayChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // When default anchor setting changes and no profile is active,
                // update to the new default if the current display is unavailable
                guard let self = self else { return }
                if AppSettings.shared.activeProfileID == nil {
                    self.applyDefaultAnchorIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    /// Gets the UUID of the built-in display (if available)
    func getBuiltInDisplayUUID() -> String? {
        return availableDisplays.first { $0.name.contains("Built-in") }?.uuid
    }

    /// Gets the UUID of the main (primary) display
    func getMainDisplayUUID() -> String {
        return Self.getDisplayUUID(for: CGMainDisplayID())
    }

    /// Gets the appropriate default anchor display UUID based on user settings
    func getDefaultAnchorDisplayUUID() -> String {
        switch AppSettings.shared.defaultAnchorDisplay {
        case .builtIn:
            // Try to use built-in display, fall back to main if not available
            return getBuiltInDisplayUUID() ?? getMainDisplayUUID()
        case .main:
            return getMainDisplayUUID()
        }
    }

    /// Applies the default anchor display setting if no specific display is selected
    private func applyDefaultAnchorIfNeeded() {
        let defaultUUID = getDefaultAnchorDisplayUUID()
        if anchorDisplayUUID != defaultUUID {
            anchorDisplayUUID = defaultUUID
            updateAnchoredDisplayName()
            AppSettings.shared.selectedDisplayUUID = defaultUUID
        }
    }
    
    func updateAvailableDisplays() {
        let newDisplays = getAllDisplays()

        // Update the displays array
        availableDisplays = newDisplays

        // Re-detect dock position in case the user changed dock orientation
        detectCurrentDockPosition()
        validateCurrentAnchorDisplay()
        updateAnchoredDisplayName()

        // Notify on main queue to ensure UI updates
        DispatchQueue.main.async {
            self.objectWillChange.send()
            NotificationCenter.default.post(name: .displaysDidChange, object: nil)
        }
    }
    
    private func validateCurrentAnchorDisplay() {
        // If there's only one display, always select it
        if availableDisplays.count == 1, let onlyDisplay = availableDisplays.first {
            if anchorDisplayUUID != onlyDisplay.uuid {
                anchorDisplayUUID = onlyDisplay.uuid
                AppSettings.shared.selectedDisplayUUID = onlyDisplay.uuid
            }
            return
        }

        // Check if the current anchor display is still available (using flexible matching)
        let isAnchorDisplayAvailable = isDisplayAvailable(uuid: anchorDisplayUUID)

        if !isAnchorDisplayAvailable {
            // Anchor display is no longer available, temporarily switch to default anchor display
            // but DON'T update AppSettings - we preserve user's preference for reconnection
            let defaultUUID = getDefaultAnchorDisplayUUID()
            anchorDisplayUUID = defaultUUID
            let defaultName = AppSettings.shared.defaultAnchorDisplay == .builtIn ? "Built-in" : "Primary"
            statusMessage = "Anchor display unavailable - temporarily using \(defaultName)"

            // Reset status message after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self else { return }
                if self.isActive {
                    self.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
                } else {
                    self.statusMessage = "Dock Anchor Ready"
                }
            }
        } else if let currentUUID = getCurrentUUID(matching: anchorDisplayUUID),
                  currentUUID != anchorDisplayUUID {
            // Display is available but fingerprint may have been updated (e.g., serial number now available)
            anchorDisplayUUID = currentUUID
        }
    }

    private func updateAnchoredDisplayName() {
        if let display = availableDisplays.first(where: { $0.uuid == anchorDisplayUUID }) {
            anchoredDisplay = display.name
        }
    }

    /// Change anchor display by UUID (preferred method for stable identification)
    func changeAnchorDisplay(toUUID uuid: String) {
        // Validate that the requested display is available
        let isDisplayAvailable = availableDisplays.contains { $0.uuid == uuid }

        if isDisplayAvailable {
            anchorDisplayUUID = uuid
            updateAnchoredDisplayName()
            statusMessage = "Anchor changed to \(anchoredDisplay)"
        } else {
            // Requested display is not available, use default anchor display instead
            let defaultUUID = getDefaultAnchorDisplayUUID()
            anchorDisplayUUID = defaultUUID
            updateAnchoredDisplayName()
            let defaultName = AppSettings.shared.defaultAnchorDisplay == .builtIn ? "Built-in" : "Primary"
            statusMessage = "Requested display not available - using \(defaultName)"

            // Update the settings to reflect the actual change
            NotificationCenter.default.post(name: .anchorDisplayChanged, object: defaultUUID)
        }
        
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

    /// Change anchor display by display ID (convenience method - converts to UUID internally)
    func changeAnchorDisplay(to displayID: CGDirectDisplayID) {
        let uuid = Self.getDisplayUUID(for: displayID)
        changeAnchorDisplay(toUUID: uuid)
    }

    private func detectCurrentDockPosition() {
        // Dock position detection - kept for internal logic if needed
        // The app primarily handles bottom dock position as left/right have predictable behavior
        dockPosition = .bottom
    }
    
    func requestAccessibilityPermissions() -> Bool {
        // Check if already trusted (without prompting)
        let trusted = AXIsProcessTrusted()

        if !trusted {
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Accessibility permissions required"
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.needsPermissionReset = false
            }
        }

        return trusted
    }

    /// Prompts for accessibility permissions by opening System Preferences
    /// Note: On modern macOS, the system dialog often just opens System Preferences
    /// without actually adding the app - users must manually add it with the + button
    func promptForAccessibilityPermissions() {
        // Use the string key directly to avoid takeRetainedValue() issues
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Checks accessibility permissions without prompting
    private func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Opens System Preferences to the Accessibility pane
    func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts the timer that periodically checks if permissions are still valid
    private func startPermissionMonitoring() {
        // Check every 2 seconds for permission changes
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.verifyPermissionsAndTapValidity()
        }
    }

    /// Stops the permission monitoring timer
    private func stopPermissionMonitoring() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    /// Verifies that accessibility permissions are still granted and event tap is valid
    private func verifyPermissionsAndTapValidity() {
        guard isMonitoring else { return }

        // Check if accessibility permissions are still granted
        if !checkAccessibilityPermissions() {
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Accessibility permissions revoked - stopping monitoring"
                self?.stopMonitoring()
            }
            return
        }

        // Check if the event tap is still valid
        if let tap = eventTap, !CFMachPortIsValid(tap) {
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Event tap invalidated - stopping monitoring"
                self?.stopMonitoring()
            }
            return
        }
    }

    func startMonitoring() {
        guard requestAccessibilityPermissions() else {
            statusMessage = "Please grant accessibility permissions in System Preferences"
            return
        }
        
        guard !isMonitoring else { return }
        
        updateAvailableDisplays()
        
        // Include mouse moved + tap-disabled notifications so we can recover if the system disables tap
        let mouseMovedMask = 1 << CGEventType.mouseMoved.rawValue
        let disabledByTimeoutMask = 1 << CGEventType.tapDisabledByTimeout.rawValue
        let disabledByUserInputMask = 1 << CGEventType.tapDisabledByUserInput.rawValue
        let eventMask = CGEventMask(mouseMovedMask | disabledByTimeoutMask | disabledByUserInputMask)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let monitor = Unmanaged<DockMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                // Recover if the system disabled tap due to timeout or user input
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                        DispatchQueue.main.async {
                            monitor.statusMessage = "Recovered event tap after system disable"
                        }
                    }
                    // Pass the event through so the system continues to receive it
                    return Unmanaged.passUnretained(event)
                }

                return monitor.handleMouseEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            // Event tap creation failed even though permissions appeared granted.
            // This usually means the permission entry is stale (app was updated).
            // The user needs to remove and re-add the app in Accessibility settings.
            needsPermissionReset = true
            statusMessage = "Permission needs reset - remove and re-add app in Accessibility settings"
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        isMonitoring = true
        startPermissionMonitoring()
        DispatchQueue.main.async { [weak self] in
            self?.isActive = true
            self?.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
        }
    }

    func stopMonitoring() {
        stopPermissionMonitoring()
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

    /// Creates a temporary event tap for dock relocation when monitoring isn't active
    /// Returns true if tap was successfully created
    private func createEventTapForRelocation() -> Bool {
        guard eventTap == nil else { return false }

        let mouseMovedMask = 1 << CGEventType.mouseMoved.rawValue
        let eventMask = CGEventMask(mouseMovedMask)

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
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        return true
    }

    /// Removes the temporary event tap created for relocation
    private func removeTemporaryEventTap() {
        // Only remove if we're not in monitoring mode
        guard !isMonitoring else { return }

        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }

        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }

    /// Moves the dock to the anchored display by simulating mouse movement to the dock trigger zone
    func relocateDockToAnchoredDisplay() {
        guard let anchorDisplay = availableDisplays.first(where: { $0.id == anchorDisplayID }) else {
            statusMessage = "Cannot relocate dock - anchor display not found"
            return
        }

        // Only relocate if we have multiple displays
        guard availableDisplays.count > 1 else {
            return
        }

        // Check if dock is already on the anchored display
        if let currentDockDisplay = getCurrentDockDisplayID(), currentDockDisplay == anchorDisplayID {
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Dock is already on \(anchorDisplay.name)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self else { return }
                    if self.isActive {
                        self.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
                    } else {
                        self.statusMessage = "Dock Anchor Ready"
                    }
                }
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = "Relocating dock to \(anchorDisplay.name)..."
        }

        // Perform relocation on background thread to not block UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Save current mouse position
            let originalPosition = CGEvent(source: nil)?.location ?? .zero

            // Ensure event tap is active so we can intercept user mouse input
            // If monitoring wasn't started, we need to temporarily create the tap
            var temporaryTapCreated = false
            if self.eventTap == nil {
                temporaryTapCreated = self.createEventTapForRelocation()
            }

            // Set relocating flag - this causes the event tap to discard all mouse events
            // This is the key to preventing user mouse movement from interfering
            self.isRelocating = true

            // Hide cursor during the operation for better UX
            DispatchQueue.main.sync {
                NSCursor.hide()
            }

            // Create an event source for our synthetic events
            let eventSource = CGEventSource(stateID: .hidSystemState)

            // Get points for the movement
            let approachPoint = self.getApproachPoint(for: anchorDisplay)
            let edgePoint = self.getDockTriggerPoint(for: anchorDisplay)

            // Warp to approach point first
            CGWarpMouseCursorPosition(approachPoint)
            Thread.sleep(forTimeInterval: 0.03)

            // Generate mouse move events toward the edge (this is what triggers dock movement)
            for i in 0..<8 {
                let progress = CGFloat(i) / 7.0
                let currentX = approachPoint.x + (edgePoint.x - approachPoint.x) * progress
                let currentY = approachPoint.y + (edgePoint.y - approachPoint.y) * progress
                let currentPoint = CGPoint(x: currentX, y: currentY)

                // Force cursor position and post event
                CGWarpMouseCursorPosition(currentPoint)
                if let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: currentPoint, mouseButton: .left) {
                    // Mark as our synthetic event so our tap lets it through
                    moveEvent.setIntegerValueField(.eventSourceUserData, value: self.syntheticEventMarker)
                    moveEvent.post(tap: .cghidEventTap)
                }
                Thread.sleep(forTimeInterval: 0.015)
            }

            // Hold at edge with continued events - this is where stability matters most
            for _ in 0..<8 {
                CGWarpMouseCursorPosition(edgePoint)
                if let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: edgePoint, mouseButton: .left) {
                    // Mark as our synthetic event so our tap lets it through
                    moveEvent.setIntegerValueField(.eventSourceUserData, value: self.syntheticEventMarker)
                    moveEvent.post(tap: .cghidEventTap)
                }
                Thread.sleep(forTimeInterval: 0.025)
            }

            // Move mouse back to original position
            CGWarpMouseCursorPosition(originalPosition)

            // Clear relocating flag - resume normal event handling
            self.isRelocating = false

            // Clean up temporary event tap if we created one
            if temporaryTapCreated {
                self.removeTemporaryEventTap()
            }

            // Show cursor again
            DispatchQueue.main.sync {
                NSCursor.unhide()
            }

            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Dock relocated to \(anchorDisplay.name)"

                // Reset status after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self else { return }
                    if self.isActive {
                        self.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
                    } else {
                        self.statusMessage = "Dock Anchor Ready"
                    }
                }
            }
        }
    }

    /// Gets the display ID where the dock is currently located
    private func getCurrentDockDisplayID() -> CGDirectDisplayID? {
        // Find the Dock application and get its window position
        let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first

        guard dockApp != nil else { return nil }

        // Use accessibility API to find dock window position
        let dockElement = AXUIElementCreateApplication(dockApp!.processIdentifier)

        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(dockElement, kAXWindowsAttribute as CFString, &windowsValue)

        guard result == .success, let windows = windowsValue as? [AXUIElement], !windows.isEmpty else {
            return nil
        }

        // Get the position of the first dock window
        var positionValue: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(windows[0], kAXPositionAttribute as CFString, &positionValue)

        guard posResult == .success else { return nil }

        var position = CGPoint.zero
        if let positionValue = positionValue, AXValueGetValue(positionValue as! AXValue, .cgPoint, &position) {
            // Find which display contains this position
            for display in availableDisplays {
                if display.frame.contains(position) {
                    return display.id
                }
            }
        }

        return nil
    }

    /// Gets the approach point (slightly before the edge) for dock trigger animation
    private func getApproachPoint(for display: DisplayInfo) -> CGPoint {
        let frame = display.frame
        let offset: CGFloat = 50 // Start 50 pixels from the edge

        switch dockPosition {
        case .bottom:
            return CGPoint(x: frame.midX, y: frame.maxY - offset)
        case .left:
            return CGPoint(x: frame.minX + offset, y: frame.midY)
        case .right:
            return CGPoint(x: frame.maxX - offset, y: frame.midY)
        }
    }

    /// Gets a point past the edge to create "pressure" against the screen edge
    private func getPastEdgePoint(for display: DisplayInfo) -> CGPoint {
        let frame = display.frame
        let overshoot: CGFloat = 20 // Try to move 20 pixels past the edge

        switch dockPosition {
        case .bottom:
            return CGPoint(x: frame.midX, y: frame.maxY + overshoot)
        case .left:
            return CGPoint(x: frame.minX - overshoot, y: frame.midY)
        case .right:
            return CGPoint(x: frame.maxX + overshoot, y: frame.midY)
        }
    }

    /// Gets the point in the dock trigger zone for a display
    private func getDockTriggerPoint(for display: DisplayInfo) -> CGPoint {
        let frame = display.frame

        switch dockPosition {
        case .bottom:
            // Bottom center of the display, at the very edge
            return CGPoint(x: frame.midX, y: frame.maxY - 1)
        case .left:
            // Left center of the display, at the very edge
            return CGPoint(x: frame.minX + 1, y: frame.midY)
        case .right:
            // Right center of the display, at the very edge
            return CGPoint(x: frame.maxX - 1, y: frame.midY)
        }
    }
    
    private func handleMouseEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .mouseMoved else {
            return Unmanaged.passUnretained(event)
        }

        // During dock relocation, suppress mouse events from real hardware
        // But allow our own synthetic events to pass through
        if isRelocating {
            // Check if this is one of our synthetic events by looking for our marker
            let userData = event.getIntegerValueField(.eventSourceUserData)
            if userData == syntheticEventMarker {
                // This is our synthetic event - let it through
                return Unmanaged.passUnretained(event)
            }
            // This is a real hardware event - discard it
            return nil
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
        
        // Get system display information once
        let systemDisplays = getSystemDisplaysInfo()
        let mainDisplayID = CGMainDisplayID()
        
        for i in 0..<Int(displayCount) {
            let displayID = displayIDs[i]
            let uuid = Self.getDisplayUUID(for: displayID)
            let serialNumber = Self.getSerialNumber(for: displayID)
            let frame = CGDisplayBounds(displayID)
            let name = getDisplayName(for: displayID, systemDisplays: systemDisplays)
            let isPrimary = displayID == mainDisplayID

            displays.append(DisplayInfo(id: displayID, uuid: uuid, serialNumber: serialNumber, frame: frame, name: name, isPrimary: isPrimary))
        }
        
        // Sort so primary display is first
        displays.sort { display1, display2 in
            if display1.isPrimary && !display2.isPrimary { return true }
            if !display1.isPrimary && display2.isPrimary { return false }
            return display1.frame.minX < display2.frame.minX
        }
        
        return displays
    }
    
    private func getSystemDisplaysInfo() -> [(name: String, info: [String: String])] {
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
            var displays: [(name: String, info: [String: String])] = []
            var currentDisplayName: String?
            var currentDisplayInfo: [String: String] = [:]
            
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                
                // Look for display names (lines ending with ":" that are indented)
                if trimmedLine.hasSuffix(":") && line.hasPrefix("        ") && !line.hasPrefix("          ") {
                    let displayName = String(trimmedLine.dropLast()) // Remove the ":"
                    
                    // Save the previous display if we have one
                    if let prevDisplayName = currentDisplayName {
                        displays.append((name: prevDisplayName, info: currentDisplayInfo))
                    }
                    
                    // Start new display
                    currentDisplayName = displayName
                    currentDisplayInfo = [:]
                }
                
                // Collect display properties
                if line.hasPrefix("          ") && currentDisplayName != nil {
                    let propertyLine = line.trimmingCharacters(in: .whitespaces)
                    if propertyLine.contains(":") {
                        let components = propertyLine.components(separatedBy: ":")
                        if components.count >= 2 {
                            let key = components[0].trimmingCharacters(in: .whitespaces)
                            let value = components[1].trimmingCharacters(in: .whitespaces)
                            currentDisplayInfo[key] = value
                        }
                    }
                }
            }
            
            // Add the last display
            if let lastDisplayName = currentDisplayName {
                displays.append((name: lastDisplayName, info: currentDisplayInfo))
            }

            return displays

        } catch {
            return []
        }
    }
    
    private func getDisplayName(for displayID: CGDirectDisplayID, systemDisplays: [(name: String, info: [String: String])]) -> String {
        let mainDisplayID = CGMainDisplayID()
        
        // Get the actual display name from the system
        if let displayName = findBestDisplayMatch(displayID: displayID, displays: systemDisplays) {
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
    

    
    private func findBestDisplayMatch(displayID: CGDirectDisplayID, displays: [(name: String, info: [String: String])]) -> String? {
        let frame = CGDisplayBounds(displayID)
        let actualResolution = "\(Int(frame.width)) x \(Int(frame.height))"
        let mainDisplayID = CGMainDisplayID()
        let isMainDisplay = displayID == mainDisplayID

        // First priority: Check for Virtual Device/AirPlay for Sidecar displays WITH resolution match
        for display in displays {
            // Check if this is a Sidecar display by name first AND resolution matches
            if display.name.contains("Sidecar") {
                if resolution_matches_exactly(actualResolution, display.info["Resolution"]) ||
                   resolution_matches_approximately(actualResolution, display.info["Resolution"]) {
                    return "Sidecar"
                }
            }

            // Only check for Virtual Device + AirPlay combination for Sidecar WITH resolution match
            if let virtualDevice = display.info["Virtual Device"], virtualDevice.contains("Yes"),
               let connectionType = display.info["Connection Type"], connectionType.contains("AirPlay") {
                if resolution_matches_exactly(actualResolution, display.info["Resolution"]) ||
                   resolution_matches_approximately(actualResolution, display.info["Resolution"]) {
                    return "Sidecar"
                }
            }
        }

        // Second priority: Check for Built-in displays by Display Type or Connection Type
        for display in displays {
            if let displayType = display.info["Display Type"], displayType.contains("Built-in") {
                if resolution_matches_exactly(actualResolution, display.info["Resolution"]) {
                    return display.name.contains("Color LCD") ? "Built-in Display" : display.name
                }
            }
            if let connectionType = display.info["Connection Type"], connectionType.contains("Internal") {
                if resolution_matches_exactly(actualResolution, display.info["Resolution"]) {
                    return display.name.contains("Color LCD") ? "Built-in Display" : display.name
                }
            }
        }

        // Third priority: Check for external displays with exact resolution match
        for display in displays {
            if let resolution = display.info["Resolution"] {
                if resolution_matches_exactly(actualResolution, resolution) {
                    // Skip displays we've already handled
                    if let connectionType = display.info["Connection Type"] {
                        if connectionType.contains("Internal") || connectionType.contains("AirPlay") {
                            continue
                        }
                    }
                    if let virtualDevice = display.info["Virtual Device"], virtualDevice.contains("Yes") {
                        continue
                    }
                    return display.name
                }
            }
        }

        // Fourth priority: Check by Main Display flag with resolution confirmation
        if isMainDisplay {
            for display in displays {
                if let mainDisplayFlag = display.info["Main Display"], mainDisplayFlag.contains("Yes") {
                    if let resolution = display.info["Resolution"], resolution_matches_exactly(actualResolution, resolution) {
                        return display.name.contains("Color LCD") ? "Built-in Display" : display.name
                    }
                }
            }
        }

        // Fifth priority: Approximate resolution matching as fallback
        for display in displays {
            if let resolution = display.info["Resolution"] {
                if resolution_matches_approximately(actualResolution, resolution) {
                    if display.name.contains("Color LCD") || display.name.contains("Built-in") {
                        return "Built-in Display"
                    } else if display.name.contains("Sidecar") {
                        return "Sidecar"
                    } else {
                        return display.name
                    }
                }
            }
        }

        return nil
    }
    
    private func resolution_matches_exactly(_ actual: String, _ reported: String?) -> Bool {
        guard let reported = reported else { return false }
        
        // Extract width and height from actual resolution (e.g., "3840 x 1600")
        let actualComponents = actual.components(separatedBy: " x ")
        guard actualComponents.count == 2,
              let actualWidth = Int(actualComponents[0]),
              let actualHeight = Int(actualComponents[1]) else {
            return false
        }
        
        // Extract width and height from reported resolution (e.g., "3840 x 1600 (Ultra-wide 4K)")
        let reportedNumbers = reported.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        guard reportedNumbers.count >= 2,
              let reportedWidth = Int(reportedNumbers[0]),
              let reportedHeight = Int(reportedNumbers[1]) else {
            return false
        }
        
        // Check exact match
        if actualWidth == reportedWidth && actualHeight == reportedHeight {
            return true
        }

        // Check for common scaling scenarios (e.g., Retina displays)
        // For Retina displays, the actual resolution is often scaled
        if (actualWidth == reportedWidth / 2 && actualHeight == reportedHeight / 2) ||
           (actualWidth * 2 == reportedWidth && actualHeight * 2 == reportedHeight) {
            return true
        }

        // For some Retina displays, the scaling might be different
        // Check if the aspect ratio matches and if one is a reasonable scale of the other
        let actualAspectRatio = Double(actualWidth) / Double(actualHeight)
        let reportedAspectRatio = Double(reportedWidth) / Double(reportedHeight)

        // If aspect ratios are close (within 5% tolerance) and one is a scale of the other
        if abs(actualAspectRatio - reportedAspectRatio) < 0.05 {
            let scaleX = Double(reportedWidth) / Double(actualWidth)
            let scaleY = Double(reportedHeight) / Double(actualHeight)

            // Check if both scales are similar (within 10% tolerance) and reasonable (between 1.2 and 3.0)
            if abs(scaleX - scaleY) < 0.1 && scaleX > 1.2 && scaleX < 3.0 {
                return true
            }
        }
        
        return false
    }
    
    private func resolution_matches_approximately(_ actual: String, _ reported: String?) -> Bool {
        guard let reported = reported else { return false }
        
        // Extract numbers from resolution strings
        let actualComponents = actual.components(separatedBy: " x ")
        let reportedNumbers = reported.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        
        if actualComponents.count == 2 && reportedNumbers.count >= 2 {
            let actualWidth = Int(actualComponents[0]) ?? 0
            let actualHeight = Int(actualComponents[1]) ?? 0
            let reportedWidth = Int(reportedNumbers[0]) ?? 0
            let reportedHeight = Int(reportedNumbers[1]) ?? 0
            
            return actualWidth == reportedWidth && actualHeight == reportedHeight
        }
        
        return false
    }
    
    func refreshDisplays() {
        let maxDisplays: UInt32 = 16
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        
        let result = CGGetActiveDisplayList(maxDisplays, &displayIDs, &displayCount)
        
        guard result == .success else {
            return
        }
        
        // Get system display information once
        let systemDisplays = getSystemDisplaysInfo()
        
        var newDisplays: [DisplayInfo] = []
        
        for i in 0..<displayCount {
            let displayID = displayIDs[Int(i)]
            let frame = CGDisplayBounds(displayID)

            // Skip displays with zero size
            if frame.width == 0 || frame.height == 0 {
                continue
            }

            let uuid = Self.getDisplayUUID(for: displayID)
            let serialNumber = Self.getSerialNumber(for: displayID)
            let name = getDisplayName(for: displayID, systemDisplays: systemDisplays)
            let isPrimary = displayID == CGMainDisplayID()

            newDisplays.append(DisplayInfo(
                id: displayID,
                uuid: uuid,
                serialNumber: serialNumber,
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
            
            // Update current anchor display and validate it's still correct
            self.validateCurrentAnchorDisplay()
            self.updateAnchoredDisplayName()
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
    
    private func setupDisplayConfigurationMonitoring() {
        // Register for display configuration changes
        CGDisplayRegisterReconfigurationCallback({ (displayID, flags, userInfo) in
            guard let userInfo = userInfo else { return }
            let monitor = Unmanaged<DockMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handleDisplayConfigurationChange(displayID: displayID, flags: flags)
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    
    private func handleDisplayConfigurationChange(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        // Handle display configuration changes
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if flags.contains(.addFlag) {
                self.statusMessage = "New display detected - updating available displays"
                self.updateAvailableDisplays()

                // Get the UUID of the specific display that was just connected
                let connectedDisplayUUID = Self.getDisplayUUID(for: displayID)

                // Check for profile auto-activation for the specific newly connected display
                var profileActivated = false
                if let profile = AppSettings.shared.findAutoActivateProfile(forDisplayUUID: connectedDisplayUUID) {
                    // Found a profile that should auto-activate for this specific display
                    // Activate if:
                    // 1. It's not the active profile, OR
                    // 2. The current anchor display doesn't match the profile's anchor
                    //    (user may have manually changed anchor while profile was "active")
                    let currentAnchorMatchesProfile = AppSettings.shared.selectedDisplayUUID == profile.anchorDisplayUUID
                    if AppSettings.shared.activeProfileID != profile.id || !currentAnchorMatchesProfile {
                        AppSettings.shared.switchToProfile(profile)
                        self.statusMessage = "Auto-activated profile: \(profile.name)"
                        profileActivated = true
                    }
                }

                // If no profile was auto-activated, handle default anchor behavior
                if !profileActivated {
                    // Check if default anchor is "Main Display" and no profile is active
                    if AppSettings.shared.activeProfileID == nil &&
                       AppSettings.shared.defaultAnchorDisplay == .main {
                        // Update to follow the current main display
                        let mainDisplayUUID = self.getMainDisplayUUID()
                        if self.anchorDisplayUUID != mainDisplayUUID {
                            self.anchorDisplayUUID = mainDisplayUUID
                            AppSettings.shared.selectedDisplayUUID = mainDisplayUUID
                            self.updateAnchoredDisplayName()
                            self.statusMessage = "Main display changed - anchoring to \(self.anchoredDisplay)"
                        }
                    } else {
                        // Check if the user's saved preference reconnected
                        let userPreferredUUID = AppSettings.shared.selectedDisplayUUID
                        let preferredDisplayNowAvailable = self.isDisplayAvailable(uuid: userPreferredUUID)

                        if preferredDisplayNowAvailable {
                            // Get the current UUID for the reconnected display (may have updated suffix)
                            if let currentUUID = self.getCurrentUUID(matching: userPreferredUUID),
                               self.anchorDisplayUUID != currentUUID {
                                // Restore the user's preferred anchor display
                                self.anchorDisplayUUID = currentUUID
                                self.updateAnchoredDisplayName()
                                self.statusMessage = "Preferred display reconnected - restoring anchor to \(self.anchoredDisplay)"

                                // Update AppSettings with the new fingerprint if it changed
                                if currentUUID != userPreferredUUID {
                                    AppSettings.shared.selectedDisplayUUID = currentUUID
                                }
                            }
                        }
                    }

                    // Auto-relocate dock if enabled (with delay to let display stabilize)
                    if AppSettings.shared.autoRelocateDock {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.relocateDockToAnchoredDisplay()
                        }
                    }
                }

                // Reset status message after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self = self else { return }
                    if self.isActive {
                        self.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
                    } else {
                        self.statusMessage = "Dock Anchor Ready"
                    }
                }
            } else if flags.contains(.removeFlag) {
                self.statusMessage = "Display removed - updating available displays"
                self.updateAvailableDisplays()

                // Check if the anchor display was removed (by checking if UUID is still available)
                let anchorStillAvailable = self.availableDisplays.contains { $0.uuid == self.anchorDisplayUUID }
                if !anchorStillAvailable {
                    // Temporarily switch to the default anchor display for dock blocking purposes
                    // but DON'T update AppSettings - we want to remember user's preference
                    // so we can restore it when the display is reconnected
                    let defaultUUID = self.getDefaultAnchorDisplayUUID()
                    self.anchorDisplayUUID = defaultUUID
                    self.updateAnchoredDisplayName()
                    let defaultName = AppSettings.shared.defaultAnchorDisplay == .builtIn ? "Built-in" : "Primary"
                    self.statusMessage = "Anchor display disconnected - temporarily using \(defaultName)"
                }

                // Reset status message after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self = self else { return }
                    if self.isActive {
                        self.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
                    } else {
                        self.statusMessage = "Dock Anchor Ready"
                    }
                }
            } else if flags.contains(.enabledFlag) || flags.contains(.disabledFlag) {
                self.updateAvailableDisplays()
            } else if flags.contains(.movedFlag) || flags.contains(.desktopShapeChangedFlag) {
                // Display was moved/rearranged or desktop shape changed
                // Use a small delay to ensure we're not updating during a view render cycle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self = self else { return }
                    self.updateAvailableDisplays()
                    self.statusMessage = "Display arrangement updated"

                    // Force UI refresh
                    self.objectWillChange.send()

                    // Reset status message after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self = self else { return }
                        if self.isActive {
                            self.statusMessage = "Dock Anchor Active - Monitoring mouse movement"
                        } else {
                            self.statusMessage = "Dock Anchor Ready"
                        }
                    }
                }
            } else if flags.contains(.setMainFlag) {
                // Primary display changed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self = self else { return }
                    self.updateAvailableDisplays()

                    // If default anchor is "Main Display" and no profile is active, follow the new main
                    if AppSettings.shared.activeProfileID == nil &&
                       AppSettings.shared.defaultAnchorDisplay == .main {
                        let mainDisplayUUID = self.getMainDisplayUUID()
                        if self.anchorDisplayUUID != mainDisplayUUID {
                            self.anchorDisplayUUID = mainDisplayUUID
                            AppSettings.shared.selectedDisplayUUID = mainDisplayUUID
                            self.updateAnchoredDisplayName()
                            self.statusMessage = "Main display changed - anchoring to \(self.anchoredDisplay)"

                            // Auto-relocate dock if enabled
                            if AppSettings.shared.autoRelocateDock {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                                    self?.relocateDockToAnchoredDisplay()
                                }
                            }

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
                    }
                }
            } else if flags.contains(.setModeFlag) {
                // Display mode changed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.updateAvailableDisplays()
                }
            }
        }
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
        
        // Remove display configuration callback
        CGDisplayRemoveReconfigurationCallback({ (displayID, flags, userInfo) in
            guard let userInfo = userInfo else { return }
            let monitor = Unmanaged<DockMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handleDisplayConfigurationChange(displayID: displayID, flags: flags)
        }, Unmanaged.passUnretained(self).toOpaque())
        
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)
    }
} 