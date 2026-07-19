import AppKit
import Combine
import Foundation

@MainActor
final class UsageMonitor: ObservableObject {
    static let safetyBufferKey = "safetyBuffer"

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var forecast: Forecast?
    @Published private(set) var samples: [UsageSample] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private static let stateKey = "usageState"
    private var previousStatus: PaceStatus?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.stateKey),
           let state = try? JSONDecoder().decode(StoredState.self, from: data) {
            snapshot = state.snapshot
            samples = state.samples
            previousStatus = state.previousStatus
            recalculate()
        }

        Task { [weak self] in
            await self?.start()
        }
    }

    var menuBarText: String {
        guard let remaining = snapshot?.mainLimit.window.remainingPercent else { return "—" }
        return "\(Int(remaining.rounded()))%"
    }

    var currentWindowSamples: [UsageSample] {
        guard let reset = snapshot?.mainLimit.window.resetsAt else { return [] }
        return samples.filter { $0.resetsAt == reset }.sorted { $0.date < $1.date }
    }

    func start() async {
        guard !started else { return }
        started = true

        Timer.publish(every: 600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            .store(in: &cancellables)

        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let newSnapshot = try await CodexClient.fetch()
            record(newSnapshot)
            snapshot = newSnapshot
            errorMessage = nil
            recalculate()
            persist()
        } catch let error as CodexClientError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Couldn’t read Codex usage. Try refreshing again."
        }
    }

    func updateSafetyBuffer(_ value: Double) {
        recalculate(safetyBuffer: value)
        persist()
    }

    private func recalculate(safetyBuffer: Double? = nil) {
        guard let snapshot else { return }
        let storedBuffer = UserDefaults.standard.object(forKey: Self.safetyBufferKey) as? Double
        let buffer = safetyBuffer ?? storedBuffer ?? 3
        let result = ForecastEngine.evaluate(
            window: snapshot.mainLimit.window,
            samples: samples,
            tokenHistory: snapshot.tokenHistory,
            safetyBuffer: buffer,
            now: snapshot.fetchedAt,
            previousStatus: previousStatus
        )
        forecast = result
        previousStatus = result.status
    }

    private func record(_ snapshot: UsageSnapshot) {
        let window = snapshot.mainLimit.window
        let sample = UsageSample(
            date: snapshot.fetchedAt,
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt
        )
        samples.removeAll { $0.date < snapshot.fetchedAt.addingTimeInterval(-90 * 86_400) }

        if let last = samples.last,
           last.resetsAt == sample.resetsAt,
           last.remainingPercent == sample.remainingPercent {
            if samples.count > 1,
               samples[samples.count - 2].resetsAt == sample.resetsAt,
               samples[samples.count - 2].remainingPercent == sample.remainingPercent {
                samples[samples.count - 1] = sample
            } else {
                samples.append(sample)
            }
        } else {
            samples.append(sample)
        }
    }

    private func persist() {
        let state = StoredState(
            snapshot: snapshot,
            samples: samples,
            previousStatus: previousStatus
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }
}

private struct StoredState: Codable {
    let snapshot: UsageSnapshot?
    let samples: [UsageSample]
    let previousStatus: PaceStatus?
}
