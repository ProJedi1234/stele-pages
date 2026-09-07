import Foundation
import Testing

@testable import SteleCore

@Suite("Live page events")
struct LivePageEventsTests {
    @Test func invalidationReachesEverySubscriberForThePage() async throws {
        let events = LivePageEvents()
        let pageID = UUID()
        let first = try await events.subscribe(pageID: pageID)
        let second = try await events.subscribe(pageID: pageID)
        var firstIterator = first.stream.makeAsyncIterator()
        var secondIterator = second.stream.makeAsyncIterator()

        await events.invalidate(pageID: pageID)

        #expect(await firstIterator.next() != nil)
        #expect(await secondIterator.next() != nil)
    }

    @Test func invalidationsAreCoalescedForSlowConsumers() async throws {
        let events = LivePageEvents()
        let pageID = UUID()
        let subscription = try await events.subscribe(pageID: pageID)
        var iterator = subscription.stream.makeAsyncIterator()

        for _ in 0..<100 {
            await events.invalidate(pageID: pageID)
        }
        #expect(await iterator.next() != nil)

        await events.shutDown()
        #expect(await iterator.next() == nil)
    }

    @Test func invalidateAllWakesSubscriptionsForDifferentPages() async throws {
        let events = LivePageEvents()
        let first = try await events.subscribe(pageID: UUID())
        let second = try await events.subscribe(pageID: UUID())
        var firstIterator = first.stream.makeAsyncIterator()
        var secondIterator = second.stream.makeAsyncIterator()

        await events.invalidateAll()

        #expect(await firstIterator.next() != nil)
        #expect(await secondIterator.next() != nil)
    }

    @Test func targetedWakeDoesNotWakeAnotherSubscriberForThePage() async throws {
        let events = LivePageEvents()
        let pageID = UUID()
        let first = try await events.subscribe(pageID: pageID)
        let second = try await events.subscribe(pageID: pageID)
        var firstIterator = first.stream.makeAsyncIterator()

        await events.wake(subscriptionID: first.id)

        #expect(await firstIterator.next() != nil)
        #expect(await events.subscriptionCount(pageID: pageID) == 2)
        await events.unsubscribe(id: second.id)
    }

    @Test func unsubscribeFinishesTheStreamAndReleasesCapacity() async throws {
        let events = LivePageEvents(maximumSubscriptions: 1, maximumSubscriptionsPerPage: 1)
        let pageID = UUID()
        let first = try await events.subscribe(pageID: pageID)
        var iterator = first.stream.makeAsyncIterator()

        await events.unsubscribe(id: first.id)

        #expect(await iterator.next() == nil)
        #expect(await events.subscriptionCount() == 0)
        _ = try await events.subscribe(pageID: pageID)
    }

    @Test func globalAndPerPageCapacityAreEnforced() async throws {
        let events = LivePageEvents(maximumSubscriptions: 3, maximumSubscriptionsPerPage: 2)
        let pageID = UUID()
        _ = try await events.subscribe(pageID: pageID)
        _ = try await events.subscribe(pageID: pageID)

        await #expect(throws: LivePageEvents.SubscriptionError.capacityReached) {
            _ = try await events.subscribe(pageID: pageID)
        }

        _ = try await events.subscribe(pageID: UUID())
        await #expect(throws: LivePageEvents.SubscriptionError.capacityReached) {
            _ = try await events.subscribe(pageID: UUID())
        }
    }

    @Test func shutdownFinishesStreamsAndRefusesNewSubscriptions() async throws {
        let events = LivePageEvents()
        let subscription = try await events.subscribe(pageID: UUID())
        var iterator = subscription.stream.makeAsyncIterator()

        await events.shutDown()

        #expect(await iterator.next() == nil)
        await #expect(throws: LivePageEvents.SubscriptionError.capacityReached) {
            _ = try await events.subscribe(pageID: UUID())
        }
    }
}
