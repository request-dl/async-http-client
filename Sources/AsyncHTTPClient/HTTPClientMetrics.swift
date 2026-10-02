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

import NIOConcurrencyHelpers
import NIOCore
import NIOSSL

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Timing and connection information for a single HTTP transaction, i.e. one request/response
/// exchange on the wire.
///
/// A request that follows redirects produces one `HTTPClientTransactionMetrics` value per hop, delivered
/// in order. Every date is `nil` when the corresponding phase was never reached, for example when the
/// request failed while waiting for a connection.
///
/// Dates are derived from a monotonic clock anchored at ``fetchStartDate``, so differences between
/// two dates of the same value are accurate even if the wall clock is adjusted while the request runs.
public struct HTTPClientTransactionMetrics: Sendable {
    /// Describes the connection a transaction ran on.
    public struct Connection: Sendable {
        /// The application protocol that was negotiated for the connection.
        public enum NegotiatedProtocol: Sendable, Hashable {
            case http1_1
            case http2
        }

        /// An identifier that is unique among the connections of one ``HTTPClient``. Two transactions with the same
        /// identifier ran on the same connection.
        public var id: Int

        public var negotiatedProtocol: NegotiatedProtocol

        /// Whether the connection had already carried at least one transaction before this one.
        ///
        /// This is `false` for the transaction that is the first one to run on a freshly established connection.
        public var isReused: Bool

        public var localAddress: SocketAddress?

        public var remoteAddress: SocketAddress?

        /// Whether the connection goes through a proxy.
        public var isProxyConnection: Bool

        /// The TLS version that was negotiated for the connection, or `nil` if it does not use TLS or the version is
        /// not known.
        public var tlsVersion: TLSVersion?

        /// The TLS cipher suite that was negotiated for the connection, as its number in the IANA registry of TLS cipher
        /// suites, for example `0x1301` for `TLS_AES_128_GCM_SHA256`.
        ///
        /// This is only known for connections made with the Network framework. NIOSSL does not tell which cipher suite it
        /// negotiated, so it is `nil` everywhere else.
        public var tlsCipherSuite: UInt16?

        // The phases of establishing the connection. They are `nil` for a reused connection, and for the phases that
        // did not take place, for example the secure connection phase of a connection without TLS.
        //
        // Connections made with the Network framework are resolved, connected and secured by it. It reports how long
        // each phase took, in whole milliseconds, which is turned into dates by laying the phases out one after the
        // other, so those dates are only as exact as the report is.

        /// When resolving the host name started. `nil` if there was nothing to resolve, or if the lookup cannot be
        /// observed, see ``HTTPClient/Configuration/collectDNSMetrics``.
        public var domainLookupStartDate: Date?

        /// When the host name was resolved. This is when the first addresses were available, which is when connecting
        /// can start.
        public var domainLookupEndDate: Date?

        /// When connecting started. With a proxy this includes setting up the tunnel to the target.
        public var connectStartDate: Date?

        public var connectEndDate: Date?

        /// When the TLS handshake started.
        public var secureConnectionStartDate: Date?

        public var secureConnectionEndDate: Date?

        public init(
            id: Int,
            negotiatedProtocol: NegotiatedProtocol,
            isReused: Bool,
            localAddress: SocketAddress? = nil,
            remoteAddress: SocketAddress? = nil,
            isProxyConnection: Bool = false,
            tlsVersion: TLSVersion? = nil,
            tlsCipherSuite: UInt16? = nil,
            domainLookupStartDate: Date? = nil,
            domainLookupEndDate: Date? = nil,
            connectStartDate: Date? = nil,
            connectEndDate: Date? = nil,
            secureConnectionStartDate: Date? = nil,
            secureConnectionEndDate: Date? = nil
        ) {
            self.id = id
            self.negotiatedProtocol = negotiatedProtocol
            self.isReused = isReused
            self.localAddress = localAddress
            self.remoteAddress = remoteAddress
            self.isProxyConnection = isProxyConnection
            self.tlsVersion = tlsVersion
            self.tlsCipherSuite = tlsCipherSuite
            self.domainLookupStartDate = domainLookupStartDate
            self.domainLookupEndDate = domainLookupEndDate
            self.connectStartDate = connectStartDate
            self.connectEndDate = connectEndDate
            self.secureConnectionStartDate = secureConnectionStartDate
            self.secureConnectionEndDate = secureConnectionEndDate
        }
    }

