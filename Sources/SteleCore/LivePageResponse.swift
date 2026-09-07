import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import ServiceLifecycle

enum LivePageResponse {
    static let unavailable = "event: unavailable\ndata: {}\n\n"

    static var headers: HTTPFields {
        [.contentType: "text/event-stream", .cacheControl: "no-store",
         HTTPField.Name("X-Accel-Buffering")!: "no"]
    }

    static func missing() -> Response {
        Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: unavailable)))
    }

    static func response(
        slug: Slug, pageID: UUID, store: some PageStoring, events: LivePageEvents
    ) async throws -> Response {
        let subscription = try await events.subscribe(pageID: pageID)
        let lease = SubscriptionLease(events: events, id: subscription.id)
        return Response(status: .ok, headers: headers, body: .init { writer in
            defer { withExtendedLifetime(lease) {} }
            var timer: Task<Void, Never>?
            do {
                // Subscribe before reading so a commit during the read remains queued.
                await events.wake(subscriptionID: subscription.id)
                var previous: PageLiveState?
                for await _ in subscription.stream.cancelOnGracefulShutdown() {
                    try Task.checkCancellation()
                    timer?.cancel()
                    guard let state = try await store.fetchLiveState(slug: slug), state.id == pageID else {
                        try await writer.write(ByteBuffer(string: unavailable))
                        break
                    }
                    if previous != state {
                        let payload = State(id: state.id.uuidString, revision: String(state.revision))
                        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
                        try await writer.write(ByteBuffer(string: "event: state\ndata: \(json)\n\n"))
                        previous = state
                    } else {
                        try await writer.write(ByteBuffer(string: ": heartbeat\n\n"))
                    }
                    // Also reconciles missed notifications; expiry does not require a write.
                    let delay = min(15, max(0.05, state.expiresAt?.timeIntervalSinceNow ?? 15))
                    timer = Task {
                        do { try await Task.sleep(for: .seconds(delay)) }
                        catch { return }
                        await events.wake(subscriptionID: subscription.id)
                    }
                }
                timer?.cancel()
                await events.unsubscribe(id: subscription.id)
                try await writer.finish(nil)
            } catch {
                timer?.cancel()
                await events.unsubscribe(id: subscription.id)
                throw error
            }
        })
    }

    // A response discarded before its body runs must also return its reserved capacity.
    private final class SubscriptionLease: Sendable {
        let events: LivePageEvents
        let id: UUID
        init(events: LivePageEvents, id: UUID) { self.events = events; self.id = id }
        deinit {
            let events = self.events
            let id = self.id
            Task { await events.unsubscribe(id: id) }
        }
    }

    private struct State: Encodable {
        let id: String
        let revision: String
    }
}
