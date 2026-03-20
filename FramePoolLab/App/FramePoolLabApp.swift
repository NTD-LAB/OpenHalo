import SwiftUI

@main
struct FramePoolLabApp: App {
    @StateObject private var viewModel = FramePoolLabViewModel()

    var body: some Scene {
        WindowGroup("Frame Pool Lab") {
            FramePoolLabView(viewModel: viewModel)
                .frame(minWidth: 1180, minHeight: 760)
        }
    }
}
