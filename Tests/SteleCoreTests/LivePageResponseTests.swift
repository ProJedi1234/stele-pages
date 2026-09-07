import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import ServiceLifecycle
import Testing

@testable import SteleCore

@Suite struct LivePageResponseTests {
    private struct Writer: ResponseBodyWriter {
        let receive: @Sendable (String) async throws -> Void
        mutating func write(_ buffer: ByteBuffer) async throws {
            try await receive(String(buffer: buffer))
        }
        consuming func finish(_ trailingHeaders: HTTPFields?) async throws {}
    }

    private actor Capture {
        var frames: [String] = []
        func append(_ frame: String) { frames.append(frame) }
    }

    @Test func missingAndReusedSlugsTerminateWithoutAuth() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        await store.seed(slug: slug, body: "<p>replacement</p>")
        try await TestFixture.makeApp(store: store).test(.router) { client in
            for path in ["/pages/absent-page/events?id=\(UUID())", "/pages/\(slug.value)/events?id=\(UUID())"] {
                try await client.execute(uri: path, method: .get) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.contentType] == "text/event-stream")
                    #expect(String(buffer: response.body) == LivePageResponse.unavailable)
                }
            }
        }
    }

    @Test func initialStateThenDeletionReleasesSubscription() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        await store.seed(slug: slug, body: "<p>first</p>")
        let state = try #require(await store.fetchLiveState(slug: slug))
        let events = LivePageEvents()
        let capture = Capture()
        let response = try await LivePageResponse.response(slug: slug, pageID: state.id, store: store, events: events)
        try await response.body.write(Writer { frame in
            await capture.append(frame)
            if frame.hasPrefix("event: state") {
                _ = try await store.delete(slug: slug)
                await events.invalidate(pageID: state.id)
            }
        })
        let frames = await capture.frames
        #expect(frames.count == 2)
        #expect(frames.first?.contains("\"revision\":\"1\"") == true)
        #expect(frames.last == LivePageResponse.unavailable)
        #expect(await events.subscriptionCount() == 0)
    }

    @Test func expiryWithoutWriteEndsStream() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        await store.seed(slug: slug, body: "<p>first</p>", expiresAt: Date().addingTimeInterval(0.1))
        let state = try #require(await store.fetchLiveState(slug: slug))
        let events = LivePageEvents()
        let capture = Capture()
        let response = try await LivePageResponse.response(slug: slug, pageID: state.id, store: store, events: events)
        try await response.body.write(Writer { await capture.append($0) })
        #expect(await capture.frames.last == LivePageResponse.unavailable)
        #expect(await events.subscriptionCount() == 0)
    }

    @Test func writeFailureReleasesSubscription() async throws {
        struct Disconnected: Error {}
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        await store.seed(slug: slug, body: "<p>first</p>")
        let state = try #require(await store.fetchLiveState(slug: slug))
        let events = LivePageEvents()
        let response = try await LivePageResponse.response(slug: slug, pageID: state.id, store: store, events: events)
        await #expect(throws: Disconnected.self) {
            try await response.body.write(Writer { _ in throw Disconnected() })
        }
        #expect(await events.subscriptionCount() == 0)
    }

    @Test func readAfterResponseCreationCatchesMissedWrite() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        await store.seed(slug: slug, body: "<p>first</p>")
        let state = try #require(await store.fetchLiveState(slug: slug))
        let events = LivePageEvents()
        let response = try await LivePageResponse.response(slug: slug, pageID: state.id, store: store, events: events)
        _ = try await store.update(slug: slug, body: .text("<p>second</p>"), contentType: PageContentType.default, clientID: nil)
        let current = try #require(await store.fetchLiveState(slug: slug))
        let capture = Capture()
        try await response.body.write(Writer { frame in
            await capture.append(frame)
            await events.shutDown()
        })
        #expect(await capture.frames.first?.contains("\"revision\":\"\(current.revision)\"") == true)
        #expect(current.revision > state.revision)
    }

    @Test func htmlGetsClientButStoredUploadIsUnchanged() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        let html = "<!doctype html><html><body><p>first</p></body></html>"
        await store.seed(slug: slug, body: html)
        let page = try #require(await store.fetch(slug: slug))
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/\(slug.value)", method: .get) { response in
                #expect(String(buffer: response.body) == LivePage.inject(html: html, slug: slug, id: page.id, revision: page.revision))
            }
        }
        #expect(try await store.fetch(slug: slug)?.content == .text(html))
    }

    @Test func automaticReloadCannotNavigateToReusedSlug() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        await store.seed(slug: slug, body: "<p>old</p>")
        let old = try #require(await store.fetchLiveState(slug: slug))
        _ = try await store.delete(slug: slug)
        await store.seed(slug: slug, body: "<p>new</p>")
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/\(slug.value)?__stele_page=\(old.id)", method: .get) { response in
                #expect(response.status == .notFound)
                #expect(String(buffer: response.body) == notFoundPage())
            }
            try await client.execute(uri: "/\(slug.value)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(TestFixture.uploadedBody(response.body) == "<p>new</p>")
            }
        }
    }

    @Test func exhaustedCapacityReturns503BeforeStreaming() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        await store.seed(slug: slug, body: "<p>page</p>")
        let page = try #require(await store.fetchLiveState(slug: slug))
        let events = LivePageEvents(maximumSubscriptions: 1)
        let held = try await events.subscribe(pageID: page.id)
        try await TestFixture.makeApp(store: store, liveEvents: events).test(.router) { client in
            try await client.execute(uri: "/pages/\(slug.value)/events?id=\(page.id)", method: .get) { response in
                #expect(response.status == .serviceUnavailable)
            }
        }
        await events.unsubscribe(id: held.id)
    }

    @Test func httpShutdownEndsAnOpenResponseBeforeListenerShutdown() async throws {
        struct StreamingService: Service {
            let response: Response
            let started: AsyncStream<Void>.Continuation
            func run() async throws {
                try await response.body.write(Writer { _ in started.yield(()) })
            }
        }
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        await store.seed(slug: slug, body: "<p>page</p>")
        let page = try #require(await store.fetchLiveState(slug: slug))
        let events = LivePageEvents()
        let response = try await LivePageResponse.response(slug: slug, pageID: page.id, store: store, events: events)
        let (started, continuation) = AsyncStream<Void>.makeStream()
        var configuration = ServiceGroupConfiguration(
            services: [.init(service: StreamingService(response: response, started: continuation))],
            gracefulShutdownSignals: [], cancellationSignals: [], logger: PostgresFixture.logger
        )
        configuration.maximumGracefulShutdownDuration = .seconds(2)
        let group = ServiceGroup(configuration: configuration)
        let runner = Task { try await group.run() }
        defer { runner.cancel(); continuation.finish() }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let clock = ContinuousClock()
        let start = clock.now
        await group.triggerGracefulShutdown()
        try await runner.value
        #expect(clock.now - start < .seconds(1))
        #expect(await events.subscriptionCount() == 0)
    }
}
