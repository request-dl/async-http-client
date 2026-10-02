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
import NIOEmbedded
import NIOHTTP1
import NIOHTTPCompression
import NIOPosix
import NIOSSL
import XCTest

@testable import AsyncHTTPClient

#if canImport(Network)
import NIOTransportServices
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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

// MARK: - Connection setup: recorder

final class HTTPConnectionSetupRecorderTests: XCTestCase {
    private let start = NIODeadline.uptimeNanoseconds(10_000_000_000)

    func testOnlyTheFirstMarkOfAPhaseIsKept() {
        let recorder = HTTPConnectionSetupRecorder(now: self.start)

        recorder.markConnectStart(at: self.start + .milliseconds(1))
        recorder.markConnectStart(at: self.start + .milliseconds(2))
        recorder.markDomainLookupEnd(at: self.start + .milliseconds(3))
        recorder.markDomainLookupEnd(at: self.start + .milliseconds(4))

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.connectStart, self.start + .milliseconds(3), "pushed back to the end of the lookup")
        XCTAssertEqual(snapshot.domainLookupEnd, self.start + .milliseconds(3))
        XCTAssertEqual(snapshot.start, self.start)
    }

    func testConnectingStartsWhenTheLookupEnds() {
        let recorder = HTTPConnectionSetupRecorder(now: self.start)

        recorder.markConnectStart(at: self.start + .milliseconds(1))
        recorder.markDomainLookupStart(at: self.start + .milliseconds(1))
        recorder.markDomainLookupEnd(at: self.start + .milliseconds(20))
        recorder.markConnectEnd(at: self.start + .milliseconds(30))

        XCTAssertEqual(recorder.snapshot().connectStart, self.start + .milliseconds(20))
    }

    func testConnectStartIsLeftAloneWithoutALookup() {
        let recorder = HTTPConnectionSetupRecorder(now: self.start)

        recorder.markConnectStart(at: self.start + .milliseconds(1))

        XCTAssertEqual(recorder.snapshot().connectStart, self.start + .milliseconds(1))
        XCTAssertNil(recorder.snapshot().domainLookupStart)
    }

    func testTunnelReplacesTheEndOfTheConnectPhase() {
        let recorder = HTTPConnectionSetupRecorder(now: self.start)

        recorder.markConnectStart(at: self.start)
        recorder.markConnectEnd(at: self.start + .milliseconds(5))
        recorder.markTunnelEstablished(at: self.start + .milliseconds(12))

        XCTAssertEqual(recorder.snapshot().connectEnd, self.start + .milliseconds(12))
    }

    func testReportWithResolutionAndHandshakeIsLaidOutPhaseByPhase() {
        let recorder = HTTPConnectionSetupRecorder(now: self.start)

        recorder.record(
            resolutionDuration: 0.010,
            handshakeDuration: 0.030,
            totalDuration: 0.100,
            connectStart: self.start,
            now: self.start + .seconds(1)
        )

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.domainLookupStart, self.start)
        XCTAssertEqual(snapshot.domainLookupEnd, self.start + .milliseconds(10))
        XCTAssertEqual(snapshot.connectStart, self.start + .milliseconds(10))
        XCTAssertEqual(snapshot.connectEnd, self.start + .milliseconds(70))
        XCTAssertEqual(snapshot.secureConnectionStart, self.start + .milliseconds(70))
        XCTAssertEqual(snapshot.secureConnectionEnd, self.start + .milliseconds(100))
    }

    func testReportWithoutHandshakeHasNoSecureConnectionPhase() {
        let recorder = HTTPConnectionSetupRecorder(now: self.start)

        recorder.record(
            resolutionDuration: nil,
            handshakeDuration: nil,
            totalDuration: 0.050,
            connectStart: self.start,
            now: self.start + .seconds(1)
        )

        let snapshot = recorder.snapshot()
        XCTAssertNil(snapshot.domainLookupStart)
        XCTAssertNil(snapshot.domainLookupEnd)
        XCTAssertEqual(snapshot.connectStart, self.start)
        XCTAssertEqual(snapshot.connectEnd, self.start + .milliseconds(50))
        XCTAssertNil(snapshot.secureConnectionStart)
        XCTAssertNil(snapshot.secureConnectionEnd)
    }

    func testReportNeverClaimsToHaveEndedAfterNow() {
        let recorder = HTTPConnectionSetupRecorder(now: self.start)

        recorder.record(
            resolutionDuration: 0.010,
            handshakeDuration: 0.040,
            totalDuration: 5,
            connectStart: self.start,
            now: self.start + .milliseconds(80)
        )

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.secureConnectionEnd, self.start + .milliseconds(80))
        XCTAssertLessThanOrEqual(snapshot.secureConnectionStart!, snapshot.secureConnectionEnd!)
        XCTAssertLessThanOrEqual(snapshot.domainLookupEnd!, snapshot.connectEnd!)
    }

    func testHandshakeLongerThanTheConnectionDoesNotStartBeforeTheLookupEnded() {
        let recorder = HTTPConnectionSetupRecorder(now: self.start)

        recorder.record(
            resolutionDuration: 0.020,
            handshakeDuration: 0.500,
            totalDuration: 0.100,
            connectStart: self.start,
            now: self.start + .seconds(1)
        )

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.secureConnectionStart, snapshot.domainLookupEnd)
        XCTAssertEqual(snapshot.secureConnectionEnd, self.start + .milliseconds(100))
    }
}

