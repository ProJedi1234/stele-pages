import Foundation
import PostgresNIO
import ServiceLifecycle
import Testing

@testable import SteleCore

@Suite(
    "Page change listener against Postgres",
    .enabled(if: PostgresFixture.isConfigured),
    .serialized
)
struct PageChangeListenerTests {
    @Test func databaseNotificationReachesTwoApplicationInstances() async throws {
        try await PostgresFixture.withThrowawaySchema(clients: 3) { database in
            let pageID = UUID()
            let firstEvents = LivePageEvents()
            let secondEvents = LivePageEvents()
            let firstSubscription = try await firstEvents.subscribe(pageID: pageID)
            let secondSubscription = try await secondEvents.subscribe(pageID: pageID)
            let listeners = [
                Task {
                    try await PageChangeListener(
                        client: database.clients[0], events: firstEvents,
                        logger: PostgresFixture.logger
                    ).run()
                },
                Task {
                    try await PageChangeListener(
                        client: database.clients[1], events: secondEvents,
                        logger: PostgresFixture.logger
                    ).run()
                },
            ]
            defer { listeners.forEach { $0.cancel() } }

            // Each listener invalidates once LISTEN is active, which is also the readiness
            // barrier that prevents the insert racing listener setup.
            #expect(await receivesEvent(from: firstSubscription.stream))
            #expect(await receivesEvent(from: secondSubscription.stream))

            try await database.clients[2].query(
                "SELECT pg_notify('stele_page_changes', \(pageID.uuidString))",
                logger: PostgresFixture.logger
            )

            #expect(await receivesEvent(from: firstSubscription.stream))
            #expect(await receivesEvent(from: secondSubscription.stream))
        }
    }

    @Test func reconnectInvalidatesSubscribersAfterTheListenerConnectionIsTerminated() async throws {
        try await PostgresFixture.withThrowawaySchema(clients: 1) { database in
            let events = LivePageEvents()
            let subscription = try await events.subscribe(pageID: UUID())
            let listenerPIDsBefore = try await listenerPIDs(on: database.bootstrap)
            let listener = Task {
                try await PageChangeListener(
                    client: database.client, events: events, logger: PostgresFixture.logger
                ).run()
            }
            defer { listener.cancel() }

            #expect(await receivesEvent(from: subscription.stream))
            let listenerPID = try #require(
                try await listenerPIDs(on: database.bootstrap).subtracting(listenerPIDsBefore).first
            )
            let terminated: Bool? = try await PostgresFixture.scalar(
                "SELECT pg_terminate_backend(\(listenerPID))", as: Bool.self,
                on: database.bootstrap
            )
            #expect(terminated == true)

            // The retry delay is one second. This waits on the stream with a deadline rather
            // than guessing how long establishing the replacement connection will take.
            #expect(await receivesEvent(from: subscription.stream, timeout: .seconds(5)))
        }
    }

    @Test func gracefulShutdownStopsTheListenerAndFinishesStreams() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            let events = LivePageEvents()
            let subscription = try await events.subscribe(pageID: UUID())
            var configuration = ServiceGroupConfiguration(
                services: [
                    .init(service: PageChangeListener(
                        client: database.client, events: events, logger: PostgresFixture.logger
                    ))
                ],
                gracefulShutdownSignals: [],
                cancellationSignals: [],
                logger: PostgresFixture.logger
            )
            configuration.maximumGracefulShutdownDuration = .seconds(2)
            let group = ServiceGroup(configuration: configuration)
            let runner = Task { try await group.run() }
            defer { runner.cancel() }

            #expect(await receivesEvent(from: subscription.stream))
            await group.triggerGracefulShutdown()
            try await runner.value

            #expect(!(await receivesEvent(from: subscription.stream, timeout: .milliseconds(100))))
            #expect(await events.subscriptionCount() == 0)
        }
    }

    private func listenerPIDs(on client: PostgresClient) async throws -> Set<Int32> {
        Set(try await PostgresFixture.column(
            """
            SELECT pid::int4 FROM pg_stat_activity
            WHERE datname = current_database()
              AND query LIKE 'LISTEN%stele_page_changes%'
            """,
            as: Int32.self,
            on: client
        ))
    }

    private func receivesEvent(
        from stream: AsyncStream<Void>, timeout: Duration = .seconds(2)
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) }
                catch { return false }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
