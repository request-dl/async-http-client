//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2026 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOSSL
import XCTest

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import AsyncHTTPClient

// MARK: - Recorder

final class HTTPRequestMetricsRecorderTests: XCTestCase {
    private let url = URL(string: "https://example.com/path")!

    private func connection(
        at time: NIODeadline,
        id: Int = 7,
        isReused: Bool = false
    ) -> HTTPConnectionMetricsInfo {
        HTTPConnectionMetricsInfo(
            id: id,
            negotiatedProtocol: .http1_1,
            isReused: isReused,
            localAddress: nil,
            remoteAddress: nil,
            acquiredAt: time
        )
    }

    func testDatesAreOffsetFromTheFetchStartAnchor() throws {
        let start = NIODeadline.uptimeNanoseconds(1_000_000_000)
        let anchor = Date(timeIntervalSince1970: 1_000)
        var recorder = HTTPRequestMetricsRecorder(url: self.url, now: start, date: anchor)

        recorder.requestWasQueued(at: start + .milliseconds(10))
        recorder.connectionAcquired(self.connection(at: start + .milliseconds(30)))
        recorder.requestEnded(at: start + .milliseconds(31))
        recorder.responseHeadReceived(at: start + .milliseconds(50))
        recorder.responseEnded(at: start + .milliseconds(70))

        let metrics = try XCTUnwrap(recorder.finish(error: nil))

        XCTAssertEqual(metrics.url, self.url)
        XCTAssertEqual(metrics.fetchStartDate, anchor)
        XCTAssertEqual(try XCTUnwrap(metrics.queuedDate).timeIntervalSince(anchor), 0.010, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metrics.requestStartDate).timeIntervalSince(anchor), 0.030, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metrics.requestEndDate).timeIntervalSince(anchor), 0.031, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metrics.responseStartDate).timeIntervalSince(anchor), 0.050, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metrics.responseEndDate).timeIntervalSince(anchor), 0.070, accuracy: 0.0001)
        XCTAssertEqual(metrics.connection?.id, 7)
        XCTAssertNil(metrics.error)
    }

    func testPhasesThatWereNeverReachedStayNil() throws {
        var recorder = HTTPRequestMetricsRecorder(url: self.url)

        let metrics = try XCTUnwrap(recorder.finish(error: HTTPClientError.cancelled))

        XCTAssertNil(metrics.queuedDate)
        XCTAssertNil(metrics.requestStartDate)
        XCTAssertNil(metrics.requestEndDate)
        XCTAssertNil(metrics.responseStartDate)
        XCTAssertNil(metrics.responseEndDate)
        XCTAssertNil(metrics.connection)
        XCTAssertEqual(metrics.error as? HTTPClientError, .cancelled)
    }

    func testOnlyTheFirstOccurrenceOfAnEventIsKept() throws {
        let start = NIODeadline.uptimeNanoseconds(1_000_000_000)
        var recorder = HTTPRequestMetricsRecorder(url: self.url, now: start, date: Date(timeIntervalSince1970: 0))

        recorder.requestWasQueued(at: start + .milliseconds(1))
        recorder.requestWasQueued(at: start + .milliseconds(2))
        recorder.responseHeadReceived(at: start + .milliseconds(3))
        recorder.responseHeadReceived(at: start + .milliseconds(4))

        let metrics = try XCTUnwrap(recorder.finish(error: nil))

        XCTAssertEqual(try XCTUnwrap(metrics.queuedDate).timeIntervalSince1970, 0.001, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metrics.responseStartDate).timeIntervalSince1970, 0.003, accuracy: 0.0001)
    }

    func testFinishProducesMetricsExactlyOnce() {
        var recorder = HTTPRequestMetricsRecorder(url: self.url)

        XCTAssertNotNil(recorder.finish(error: nil))
        XCTAssertNil(recorder.finish(error: HTTPClientError.cancelled))
    }
}

// MARK: - Redirect hops

final class HTTPHopMetricsHandlerTests: XCTestCase {
    private func metrics(error: (any Error)?) -> HTTPClientTransactionMetrics {
        HTTPClientTransactionMetrics(
            url: URL(string: "https://example.com")!,
            fetchStartDate: Date(timeIntervalSince1970: 0),
            error: error
        )
    }

    func testCancellationOfAHopThatFollowedARedirectIsNotAnError() {
        let received = NIOLockedValueBox<[HTTPClientTransactionMetrics]>([])
        let handler = HTTPHopMetricsHandler { metrics in received.withLockedValue { $0.append(metrics) } }

        handler.redirectWillBeFollowed()
        handler(self.metrics(error: HTTPClientError.cancelled))

        XCTAssertEqual(received.withLockedValue { $0 }.count, 1)
        XCTAssertNil(received.withLockedValue { $0 }.first?.error)
    }