    /// The URL this transaction was sent to.
    public var url: URL

    /// When the client started working on the request.
    public var fetchStartDate: Date

    /// When the request had to wait for a connection to become available. `nil` if a connection was
    /// available immediately.
    ///
    /// The time spent waiting is `requestStartDate - queuedDate`. For the first request on a new connection that is
    /// the time it took to establish the connection, see ``Connection/connectStartDate``.
    public var queuedDate: Date?

    /// When a connection was assigned and the request head started to be written.
    public var requestStartDate: Date?

    /// When the complete request, including its body, was handed to the connection.
    public var requestEndDate: Date?

    /// When the response head was received.
    public var responseStartDate: Date?

    /// When the complete response was received from the connection.
    ///
    /// This is the point at which the last byte arrived, not the point at which the caller consumed it.
    /// It is `nil` if the transaction ended before the response was complete, for example because
    /// a redirect was followed as soon as the response head arrived.
    public var responseEndDate: Date?

    // The bytes the transaction moved. They are counted above TLS, which is what HTTP is made of, and not on the
    // network, which is more than that.

    /// The bytes of the request head that were sent, with the request line and the headers. `nil` if that is not
    /// known, which is the case for HTTP/2: it compresses the headers, and the connection is shared with other requests.
    public var requestHeaderBytesSent: Int?

    /// The bytes of the request body that were sent, with what the transfer encoding adds to them. For HTTP/2 these are
    /// the bytes of the body, because they are all it sends.
    public var requestBodyBytesSent: Int

    /// The bytes of the request body as the caller gave them, before the transfer encoding added to them.
    public var requestBodyBytesBeforeEncoding: Int

    /// The bytes of the response head that were received, with the status line and the headers. For a response with a
    /// chunked body this includes the chunk framing, and the trailers. `nil` if that is not known, which is the case for
    /// HTTP/2, and for a response that was not received completely.
    public var responseHeaderBytesReceived: Int?

    /// The bytes of the response body that were received, which is before they are decompressed.
    public var responseBodyBytesReceived: Int

    /// The bytes of the response body as the caller gets them, after they were decompressed.
    public var responseBodyBytesAfterDecoding: Int

    /// The connection the transaction ran on, or `nil` if it never got one.
    public var connection: Connection?

    /// The error that ended the transaction, or `nil` if it ended without one.
    public var error: (any Error)?

    public init(
        url: URL,
        fetchStartDate: Date,
        queuedDate: Date? = nil,
        requestStartDate: Date? = nil,
        requestEndDate: Date? = nil,
        responseStartDate: Date? = nil,
        responseEndDate: Date? = nil,
        requestHeaderBytesSent: Int? = nil,
        requestBodyBytesSent: Int = 0,
        requestBodyBytesBeforeEncoding: Int = 0,
        responseHeaderBytesReceived: Int? = nil,
        responseBodyBytesReceived: Int = 0,
        responseBodyBytesAfterDecoding: Int = 0,
        connection: Connection? = nil,
        error: (any Error)? = nil
    ) {
        self.url = url
        self.fetchStartDate = fetchStartDate
        self.queuedDate = queuedDate
        self.requestStartDate = requestStartDate
        self.requestEndDate = requestEndDate
        self.responseStartDate = responseStartDate
        self.responseEndDate = responseEndDate
        self.requestHeaderBytesSent = requestHeaderBytesSent
        self.requestBodyBytesSent = requestBodyBytesSent
        self.requestBodyBytesBeforeEncoding = requestBodyBytesBeforeEncoding
        self.responseHeaderBytesReceived = responseHeaderBytesReceived
        self.responseBodyBytesReceived = responseBodyBytesReceived
        self.responseBodyBytesAfterDecoding = responseBodyBytesAfterDecoding
        self.connection = connection
        self.error = error
    }
}

