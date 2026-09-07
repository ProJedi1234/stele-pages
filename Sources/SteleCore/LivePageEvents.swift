import Foundation
import Logging
import PostgresNIO
import ServiceLifecycle

/// Fans database invalidations out to the browsers currently watching each page.
public actor LivePageEvents {
    public struct Subscription: Sendable {
        public let id: UUID
        public let stream: AsyncStream<Void>
    }

    public enum SubscriptionError: Error, Equatable {
        case capacityReached
    }

    private struct Subscriber {
        let pageID: UUID
        let continuation: AsyncStream<Void>.Continuation
    }

    private let maximumSubscriptions: Int
    private let maximumSubscriptionsPerPage: Int
    private var subscribers: [UUID: Subscriber] = [:]
    private var subscriptionsPerPage: [UUID: Int] = [:]
    private var isShutDown = false

    public init(maximumSubscriptions: Int = 1_024, maximumSubscriptionsPerPage: Int = 64) {
        precondition(maximumSubscriptions > 0)
        precondition(maximumSubscriptionsPerPage > 0)
        self.maximumSubscriptions = maximumSubscriptions
        self.maximumSubscriptionsPerPage = maximumSubscriptionsPerPage
    }

    public func subscribe(pageID: UUID) throws -> Subscription {
        guard !isShutDown,
              subscribers.count < maximumSubscriptions,
              subscriptionsPerPage[pageID, default: 0] < maximumSubscriptionsPerPage
        else {
            throw SubscriptionError.capacityReached
        }

        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id: id) }
        }
        subscribers[id] = Subscriber(pageID: pageID, continuation: continuation)
        subscriptionsPerPage[pageID, default: 0] += 1
        return Subscription(id: id, stream: stream)
    }

    public func unsubscribe(id: UUID) {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        decrementCount(for: subscriber.pageID)
        subscriber.continuation.finish()
    }

    public func invalidate(pageID: UUID) {
        for subscriber in subscribers.values where subscriber.pageID == pageID {
            subscriber.continuation.yield(())
        }
    }

    /// Wakes one stream for its periodic reconciliation without fanning out to sibling tabs.
    func wake(subscriptionID: UUID) {
        subscribers[subscriptionID]?.continuation.yield(())
    }

    /// Wakes every stream after the database listener has lost notifications and reconnected.
    public func invalidateAll() {
        for subscriber in subscribers.values {
            subscriber.continuation.yield(())
        }
    }

    public func shutDown() {
        isShutDown = true
        let activeSubscribers = subscribers.values
        subscribers.removeAll(keepingCapacity: false)
        subscriptionsPerPage.removeAll(keepingCapacity: false)
        for subscriber in activeSubscribers {
            subscriber.continuation.finish()
        }
    }

    func subscriptionCount(pageID: UUID? = nil) -> Int {
        guard let pageID else { return subscribers.count }
        return subscriptionsPerPage[pageID, default: 0]
    }

    private func decrementCount(for pageID: UUID) {
        guard let count = subscriptionsPerPage[pageID] else { return }
        if count == 1 {
            subscriptionsPerPage.removeValue(forKey: pageID)
        } else {
            subscriptionsPerPage[pageID] = count - 1
        }
    }
}

/// Holds a dedicated pooled connection open for PostgreSQL LISTEN/NOTIFY delivery.
public struct PageChangeListener: Service {
    public static let channel = "stele_page_changes"

    private let client: PostgresClient
    private let events: LivePageEvents
    private let logger: Logger

    public init(client: PostgresClient, events: LivePageEvents, logger: Logger) {
        self.client = client
        self.events = events
        self.logger = logger
    }

    public func run() async throws {
        do {
            try await cancelWhenGracefulShutdown {
                try await self.runListener()
            }
        } catch is CancellationError {
            // Task cancellation and graceful shutdown take the same cleanup path.
        }
        await events.shutDown()
    }

    private func runListener() async throws {
        var retryDelay = 1
        do {
            while !Task.isCancelled {
                do {
                    try await client.withConnection { connection in
                        try await connection.listen(on: Self.channel) { notifications in
                            // LISTEN has completed when this closure begins. Reconcile on the
                            // initial connection as well as reconnects so startup has no gap.
                            await events.invalidateAll()
                            retryDelay = 1

                            for try await notification in notifications {
                                guard let pageID = UUID(uuidString: notification.payload) else {
                                    logger.warning(
                                        "ignoring malformed page change notification",
                                        metadata: ["payload": "\(notification.payload)"]
                                    )
                                    continue
                                }
                                await events.invalidate(pageID: pageID)
                            }
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard !Task.isCancelled else { throw CancellationError() }
                    logger.error(
                        "postgres page change listener disconnected",
                        metadata: [
                            "error": "\(error)",
                            "retry_seconds": "\(retryDelay)",
                        ]
                    )
                    try await Task.sleep(for: .seconds(retryDelay))
                    retryDelay = min(retryDelay * 2, 30)
                }
            }
        } catch is CancellationError {
            return
        }
    }
}