    func testCancellationOfAHopThatDidNotFollowARedirectIsKept() {
        let received = NIOLockedValueBox<[HTTPClientTransactionMetrics]>([])
        let handler = HTTPHopMetricsHandler { metrics in received.withLockedValue { $0.append(metrics) } }

        handler(self.metrics(error: HTTPClientError.cancelled))

        XCTAssertEqual(received.withLockedValue { $0 }.first?.error as? HTTPClientError, .cancelled)
    }

    func testOtherErrorsAreKeptEvenIfARedirectWasFollowed() {
        let received = NIOLockedValueBox<[HTTPClientTransactionMetrics]>([])
        let handler = HTTPHopMetricsHandler { metrics in received.withLockedValue { $0.append(metrics) } }

        handler.redirectWillBeFollowed()
        handler(self.metrics(error: HTTPClientError.remoteConnectionClosed))

        XCTAssertEqual(received.withLockedValue { $0 }.first?.error as? HTTPClientError, .remoteConnectionClosed)
    }
}

// MARK: - Through the client

private final class MetricsCollector: Sendable {
    private let storage = NIOLockedValueBox<[HTTPClientTransactionMetrics]>([])

    var metrics: [HTTPClientTransactionMetrics] {
        self.storage.withLockedValue { $0 }
    }

    @Sendable func record(_ metrics: HTTPClientTransactionMetrics) {
        self.storage.withLockedValue { $0.append(metrics) }
    }
}

private final class MetricsRecordingDelegate: HTTPClientResponseDelegate {
    typealias Response = [HTTPClientTransactionMetrics]

    private let collector = MetricsCollector()

    func didCollectMetrics(task: HTTPClient.Task<Response>, _ metrics: HTTPClientTransactionMetrics) {
        self.collector.record(metrics)
    }

    func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
        self.collector.metrics
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class HTTPClientMetricsTests: XCTestCase {
    private static func makeClient(configure: (inout HTTPClient.Configuration) -> Void = { _ in }) -> HTTPClient {
        var config = HTTPClient.Configuration()
        config.tlsConfiguration = .clientDefault
        config.tlsConfiguration?.certificateVerification = .none
        config.httpVersion = .automatic
        configure(&config)
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)
    }

    private static func assertPhasesAreOrdered(
        _ metrics: HTTPClientTransactionMetrics,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let requestStart = try XCTUnwrap(metrics.requestStartDate, file: file, line: line)
        let requestEnd = try XCTUnwrap(metrics.requestEndDate, file: file, line: line)
        let responseStart = try XCTUnwrap(metrics.responseStartDate, file: file, line: line)
        let responseEnd = try XCTUnwrap(metrics.responseEndDate, file: file, line: line)

        XCTAssertLessThanOrEqual(metrics.fetchStartDate, requestStart, file: file, line: line)
        XCTAssertLessThanOrEqual(requestStart, requestEnd, file: file, line: line)
        XCTAssertLessThanOrEqual(requestStart, responseStart, file: file, line: line)
        XCTAssertLessThanOrEqual(responseStart, responseEnd, file: file, line: line)
    }

    func testHTTP1TransactionIsReportedAndSecondRequestReusesTheConnection() {
        XCTAsyncTest {
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let url = "http://localhost:\(bin.port)/ok"
            let first = MetricsCollector()
            let firstResponse = try await client.execute(
                HTTPClientRequest(url: url),
                timeout: .seconds(10),
                metrics: first.record
            )
            _ = try await firstResponse.body.collect(upTo: 1024)

            let second = MetricsCollector()
            let secondResponse = try await client.execute(
                HTTPClientRequest(url: url),
                timeout: .seconds(10),
                metrics: second.record
            )
            _ = try await secondResponse.body.collect(upTo: 1024)

            let firstMetrics = try XCTUnwrap(first.metrics.first)
            XCTAssertEqual(first.metrics.count, 1)
            XCTAssertEqual(firstMetrics.url.absoluteString, url)
            XCTAssertNil(firstMetrics.error)
            // nothing to reuse yet: the request waited for its connection to be established
            XCTAssertNotNil(firstMetrics.queuedDate)
            try Self.assertPhasesAreOrdered(firstMetrics)

            let firstConnection = try XCTUnwrap(firstMetrics.connection)
            XCTAssertEqual(firstConnection.negotiatedProtocol, .http1_1)
            XCTAssertFalse(firstConnection.isReused)
            XCTAssertEqual(firstConnection.remoteAddress?.port, bin.port)
            XCTAssertNotNil(firstConnection.localAddress)

            let secondMetrics = try XCTUnwrap(second.metrics.first)
            XCTAssertEqual(second.metrics.count, 1)
            let secondConnection = try XCTUnwrap(secondMetrics.connection)
            XCTAssertNil(secondMetrics.queuedDate)
            XCTAssertTrue(secondConnection.isReused)
            XCTAssertEqual(secondConnection.id, firstConnection.id)
            try Self.assertPhasesAreOrdered(secondMetrics)
        }
    }

