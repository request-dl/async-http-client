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
import NIOPosix
import NIOSSL
import XCTest

@testable import AsyncHTTPClient

/// Tests for `HTTPClient.Configuration.tlsLocalIdentityProviderNIOSSL` — choosing the mTLS client
/// identity per origin on connections that use NIOSSL.
///
/// These always run on a `MultiThreadedEventLoopGroup`, which is what selects the NIOSSL backend even
/// on Apple platforms.
final class LocalIdentityNIOSSLTests: XCTestCase {
    var clientGroup: EventLoopGroup!

    override func setUp() {
        XCTAssertNil(self.clientGroup)
        self.clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        XCTAssertNotNil(self.clientGroup)
        XCTAssertNoThrow(try self.clientGroup.syncShutdownGracefully())
        self.clientGroup = nil
    }

    private static let identity = HTTPClient.Configuration.NIOSSLClientIdentity(
        certificateChain: [.certificate(TestTLS.certificate)],
        privateKey: .privateKey(TestTLS.privateKey)
    )

    /// An mTLS server (trusting only `TestTLS.certificate`) reachable as `https://localhost:<port>`.
    private func makeClientCertificateRequiringServer(
        proxy: HTTPBin<HTTPBinHandler>.Proxy = .none
    ) -> HTTPBin<HTTPBinHandler> {
        var serverConfig = TestTLS.serverConfiguration
        serverConfig.certificateVerification = .noHostnameVerification
        serverConfig.trustRoots = .certificates([TestTLS.certificate])
        return HTTPBin(.http1_1(tlsConfiguration: serverConfig), proxy: proxy)
    }

    private func makeClient(
        configure: (inout HTTPClient.Configuration) -> Void
    ) -> HTTPClient {
        // The test server is self-signed; the subject here is the *client's* certificate.
        var config = HTTPClient.Configuration(certificateVerification: .none).enableFastFailureModeForTesting()
        configure(&config)
        return HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
    }

    func testNoProviderAndNoCertificateIsRejectedByTheServer() throws {
        // The negative control proving the server genuinely enforces mTLS, so the tests below aren't
        // false passes.
        let httpBin = self.makeClientCertificateRequiringServer()
        let httpClient = self.makeClient { _ in }
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
    }

    func testProviderIsAskedForTheOriginOfEachConnection() throws {
        let requestedOrigins = NIOLockedValueBox<[String]>([])
        let httpBin = self.makeClientCertificateRequiringServer()
        let httpClient = self.makeClient {
            $0.tlsLocalIdentityProviderNIOSSL = { host, port in
                requestedOrigins.withLockedValue { $0.append("\(host):\(port)") }
                return nil
            }
        }
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        // The provider has no identity, so the server rejects this; what matters is that it was
        // consulted with the origin that was being connected to.
        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
        XCTAssertEqual(requestedOrigins.withLockedValue { $0 }, ["localhost:\(httpBin.port)"])
    }

    func testIdentityFromProviderIsPresentedToTheOriginItIsConfiguredFor() throws {
        let httpBin = self.makeClientCertificateRequiringServer()
        let httpClient = self.makeClient {
            $0.tlsLocalIdentityProviderNIOSSL = { host, _ in
                host == "localhost" ? Self.identity : nil
            }
        }
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        let response = try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()
        XCTAssertEqual(response.status, .ok)
    }

