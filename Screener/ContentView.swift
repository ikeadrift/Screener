//
//  ContentView.swift
//  Screener
//
//  Created by Benjamin Zweig on 5/8/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("apiKey") private var apiKey: String = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("Screener App")
                .font(.headline)
                .padding(.top)

            SecureField("Enter OpenAI API Key & Press Return", text: $apiKey)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal)
                .onSubmit {
                    if !apiKey.isEmpty {
                        // Automatically start monitoring if not already, or re-check if key changes
                        if !appState.isMonitoring {
                            appState.startMonitoring()
                        }
                    } else {
                        // If API key is cleared, stop monitoring
                        if appState.isMonitoring {
                            appState.stopMonitoring()
                        }
                    }
                }
            
            if !apiKey.isEmpty {
                HStack {
                    Text("Monitoring:")
                    Text(appState.isMonitoring ? "Active" : "Paused")
                        .foregroundColor(appState.isMonitoring ? .green : .orange)
                }
                .padding(.top, 5) // Add some space above the status
                
                Button(appState.isMonitoring ? "Pause Monitoring" : "Start Monitoring") {
                    if appState.isMonitoring {
                        appState.stopMonitoring()
                    } else {
                        // Ensure API key is still valid before starting
                        if !apiKey.isEmpty {
                            appState.startMonitoring()
                        }
                    }
                }
            } else {
                // No additional text needed here if SecureField has a good prompt
                // Adding a bit of placeholder space if nothing else is shown in this branch
                // to maintain layout consistency, or we can allow the VStack to shrink.
                Spacer()
                    .frame(height: 30) // Approximate height of the status + button
            }

            Divider()
                .padding(.horizontal)

            Button("Quit Screener") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.bottom)
        }
        .frame(width: 320, height: apiKey.isEmpty ? 160 : 220) // Adjusted height slightly
        .onAppear {
            if !apiKey.isEmpty && !appState.isMonitoring {
                appState.startMonitoring()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState()) // Add for preview
}