    func testHTTP2TransactionReportsTheNegotiatedProtocolAndReuse() {
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let url = "https://localhost:\(bin.port)/get"
            var collected: [HTTPClientTransactionMetrics] = []
            for _ in 0..<2 {
                let collector = MetricsCollector()
                let response = try await client.execute(
                    HTTPClientRequest(url: url),
                    timeout: .seconds(10),
                    metrics: collector.record
                )
                _ = try await response.body.collect(upTo: 1024 * 1024)
                collected.append(contentsOf: collector.metrics)
            }

            XCTAssertEqual(collected.count, 2)
            let first = try XCTUnwrap(collected.first)
            let second = try XCTUnwrap(collected.last)
            XCTAssertEqual(first.connection?.negotiatedProtocol, .http2)
            XCTAssertEqual(first.connection?.isReused, false)
            XCTAssertEqual(second.connection?.negotiatedProtocol, .http2)
            XCTAssertEqual(second.connection?.isReused, true)
            XCTAssertEqual(second.connection?.id, first.connection?.id)
            try Self.assertPhasesAreOrdered(first)
            try Self.assertPhasesAreOrdered(second)
        }
    }

    func testEachRedirectHopIsReportedInOrder() {
        XCTAsyncTest {
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            var config = HTTPClient.Configuration()
            config.redirectConfiguration = .follow(max: 5, allowCycles: false)
            let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let collector = MetricsCollector()
            let response = try await client.execute(
                HTTPClientRequest(url: "http://localhost:\(bin.port)/redirect/302"),
                timeout: .seconds(10),
                metrics: collector.record
            )
            _ = try await response.body.collect(upTo: 1024)

            XCTAssertEqual(
                collector.metrics.map(\.url.path),
                ["/redirect/302", "/ok"]
            )
            XCTAssertEqual(collector.metrics.map { $0.error == nil }, [true, true])
        }
    }

    func testTransactionThatFailsAfterGettingAConnectionIsReportedWithTheError() {
        XCTAsyncTest {
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            // the server closes the connection without answering
            let collector = MetricsCollector()
            do {
                _ = try await client.execute(
                    HTTPClientRequest(url: "http://localhost:\(bin.port)/close"),
                    timeout: .seconds(10),
                    metrics: collector.record
                )
                XCTFail("Expected the request to fail")
            } catch {
                XCTAssertEqual(collector.metrics.count, 1)
                let metrics = try XCTUnwrap(collector.metrics.first)
                XCTAssertNotNil(metrics.error)
                XCTAssertNotNil(metrics.connection)
                XCTAssertNotNil(metrics.requestStartDate)
                XCTAssertNil(metrics.responseStartDate)
                XCTAssertNil(metrics.responseEndDate)
            }
        }
    }

    func testRequestThatWaitsForAConnectionReportsWhenItWasQueued() {
        XCTAsyncTest {
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient {
                $0.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = 1
            }
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let url = "http://localhost:\(bin.port)/wait"

            // occupies the only connection, `/wait` never answers
            let blocker = Task {
                try? await client.execute(HTTPClientRequest(url: url), timeout: .seconds(3))
            }
            try await Task.sleep(nanoseconds: 300_000_000)

            let collector = MetricsCollector()
            do {
                _ = try await client.execute(
                    HTTPClientRequest(url: url),
                    timeout: .milliseconds(500),
                    metrics: collector.record
                )
                XCTFail("Expected the request to run into its deadline")
            } catch {
                XCTAssertEqual(error as? HTTPClientError, .deadlineExceeded)
            }
            blocker.cancel()

            XCTAssertEqual(collector.metrics.count, 1)
            let metrics = try XCTUnwrap(collector.metrics.first)
            XCTAssertNotNil(metrics.queuedDate)
            XCTAssertNil(metrics.connection)
            XCTAssertNil(metrics.requestStartDate)
            XCTAssertEqual(metrics.error as? HTTPClientError, .deadlineExceeded)
        }
    }

    func testDelegateReceivesMetricsBeforeTheRequestFinishes() {
        XCTAsyncTest {
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            var config = HTTPClient.Configuration()
            config.redirectConfiguration = .follow(max: 5, allowCycles: false)
            let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let request = try HTTPClient.Request(url: "http://localhost:\(bin.port)/redirect/302")
            let delegate = MetricsRecordingDelegate()
            let collected = try await client.execute(request: request, delegate: delegate).get()

            // `didFinishRequest` ran after the metrics of the last hop were delivered. The redirect hop
            // went to a second task with the same delegate, so both hops were seen.
            XCTAssertEqual(collected.map(\.url.path), ["/redirect/302", "/ok"])
            XCTAssertEqual(collected.map { $0.error == nil }, [true, true])
            for metrics in collected {
                try Self.assertPhasesAreOrdered(metrics)
                XCTAssertEqual(metrics.connection?.negotiatedProtocol, .http1_1)
            }
        }
    }
}
