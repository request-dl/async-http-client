//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import AsyncHTTPClient
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSOCKS
import XCTest

struct MockSOCKSError: Error, Hashable {
    var description: String
}

class TestSOCKSBadServerHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // just write some nonsense bytes
        let buffer = context.channel.allocator.buffer(bytes: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
        context.writeAndFlush(.init(buffer), promise: nil)
    }
}

/// What a `MockSOCKSServer` observed from its clients. Thread safe, the server runs on its own event loop.
final class MockSOCKSObservations: Sendable {
    private struct State {
        var offeredMethods: [[AuthenticationMethod]] = []
        var receivedCredentials: [UsernamePasswordCredentials] = []
        var acceptedConnections = 0
        var rejectedConnections = 0
    }

    private let state = NIOLockedValueBox(State())

    /// The authentication methods offered in each greeting the server received.
    var offeredMethods: [[AuthenticationMethod]] { self.state.withLockedValue { $0.offeredMethods } }

    /// The credentials the server received, in the order they arrived.
    var receivedCredentials: [UsernamePasswordCredentials] { self.state.withLockedValue { $0.receivedCredentials } }

    /// The number of connections that completed the SOCKS handshake.
    var acceptedConnections: Int { self.state.withLockedValue { $0.acceptedConnections } }

    /// The number of connections that were refused because of missing or wrong credentials.
    var rejectedConnections: Int { self.state.withLockedValue { $0.rejectedConnections } }

    func recordGreeting(_ methods: [AuthenticationMethod]) {
        self.state.withLockedValue { $0.offeredMethods.append(methods) }
    }

    func recordCredentials(_ credentials: UsernamePasswordCredentials) {
        self.state.withLockedValue { $0.receivedCredentials.append(credentials) }
    }

    func recordAccepted() {
        self.state.withLockedValue { $0.acceptedConnections += 1 }
    }

    func recordRejected() {
        self.state.withLockedValue { $0.rejectedConnections += 1 }
    }
}

class MockSOCKSServer {
    /// How the mock server authenticates its clients.
    enum Authentication: Sendable {
        /// Selects `noneRequired`, whatever the client offers.
        case none
        /// Only accepts clients that offer and use username/password (RFC 1929) with exactly these credentials.
        case usernamePassword(UsernamePasswordCredentials)
    }

    let channel: Channel
    let observations = MockSOCKSObservations()

    var port: Int {
        self.channel.localAddress!.port!
    }

    init(
        expectedURL: String,
        expectedResponse: String,
        misbehave: Bool = false,
        authentication: Authentication = .none,
        file: String = #filePath,
        line: UInt = #line
    ) throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let observations = self.observations
        let bootstrap: ServerBootstrap
        if misbehave {
            bootstrap = ServerBootstrap(group: elg)
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(TestSOCKSBadServerHandler())
                    }
                }
        } else {
            bootstrap = ServerBootstrap(group: elg)
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let handshakeHandler = SOCKSServerHandshakeHandler()
                        try channel.pipeline.syncOperations.addHandlers([
                            handshakeHandler,
                            SOCKSTestHandler(
                                handshakeHandler: handshakeHandler,
                                authentication: authentication,
                                observations: observations
                            ),
                            TestHTTPServer(
                                expectedURL: expectedURL,
                                expectedResponse: expectedResponse,
                                file: file,
                                line: line
                            ),
                        ])
                    }
                }
        }
        self.channel = try bootstrap.bind(host: "localhost", port: 0).wait()
    }

    func shutdown() throws {
        try self.channel.close().wait()
    }
}

class SOCKSTestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ClientMessage

    let handshakeHandler: SOCKSServerHandshakeHandler
    let authentication: MockSOCKSServer.Authentication
    let observations: MockSOCKSObservations

    init(
        handshakeHandler: SOCKSServerHandshakeHandler,
        authentication: MockSOCKSServer.Authentication = .none,
        observations: MockSOCKSObservations = .init()
    ) {
        self.handshakeHandler = handshakeHandler
        self.authentication = authentication
        self.observations = observations
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard context.channel.isActive else {
            return
        }

        let message = self.unwrapInboundIn(data)
        switch message {
        case .greeting(let greeting):
            self.observations.recordGreeting(greeting.methods)
            let selected: AuthenticationMethod
            switch self.authentication {
            case .none:
                selected = .noneRequired
            case .usernamePassword:
                selected = greeting.methods.contains(.usernamePassword) ? .usernamePassword : .noneAcceptable
            }
            context.writeAndFlush(
                .init(ServerMessage.selectedAuthenticationMethod(.init(method: selected))),
                promise: nil
            )
            if selected == .noneAcceptable {
                self.observations.recordRejected()
                context.close(promise: nil)
            }
        case .authenticationData(var data):
            guard case .usernamePassword(let expected) = self.authentication else {
                context.fireErrorCaught(
                    MockSOCKSError(description: "Received authentication data but didn't receive any.")
                )
                return
            }
            do {
                guard let request = try data.readUsernamePasswordRequest() else {
                    context.fireErrorCaught(MockSOCKSError(description: "Incomplete username/password request."))
                    return
                }
                self.observations.recordCredentials(request.credentials)
                let accepted = request.credentials == expected
                var response = context.channel.allocator.buffer(capacity: 2)
                response.writeUsernamePasswordResponse(accepted ? .success : .failure)
                context.writeAndFlush(.init(ServerMessage.authenticationData(response, complete: accepted)), promise: nil)
                if !accepted {
                    self.observations.recordRejected()
                    context.close(promise: nil)
                }
            } catch {
                context.fireErrorCaught(error)
            }
        case .request(let request):
            self.observations.recordAccepted()
            context.writeAndFlush(
                .init(
                    ServerMessage.response(.init(reply: .succeeded, boundAddress: request.addressType))
                ),
                promise: nil
            )

            do {
                try context.channel.pipeline.syncOperations.addHandlers(
                    [
                        ByteToMessageHandler(HTTPRequestDecoder()),
                        HTTPResponseEncoder(),
                    ],
                    position: .after(self)
                )
                context.channel.pipeline.syncOperations.removeHandler(self, promise: nil)
                context.channel.pipeline.syncOperations.removeHandler(self.handshakeHandler, promise: nil)
            } catch {
                context.fireErrorCaught(error)
            }
        }
    }
}

class TestHTTPServer: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let expectedURL: String
    let expectedResponse: String
    let file: String
    let line: UInt
    var requestCount = 0

    init(expectedURL: String, expectedResponse: String, file: String, line: UInt) {
        self.expectedURL = expectedURL
        self.expectedResponse = expectedResponse
        self.file = file
        self.line = line
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = self.unwrapInboundIn(data)
        switch message {
        case .head(let head):
            guard self.requestCount == 0 else {
                return
            }
            XCTAssertEqual(head.uri, self.expectedURL)
            self.requestCount += 1
        case .body:
            break
        case .end:
            context.write(self.wrapOutboundOut(.head(.init(version: .http1_1, status: .ok))), promise: nil)
            context.write(
                self.wrapOutboundOut(
                    .body(.byteBuffer(context.channel.allocator.buffer(string: self.expectedResponse)))
                ),
                promise: nil
            )
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}