final class HTTPRequestMetricsSetupMappingTests: XCTestCase {
    private let url = URL(string: "https://example.com")!
    private let start = NIODeadline.uptimeNanoseconds(10_000_000_000)

    private func info(setup: HTTPConnectionSetupRecorder?, isReused: Bool = false) -> HTTPConnectionMetricsInfo {
        HTTPConnectionMetricsInfo(
            id: 1,
            negotiatedProtocol: .http1_1,
            isReused: isReused,
            localAddress: nil,
            remoteAddress: nil,
            setup: setup,
            acquiredAt: self.start + .milliseconds(50)
        )
    }

    func testSetupThatBeganAfterTheRequestStartedIsReported() throws {
        var recorder = HTTPRequestMetricsRecorder(url: self.url, now: self.start, date: Date(timeIntervalSince1970: 0))
        let setup = HTTPConnectionSetupRecorder(now: self.start + .milliseconds(5))
        setup.markDomainLookupStart(at: self.start + .milliseconds(6))
        setup.markDomainLookupEnd(at: self.start + .milliseconds(10))
        setup.markConnectStart(at: self.start + .milliseconds(10))
        setup.markConnectEnd(at: self.start + .milliseconds(30))
        setup.markSecureConnectionStart(at: self.start + .milliseconds(30))
        setup.markSecureConnectionEnd(at: self.start + .milliseconds(45))
        setup.markProxyConnection()
        recorder.connectionAcquired(self.info(setup: setup))

        let connection = try XCTUnwrap(recorder.finish(error: nil)?.connection)

        XCTAssertFalse(connection.isReused)
        XCTAssertTrue(connection.isProxyConnection)
        XCTAssertEqual(try XCTUnwrap(connection.domainLookupStartDate).timeIntervalSince1970, 0.006, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(connection.domainLookupEndDate).timeIntervalSince1970, 0.010, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(connection.connectStartDate).timeIntervalSince1970, 0.010, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(connection.connectEndDate).timeIntervalSince1970, 0.030, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(connection.secureConnectionStartDate).timeIntervalSince1970,
            0.030,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(connection.secureConnectionEndDate).timeIntervalSince1970,
            0.045,
            accuracy: 0.0001
        )
    }

    func testSetupThatIsRecordedAfterTheConnectionWasAcquiredIsStillReported() throws {
        var recorder = HTTPRequestMetricsRecorder(url: self.url, now: self.start, date: Date(timeIntervalSince1970: 0))
        let setup = HTTPConnectionSetupRecorder(now: self.start + .milliseconds(5))
        recorder.connectionAcquired(self.info(setup: setup))

        // for example what the Network framework reports about a connection after it was established
        setup.markConnectStart(at: self.start + .milliseconds(5))
        setup.markConnectEnd(at: self.start + .milliseconds(20))

        let connection = try XCTUnwrap(recorder.finish(error: nil)?.connection)
        XCTAssertEqual(try XCTUnwrap(connection.connectEndDate).timeIntervalSince1970, 0.020, accuracy: 0.0001)
    }

    func testConnectionThatExistedBeforeTheRequestIsReusedAndHasNoSetup() throws {
        var recorder = HTTPRequestMetricsRecorder(url: self.url, now: self.start, date: Date(timeIntervalSince1970: 0))
        let setup = HTTPConnectionSetupRecorder(now: self.start - .seconds(2))
        setup.markConnectStart(at: self.start - .seconds(2))
        setup.markConnectEnd(at: self.start - .seconds(1))
        // the first request on a pre-warmed connection is handed its setup, but it was not made for the request
        recorder.connectionAcquired(self.info(setup: setup, isReused: false))

        let connection = try XCTUnwrap(recorder.finish(error: nil)?.connection)

        XCTAssertTrue(connection.isReused)
        XCTAssertNil(connection.connectStartDate)
        XCTAssertNil(connection.connectEndDate)
        XCTAssertFalse(connection.isProxyConnection)
    }

    func testConnectionWithoutSetupHasNoSetupPhases() throws {
        var recorder = HTTPRequestMetricsRecorder(url: self.url, now: self.start, date: Date(timeIntervalSince1970: 0))
        recorder.connectionAcquired(self.info(setup: nil, isReused: true))

        let connection = try XCTUnwrap(recorder.finish(error: nil)?.connection)

        XCTAssertTrue(connection.isReused)
        XCTAssertNil(connection.domainLookupStartDate)
        XCTAssertNil(connection.secureConnectionEndDate)
    }
}

// MARK: - Connection setup: resolvers

