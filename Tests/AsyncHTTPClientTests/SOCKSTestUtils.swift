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
        var closedConnections = 0
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

    /// The number of connections the server saw being closed.
    var closedConnections: Int { self.state.withLockedValue { $0.closedConnections } }

    func recordClosed() {
        self.state.withLockedValue { $0.closedConnections += 1 }
    }

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

    /// What the mock server does once it received the credentials of a client.
    enum CredentialsBehavior: Sendable {
        /// Compares them with the expected credentials, and answers accordingly.
        case verify
        /// Closes the connection without sending a status.
        case closeWithoutReply
        /// Never answers, and keeps the connection open.
        case neverReply
    }

    let channel: Channel
    private let group: EventLoopGroup
    let observations = MockSOCKSObservations()

    var port: Int {
        self.channel.localAddress!.port!
    }

    init(
        expectedURL: String,
        expectedResponse: String,
        misbehave: Bool = false,
        authentication: Authentication = .none,
        credentialsBehavior: CredentialsBehavior = .verify,
        tunnelTo tunnelPort: Int? = nil,
        file: String = #filePath,
        line: UInt = #line
    ) throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = elg
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
                                credentialsBehavior: credentialsBehavior,
                                tunnelPort: tunnelPort,
                                observations: observations
                            ),
                        ])
                        if tunnelPort == nil {
                            try channel.pipeline.syncOperations.addHandler(
                                TestHTTPServer(
                                    expectedURL: expectedURL,
                                    expectedResponse: expectedResponse,
                                    file: file,
                                    line: line
                                )
                            )
                        }
                    }
                }
        }
        do {
            self.channel = try bootstrap.bind(host: "localhost", port: 0).wait()
        } catch {
            try? elg.syncShutdownGracefully()
            throw error
        }
    }

    func shutdown() throws {
        try self.channel.close().wait()
        try self.group.syncShutdownGracefully()
    }
}

class SOCKSTestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ClientMessage

    let handshakeHandler: SOCKSServerHandshakeHandler
    let authentication: MockSOCKSServer.Authentication
    let credentialsBehavior: MockSOCKSServer.CredentialsBehavior
    let tunnelPort: Int?
    let observations: MockSOCKSObservations

    init(
        handshakeHandler: SOCKSServerHandshakeHandler,
        authentication: MockSOCKSServer.Authentication = .none,
        credentialsBehavior: MockSOCKSServer.CredentialsBehavior = .verify,
        tunnelPort: Int? = nil,
        observations: MockSOCKSObservations = .init()
    ) {
        self.handshakeHandler = handshakeHandler
        self.authentication = authentication
        self.credentialsBehavior = credentialsBehavior
        self.tunnelPort = tunnelPort
        self.observations = observations
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.observations.recordClosed()
        context.fireChannelInactive()
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
                switch self.credentialsBehavior {
                case .verify:
                    break
                case .closeWithoutReply:
                    context.close(promise: nil)
                    return
                case .neverReply:
                    return
                }
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

            if let tunnelPort = self.tunnelPort {
                self.tunnel(to: tunnelPort, context: context)
                return
            }

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

extension SOCKSTestHandler {
    /// Connects to `localhost:port` and, once connected, relays the bytes in both directions.
    /// The mock server uses this to put a real (for example TLS and HTTP/2) server behind its SOCKS handshake,
    /// whatever the target address of the client was.
    fileprivate func tunnel(to port: Int, context: ChannelHandlerContext) {
        let clientChannel = context.channel
        // whatever the client sends right after our reply waits until the tunnel is ready
        _ = clientChannel.setOption(ChannelOptions.autoRead, value: false)

        let this = NIOLoopBound(self, eventLoop: context.eventLoop)
        ClientBootstrap(group: context.eventLoop).connect(host: "127.0.0.1", port: port).whenComplete { result in
            switch result {
            case .success(let target):
                do {
                    let this = this.value
                    try clientChannel.pipeline.syncOperations.addHandler(
                        MockSOCKSRelayHandler(peer: target),
                        position: .after(this)
                    )
                    try target.pipeline.syncOperations.addHandler(MockSOCKSRelayHandler(peer: clientChannel))
                    // the data the handshake handler buffered is delivered to the relay when it is removed
                    clientChannel.pipeline.syncOperations.removeHandler(this, promise: nil)
                    clientChannel.pipeline.syncOperations.removeHandler(this.handshakeHandler, promise: nil)
                    _ = clientChannel.setOption(ChannelOptions.autoRead, value: true)
                    clientChannel.read()
                } catch {
                    clientChannel.close(promise: nil)
                    target.close(promise: nil)
                }
            case .failure:
                clientChannel.close(promise: nil)
            }
        }
    }
}

/// Writes everything it reads to `peer`, and closes `peer` when its own channel closes.
final class MockSOCKSRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.peer.writeAndFlush(self.unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
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