/// What a connection tells a request about itself at the moment it is assigned to it.
struct HTTPConnectionMetricsInfo: Sendable {
    var id: Int
    var negotiatedProtocol: HTTPClientTransactionMetrics.Connection.NegotiatedProtocol
    var isReused: Bool
    var localAddress: SocketAddress?
    var remoteAddress: SocketAddress?
    /// How the connection was established, and what is known about it since.
    ///
    /// This is the recorder and not what it recorded so far, because the connection is handed out before everything
    /// is known about how it was established. It is read when the transaction ends.
    var setup: HTTPConnectionSetupRecorder?
    /// What went through the connection or, for HTTP/2, through the stream the request runs on.
    var byteCounters: HTTPByteCounters?
    var acquiredAt: NIODeadline
}

/// Collects the events of one transaction and turns them into a ``HTTPClientTransactionMetrics``.
///
/// The recorder is a plain value. Whoever owns it is responsible for serialising access, which for
/// `RequestBag` is the task's event loop and for `Transaction` its lock.
struct HTTPRequestMetricsRecorder: Sendable {
    private let url: URL
    private let fetchStart: NIODeadline
    private let fetchStartDate: Date

    private var queuedAt: NIODeadline?
    private var connection: HTTPConnectionMetricsInfo?
    private var requestEndAt: NIODeadline?
    private var responseStartAt: NIODeadline?
    private var responseEndAt: NIODeadline?

    // The byte counters when the connection was acquired, when the request head and the request were sent, and when
    // the response was received.
    private var baseCounters = HTTPByteCounters.Snapshot()
    private var headSentCounters: HTTPByteCounters.Snapshot?
    private var requestEndCounters: HTTPByteCounters.Snapshot?
    private var responseEndCounters: HTTPByteCounters.Snapshot?

    private var requestBodyBytesBeforeEncoding = 0
    private var responseBodyBytesAfterDecoding = 0

    private var isFinished = false

    init(url: URL, now: NIODeadline = .now(), date: Date = Date()) {
        self.url = url
        self.fetchStart = now
        self.fetchStartDate = date
    }

    mutating func requestWasQueued(at time: NIODeadline) {
        self.queuedAt = self.queuedAt ?? time
    }

    mutating func connectionAcquired(_ info: HTTPConnectionMetricsInfo) {
        self.connection = info
        self.baseCounters = info.byteCounters?.snapshot() ?? HTTPByteCounters.Snapshot()
    }

    mutating func requestHeadSent() {
        self.headSentCounters = self.headSentCounters ?? self.connection?.byteCounters?.snapshot()
    }

    mutating func requestBodyBytesWritten(_ bytes: Int) {
        self.requestBodyBytesBeforeEncoding += bytes
    }

    mutating func requestEnded(at time: NIODeadline) {
        self.requestEndAt = self.requestEndAt ?? time
        self.requestEndCounters = self.requestEndCounters ?? self.connection?.byteCounters?.snapshot()
    }

    mutating func responseBodyBytesDelivered(_ bytes: Int) {
        self.responseBodyBytesAfterDecoding += bytes
    }

    mutating func responseHeadReceived(at time: NIODeadline) {
        self.responseStartAt = self.responseStartAt ?? time
    }

    mutating func responseEnded(at time: NIODeadline) {
        self.responseEndAt = self.responseEndAt ?? time
        self.responseEndCounters = self.responseEndCounters ?? self.connection?.byteCounters?.snapshot()
    }

