import SwiftUI

struct FramePoolLabView: View {
    @ObservedObject var viewModel: FramePoolLabViewModel

    var body: some View {
        VStack(spacing: 16) {
            controlsSection
            HSplitView {
                previewSection
                interpretationSection
            }
        }
        .padding(16)
        .onAppear {
            viewModel.startMonitoring()
        }
        .onDisappear {
            viewModel.stopMonitoring()
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SecureField("OpenRouter API Key", text: $viewModel.apiKey)
                    .textFieldStyle(.roundedBorder)
                TextField("Model ID", text: $viewModel.modelID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                Button(viewModel.isMonitoring ? "Monitoring" : "Start Monitoring") {
                    viewModel.startMonitoring()
                }
                .disabled(viewModel.isMonitoring)
                Button("Interpret Now") {
                    viewModel.interpretNow()
                }
                .disabled(viewModel.isInterpreting)
            }

            HStack(spacing: 16) {
                Toggle("Auto interpret", isOn: $viewModel.autoInterpretationEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Interval: \(viewModel.refreshIntervalSeconds, specifier: "%.1f")s")
                    Slider(value: $viewModel.refreshIntervalSeconds, in: 0.5...6.0, step: 0.5)
                        .frame(width: 180)
                }
                Text("Status: \(viewModel.statusText)")
                    .foregroundStyle(.secondary)
                if let lastErrorText = viewModel.lastErrorText {
                    Text("Error: \(lastErrorText)")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            TextEditor(text: $viewModel.interpretationPrompt)
                .font(.callout)
                .frame(height: 84)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                )
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Latest Frame")
                .font(.headline)
            HStack(spacing: 12) {
                metadataChip(title: "Sequence", value: viewModel.latestFrameSequence.map(String.init) ?? "n/a")
                metadataChip(title: "Captured", value: formattedTimestamp(viewModel.latestFrameCapturedAt))
                metadataChip(title: "Age", value: viewModel.latestFrameAgeText)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.04))
                if let image = viewModel.latestFrameImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text("No frame yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var interpretationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Realtime Interpretations")
                .font(.headline)
            if viewModel.entries.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.04))
                    .overlay(
                        Text("Interpretations will appear here.")
                            .foregroundStyle(.secondary)
                    )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("#\(entry.frameSequence)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(formattedTimestamp(entry.receivedAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(entry.latencyMilliseconds) ms")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.summary)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.black.opacity(0.04))
                            )
                        }
                    }
                }
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func metadataChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.04))
        )
    }

    private func formattedTimestamp(_ date: Date?) -> String {
        guard let date else { return "n/a" }
        return date.formatted(date: .omitted, time: .standard)
    }
}
