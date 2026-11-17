//  RootView.swift
//  MacTwin — 主界面

import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem { Label("库", systemImage: "square.stack.3d.up") }
                .tag(0)

            RunView()
                .tabItem { Label("运行", systemImage: "play.circle") }
                .tag(1)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(2)
        }
        .onChange(of: state.isRunning) { running in
            if running { tab = 1 }
        }
    }
}