final class DNSResolverMetricsTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
    }

    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    func testSystemResolverResolvesLocalhost() throws {
        let resolver = SystemDNSResolver(loop: self.group.next())

        let v6 = try resolver.initiateAAAAQuery(host: "localhost", port: 8080).wait()
        let v4 = try resolver.initiateAQuery(host: "localhost", port: 8080).wait()

        XCTAssertFalse((v4 + v6).isEmpty)
        XCTAssertTrue(v4.allSatisfy { $0.protocol == .inet && $0.port == 8080 })
        XCTAssertTrue(v6.allSatisfy { $0.protocol == .inet6 && $0.port == 8080 })
    }

    func testSystemResolverFailsLikeSwiftNIOForUnknownHosts() {
        let resolver = SystemDNSResolver(loop: self.group.next())

        let v6 = resolver.initiateAAAAQuery(host: "does-not-exist.invalid", port: 80)
        let v4 = resolver.initiateAQuery(host: "does-not-exist.invalid", port: 80)

        XCTAssertThrowsError(try v6.wait()) { error in
            XCTAssertTrue(error is SocketAddressError.UnknownHost, "unexpected error \(error)")
        }
        XCTAssertThrowsError(try v4.wait()) { error in
            XCTAssertTrue(error is SocketAddressError.UnknownHost, "unexpected error \(error)")
        }
    }

    func testMeasuredResolverRecordsTheLookupAroundTheSystemResolver() throws {
        let setup = HTTPConnectionSetupRecorder()
        let resolver = MeasuredDNSResolver(SystemDNSResolver(loop: self.group.next()), setup: setup)

        XCTAssertNil(setup.snapshot().domainLookupStart)
        _ = try resolver.initiateAAAAQuery(host: "localhost", port: 80).wait()
        _ = try resolver.initiateAQuery(host: "localhost", port: 80).wait()

        let snapshot = setup.snapshot()
        let lookupStart = try XCTUnwrap(snapshot.domainLookupStart)
        let lookupEnd = try XCTUnwrap(snapshot.domainLookupEnd)
        XCTAssertLessThanOrEqual(snapshot.start, lookupStart)
        XCTAssertLessThanOrEqual(lookupStart, lookupEnd)
    }

    func testMeasuredResolverRecordsFailedLookups() throws {
        let setup = HTTPConnectionSetupRecorder()
        let resolver = MeasuredDNSResolver(SystemDNSResolver(loop: self.group.next()), setup: setup)

        XCTAssertThrowsError(try resolver.initiateAAAAQuery(host: "does-not-exist.invalid", port: 80).wait())
        _ = try? resolver.initiateAQuery(host: "does-not-exist.invalid", port: 80).wait()

        XCTAssertNotNil(setup.snapshot().domainLookupStart)
        XCTAssertNotNil(setup.snapshot().domainLookupEnd)
    }
    #endif
}

