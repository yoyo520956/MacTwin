//  MacTwinApp.swift
//  MacTwin — 应用入口

import SwiftUI

@main
struct MacTwinApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .onAppear { CrashGuard.shared.install() }
                .preferredColorScheme(nil)
        }
    }
}