    func testIdentityIsNotPresentedToTheTargetOfARedirectToAnotherHost() throws {
        // The identity is meant for 127.0.0.1 only. That server answers with a redirect to
        // https://localhost, which demands a client certificate: following the redirect must not hand
        // the identity over, so the handshake has to fail.
        let redirector = HTTPBin()
        let mTLSServer = self.makeClientCertificateRequiringServer()
        let httpClient = self.makeClient {
            $0.tlsLocalIdentityProviderNIOSSL = { host, _ in
                host == "127.0.0.1" ? Self.identity : nil
            }
        }
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try mTLSServer.shutdown())
            XCTAssertNoThrow(try redirector.shutdown())
        }

        XCTAssertThrowsError(
            try httpClient.get(
                url: "http://127.0.0.1:\(redirector.port)/redirect/https?port=\(mTLSServer.port)"
            ).wait()
        )
    }

    func testIdentityIsPresentedToTheTargetOfARedirectWhenItIsTheConfiguredHost() throws {
        // Same redirect as above, but the identity is configured for the redirect's destination: the
        // positive control proving the failure above comes from the scoping, not from the redirect.
        let redirector = HTTPBin()
        let mTLSServer = self.makeClientCertificateRequiringServer()
        let httpClient = self.makeClient {
            $0.tlsLocalIdentityProviderNIOSSL = { host, _ in
                host == "localhost" ? Self.identity : nil
            }
        }
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try mTLSServer.shutdown())
            XCTAssertNoThrow(try redirector.shutdown())
        }

        let response = try httpClient.get(
            url: "http://127.0.0.1:\(redirector.port)/redirect/https?port=\(mTLSServer.port)"
        ).wait()
        XCTAssertEqual(response.status, .ok)
    }

    func testProviderOverridesAnUnscopedIdentityInTLSConfiguration() throws {
        // `tlsConfiguration` carries the identity for every origin — the leak a provider exists to
        // prevent. With a provider set, its answer (here: none for localhost) wins.
        let httpBin = self.makeClientCertificateRequiringServer()
        let httpClient = self.makeClient {
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.certificateVerification = .none
            tlsConfiguration.certificateChain = Self.identity.certificateChain
            tlsConfiguration.privateKey = Self.identity.privateKey
            $0.tlsConfiguration = tlsConfiguration
            $0.tlsLocalIdentityProviderNIOSSL = { _, _ in nil }
        }
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
    }

    func testProviderOverridesAnUnscopedIdentityInARequestsTLSConfiguration() throws {
        // Redirects preserve a request's own TLS configuration, so an identity in it would follow the
        // redirect too. The provider has to win over that as well.
        let httpBin = self.makeClientCertificateRequiringServer()
        let httpClient = self.makeClient {
            $0.tlsLocalIdentityProviderNIOSSL = { _, _ in nil }
        }
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        var requestTLS = TLSConfiguration.makeClientConfiguration()
        requestTLS.certificateVerification = .none
        requestTLS.certificateChain = Self.identity.certificateChain
        requestTLS.privateKey = Self.identity.privateKey
        var request = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)/get")
        request.tlsConfiguration = requestTLS

        XCTAssertThrowsError(try httpClient.execute(request: request).wait())
    }

    func testUnscopedIdentityInTLSConfigurationStillWorksWithoutAProvider() throws {
        // Existing behaviour, unchanged when no provider is configured.
        let httpBin = self.makeClientCertificateRequiringServer()
        let httpClient = self.makeClient {
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.certificateVerification = .none
            tlsConfiguration.certificateChain = Self.identity.certificateChain
            tlsConfiguration.privateKey = Self.identity.privateKey
            $0.tlsConfiguration = tlsConfiguration
        }
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        let response = try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()
        XCTAssertEqual(response.status, .ok)
    }

    // MARK: - TLS inside a proxy tunnel

    func testProxyTunnelAsksTheProviderForTheDestinationOrigin() throws {
        // The simulated proxy answers CONNECT and then terminates TLS itself, demanding a client
        // certificate: the same port plays proxy and destination.
        let proxyAndDestination = self.makeClientCertificateRequiringServer(proxy: .simulate(authorization: nil))
        let requestedOrigins = NIOLockedValueBox<[String]>([])
        let httpClient = self.makeClient {
            $0.proxy = .server(host: "localhost", port: proxyAndDestination.port)
            $0.tlsLocalIdentityProviderNIOSSL = { host, port in
                requestedOrigins.withLockedValue { $0.append("\(host):\(port)") }
                return nil
            }
        }
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try proxyAndDestination.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://test/ok").wait())
        // The origin is the one the request named, not the proxy it is tunnelled through.
        XCTAssertEqual(requestedOrigins.withLockedValue { $0 }, ["test:443"])
    }

    func testProxyTunnelPresentsTheIdentityTheProviderChoosesForTheDestination() throws {
        let proxyAndDestination = self.makeClientCertificateRequiringServer(proxy: .simulate(authorization: nil))
        let httpClient = self.makeClient {
            $0.proxy = .server(host: "localhost", port: proxyAndDestination.port)
            $0.tlsLocalIdentityProviderNIOSSL = { host, _ in
                host == "test" ? Self.identity : nil
            }
        }
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try proxyAndDestination.shutdown())
        }

        let response = try httpClient.get(url: "https://test/ok").wait()
        XCTAssertEqual(response.status, .ok)
    }

    func testProxyTunnelDoesNotPresentTheIdentityToAnotherDestination() throws {
        let proxyAndDestination = self.makeClientCertificateRequiringServer(proxy: .simulate(authorization: nil))
        let httpClient = self.makeClient {
            $0.proxy = .server(host: "localhost", port: proxyAndDestination.port)
            $0.tlsLocalIdentityProviderNIOSSL = { host, _ in
                host == "somewhere-else" ? Self.identity : nil
            }
        }
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try proxyAndDestination.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://test/ok").wait())
    }
}
