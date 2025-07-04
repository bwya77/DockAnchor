//
//  ContentView.swift
//  DockAnchor
//
//  Created by Bradley Wyatt on 7/2/25.
//

import SwiftUI
import CoreData

private func getAppVersion() -> String {
    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
        return version
    }
    return "1.3"
}

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var dockMonitor: DockMonitor
    @EnvironmentObject var appSettings: AppSettings
    @State private var showingSettings = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "dock.rectangle")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                Text("DockAnchor")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Keep your dock anchored to one display")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top)
            Divider()
            
            // Status Section
            VStack(spacing: 12) {
                HStack {
                    Circle()
                        .fill(dockMonitor.isActive ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    
                    Text(dockMonitor.statusMessage)
                        .font(.headline)
                        .foregroundColor(dockMonitor.isActive ? .green : .primary)
                    
                    Spacer()
                }
                
                if !dockMonitor.isActive {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("Dock movement protection is disabled")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            // Control Buttons
            HStack(spacing: 16) {
                Button(action: {
                    if dockMonitor.isActive {
                        dockMonitor.stopMonitoring()
                    } else {
                        dockMonitor.startMonitoring()
                    }
                }) {
                    HStack {
                        Image(systemName: dockMonitor.isActive ? "stop.circle" : "play.circle")
                        Text(dockMonitor.isActive ? "Stop Protection" : "Start Protection")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Button("Settings") {
                    showingSettings = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            
            Divider()
            
            // Display Information & Selection
            VStack(alignment: .leading, spacing: 12) {
                Text("Display Settings")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Current Anchor:")
                        Spacer()
                        Text(dockMonitor.anchoredDisplay)
                            .fontWeight(.medium)
                            .foregroundColor(.accentColor)
                    }
                    
                    HStack {
                        Text("Dock Position:")
                        Spacer()
                        Text(getCurrentDockPosition())
                            .fontWeight(.medium)
                    }
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Anchor Display:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Picker("Anchor Display", selection: Binding(
                            get: { appSettings.selectedDisplayID },
                            set: { appSettings.selectedDisplayID = $0 }
                        )) {
                            ForEach(dockMonitor.availableDisplays, id: \.id) { display in
                                Text(display.name) // Don't add (Primary) here since it's already in display.name
                                    .tag(display.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Text("Select which display the dock should stay on")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .font(.subheadline)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            Spacer()
        }
        .padding()
        .frame(width: 420, height: 520)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear {
            // Request permissions on startup
            _ = dockMonitor.requestAccessibilityPermissions()
            // Update available displays
            dockMonitor.updateAvailableDisplays()
            // Set the anchor display from settings
            dockMonitor.changeAnchorDisplay(to: appSettings.selectedDisplayID)
        }
        .onChange(of: appSettings.selectedDisplayID) { oldValue, newValue in
            dockMonitor.changeAnchorDisplay(to: newValue)
        }
    }
    
    private func getCurrentDockPosition() -> String {
        let orientation = UserDefaults.standard.string(forKey: "com.apple.dock.orientation") ?? "bottom"
        switch orientation {
        case "left":
            return "Left"
        case "right":
            return "Right"
        default:
            return "Bottom"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var dockMonitor: DockMonitor
    @EnvironmentObject var updateChecker: UpdateChecker
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Content
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Startup & Background")
                            .font(.headline)
                        
                        Toggle("Start at Login", isOn: $appSettings.startAtLogin)
                        Toggle("Run in Background", isOn: $appSettings.runInBackground)
                        
                        Text("When 'Run in Background' is enabled, the app continues protecting even when the window is closed.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Interface")
                            .font(.headline)
                        
                        Toggle("Show Menu Bar Icon", isOn: $appSettings.showStatusIcon)
                        Toggle("Hide from Dock", isOn: $appSettings.hideFromDock)
                        
                        Text("The menu bar icon provides quick access to controls and shows protection status.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("When 'Hide from Dock' is enabled, the app will only appear in the menu bar and won't show in the dock.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Display Info")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Available Displays: \(dockMonitor.availableDisplays.count)")
                            
                            ForEach(dockMonitor.availableDisplays, id: \.id) { display in
                                HStack {
                                    Circle()
                                        .fill(display.id == appSettings.selectedDisplayID ? Color.green : Color.gray)
                                        .frame(width: 8, height: 8)
                                    Text(display.name) // Don't add (Primary) here since it's already in display.name
                                    Spacer()
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.leading, 8)
                    }
                }
                .padding()
                
                Spacer(minLength: 20)
                
                VStack(spacing: 4) {
                    Text("Version \(getAppVersion())")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom)
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .onAppear {
            dockMonitor.updateAvailableDisplays()
        }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environmentObject(AppSettings())
        .environmentObject(DockMonitor())
        .environmentObject(UpdateChecker())
}