// MARK: - Connection setup: through the client

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class HTTPClientConnectionSetupMetricsTests: XCTestCase {
    private static func fetch(
        _ client: HTTPClient,
        _ url: String
    ) async throws -> HTTPClientTransactionMetrics {
        let collector = MetricsCollector()
        let response = try await client.execute(
            HTTPClientRequest(url: url),
            timeout: .seconds(10),
            metrics: collector.record
        )
        _ = try await response.body.collect(upTo: 1024 * 1024)
        return try XCTUnwrap(collector.metrics.first)
    }

    private static func makeClient(
        group: EventLoopGroup,
        configure: (inout HTTPClient.Configuration) -> Void = { _ in }
    ) -> HTTPClient {
        var config = HTTPClient.Configuration()
        config.tlsConfiguration = .clientDefault
        config.tlsConfiguration?.certificateVerification = .none
        configure(&config)
        return HTTPClient(eventLoopGroupProvider: .shared(group), configuration: config)
    }

    private static func assertPhasesAreOrdered(
        _ connection: HTTPClientTransactionMetrics.Connection,
        secure: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let connectStart = try XCTUnwrap(connection.connectStartDate, file: file, line: line)
        let connectEnd = try XCTUnwrap(connection.connectEndDate, file: file, line: line)
        XCTAssertLessThanOrEqual(connectStart, connectEnd, file: file, line: line)

        if let lookupStart = connection.domainLookupStartDate, let lookupEnd = connection.domainLookupEndDate {
            XCTAssertLessThanOrEqual(lookupStart, lookupEnd, file: file, line: line)
            XCTAssertLessThanOrEqual(lookupEnd, connectStart, file: file, line: line)
        }

        if secure {
            let secureStart = try XCTUnwrap(connection.secureConnectionStartDate, file: file, line: line)
            let secureEnd = try XCTUnwrap(connection.secureConnectionEndDate, file: file, line: line)
            XCTAssertLessThanOrEqual(connectEnd, secureStart, file: file, line: line)
            XCTAssertLessThanOrEqual(secureStart, secureEnd, file: file, line: line)
        } else {
            XCTAssertNil(connection.secureConnectionStartDate, file: file, line: line)
            XCTAssertNil(connection.secureConnectionEndDate, file: file, line: line)
        }
    }

    func testPlainConnectionReportsConnectAndMeasuredDNSAndReuseHasNoSetup() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group) { $0.collectDNSMetrics = true }
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let url = "http://localhost:\(bin.port)/ok"
            let first = try await Self.fetch(client, url)
            let second = try await Self.fetch(client, url)

            let connection = try XCTUnwrap(first.connection)
            XCTAssertFalse(connection.isReused)
            XCTAssertFalse(connection.isProxyConnection)
            XCTAssertNotNil(connection.domainLookupStartDate)
            XCTAssertNotNil(connection.domainLookupEndDate)
            try Self.assertPhasesAreOrdered(connection, secure: false)

            let reused = try XCTUnwrap(second.connection)
            XCTAssertTrue(reused.isReused)
            XCTAssertEqual(reused.id, connection.id)
            XCTAssertNil(reused.domainLookupStartDate)
            XCTAssertNil(reused.connectStartDate)
            XCTAssertNil(reused.connectEndDate)
            XCTAssertNil(reused.secureConnectionStartDate)
        }
    }

    func testDNSIsNotReportedWhenTheDefaultResolverIsUsed() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let metrics = try await Self.fetch(client, "http://localhost:\(bin.port)/ok")

            let connection = try XCTUnwrap(metrics.connection)
            XCTAssertNil(connection.domainLookupStartDate)
            XCTAssertNil(connection.domainLookupEndDate)
            try Self.assertPhasesAreOrdered(connection, secure: false)
        }
    }

    func testRandomizedResolverIsMeasuredWithoutAskingFor() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group) { $0.dnsResolver = .randomized }
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let metrics = try await Self.fetch(client, "http://localhost:\(bin.port)/ok")

            let connection = try XCTUnwrap(metrics.connection)
            XCTAssertNotNil(connection.domainLookupStartDate)
            XCTAssertNotNil(connection.domainLookupEndDate)
            try Self.assertPhasesAreOrdered(connection, secure: false)
        }
    }

    func testIPAddressHasNothingToResolve() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group) { $0.collectDNSMetrics = true }
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let metrics = try await Self.fetch(client, "http://127.0.0.1:\(bin.port)/ok")

            let connection = try XCTUnwrap(metrics.connection)
            XCTAssertNil(connection.domainLookupStartDate)
            XCTAssertNil(connection.domainLookupEndDate)
            try Self.assertPhasesAreOrdered(connection, secure: false)
        }
    }

    func testTLSConnectionReportsTheSecureConnectionPhase() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group) { $0.collectDNSMetrics = true }
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let metrics = try await Self.fetch(client, "https://localhost:\(bin.port)/get")

            let connection = try XCTUnwrap(metrics.connection)
            XCTAssertEqual(connection.negotiatedProtocol, .http2)
            XCTAssertNotNil(connection.domainLookupStartDate)
            try Self.assertPhasesAreOrdered(connection, secure: true)
        }
    }

    func testConnectionThroughAProxyIsReported() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(ssl: true), proxy: .simulate(authorization: nil))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group) {
                $0.proxy = .server(host: "localhost", port: bin.port)
            }
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let metrics = try await Self.fetch(client, "https://test/ok")

            let connection = try XCTUnwrap(metrics.connection)
            XCTAssertTrue(connection.isProxyConnection)
            // connecting includes the tunnel, the TLS handshake with the target comes after it
            try Self.assertPhasesAreOrdered(connection, secure: true)
        }
    }

    func testTransactionThatFailsAfterConnectingStillReportsTheConnectionSetup() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let collector = MetricsCollector()
            do {
                _ = try await client.execute(
                    HTTPClientRequest(url: "http://localhost:\(bin.port)/close"),
                    timeout: .seconds(10),
                    metrics: collector.record
                )
                XCTFail("Expected the request to fail")
            } catch {
                // the connection was established, only the response never came
                let connection = try XCTUnwrap(collector.metrics.first?.connection)
                try Self.assertPhasesAreOrdered(connection, secure: false)
            }
        }
    }

    #if canImport(Network)
    func testNetworkFrameworkConnectionReportsConnectAndSecureConnection() {
        XCTAsyncTest {
            let group = NIOTSEventLoopGroup(loopCount: 1, defaultQoS: .default)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let plainBin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try plainBin.shutdown()) }
            let tlsBin = HTTPBin(.http1_1(ssl: true))
            defer { XCTAssertNoThrow(try tlsBin.shutdown()) }
            let client = Self.makeClient(group: group)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let plain = try await Self.fetch(client, "http://localhost:\(plainBin.port)/ok")
            let tls = try await Self.fetch(client, "https://localhost:\(tlsBin.port)/ok")

            let plainConnection = try XCTUnwrap(plain.connection)
            try Self.assertPhasesAreOrdered(plainConnection, secure: false)

            let tlsConnection = try XCTUnwrap(tls.connection)
            try Self.assertPhasesAreOrdered(tlsConnection, secure: true)
        }
    }

    func testProxyConnectionOverTheNetworkFrameworkReportsTheTLSOfNIOSSL() {
        XCTAsyncTest {
            let group = NIOTSEventLoopGroup(loopCount: 1, defaultQoS: .default)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(ssl: true), proxy: .simulate(authorization: nil))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group) {
                $0.proxy = .server(host: "localhost", port: bin.port)
            }
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let metrics = try await Self.fetch(client, "https://test/ok")

            // The tunnel is a Network framework connection without TLS, the TLS to the target is done by NIOSSL.
            let connection = try XCTUnwrap(metrics.connection)
            XCTAssertTrue(connection.isProxyConnection)
            XCTAssertNotNil(connection.tlsVersion)
            XCTAssertNil(connection.tlsCipherSuite)
            try Self.assertPhasesAreOrdered(connection, secure: true)
        }
    }

    func testHTTP2ConnectionsOverTheNetworkFrameworkWorkWithTheEstablishmentReport() {
        XCTAsyncTest {
            let group = NIOTSEventLoopGroup(loopCount: 1, defaultQoS: .default)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }

            // Every round has a new client, so every round establishes a connection and asks the Network framework
            // how it did that.
            for _ in 0..<20 {
                let client = Self.makeClient(group: group)
                defer { XCTAssertNoThrow(try client.syncShutdown()) }

                let metrics = try await Self.fetch(client, "https://localhost:\(bin.port)/get")
                XCTAssertEqual(metrics.connection?.negotiatedProtocol, .http2)
                XCTAssertEqual(metrics.connection?.isReused, false)
            }
        }
    }
    #endif
}

