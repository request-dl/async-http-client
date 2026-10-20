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
import NIOSSL
import XCTest

@testable import AsyncHTTPClient

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Network)
import Network
import Security
#endif

/// Tests for `HTTPClient.Configuration.tlsLocalIdentityNetworkFramework` — the mTLS client-identity
/// hook for direct (non-proxied) connections that use Network.framework instead of NIOSSL.
final class LocalIdentityNetworkFrameworkTests: XCTestCase {
    var clientGroup: EventLoopGroup!

    override func setUp() {
        XCTAssertNil(self.clientGroup)
        self.clientGroup = getDefaultEventLoopGroup(numberOfThreads: 3)
    }

    override func tearDown() {
        XCTAssertNotNil(self.clientGroup)
        XCTAssertNoThrow(try self.clientGroup.syncShutdownGracefully())
        self.clientGroup = nil
    }

    #if canImport(Network)
    func testClientCertificateIsPresentedOverNetworkFramework() throws {
        guard isTestingNIOTS() else { return }

        let identity = try TestIdentityBuilder.makeIdentity()

        // The server requires and validates a client certificate, trusting only TestTLS.certificate
        // itself (it's self-signed, so it is its own trust anchor).
        var serverConfig = TestTLS.serverConfiguration
        serverConfig.certificateVerification = .noHostnameVerification
        serverConfig.trustRoots = .certificates([TestTLS.certificate])

        var config = HTTPClient.Configuration(certificateVerification: .none)
        config.tlsLocalIdentityNetworkFramework = identity

        let httpBin = HTTPBin(.http1_1(tlsConfiguration: serverConfig))
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        // If the client failed to present its certificate, the server would reject the handshake
        // and this would throw instead of succeeding.
        XCTAssertNoThrow(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
    }

    func testConnectionFailsWithoutClientCertificateWhenServerRequiresOne() throws {
        guard isTestingNIOTS() else { return }

        var serverConfig = TestTLS.serverConfiguration
        serverConfig.certificateVerification = .noHostnameVerification
        serverConfig.trustRoots = .certificates([TestTLS.certificate])

        // No tlsLocalIdentityNetworkFramework configured — the negative control proving the server
        // above genuinely enforces mTLS, so the positive test isn't a false pass.
        let config = HTTPClient.Configuration(certificateVerification: .none).enableFastFailureModeForTesting()

        let httpBin = HTTPBin(.http1_1(tlsConfiguration: serverConfig))
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
    }

    // MARK: - Per-origin identity (tlsLocalIdentityProviderNetworkFramework)

    /// An mTLS server (trusting only `TestTLS.certificate`) reachable as `https://localhost:<port>`.
    private func makeClientCertificateRequiringServer() -> HTTPBin<HTTPBinHandler> {
        var serverConfig = TestTLS.serverConfiguration
        serverConfig.certificateVerification = .noHostnameVerification
        serverConfig.trustRoots = .certificates([TestTLS.certificate])
        return HTTPBin(.http1_1(tlsConfiguration: serverConfig))
    }

    func testProviderIsAskedForTheOriginOfEachConnection() throws {
        guard isTestingNIOTS() else { return }

        let requestedOrigins = NIOLockedValueBox<[String]>([])
        var config = HTTPClient.Configuration(certificateVerification: .none).enableFastFailureModeForTesting()
        config.tlsLocalIdentityProviderNetworkFramework = { host, port in
            requestedOrigins.withLockedValue { $0.append("\(host):\(port)") }
            return nil
        }

        let httpBin = self.makeClientCertificateRequiringServer()
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        // The server requires a certificate and the provider has none, so this fails; what matters is
        // that the provider was consulted with the origin that was being connected to.
        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
        XCTAssertEqual(requestedOrigins.withLockedValue { $0 }, ["localhost:\(httpBin.port)"])
    }

    func testProviderDoesNotSeeIPv6BracketsOrUnixSockets() {
        var config = HTTPClient.Configuration()
        let requestedOrigins = NIOLockedValueBox<[String]>([])
        config.tlsLocalIdentityProviderNetworkFramework = { host, port in
            requestedOrigins.withLockedValue { $0.append("\(host)|\(port)") }
            return nil
        }

        func key(_ target: ConnectionTarget, sni: String? = nil) -> ConnectionPool.Key {
            ConnectionPool.Key(scheme: .https, connectionTarget: target, serverNameIndicatorOverride: sni)
        }

        XCTAssertNil(config.localIdentityNetworkFramework(for: key(.init(remoteHost: "::1", port: 8443)).origin))
        XCTAssertNil(config.localIdentityNetworkFramework(for: key(.init(remoteHost: "example.com", port: 443)).origin))
        // A DNS override connects to another address but the origin stays the host the URL named.
        XCTAssertNil(
            config.localIdentityNetworkFramework(
                for: key(.init(remoteHost: "10.0.0.1", port: 443), sni: "example.org").origin
            )
        )
        XCTAssertNil(config.localIdentityNetworkFramework(for: key(.unixSocket(path: "/tmp/s")).origin))
        XCTAssertEqual(requestedOrigins.withLockedValue { $0 }, ["::1|8443", "example.com|443", "example.org|443"])
    }

    func testIdentityFromProviderIsPresentedToTheOriginItIsConfiguredFor() throws {
        guard isTestingNIOTS() else { return }

        let identity = try TestIdentityBuilder.makeIdentity()

        var config = HTTPClient.Configuration(certificateVerification: .none)
        config.tlsLocalIdentityProviderNetworkFramework = { host, _ in
            host == "localhost" ? identity : nil
        }

        let httpBin = self.makeClientCertificateRequiringServer()
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertNoThrow(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
    }

    func testIdentityIsNotPresentedToTheTargetOfARedirectToAnotherHost() throws {
        guard isTestingNIOTS() else { return }

        let identity = try TestIdentityBuilder.makeIdentity()

        // The identity is meant for 127.0.0.1 only. That server answers with a redirect to
        // https://localhost, which demands a client certificate: following the redirect must not
        // hand the identity over, so the handshake has to fail.
        var config = HTTPClient.Configuration(certificateVerification: .none).enableFastFailureModeForTesting()
        config.tlsLocalIdentityProviderNetworkFramework = { host, _ in
            host == "127.0.0.1" ? identity : nil
        }

        let redirector = HTTPBin()
        let mTLSServer = self.makeClientCertificateRequiringServer()
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
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
        guard isTestingNIOTS() else { return }

        let identity = try TestIdentityBuilder.makeIdentity()

        // Same redirect as above, but the identity is configured for the redirect's destination: this
        // is the positive control proving the failure above comes from the scoping rather than from
        // the redirect itself.
        var config = HTTPClient.Configuration(certificateVerification: .none)
        config.tlsLocalIdentityProviderNetworkFramework = { host, _ in
            host == "localhost" ? identity : nil
        }

        let redirector = HTTPBin()
        let mTLSServer = self.makeClientCertificateRequiringServer()
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
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
    #endif
}

#if canImport(Network)
/// Test-only construction of a `SecIdentity` for `TestTLS`'s certificate and key.
///
/// There is no public API on Apple platforms to pair a certificate and private key into a
/// `SecIdentity` from raw bytes, and a Keychain round-trip is unreliable inside an unsigned
/// `swift test` process (it fails to find the key it just added, depending on the keychain setup).
/// Importing a PKCS#12 bundle with `kSecImportToMemoryOnly` produces the identity without touching
/// any keychain.
enum TestIdentityBuilder {
    enum Error: Swift.Error {
        case pkcs12ImportFailed(OSStatus)
        case noIdentityInBundle
    }

    /// `TestTLS.certificate` + `TestTLS.key`, exported as PKCS#12 with the password `"test"`
    /// (3DES/SHA-1, which is what `SecPKCS12Import` accepts on every supported OS version).
    private static let pkcs12Base64 = """
        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
        """

    static func makeIdentity() throws -> SecIdentity {
        // `kSecImportToMemoryOnly` is what keeps this off the keychain; before these OS versions an
        // import always lands in one, which is what this helper exists to avoid.
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) else {
            throw XCTSkip("SecPKCS12Import(kSecImportToMemoryOnly:) needs macOS 15 / iOS 18 or newer")
        }

        let bundle = Data(base64Encoded: Self.pkcs12Base64, options: .ignoreUnknownCharacters)!
        var items: CFArray?
        let status = SecPKCS12Import(
            bundle as CFData,
            [kSecImportExportPassphrase: "test", kSecImportToMemoryOnly: true] as CFDictionary,
            &items
        )
        guard status == errSecSuccess else {
            throw Error.pkcs12ImportFailed(status)
        }
        guard
            let entry = (items as? [[String: Any]])?.first,
            let identity = entry[kSecImportItemIdentity as String]
        else {
            throw Error.noIdentityInBundle
        }
        return identity as! SecIdentity
    }
}
#endif
