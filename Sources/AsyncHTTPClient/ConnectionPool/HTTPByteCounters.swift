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
import NIOHTTP1

/// Counts the bytes that go through a connection, or for HTTP/2 through one stream of it.
///
/// The counters only ever grow. A transaction learns how many bytes were its own by taking a snapshot when it starts and
/// another one when it ends. That is exact for HTTP/1, where a connection carries one transaction at a time.
final class HTTPByteCounters: Sendable {
    struct Snapshot: Sendable, Equatable {
        /// Bytes written to the connection, with everything the HTTP encoder adds to them.
        var sent = 0
        /// Bytes read from the connection, before they are decoded.
        var received = 0
        /// Bytes of response bodies as they were decoded off the wire, which is before they are decompressed.
        var responseBodyReceived = 0
    }

    private let state = NIOLockedValueBox(Snapshot())

    func snapshot() -> Snapshot {
        self.state.withLockedValue { $0 }
    }

    func addSent(_ bytes: Int) {
        self.state.withLockedValue { $0.sent += bytes }
    }

    func addReceived(_ bytes: Int) {
        self.state.withLockedValue { $0.received += bytes }
    }

    func addResponseBodyReceived(_ bytes: Int) {
        self.state.withLockedValue { $0.responseBodyReceived += bytes }
    }
}

/// Counts the bytes that are written to and read from the connection. It sits right behind the part of the pipeline
/// that deals with the transport, so it sees the HTTP/1 bytes as they are on the wire, without TLS.
final class HTTPRawByteCountingHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = IOData

    private let counters: HTTPByteCounters

    init(counters: HTTPByteCounters) {
        self.counters = counters
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.counters.addReceived(self.unwrapInboundIn(data).readableBytes)
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.counters.addSent(self.unwrapOutboundIn(data).readableBytes)
        context.write(data, promise: promise)
    }
}

/// Counts the response body bytes that the HTTP decoder produces. It has to sit before the decompression handler, to
/// count what the server sent and not what the caller gets.
final class HTTPResponseBodyCountingHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let counters: HTTPByteCounters

    init(counters: HTTPByteCounters) {
        self.counters = counters
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .body(let body) = self.unwrapInboundIn(data) {
            self.counters.addResponseBodyReceived(body.readableBytes)
        }
        context.fireChannelRead(data)
    }
}