// MARK: - Bytes: counters

final class HTTPByteCountersTests: XCTestCase {
    func testRawHandlerCountsWhatIsWrittenAndRead() throws {
        let counters = HTTPByteCounters()
        let channel = EmbeddedChannel(handler: HTTPRawByteCountingHandler(counters: counters))
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }

        try channel.writeInbound(ByteBuffer(string: "12345"))
        try channel.writeInbound(ByteBuffer(string: "678"))
        try channel.writeOutbound(IOData.byteBuffer(ByteBuffer(string: "abcd")))

        XCTAssertEqual(counters.snapshot(), HTTPByteCounters.Snapshot(sent: 4, received: 8, responseBodyReceived: 0))
        // what was counted is passed on untouched
        XCTAssertEqual(try channel.readInbound(as: ByteBuffer.self)?.readableBytes, 5)
        XCTAssertEqual(try channel.readInbound(as: ByteBuffer.self)?.readableBytes, 3)
        XCTAssertEqual(try channel.readOutbound(as: IOData.self)?.readableBytes, 4)
    }

    func testBodyHandlerCountsOnlyBodyParts() throws {
        let counters = HTTPByteCounters()
        let channel = EmbeddedChannel(handler: HTTPResponseBodyCountingHandler(counters: counters))
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }

        try channel.writeInbound(HTTPClientResponsePart.head(.init(version: .http1_1, status: .ok)))
        try channel.writeInbound(HTTPClientResponsePart.body(ByteBuffer(string: "hello")))
        try channel.writeInbound(HTTPClientResponsePart.body(ByteBuffer(string: "world!")))
        try channel.writeInbound(HTTPClientResponsePart.end(nil))

        XCTAssertEqual(counters.snapshot().responseBodyReceived, 11)
        XCTAssertEqual(counters.snapshot().received, 0)
        // and passes all four parts on
        for _ in 0..<4 {
            XCTAssertNotNil(try channel.readInbound(as: HTTPClientResponsePart.self))
        }
        XCTAssertNil(try channel.readInbound(as: HTTPClientResponsePart.self))
    }
}

// MARK: - Bytes and TLS: recorder

final class HTTPRequestMetricsBytesTests: XCTestCase {
    private let url = URL(string: "https://example.com")!
    private let start = NIODeadline.uptimeNanoseconds(10_000_000_000)

    private func info(
        _ negotiatedProtocol: HTTPClientTransactionMetrics.Connection.NegotiatedProtocol,
        counters: HTTPByteCounters?,
        setup: HTTPConnectionSetupRecorder? = nil,
        isReused: Bool = false
    ) -> HTTPConnectionMetricsInfo {
        HTTPConnectionMetricsInfo(
            id: 1,
            negotiatedProtocol: negotiatedProtocol,
            isReused: isReused,
            localAddress: nil,
            remoteAddress: nil,
            setup: setup,
            byteCounters: counters,
            acquiredAt: self.start
        )
    }

