import SwiftUI

struct LogView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            Text(appState.logs.joined(separator: "\n"))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .task {
            appState.bootstrap()
        }
    }
}
