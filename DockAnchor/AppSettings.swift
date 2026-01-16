//
//  AppSettings.swift
//  DockAnchor
//
//  Created by Bradley Wyatt on 7/2/25.
//

import Foundation
import SwiftUI
import ServiceManagement

enum AppTheme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum DefaultAnchorDisplay: String, CaseIterable {
    case builtIn = "Built-in Display"
    case main = "Main Display"
}

// MARK: - Profile Model
struct DockProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var anchorDisplayUUID: String
    var createdAt: Date
    var autoActivate: Bool  // Auto-activate when anchor display connects

    init(id: UUID = UUID(), name: String, anchorDisplayUUID: String, createdAt: Date = Date(), autoActivate: Bool = false) {
        self.id = id
        self.name = name
        self.anchorDisplayUUID = anchorDisplayUUID
        self.createdAt = createdAt
        self.autoActivate = autoActivate
    }

    // Custom decoder to handle migration from profiles without autoActivate field
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        anchorDisplayUUID = try container.decode(String.self, forKey: .anchorDisplayUUID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        autoActivate = try container.decodeIfPresent(Bool.self, forKey: .autoActivate) ?? false
    }
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var startAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(startAtLogin, forKey: "startAtLogin")
            updateLoginItem()
        }
    }
    
    @Published var runInBackground: Bool {
        didSet {
            UserDefaults.standard.set(runInBackground, forKey: "runInBackground")
        }
    }
    
    @Published var showStatusIcon: Bool {
        didSet {
            UserDefaults.standard.set(showStatusIcon, forKey: "showStatusIcon")
            NotificationCenter.default.post(name: .statusIconVisibilityChanged, object: showStatusIcon)
        }
    }
    
    @Published var hideFromDock: Bool {
        didSet {
            UserDefaults.standard.set(hideFromDock, forKey: "hideFromDock")
            if oldValue != hideFromDock {
                // Notify the app to update activation policy
                NotificationCenter.default.post(name: .dockVisibilityChanged, object: hideFromDock)
            }
        }
    }

    @Published var autoRelocateDock: Bool {
        didSet {
            UserDefaults.standard.set(autoRelocateDock, forKey: "autoRelocateDock")
        }
    }

    @Published var defaultAnchorDisplay: DefaultAnchorDisplay {
        didSet {
            UserDefaults.standard.set(defaultAnchorDisplay.rawValue, forKey: "defaultAnchorDisplay")
            NotificationCenter.default.post(name: .defaultAnchorDisplayChanged, object: defaultAnchorDisplay)
        }
    }

    @Published var appTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme")
        }
    }

    // MARK: - Profiles
    @Published var profiles: [DockProfile] = [] {
        didSet {
            saveProfiles()
        }
    }

    @Published var activeProfileID: UUID? {
        didSet {
            if let idString = activeProfileID?.uuidString {
                UserDefaults.standard.set(idString, forKey: "activeProfileID")
            } else {
                UserDefaults.standard.removeObject(forKey: "activeProfileID")
            }
        }
    }

    /// The currently active profile (if any)
    var activeProfile: DockProfile? {
        guard let activeID = activeProfileID else { return nil }
        return profiles.first { $0.id == activeID }
    }

    /// Hardware UUID of the selected anchor display (stable across reboots/cable swaps)
    @Published var selectedDisplayUUID: String {
        didSet {
            UserDefaults.standard.set(selectedDisplayUUID, forKey: "selectedDisplayUUID")
            NotificationCenter.default.post(name: .anchorDisplayChanged, object: selectedDisplayUUID)
        }
    }

    /// Display ID for runtime use - computed from UUID via DockMonitor
    var selectedDisplayID: CGDirectDisplayID {
        get {
            return DockMonitor.shared.getDisplayID(forUUID: selectedDisplayUUID) ?? CGMainDisplayID()
        }
        set {
            // When setting by ID, look up the UUID
            if let uuid = DockMonitor.shared.getDisplayUUID(forID: newValue) {
                selectedDisplayUUID = uuid
            }
        }
    }
    
    init() {
        // Check actual login item status from system
        let actualLoginStatus = SMAppService.mainApp.status == .enabled
        self.startAtLogin = actualLoginStatus
        
        self.runInBackground = UserDefaults.standard.object(forKey: "runInBackground") as? Bool ?? true
        self.showStatusIcon = UserDefaults.standard.object(forKey: "showStatusIcon") as? Bool ?? true
        self.hideFromDock = UserDefaults.standard.object(forKey: "hideFromDock") as? Bool ?? false
        self.autoRelocateDock = UserDefaults.standard.object(forKey: "autoRelocateDock") as? Bool ?? true

        // Get saved default anchor display or default to main display
        let savedDefaultAnchor = UserDefaults.standard.string(forKey: "defaultAnchorDisplay") ?? "Main Display"
        self.defaultAnchorDisplay = DefaultAnchorDisplay(rawValue: savedDefaultAnchor) ?? .main

        // Get saved theme or default to system
        let savedTheme = UserDefaults.standard.string(forKey: "appTheme") ?? "System"
        self.appTheme = AppTheme(rawValue: savedTheme) ?? .system

        // Load saved profiles
        self.profiles = Self.loadProfiles()

        // Load active profile ID
        if let activeIDString = UserDefaults.standard.string(forKey: "activeProfileID"),
           let activeID = UUID(uuidString: activeIDString) {
            self.activeProfileID = activeID
        } else {
            self.activeProfileID = nil
        }

        // Get saved display UUID, with migration from old display ID storage
        if let savedUUID = UserDefaults.standard.string(forKey: "selectedDisplayUUID") {
            self.selectedDisplayUUID = savedUUID
        } else if let oldDisplayID = UserDefaults.standard.object(forKey: "selectedDisplayID") as? Int {
            // Migrate from old display ID to UUID
            let displayID = CGDirectDisplayID(oldDisplayID)
            if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) {
                let uuidRef = uuid.takeRetainedValue()
                self.selectedDisplayUUID = CFUUIDCreateString(nil, uuidRef) as String
            } else {
                // Fallback to main display UUID
                self.selectedDisplayUUID = Self.getMainDisplayUUID()
            }
        } else {
            // Default to main display UUID
            self.selectedDisplayUUID = Self.getMainDisplayUUID()
        }
        
        // Sync UserDefaults with actual system state
        UserDefaults.standard.set(actualLoginStatus, forKey: "startAtLogin")
    }
    
    private func updateLoginItem() {
        do {
            if startAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update login item: \(error)")
        }
    }

    /// Gets the hardware UUID for the main display
    private static func getMainDisplayUUID() -> String {
        let mainDisplayID = CGMainDisplayID()
        if let uuid = CGDisplayCreateUUIDFromDisplayID(mainDisplayID) {
            let uuidRef = uuid.takeRetainedValue()
            return CFUUIDCreateString(nil, uuidRef) as String
        }
        return "DisplayID-\(mainDisplayID)"
    }

    // MARK: - Profile Management

    /// Creates a new profile with the current anchor display
    func createProfile(name: String, autoActivate: Bool = false) -> DockProfile {
        let profile = DockProfile(name: name, anchorDisplayUUID: selectedDisplayUUID, autoActivate: autoActivate)
        profiles.append(profile)
        return profile
    }

    /// Updates an existing profile
    func updateProfile(_ profile: DockProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        }
    }

    /// Deletes a profile
    func deleteProfile(_ profile: DockProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = nil
        }
    }

    /// Switches to a profile, updating the anchor display
    func switchToProfile(_ profile: DockProfile) {
        activeProfileID = profile.id
        selectedDisplayUUID = profile.anchorDisplayUUID

        // Trigger dock relocation if enabled
        if autoRelocateDock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                DockMonitor.shared.relocateDockToAnchoredDisplay()
            }
        }
    }

    /// Deactivates the current profile (keeps current display setting)
    func deactivateProfile() {
        activeProfileID = nil
    }

    /// Saves the current display setting to the active profile
    func saveCurrentToActiveProfile() {
        guard let activeID = activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        profiles[index].anchorDisplayUUID = selectedDisplayUUID
    }

    /// Finds a profile that should auto-activate for the given display UUID
    /// Uses flexible matching to handle migration from old UUID-only format to new UUID+Serial format
    func findAutoActivateProfile(forDisplayUUID uuid: String) -> DockProfile? {
        // First try exact match
        if let exactMatch = profiles.first(where: { $0.autoActivate && $0.anchorDisplayUUID == uuid }) {
            return exactMatch
        }

        // Try flexible matching - extract base UUID (before -SN or -V suffix)
        let baseUUID = extractBaseUUID(from: uuid)

        return profiles.first { profile in
            guard profile.autoActivate else { return false }
            let profileBaseUUID = extractBaseUUID(from: profile.anchorDisplayUUID)
            return profileBaseUUID == baseUUID
        }
    }

    /// Extracts the base UUID portion from a fingerprint (removes -SN or -V suffixes)
    private func extractBaseUUID(from fingerprint: String) -> String {
        // Check for -SN suffix (serial number)
        if let snRange = fingerprint.range(of: "-SN") {
            return String(fingerprint[..<snRange.lowerBound])
        }
        // Check for -V suffix (vendor/model)
        if let vRange = fingerprint.range(of: "-V") {
            return String(fingerprint[..<vRange.lowerBound])
        }
        return fingerprint
    }

    // MARK: - Profile Persistence

    private func saveProfiles() {
        do {
            let data = try JSONEncoder().encode(profiles)
            UserDefaults.standard.set(data, forKey: "dockProfiles")
        } catch {
            print("Failed to save profiles: \(error)")
        }
    }

    private static func loadProfiles() -> [DockProfile] {
        guard let data = UserDefaults.standard.data(forKey: "dockProfiles") else {
            return []
        }
        do {
            return try JSONDecoder().decode([DockProfile].self, from: data)
        } catch {
            print("Failed to load profiles: \(error)")
            return []
        }
    }
}

extension Notification.Name {
    static let statusIconVisibilityChanged = Notification.Name("statusIconVisibilityChanged")
    static let anchorDisplayChanged = Notification.Name("anchorDisplayChanged")
    static let dockVisibilityChanged = Notification.Name("dockVisibilityChanged")
    static let showMainWindowRequested = Notification.Name("showMainWindowRequested")
    static let displaysDidChange = Notification.Name("displaysDidChange")
    static let defaultAnchorDisplayChanged = Notification.Name("defaultAnchorDisplayChanged")
} 