    func testHTTP1TransactionIsMeasuredAgainstTheCountersOfTheConnection() throws {
        let counters = HTTPByteCounters()
        // an earlier transaction on the same connection
        counters.addSent(1000)
        counters.addReceived(5000)
        counters.addResponseBodyReceived(4000)

        var recorder = HTTPRequestMetricsRecorder(url: self.url, now: self.start)
        recorder.connectionAcquired(self.info(.http1_1, counters: counters, isReused: true))

        counters.addSent(120)  // the head
        recorder.requestHeadSent()
        counters.addSent(40 + 13)  // a chunked body of 40 bytes and what the encoding adds
        recorder.requestBodyBytesWritten(25)
        recorder.requestBodyBytesWritten(15)
        recorder.requestEnded(at: self.start)

        counters.addReceived(200 + 30 + 77)  // a head, the chunk framing and the body
        counters.addResponseBodyReceived(77)
        recorder.responseBodyBytesDelivered(300)  // it was compressed
        recorder.responseEnded(at: self.start)

        // what comes later is another transaction's
        counters.addSent(999)
        counters.addReceived(999)
        counters.addResponseBodyReceived(999)

        let metrics = try XCTUnwrap(recorder.finish(error: nil))

        XCTAssertEqual(metrics.requestHeaderBytesSent, 120)
        XCTAssertEqual(metrics.requestBodyBytesSent, 53)
        XCTAssertEqual(metrics.requestBodyBytesBeforeEncoding, 40)
        XCTAssertEqual(metrics.responseHeaderBytesReceived, 230)
        XCTAssertEqual(metrics.responseBodyBytesReceived, 77)
        XCTAssertEqual(metrics.responseBodyBytesAfterDecoding, 300)
    }

    func testHTTP2TransactionHasNoHeaderBytesAndTheBodyIsWhatWasWritten() throws {
        let counters = HTTPByteCounters()
        var recorder = HTTPRequestMetricsRecorder(url: self.url, now: self.start)
        recorder.connectionAcquired(self.info(.http2, counters: counters))

        recorder.requestHeadSent()
        recorder.requestBodyBytesWritten(64)
        recorder.requestEnded(at: self.start)
        counters.addResponseBodyReceived(10)
        recorder.responseBodyBytesDelivered(10)
        recorder.responseEnded(at: self.start)

        let metrics = try XCTUnwrap(recorder.finish(error: nil))

        XCTAssertNil(metrics.requestHeaderBytesSent)
        XCTAssertEqual(metrics.requestBodyBytesSent, 64)
        XCTAssertEqual(metrics.requestBodyBytesBeforeEncoding, 64)
        XCTAssertNil(metrics.responseHeaderBytesReceived)
        XCTAssertEqual(metrics.responseBodyBytesReceived, 10)
        XCTAssertEqual(metrics.responseBodyBytesAfterDecoding, 10)
    }

    func testTransactionThatEndedBeforeTheResponseWasCompleteKeepsWhatWasCounted() throws {
        let counters = HTTPByteCounters()
        var recorder = HTTPRequestMetricsRecorder(url: self.url, now: self.start)
        recorder.connectionAcquired(self.info(.http1_1, counters: counters))
        counters.addSent(90)
        recorder.requestHeadSent()
        recorder.requestEnded(at: self.start)
        counters.addReceived(150)
        counters.addResponseBodyReceived(20)
        recorder.responseBodyBytesDelivered(20)

        let metrics = try XCTUnwrap(recorder.finish(error: HTTPClientError.cancelled))

        XCTAssertEqual(metrics.requestHeaderBytesSent, 90)
        XCTAssertEqual(metrics.responseBodyBytesReceived, 20)
        XCTAssertEqual(metrics.responseBodyBytesAfterDecoding, 20)
        XCTAssertNil(metrics.responseHeaderBytesReceived, "the response was not complete, the head size is not known")
    }

    func testTransactionWithoutConnectionHasNoBytes() throws {
        var recorder = HTTPRequestMetricsRecorder(url: self.url, now: self.start)

        let metrics = try XCTUnwrap(recorder.finish(error: HTTPClientError.cancelled))

        XCTAssertNil(metrics.requestHeaderBytesSent)
        XCTAssertNil(metrics.responseHeaderBytesReceived)
        XCTAssertEqual(metrics.requestBodyBytesSent, 0)
        XCTAssertEqual(metrics.responseBodyBytesReceived, 0)
        XCTAssertEqual(metrics.responseBodyBytesAfterDecoding, 0)
    }

    func testTLSAndProxyAreReportedForReusedConnectionsToo() throws {
        let setup = HTTPConnectionSetupRecorder(now: self.start - .seconds(5))
        setup.markConnectStart(at: self.start - .seconds(5))
        setup.markConnectEnd(at: self.start - .seconds(4))
        setup.markProxyConnection()
        setup.setTLSVersion(.tlsv13)
        setup.setTLSCipherSuite(0x1301)
        var recorder = HTTPRequestMetricsRecorder(url: self.url, now: self.start)
        recorder.connectionAcquired(self.info(.http1_1, counters: nil, setup: setup, isReused: true))

        let connection = try XCTUnwrap(recorder.finish(error: nil)?.connection)

        XCTAssertTrue(connection.isReused)
        XCTAssertTrue(connection.isProxyConnection)
        XCTAssertEqual(connection.tlsVersion, .tlsv13)
        XCTAssertEqual(connection.tlsCipherSuite, 0x1301)
        XCTAssertNil(connection.connectStartDate, "how it was established is only reported once")
    }

    func testVersionOrCipherSuiteThatIsKnownLaterIsNotLostToAnUnknownOne() {
        let setup = HTTPConnectionSetupRecorder()

        setup.setTLSVersion(.tlsv12)
        setup.setTLSVersion(nil)
        setup.setTLSCipherSuite(0xC02F)
        setup.setTLSCipherSuite(nil)

        XCTAssertEqual(setup.snapshot().tlsVersion, .tlsv12)
        XCTAssertEqual(setup.snapshot().tlsCipherSuite, 0xC02F)
    }
}

