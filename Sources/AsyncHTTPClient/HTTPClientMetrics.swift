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
    /// How the connection was established. Only the first request on a connection gets this.
    ///
    /// This is the recorder and not what it recorded so far, because the connection is handed out before everything
    /// is known about how it was established. It is read when the transaction ends.
    var setup: HTTPConnectionSetupRecorder?
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
    }

    mutating func requestEnded(at time: NIODeadline) {
        self.requestEndAt = self.requestEndAt ?? time
    }

    mutating func responseHeadReceived(at time: NIODeadline) {
        self.responseStartAt = self.responseStartAt ?? time
    }

    mutating func responseEnded(at time: NIODeadline) {
        self.responseEndAt = self.responseEndAt ?? time
    }

    /// Produces the final metrics, exactly once. Every later call returns `nil`.
    mutating func finish(error: (any Error)?) -> HTTPClientTransactionMetrics? {
        guard !self.isFinished else {
            return nil
        }
        self.isFinished = true

        return HTTPClientTransactionMetrics(
            url: self.url,
            fetchStartDate: self.fetchStartDate,
            queuedDate: self.queuedAt.map(self.date),
            requestStartDate: self.connection.map { self.date($0.acquiredAt) },
            requestEndDate: self.requestEndAt.map(self.date),
            responseStartDate: self.responseStartAt.map(self.date),
            responseEndDate: self.responseEndAt.map(self.date),
            connection: self.connection.map(self.makeConnection),
            error: error
        )
    }

    private func makeConnection(_ info: HTTPConnectionMetricsInfo) -> HTTPClientTransactionMetrics.Connection {
        // A connection that was established before the request started, for example a pre-warmed one, was not
        // established for this request, which makes it a reused connection and the setup none of its business.
        let recorded = info.setup?.snapshot()
        let setup = recorded.flatMap { $0.start >= self.fetchStart ? $0 : nil }

        return .init(
            id: info.id,
            negotiatedProtocol: info.negotiatedProtocol,
            isReused: info.isReused || (recorded != nil && setup == nil),
            localAddress: info.localAddress,
            remoteAddress: info.remoteAddress,
            isProxyConnection: setup?.isProxyConnection ?? false,
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
