//
//  AppSettings.swift
//  DockAnchor
//
//  Created by Bradley Wyatt on 7/2/25.
//

import Foundation
import SwiftUI
import ServiceManagement

class AppSettings: ObservableObject {
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
    

    
    @Published var selectedDisplayID: CGDirectDisplayID {
        didSet {
            UserDefaults.standard.set(Int(selectedDisplayID), forKey: "selectedDisplayID")
            NotificationCenter.default.post(name: .anchorDisplayChanged, object: selectedDisplayID)
        }
    }
    
    init() {
        // Check actual login item status from system
        let actualLoginStatus = SMAppService.mainApp.status == .enabled
        self.startAtLogin = actualLoginStatus
        
        self.runInBackground = UserDefaults.standard.object(forKey: "runInBackground") as? Bool ?? true
        self.showStatusIcon = UserDefaults.standard.object(forKey: "showStatusIcon") as? Bool ?? true
        self.hideFromDock = UserDefaults.standard.object(forKey: "hideFromDock") as? Bool ?? false

        
        // Get saved display ID or default to main display
        let savedDisplayID = UserDefaults.standard.object(forKey: "selectedDisplayID") as? Int ?? Int(CGMainDisplayID())
        self.selectedDisplayID = CGDirectDisplayID(savedDisplayID)
        
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
    

    

}

extension Notification.Name {
    static let statusIconVisibilityChanged = Notification.Name("statusIconVisibilityChanged")
    static let anchorDisplayChanged = Notification.Name("anchorDisplayChanged")
    static let dockVisibilityChanged = Notification.Name("dockVisibilityChanged")
} 