/// A server that answers every request with the same bytes, and that knows how many bytes made up the request head.
private final class RawResponder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let received: NIOLockedValueBox<Int>
    private let response: String
    private var seen = ByteBuffer()

    init(response: String, received: NIOLockedValueBox<Int>) {
        self.response = response
        self.received = received
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        self.seen.writeBuffer(&buffer)
        if self.seen.getString(at: 0, length: self.seen.readableBytes)?.contains("\r\n\r\n") == true {
            let bytes = self.seen.readableBytes
            self.received.withLockedValue { $0 = bytes }
            context.writeAndFlush(self.wrapOutboundOut(ByteBuffer(string: self.response)), promise: nil)
        }
    }
}

// MARK: - Bytes and TLS: through the client

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class HTTPClientByteMetricsTests: XCTestCase {
    private static func fetch(
        _ client: HTTPClient,
        _ request: HTTPClientRequest
    ) async throws -> (HTTPClientTransactionMetrics, ByteBuffer) {
        let collector = MetricsCollector()
        let response = try await client.execute(request, timeout: .seconds(10), metrics: collector.record)
        let body = try await response.body.collect(upTo: 10 * 1024 * 1024)
        return (try XCTUnwrap(collector.metrics.first), body)
    }

    private static func makeClient(
        group: EventLoopGroup,
        configure: (inout HTTPClient.Configuration) -> Void = { _ in }
    ) -> HTTPClient {
        var config = HTTPClient.Configuration()
        config.tlsConfiguration = .clientDefault
        config.tlsConfiguration?.certificateVerification = .none
        configure(&config)
        return HTTPClient(eventLoopGroupProvider: .shared(group), configuration: config)
    }

    func testHTTP1TransactionsAreMeasuredOneByOneOnASharedConnection() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let request = HTTPClientRequest(url: "http://localhost:\(bin.port)/get")
            let (first, firstBody) = try await Self.fetch(client, request)
            let (second, _) = try await Self.fetch(client, request)

            XCTAssertEqual(second.connection?.id, first.connection?.id)
            XCTAssertTrue(try XCTUnwrap(first.requestHeaderBytesSent) > 0)
            XCTAssertTrue(try XCTUnwrap(first.responseHeaderBytesReceived) > 0)
            XCTAssertEqual(first.requestBodyBytesSent, 0)
            XCTAssertEqual(first.requestBodyBytesBeforeEncoding, 0)
            XCTAssertEqual(first.responseBodyBytesReceived, firstBody.readableBytes)
            XCTAssertEqual(first.responseBodyBytesAfterDecoding, firstBody.readableBytes)
            // The same request over the same connection costs the same, and does not add up what came before.
            XCTAssertEqual(second.requestHeaderBytesSent, first.requestHeaderBytesSent)
            XCTAssertEqual(second.responseHeaderBytesReceived, first.responseHeaderBytesReceived)
        }
    }

    func testHeaderBytesMatchWhatTheServerSawAndWhatItSent() {
        XCTAsyncTest {
            let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try serverGroup.syncShutdownGracefully()) }
            let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try clientGroup.syncShutdownGracefully()) }

            let head = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Padding: 0123456789\r\n\r\n"
            let received = NIOLockedValueBox(0)
            let response = head + "hello"
            let server = try await ServerBootstrap(group: serverGroup)
                .childChannelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(
                            RawResponder(response: response, received: received)
                        )
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .bind(host: "127.0.0.1", port: 0).get()
            defer { XCTAssertNoThrow(try server.close().wait()) }

            let client = Self.makeClient(group: clientGroup)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let port = try XCTUnwrap(server.localAddress?.port)
            let (metrics, body) = try await Self.fetch(
                client,
                HTTPClientRequest(url: "http://127.0.0.1:\(port)/some/path")
            )

            XCTAssertEqual(body, ByteBuffer(string: "hello"))
            XCTAssertEqual(metrics.requestHeaderBytesSent, received.withLockedValue { $0 })
            XCTAssertEqual(metrics.responseHeaderBytesReceived, head.utf8.count)
            XCTAssertEqual(metrics.responseBodyBytesReceived, 5)
            XCTAssertEqual(metrics.responseBodyBytesAfterDecoding, 5)
        }
    }

    func testRequestBodyWithKnownLengthIsSentAsIs() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            var request = HTTPClientRequest(url: "http://localhost:\(bin.port)/post")
            request.method = .POST
            request.body = .bytes(ByteBuffer(repeating: UInt8(ascii: "x"), count: 5000))
            let (metrics, _) = try await Self.fetch(client, request)

            XCTAssertEqual(metrics.requestBodyBytesBeforeEncoding, 5000)
            XCTAssertEqual(metrics.requestBodyBytesSent, 5000)
            XCTAssertTrue(try XCTUnwrap(metrics.requestHeaderBytesSent) > 0)
        }
    }

    func testChunkedRequestBodyIsLargerOnTheWireThanTheCallerGaveIt() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let parts = AsyncStream<ByteBuffer> { continuation in
                continuation.yield(ByteBuffer(repeating: UInt8(ascii: "x"), count: 1000))
                continuation.yield(ByteBuffer(repeating: UInt8(ascii: "y"), count: 2000))
                continuation.finish()
            }
            var request = HTTPClientRequest(url: "http://localhost:\(bin.port)/post")
            request.method = .POST
            request.body = .stream(parts, length: .unknown)
            let (metrics, _) = try await Self.fetch(client, request)

            XCTAssertEqual(metrics.requestBodyBytesBeforeEncoding, 3000)
            XCTAssertGreaterThan(metrics.requestBodyBytesSent, 3000, "every chunk comes with its size and delimiters")
        }
    }

    func testCompressedResponseCountsTheBytesBeforeAndAfterDecompression() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(compress: true))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group) { $0.decompression = .enabled(limit: .none) }
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            // the server answers a POST with a description of it that contains the whole body
            var request = HTTPClientRequest(url: "http://localhost:\(bin.port)/post")
            request.method = .POST
            request.headers.add(name: "Accept-Encoding", value: "gzip")
            request.body = .bytes(ByteBuffer(string: String(repeating: "Lorem ipsum dolor sit amet. ", count: 4000)))
            let (metrics, body) = try await Self.fetch(client, request)

            XCTAssertEqual(metrics.responseBodyBytesAfterDecoding, body.readableBytes)
            XCTAssertGreaterThan(metrics.responseBodyBytesReceived, 0)
            XCTAssertLessThan(
                metrics.responseBodyBytesReceived,
                metrics.responseBodyBytesAfterDecoding,
                "the response was compressed on the wire"
            )
        }
    }

    func testHTTP2TransactionCountsBodiesAndNotHeaders() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/post-respond-with-byte-count")
            request.method = .POST
            request.body = .bytes(ByteBuffer(repeating: UInt8(ascii: "x"), count: 3000))
            let (metrics, body) = try await Self.fetch(client, request)

            XCTAssertEqual(metrics.connection?.negotiatedProtocol, .http2)
            XCTAssertNil(metrics.requestHeaderBytesSent)
            XCTAssertNil(metrics.responseHeaderBytesReceived)
            XCTAssertEqual(metrics.requestBodyBytesBeforeEncoding, 3000)
            XCTAssertEqual(metrics.requestBodyBytesSent, 3000)
            XCTAssertGreaterThan(body.readableBytes, 0)
            XCTAssertEqual(metrics.responseBodyBytesReceived, body.readableBytes)
            XCTAssertEqual(metrics.responseBodyBytesAfterDecoding, body.readableBytes)
        }
    }

    func testTLSVersionIsReportedForEveryTransactionAndTheCipherSuiteOnlyWhereKnown() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(ssl: true))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")
            let (first, _) = try await Self.fetch(client, request)
            let (second, _) = try await Self.fetch(client, request)

            let firstConnection = try XCTUnwrap(first.connection)
            XCTAssertFalse(firstConnection.isReused)
            XCTAssertNotNil(firstConnection.tlsVersion)
            XCTAssertNotNil(firstConnection.secureConnectionStartDate)
            XCTAssertNil(firstConnection.tlsCipherSuite, "NIOSSL does not tell")

            let secondConnection = try XCTUnwrap(second.connection)
            XCTAssertTrue(secondConnection.isReused)
            XCTAssertEqual(secondConnection.tlsVersion, firstConnection.tlsVersion)
            XCTAssertNil(secondConnection.secureConnectionStartDate)
        }
    }

    func testPlainConnectionHasNoTLSInformation() {
        XCTAsyncTest {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let (metrics, _) = try await Self.fetch(client, HTTPClientRequest(url: "http://localhost:\(bin.port)/get"))

            XCTAssertNil(metrics.connection?.tlsVersion)
            XCTAssertNil(metrics.connection?.tlsCipherSuite)
        }
    }

    #if canImport(Network)
    func testNetworkFrameworkReportsTheTLSVersionAndTheCipherSuite() {
        XCTAsyncTest {
            let group = NIOTSEventLoopGroup(loopCount: 1, defaultQoS: .default)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
            let bin = HTTPBin(.http1_1(ssl: true))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = Self.makeClient(group: group)
            defer { XCTAssertNoThrow(try client.syncShutdown()) }

            let request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")
            let (first, _) = try await Self.fetch(client, request)
            let (second, _) = try await Self.fetch(client, request)

            for metrics in [first, second] {
                let connection = try XCTUnwrap(metrics.connection)
                XCTAssertNotNil(connection.tlsVersion)
                XCTAssertNotNil(connection.tlsCipherSuite)
            }
            // Over the Network framework the bytes are counted above TLS as well.
            XCTAssertTrue(try XCTUnwrap(first.requestHeaderBytesSent) > 0)
            XCTAssertTrue(try XCTUnwrap(first.responseHeaderBytesReceived) > 0)
        }
    }
    #endif
}
