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

import AsyncHTTPClient  // NOT @testable - tests that need @testable go into HTTPClientInternalTests.swift
import InMemoryLogging
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSOCKS
import XCTest

class HTTPClientSOCKSTests: XCTestCase {
    typealias Request = HTTPClient.Request

    var clientGroup: EventLoopGroup!
    var serverGroup: EventLoopGroup!
    var defaultHTTPBin: HTTPBin<HTTPBinHandler>!
    var defaultClient: HTTPClient!
    var backgroundLogStore: InMemoryLogHandler!

    var defaultHTTPBinURLPrefix: String {
        "http://localhost:\(self.defaultHTTPBin.port)/"
    }

    override func setUp() {
        XCTAssertNil(self.clientGroup)
        XCTAssertNil(self.serverGroup)
        XCTAssertNil(self.defaultHTTPBin)
        XCTAssertNil(self.defaultClient)
        XCTAssertNil(self.backgroundLogStore)

        self.clientGroup = getDefaultEventLoopGroup(numberOfThreads: 1)
        self.serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.defaultHTTPBin = HTTPBin()
        let (backgroundLogStore, backgroundLogger) = InMemoryLogHandler.makeLogger(logLevel: .trace)
        self.backgroundLogStore = backgroundLogStore
        self.defaultClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            backgroundActivityLogger: backgroundLogger
        )
    }

    override func tearDown() {
        if let defaultClient = self.defaultClient {
            XCTAssertNoThrow(try defaultClient.syncShutdown())
            self.defaultClient = nil
        }

        XCTAssertNotNil(self.defaultHTTPBin)
        XCTAssertNoThrow(try self.defaultHTTPBin.shutdown())
        self.defaultHTTPBin = nil

        XCTAssertNotNil(self.clientGroup)
        XCTAssertNoThrow(try self.clientGroup.syncShutdownGracefully())
        self.clientGroup = nil

        XCTAssertNotNil(self.serverGroup)
        XCTAssertNoThrow(try self.serverGroup.syncShutdownGracefully())
        self.serverGroup = nil

        XCTAssertNotNil(self.backgroundLogStore)
        self.backgroundLogStore = nil
    }

    func testProxySOCKS() throws {
        let socksBin = try MockSOCKSServer(expectedURL: "/socks/test", expectedResponse: "it works!")
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(
                proxy: .socksServer(host: "localhost", port: socksBin.port)
            ).enableFastFailureModeForTesting()
        )

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try localClient.get(url: "http://localhost/socks/test").wait())
        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(ByteBuffer(string: "it works!"), response?.body)
    }

    func testProxySOCKSBogusAddress() throws {
        let config = HTTPClient.Configuration(proxy: .socksServer(host: "127.0.."))
            .enableFastFailureModeForTesting()
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: config
        )

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait())
    }

    // there is no socks server, so we should fail
    func testProxySOCKSFailureNoServer() throws {
        let localHTTPBin = HTTPBin()
        let config = HTTPClient.Configuration(proxy: .socksServer(host: "localhost", port: localHTTPBin.port))
            .enableFastFailureModeForTesting()

        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: config
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait())
    }

    // speak to a server that doesn't speak SOCKS
    func testProxySOCKSFailureInvalidServer() throws {
        let config = HTTPClient.Configuration(proxy: .socksServer(host: "localhost"))
            .enableFastFailureModeForTesting()

        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: config
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait())
    }

    // test a handshake failure with a misbehaving server
    func testProxySOCKSMisbehavingServer() throws {
        let socksBin = try MockSOCKSServer(expectedURL: "/socks/test", expectedResponse: "it works!", misbehave: true)
        let config = HTTPClient.Configuration(proxy: .socksServer(host: "localhost", port: socksBin.port))
            .enableFastFailureModeForTesting()

        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: config
        )

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        // the server will send a bogus message in response to the clients greeting
        // this will be first picked up as an invalid protocol
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait()) { e in
            XCTAssertTrue(e is SOCKSError.InvalidProtocolVersion)
        }
    }

    // MARK: - Username/password authentication (RFC 1929)

    private func makeLocalClient(
        proxy: HTTPClient.Configuration.Proxy,
        logger: Logger? = nil
    ) -> HTTPClient {
        HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(proxy: proxy).enableFastFailureModeForTesting(),
            backgroundActivityLogger: logger ?? Logger(label: "no-op", factory: { _ in SwiftLogNoOpLogHandler() })
        )
    }

    func testProxySOCKSWithUsernamePassword() throws {
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "s3cr3t-pa55")
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials)
        )
        let localClient = self.makeLocalClient(
            proxy: try .socksServer(
                host: "localhost",
                port: socksBin.port,
                username: "alice",
                password: "s3cr3t-pa55"
            )
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try localClient.get(url: "http://localhost/socks/test").wait())
        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(ByteBuffer(string: "it works!"), response?.body)

        XCTAssertEqual(socksBin.observations.offeredMethods, [[.noneRequired, .usernamePassword]])
        XCTAssertEqual(socksBin.observations.receivedCredentials, [credentials])
        XCTAssertEqual(socksBin.observations.acceptedConnections, 1)
        XCTAssertEqual(socksBin.observations.rejectedConnections, 0)
    }

    func testProxySOCKSWithEmptyPassword() throws {
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "")
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials)
        )
        let localClient = self.makeLocalClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: "alice", password: "")
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try localClient.get(url: "http://localhost/socks/test").wait())
        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(socksBin.observations.receivedCredentials, [credentials])
        XCTAssertEqual(socksBin.observations.receivedCredentials.first?.passwordBytes, [])
        XCTAssertEqual(socksBin.observations.acceptedConnections, 1)
    }

    func testProxySOCKSWithEmptyPasswordAgainstServerExpectingAPasswordFails() throws {
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "s3cr3t-pa55")
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials)
        )
        let localClient = self.makeLocalClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: "alice", password: "")
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait()) {
            XCTAssertEqual($0 as? SOCKSError.AuthenticationFailed, .init(status: 0x01))
        }
        XCTAssertEqual(socksBin.observations.receivedCredentials.first?.passwordBytes, [])
        XCTAssertEqual(socksBin.observations.acceptedConnections, 0)
    }

    func testProxySOCKSWithAccentedUsernamePassword() throws {
        // "é" as one scalar (2 bytes) and as "e" + combining acute (3 bytes) are different credentials
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        let credentials = try UsernamePasswordCredentials(username: composed, password: composed)
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials)
        )
        let goodClient = self.makeLocalClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: composed, password: composed)
        )
        let decomposedClient = self.makeLocalClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: composed, password: decomposed)
        )
        defer {
            XCTAssertNoThrow(try goodClient.syncShutdown())
            XCTAssertNoThrow(try decomposedClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        XCTAssertNoThrow(try goodClient.get(url: "http://localhost/socks/test").wait())
        XCTAssertEqual(Array(socksBin.observations.receivedCredentials[0].usernameBytes), Array(composed.utf8))
        XCTAssertEqual(socksBin.observations.receivedCredentials[0].passwordBytes, Array(composed.utf8))

        XCTAssertThrowsError(try decomposedClient.get(url: "http://localhost/socks/test").wait()) {
            XCTAssertEqual($0 as? SOCKSError.AuthenticationFailed, .init(status: 0x01))
        }
    }

    func testProxySOCKSWithNonASCIIUsernamePassword() throws {
        let credentials = try UsernamePasswordCredentials(username: "usuário-ß", password: "señha-✓")
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials)
        )
        let localClient = self.makeLocalClient(
            proxy: try .socksServer(
                host: "localhost",
                port: socksBin.port,
                username: "usuário-ß",
                password: "señha-✓"
            )
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try localClient.get(url: "http://localhost/socks/test").wait())
        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(socksBin.observations.receivedCredentials, [credentials])
    }

    func testProxySOCKSWrongPasswordFailsTheRequestWithoutLeakingThePassword() throws {
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "the-right-password")
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials)
        )
        let wrongPassword = "the-wrong-password"
        let proxy = try HTTPClient.Configuration.Proxy.socksServer(
            host: "localhost",
            port: socksBin.port,
            username: "alice",
            password: wrongPassword
        )
        let (backgroundLogStore, backgroundLogger) = InMemoryLogHandler.makeLogger(logLevel: .trace)
        let (requestLogStore, requestLogger) = InMemoryLogHandler.makeLogger(logLevel: .trace)
        let localClient = self.makeLocalClient(proxy: proxy, logger: backgroundLogger)
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        var thrownError: Error?
        XCTAssertThrowsError(
            try localClient.execute(
                request: try Request(url: "http://localhost/socks/test"),
                eventLoop: .indifferent,
                deadline: .now() + .seconds(10),
                logger: requestLogger
            ).wait()
        ) {
            thrownError = $0
        }

        // the request fails with the rejection, it does not hang until a timeout
        XCTAssertEqual(thrownError as? SOCKSError.AuthenticationFailed, .init(status: 0x01))
        XCTAssertGreaterThanOrEqual(socksBin.observations.rejectedConnections, 1)
        XCTAssertEqual(socksBin.observations.acceptedConnections, 0)
        XCTAssertEqual(socksBin.observations.receivedCredentials.first?.password, wrongPassword)

        // the password is neither in the error, nor in the proxy description, nor in any log
        for text in [
            String(describing: thrownError as Any),
            String(reflecting: thrownError as Any),
            "\(proxy)",
            String(reflecting: proxy),
        ] + backgroundLogStore.entries.map { "\($0)" } + requestLogStore.entries.map { "\($0)" } {
            XCTAssertFalse(text.contains(wrongPassword), "\(text) contains the password")
            XCTAssertFalse(text.contains("the-right-password"), "\(text) contains the password")
        }
    }

    func testProxySOCKSWithoutCredentialsFailsAgainstServerRequiringAuthentication() throws {
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "s3cr3t-pa55")
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials)
        )
        let localClient = self.makeLocalClient(proxy: .socksServer(host: "localhost", port: socksBin.port))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait()) {
            // the server answers "no acceptable method", which the client reports as one of these
            XCTAssertTrue(
                $0 is SOCKSError.NoValidAuthenticationMethod || $0 is SOCKSError.InvalidAuthenticationSelection,
                "\($0)"
            )
        }
        XCTAssertEqual(socksBin.observations.offeredMethods.first, [.noneRequired])
        XCTAssertEqual(socksBin.observations.receivedCredentials, [])
    }

    func testProxySOCKSWithCredentialsAgainstServerNotRequiringAuthentication() throws {
        let socksBin = try MockSOCKSServer(expectedURL: "/socks/test", expectedResponse: "it works!")
        let localClient = self.makeLocalClient(
            proxy: try .socksServer(
                host: "localhost",
                port: socksBin.port,
                username: "alice",
                password: "s3cr3t-pa55"
            )
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try localClient.get(url: "http://localhost/socks/test").wait())
        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(ByteBuffer(string: "it works!"), response?.body)

        // the credentials were offered as an option, but never sent to a server that did not ask for them
        XCTAssertEqual(socksBin.observations.offeredMethods, [[.noneRequired, .usernamePassword]])
        XCTAssertEqual(socksBin.observations.receivedCredentials, [])
    }

    // Two clients talk to the same proxy that requires authentication, and only differ in the
    // credentials of their `Proxy`. Neither can use a connection that was authenticated for the other.
    func testProxySOCKSCredentialsDoNotLeakBetweenClients() throws {
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "s3cr3t-pa55")
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials)
        )
        let goodClient = self.makeLocalClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: "alice", password: "s3cr3t-pa55")
        )
        let badClient = self.makeLocalClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: "alice", password: "nope")
        )
        defer {
            XCTAssertNoThrow(try goodClient.syncShutdown())
            XCTAssertNoThrow(try badClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        // interleave, so that a shared connection would be found if there was one
        XCTAssertNoThrow(try goodClient.get(url: "http://localhost/socks/test").wait())
        XCTAssertThrowsError(try badClient.get(url: "http://localhost/socks/test").wait()) {
            XCTAssertEqual($0 as? SOCKSError.AuthenticationFailed, .init(status: 0x01))
        }
        XCTAssertNoThrow(try goodClient.get(url: "http://localhost/socks/test").wait())
        XCTAssertThrowsError(try badClient.get(url: "http://localhost/socks/test").wait()) {
            XCTAssertEqual($0 as? SOCKSError.AuthenticationFailed, .init(status: 0x01))
        }

        XCTAssertEqual(socksBin.observations.acceptedConnections, 1)  // the good client reuses its connection
        XCTAssertGreaterThanOrEqual(socksBin.observations.rejectedConnections, 2)
    }
}
