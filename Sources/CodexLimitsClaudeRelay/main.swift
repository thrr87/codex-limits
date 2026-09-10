import ClaudeIntegrationCore
import Foundation

let receivedAt = Date()
let arguments = CommandLine.arguments
guard arguments.count == 5,
      arguments[1] == "--cache",
      arguments[3] == "--enabled-marker" else {
    exit(64)
}
let cacheURL = URL(fileURLWithPath: arguments[2])
let markerURL = URL(fileURLWithPath: arguments[4])

do {
    let input = try ClaudeRelay.readBoundedInput(from: .standardInput)
    let snapshot = try ClaudeRelay.decode(input, observedAt: receivedAt)
    let didWrite = try ClaudeRelay.storeIfNewer(
        snapshot,
        at: cacheURL,
        enabledMarkerURL: markerURL
    )
    if didWrite {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(ClaudeRelay.snapshotChangedNotificationName),
            object: nil,
            deliverImmediately: true
        )
    }
    FileHandle.standardOutput.write(
        Data((ClaudeRelay.statusLine(for: snapshot) + "\n").utf8)
    )
} catch ClaudeRelayError.disabled {
    exit(0)
} catch ClaudeRelayError.noAllowance {
    FileHandle.standardOutput.write(
        Data((ClaudeRelay.unavailableStatusLine + "\n").utf8)
    )
} catch {
    exit(65)
}