    /// Produces the final metrics, exactly once. Every later call returns `nil`.
    mutating func finish(error: (any Error)?) -> HTTPClientTransactionMetrics? {
        guard !self.isFinished else {
            return nil
        }
        self.isFinished = true

        let isHTTP1 = self.connection?.negotiatedProtocol == .http1_1
        let base = self.baseCounters
        let latest = self.responseEndCounters ?? self.connection?.byteCounters?.snapshot() ?? base

        var requestHeaderBytesSent: Int?
        var requestBodyBytesSent = self.requestBodyBytesBeforeEncoding
        if isHTTP1, let headSent = self.headSentCounters {
            requestHeaderBytesSent = headSent.sent - base.sent
            if let requestEnd = self.requestEndCounters {
                requestBodyBytesSent = requestEnd.sent - headSent.sent
            }
        }

        var responseHeaderBytesReceived: Int?
        if isHTTP1, let responseEnd = self.responseEndCounters {
            let received = responseEnd.received - base.received
            let body = responseEnd.responseBodyReceived - base.responseBodyReceived
            responseHeaderBytesReceived = received - body
        }

        return HTTPClientTransactionMetrics(
            url: self.url,
            fetchStartDate: self.fetchStartDate,
            queuedDate: self.queuedAt.map(self.date),
            requestStartDate: self.connection.map { self.date($0.acquiredAt) },
            requestEndDate: self.requestEndAt.map(self.date),
            responseStartDate: self.responseStartAt.map(self.date),
            responseEndDate: self.responseEndAt.map(self.date),
            requestHeaderBytesSent: requestHeaderBytesSent,
            requestBodyBytesSent: requestBodyBytesSent,
            requestBodyBytesBeforeEncoding: self.requestBodyBytesBeforeEncoding,
            responseHeaderBytesReceived: responseHeaderBytesReceived,
            responseBodyBytesReceived: latest.responseBodyReceived - base.responseBodyReceived,
            responseBodyBytesAfterDecoding: self.responseBodyBytesAfterDecoding,
            connection: self.connection.map(self.makeConnection),
            error: error
        )
    }

    private func makeConnection(_ info: HTTPConnectionMetricsInfo) -> HTTPClientTransactionMetrics.Connection {
        // Only the first transaction on a connection reports how it was established. A connection that was established
        // before the request started, for example a pre-warmed one, was not established for this request, which makes it
        // a reused connection and the setup none of its business.
        let recorded = info.setup?.snapshot()
        let setup = recorded.flatMap { !info.isReused && $0.start >= self.fetchStart ? $0 : nil }

        return .init(
            id: info.id,
            negotiatedProtocol: info.negotiatedProtocol,
            isReused: info.isReused || (recorded != nil && setup == nil),
            localAddress: info.localAddress,
            remoteAddress: info.remoteAddress,
            isProxyConnection: recorded?.isProxyConnection ?? false,
            tlsVersion: recorded?.tlsVersion,
            tlsCipherSuite: recorded?.tlsCipherSuite,
            domainLookupStartDate: setup?.domainLookupStart.map(self.date),
            domainLookupEndDate: setup?.domainLookupEnd.map(self.date),
            connectStartDate: setup?.connectStart.map(self.date),
            connectEndDate: setup?.connectEnd.map(self.date),
            secureConnectionStartDate: setup?.secureConnectionStart.map(self.date),
            secureConnectionEndDate: setup?.secureConnectionEnd.map(self.date)
        )
    }

    private func date(_ time: NIODeadline) -> Date {
        let elapsed = Double((time - self.fetchStart).nanoseconds) / 1_000_000_000
        return self.fetchStartDate.addingTimeInterval(elapsed)
    }
}

/// Hands the metrics of one hop of a redirect chain to the caller's handler.
///
/// When a hop ends in a redirect, its response body is dropped without being read. If the response was not
/// complete yet, that cancels the transaction, which is not an error of the hop. Once the redirect is known to be
/// followed, such a cancellation is therefore reported without an error.
struct HTTPHopMetricsHandler: Sendable {
    private let followedRedirect = NIOLockedValueBox(false)
    private let handler: @Sendable (HTTPClientTransactionMetrics) -> Void

    init(_ handler: @escaping @Sendable (HTTPClientTransactionMetrics) -> Void) {
        self.handler = handler
    }

    /// Call this before the response of the hop is dropped.
    func redirectWillBeFollowed() {
        self.followedRedirect.withLockedValue { $0 = true }
    }

    /// The handler to hand to the transaction of the hop.
    var transactionHandler: @Sendable (HTTPClientTransactionMetrics) -> Void {
        { metrics in self(metrics) }
    }

    func callAsFunction(_ metrics: HTTPClientTransactionMetrics) {
        var metrics = metrics
        if (metrics.error as? HTTPClientError) == .cancelled, self.followedRedirect.withLockedValue({ $0 }) {
            metrics.error = nil
        }
        self.handler(metrics)
    }
}
