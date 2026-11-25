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
import NIOSSL
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

    /// - parameter fastFailure: `true` disables connection retries (and Network.framework's wait for connectivity).
    ///   Tests of the retry policy pass `false`: they use the defaults a real client has.
    private func makeLocalClient(
        proxy: HTTPClient.Configuration.Proxy,
        logger: Logger? = nil,
        fastFailure: Bool = true,
        configure: (inout HTTPClient.Configuration) -> Void = { _ in }
    ) -> HTTPClient {
        var configuration = HTTPClient.Configuration(proxy: proxy)
        if fastFailure {
            configuration = configuration.enableFastFailureModeForTesting()
        }
        configure(&configuration)
        return HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: configuration,
            backgroundActivityLogger: logger ?? Logger(label: "no-op", factory: { _ in SwiftLogNoOpLogHandler() })
        )
    }

    /// Gives a connection attempt that is wrongly retried the time to reach the server.
    private func waitForPossibleRetries() {
        Thread.sleep(forTimeInterval: 0.6)
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
        // default retry policy: a proxy without a usable authentication method must not be retried either
        let localClient = self.makeLocalClient(
            proxy: .socksServer(host: "localhost", port: socksBin.port),
            fastFailure: false
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        let start = NIODeadline.now()
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait()) {
            XCTAssertTrue($0 is SOCKSError.NoValidAuthenticationMethod, "\($0)")
        }
        XCTAssertLessThan(NIODeadline.now() - start, .seconds(5))

        self.waitForPossibleRetries()
        XCTAssertEqual(socksBin.observations.offeredMethods, [[.noneRequired]])
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

    // A regression guard, not a proof: a client owns its connection pools and exactly one `Proxy`, so
    // two clients that only differ in the credentials of their `Proxy` cannot share connections by design.
    // This only fails if that ever changes, for example if pools were shared between clients.
    func testProxySOCKSClientsWithDifferentCredentialsDoNotInterfere() throws {
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

    // MARK: - Failures during the handshake

    // Retrying cannot fix a wrong password, and would hammer the proxy (which might lock the account),
    // so with the default retry policy the request must fail right away, after exactly one attempt.
    func testProxySOCKSWrongPasswordIsNotRetried() throws {
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "the-right-password")
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials)
        )
        let localClient = self.makeLocalClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: "alice", password: "nope"),
            fastFailure: false
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        // `get(url:)` has no deadline: it must not wait for the connect timeout (10s) either
        let start = NIODeadline.now()
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait()) {
            XCTAssertEqual($0 as? SOCKSError.AuthenticationFailed, .init(status: 0x01))
        }
        XCTAssertLessThan(NIODeadline.now() - start, .seconds(5))

        self.waitForPossibleRetries()
        XCTAssertEqual(socksBin.observations.receivedCredentials.count, 1)
        XCTAssertEqual(socksBin.observations.rejectedConnections, 1)

        // a failure is not remembered: the next request makes exactly one new attempt, and fails again
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait()) {
            XCTAssertEqual($0 as? SOCKSError.AuthenticationFailed, .init(status: 0x01))
        }
        self.waitForPossibleRetries()
        XCTAssertEqual(socksBin.observations.receivedCredentials.count, 2)
    }

    // All the requests that wait for the connection fail with the rejection, not only the first one.
    func testProxySOCKSWrongPasswordFailsAllWaitingRequests() throws {
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "the-right-password")
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials)
        )
        let localClient = self.makeLocalClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: "alice", password: "nope"),
            fastFailure: false
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        let futures = (0..<5).map { _ in localClient.get(url: "http://localhost/socks/test") }
        for future in futures {
            XCTAssertThrowsError(try future.wait()) {
                XCTAssertEqual($0 as? SOCKSError.AuthenticationFailed, .init(status: 0x01))
            }
        }
        self.waitForPossibleRetries()
        XCTAssertEqual(socksBin.observations.acceptedConnections, 0)
    }

    func testProxySOCKSProxyClosingTheConnectionAfterTheCredentialsFailsWithAnError() throws {
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "s3cr3t-pa55")
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials),
            credentialsBehavior: .closeWithoutReply
        )
        let localClient = self.makeLocalClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: "alice", password: "s3cr3t-pa55")
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        // A proxy that closes the connection after the credentials, without a status, did not accept them
        // (RFC 1929 only knows a status of `0x00` for success). There is no status to report: `0xFF`.
        let start = NIODeadline.now()
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait()) {
            XCTAssertEqual($0 as? SOCKSError.AuthenticationFailed, .init(status: 0xFF))
        }
        XCTAssertLessThan(NIODeadline.now() - start, .seconds(5))
        XCTAssertEqual(socksBin.observations.receivedCredentials, [credentials])
    }

    // Like a rejection with a status, a proxy that closes the connection after the credentials must not
    // be retried with the same credentials: with the default retry policy the request fails after one attempt.
    func testProxySOCKSProxyClosingTheConnectionAfterTheCredentialsIsNotRetried() throws {
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "s3cr3t-pa55")
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials),
            credentialsBehavior: .closeWithoutReply
        )
        let localClient = self.makeLocalClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: "alice", password: "s3cr3t-pa55"),
            fastFailure: false
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        // `get(url:)` has no deadline: it must not wait for the connect timeout (10s) either
        let start = NIODeadline.now()
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait()) {
            XCTAssertEqual($0 as? SOCKSError.AuthenticationFailed, .init(status: 0xFF))
        }
        XCTAssertLessThan(NIODeadline.now() - start, .seconds(5))

        self.waitForPossibleRetries()
        XCTAssertEqual(socksBin.observations.receivedCredentials, [credentials])
        XCTAssertEqual(socksBin.observations.acceptedConnections, 0)
    }

    func testProxySOCKSProxyNeverAnsweringTheCredentialsTimesOut() throws {
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "s3cr3t-pa55")
        let socksBin = try MockSOCKSServer(
            expectedURL: "/socks/test",
            expectedResponse: "it works!",
            authentication: .usernamePassword(credentials),
            credentialsBehavior: .neverReply
        )
        let localClient = self.makeLocalClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: "alice", password: "s3cr3t-pa55")
        ) {
            $0.timeout.connect = .milliseconds(500)
        }
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        let start = NIODeadline.now()
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait()) {
            // The handshake timer and the timer of the waiting request have the same deadline, either one can
            // win. Neither lets the request wait for a proxy that never answers.
            let error = $0 as? HTTPClientError
            XCTAssertTrue(error == .socksHandshakeTimeout || error == .connectTimeout, "\($0)")
        }
        XCTAssertLessThan(NIODeadline.now() - start, .seconds(5))
        XCTAssertEqual(socksBin.observations.receivedCredentials, [credentials])

        // ... and the handshake timer closes the connection to the proxy
        let closeDeadline = NIODeadline.now() + .seconds(3)
        while socksBin.observations.closedConnections < 1 && NIODeadline.now() < closeDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(socksBin.observations.closedConnections, 1)
    }

    // MARK: - HTTPS (and HTTP/2) through an authenticating SOCKS proxy

    private func makeHTTPSClient(proxy: HTTPClient.Configuration.Proxy, fastFailure: Bool) -> HTTPClient {
        self.makeLocalClient(proxy: proxy, fastFailure: fastFailure) {
            $0.tlsConfiguration = .makeClientConfiguration()
            $0.tlsConfiguration?.certificateVerification = .none
        }
    }

    func testProxySOCKSWithUsernamePasswordForHTTPSOverHTTP2() throws {
        let bin = HTTPBin(.http2())
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "s3cr3t-pa55")
        let socksBin = try MockSOCKSServer(
            expectedURL: "",
            expectedResponse: "",
            authentication: .usernamePassword(credentials),
            tunnelTo: bin.port
        )
        let localClient = self.makeHTTPSClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: "alice", password: "s3cr3t-pa55"),
            fastFailure: false
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
            XCTAssertNoThrow(try bin.shutdown())
        }

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try localClient.get(url: "https://localhost:\(bin.port)/get").wait())
        XCTAssertEqual(response?.status, .ok)
        XCTAssertEqual(response?.version, .init(major: 2, minor: 0))
        XCTAssertEqual(socksBin.observations.receivedCredentials, [credentials])
        XCTAssertEqual(socksBin.observations.acceptedConnections, 1)
    }

    func testProxySOCKSWrongPasswordForHTTPSOverHTTP2IsNotRetried() throws {
        let bin = HTTPBin(.http2())
        let credentials = try UsernamePasswordCredentials(username: "alice", password: "the-right-password")
        let socksBin = try MockSOCKSServer(
            expectedURL: "",
            expectedResponse: "",
            authentication: .usernamePassword(credentials),
            tunnelTo: bin.port
        )
        let localClient = self.makeHTTPSClient(
            proxy: try .socksServer(host: "localhost", port: socksBin.port, username: "alice", password: "nope"),
            fastFailure: false
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
            XCTAssertNoThrow(try bin.shutdown())
        }

        let start = NIODeadline.now()
        XCTAssertThrowsError(try localClient.get(url: "https://localhost:\(bin.port)/get").wait()) {
            XCTAssertEqual($0 as? SOCKSError.AuthenticationFailed, .init(status: 0x01))
        }
        XCTAssertLessThan(NIODeadline.now() - start, .seconds(5))

        self.waitForPossibleRetries()
        XCTAssertEqual(socksBin.observations.receivedCredentials.count, 1)
        XCTAssertEqual(socksBin.observations.acceptedConnections, 0)
    }
}
