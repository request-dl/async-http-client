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

/// Tests for `HTTPClient.Configuration.tlsLocalIdentityChainProviderNetworkFramework` — presenting the
/// intermediate certificates together with the mTLS client identity on Network.framework connections.
final class LocalIdentityChainNetworkFrameworkTests: XCTestCase {
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
    /// A server that requires a client certificate and trusts **only** `TestIdentityChain.root`. The
    /// client's leaf is issued by an intermediate the server has never seen, so the handshake only
    /// succeeds if the client sends that intermediate along with its leaf.
    private func makeRootOnlyTrustingServer() throws -> HTTPBin<HTTPBinHandler> {
        var serverConfig = TestTLS.serverConfiguration
        serverConfig.certificateVerification = .noHostnameVerification
        serverConfig.trustRoots = .certificates([try TestIdentityChain.root])
        return HTTPBin(.http1_1(tlsConfiguration: serverConfig))
    }

    private func makeClient(_ configuration: HTTPClient.Configuration) -> HTTPClient {
        HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: configuration)
    }

    // MARK: - The chain is presented

    func testIdentityAloneIsRejectedByAServerThatOnlyTrustsTheRoot() throws {
        guard isTestingNIOTS() else { return }

        let identity = try TestIdentityChain.makeLeafIdentity()
        let httpBin = try self.makeRootOnlyTrustingServer()

        // The negative control: without the intermediate the server cannot build a path to its root
        // (Network.framework reports -9831, errSSLPeerUnknownCA, "unknown Cert Authority"). This is
        // what makes the positive test below meaningful.
        var config = HTTPClient.Configuration(certificateVerification: .none).enableFastFailureModeForTesting()
        config.tlsLocalIdentityProviderNetworkFramework = { _, _ in identity }

        let httpClient = self.makeClient(config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()) {
            XCTAssertEqual(($0 as? HTTPClient.NWTLSError)?.status, errSSLPeerUnknownCA)
        }
    }

    func testIdentityPropertyAloneIsRejectedByAServerThatOnlyTrustsTheRoot() throws {
        guard isTestingNIOTS() else { return }

        let identity = try TestIdentityChain.makeLeafIdentity()
        let httpBin = try self.makeRootOnlyTrustingServer()

        var config = HTTPClient.Configuration(certificateVerification: .none).enableFastFailureModeForTesting()
        config.tlsLocalIdentityNetworkFramework = identity

        let httpClient = self.makeClient(config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()) {
            XCTAssertEqual(($0 as? HTTPClient.NWTLSError)?.status, errSSLPeerUnknownCA)
        }
    }

    func testIdentityTogetherWithItsIntermediateIsAcceptedByAServerThatOnlyTrustsTheRoot() throws {
        guard isTestingNIOTS() else { return }

        let identity = try TestIdentityChain.makeLeafIdentity()
        let intermediate = try TestIdentityChain.makeIntermediate()
        let httpBin = try self.makeRootOnlyTrustingServer()

        var config = HTTPClient.Configuration(certificateVerification: .none)
        config.tlsLocalIdentityChainProviderNetworkFramework = { _, _ in
            .init(identity: identity, certificates: [intermediate])
        }

        let httpClient = self.makeClient(config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        let response = try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()
        XCTAssertEqual(response.status, .ok)
    }

    func testChainProviderWithNoCertificatesPresentsTheIdentityAlone() throws {
        guard isTestingNIOTS() else { return }

        let identity = try TestIdentityChain.makeLeafIdentity()
        let httpBin = try self.makeRootOnlyTrustingServer()

        var config = HTTPClient.Configuration(certificateVerification: .none).enableFastFailureModeForTesting()
        config.tlsLocalIdentityChainProviderNetworkFramework = { _, _ in .init(identity: identity) }

        let httpClient = self.makeClient(config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()) {
            XCTAssertEqual(($0 as? HTTPClient.NWTLSError)?.status, errSSLPeerUnknownCA)
        }
    }

    // MARK: - Precedence

    func testChainProviderTakesPrecedenceOverTheOtherTwo() throws {
        guard isTestingNIOTS() else { return }

        let identity = try TestIdentityChain.makeLeafIdentity()
        let intermediate = try TestIdentityChain.makeIntermediate()
        let httpBin = try self.makeRootOnlyTrustingServer()

        let otherProviderCalls = NIOLockedValueBox(0)
        var config = HTTPClient.Configuration(certificateVerification: .none)
        // Both of these would be rejected (no intermediate), so success proves they were not used.
        config.tlsLocalIdentityNetworkFramework = identity
        config.tlsLocalIdentityProviderNetworkFramework = { _, _ in
            otherProviderCalls.withLockedValue { $0 += 1 }
            return identity
        }
        config.tlsLocalIdentityChainProviderNetworkFramework = { _, _ in
            .init(identity: identity, certificates: [intermediate])
        }

        let httpClient = self.makeClient(config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertEqual(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait().status, .ok)
        XCTAssertEqual(otherProviderCalls.withLockedValue { $0 }, 0)
    }

    func testIdentityProviderTakesPrecedenceOverTheIdentityProperty() throws {
        let identity = try TestIdentityChain.makeLeafIdentity()
        let intermediate = try TestIdentityChain.makeIntermediate()

        var config = HTTPClient.Configuration(certificateVerification: .none)
        config.tlsLocalIdentityNetworkFramework = identity
        // The provider returns nil for this origin: that must win over the property rather than
        // falling back to it.
        config.tlsLocalIdentityProviderNetworkFramework = { _, _ in nil }
        XCTAssertNil(config.localIdentityWithCertificatesNetworkFramework(for: (host: "localhost", port: 443)))

        // Only the identity property: identity, no intermediates.
        config.tlsLocalIdentityProviderNetworkFramework = nil
        let propertyOnly = config.localIdentityWithCertificatesNetworkFramework(for: (host: "localhost", port: 443))
        XCTAssertNotNil(propertyOnly)
        XCTAssertEqual(propertyOnly?.certificates.count, 0)

        // The chain provider wins over both, including when it returns nil for the origin.
        config.tlsLocalIdentityProviderNetworkFramework = { _, _ in identity }
        config.tlsLocalIdentityChainProviderNetworkFramework = { host, _ in
            host == "localhost" ? .init(identity: identity, certificates: [intermediate]) : nil
        }
        let chained = config.localIdentityWithCertificatesNetworkFramework(for: (host: "localhost", port: 443))
        XCTAssertEqual(chained?.certificates.count, 1)
        XCTAssertNil(config.localIdentityWithCertificatesNetworkFramework(for: (host: "example.com", port: 443)))
    }

    func testChainProviderReturningNilIsNotReplacedByTheOtherTwoEndToEnd() throws {
        guard isTestingNIOTS() else { return }

        // Serves a server that accepts the self-signed TestTLS identity, which the two older settings
        // would present successfully: if the chain provider's `nil` fell through to them, this would
        // connect.
        let identity = try TestIdentityBuilder.makeIdentity()
        var serverConfig = TestTLS.serverConfiguration
        serverConfig.certificateVerification = .noHostnameVerification
        serverConfig.trustRoots = .certificates([TestTLS.certificate])
        let httpBin = HTTPBin(.http1_1(tlsConfiguration: serverConfig))

        var config = HTTPClient.Configuration(certificateVerification: .none).enableFastFailureModeForTesting()
        config.tlsLocalIdentityNetworkFramework = identity
        config.tlsLocalIdentityProviderNetworkFramework = { _, _ in identity }
        config.tlsLocalIdentityChainProviderNetworkFramework = { _, _ in nil }

        let httpClient = self.makeClient(config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
    }

    // MARK: - Per origin

    func testChainProviderIsAskedForTheOriginOfEachConnectionAndNilPresentsNothing() throws {
        guard isTestingNIOTS() else { return }

        let requestedOrigins = NIOLockedValueBox<[String]>([])
        var config = HTTPClient.Configuration(certificateVerification: .none).enableFastFailureModeForTesting()
        config.tlsLocalIdentityChainProviderNetworkFramework = { host, port in
            requestedOrigins.withLockedValue { $0.append("\(host):\(port)") }
            return nil
        }

        let httpBin = try self.makeRootOnlyTrustingServer()
        let httpClient = self.makeClient(config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        // The server requires a certificate and the provider has none, so this fails; what matters is
        // that the provider was consulted with the origin that was being connected to.
        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
        XCTAssertEqual(requestedOrigins.withLockedValue { $0 }, ["localhost:\(httpBin.port)"])
    }

    func testChainProviderDoesNotSeeIPv6BracketsOrUnixSockets() throws {
        let identity = try TestIdentityChain.makeLeafIdentity()
        let requestedOrigins = NIOLockedValueBox<[String]>([])
        var config = HTTPClient.Configuration(certificateVerification: .none)
        config.tlsLocalIdentityChainProviderNetworkFramework = { host, port in
            requestedOrigins.withLockedValue { $0.append("\(host)|\(port)") }
            return .init(identity: identity)
        }

        func key(_ target: ConnectionTarget, sni: String? = nil) -> ConnectionPool.Key {
            ConnectionPool.Key(scheme: .https, connectionTarget: target, serverNameIndicatorOverride: sni)
        }

        XCTAssertNotNil(
            config.localIdentityWithCertificatesNetworkFramework(
                for: key(.init(remoteHost: "::1", port: 8443)).origin
            )
        )
        XCTAssertNotNil(
            config.localIdentityWithCertificatesNetworkFramework(
                for: key(.init(remoteHost: "example.com", port: 443)).origin
            )
        )
        // A DNS override connects to another address but the origin stays the host the URL named.
        XCTAssertNotNil(
            config.localIdentityWithCertificatesNetworkFramework(
                for: key(.init(remoteHost: "10.0.0.1", port: 443), sni: "example.org").origin
            )
        )
        XCTAssertNil(config.localIdentityWithCertificatesNetworkFramework(for: key(.unixSocket(path: "/tmp/s")).origin))
        XCTAssertEqual(requestedOrigins.withLockedValue { $0 }, ["::1|8443", "example.com|443", "example.org|443"])
    }

    func testIdentityAndChainAreNotPresentedToTheTargetOfARedirectToAnotherHost() throws {
        guard isTestingNIOTS() else { return }

        let identity = try TestIdentityChain.makeLeafIdentity()
        let intermediate = try TestIdentityChain.makeIntermediate()

        // The identity and its chain are meant for 127.0.0.1 only. That server answers with a redirect
        // to https://localhost, which demands a client certificate: following the redirect must not
        // hand them over, so the handshake has to fail.
        var config = HTTPClient.Configuration(certificateVerification: .none).enableFastFailureModeForTesting()
        let requestedHosts = NIOLockedValueBox<[String]>([])
        config.tlsLocalIdentityChainProviderNetworkFramework = { host, _ in
            requestedHosts.withLockedValue { $0.append(host) }
            return host == "127.0.0.1" ? .init(identity: identity, certificates: [intermediate]) : nil
        }

        let redirector = HTTPBin()
        let mTLSServer = try self.makeRootOnlyTrustingServer()
        let httpClient = self.makeClient(config)
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
        // Asked again, for the new host, and not answered with the old host's identity.
        XCTAssertEqual(requestedHosts.withLockedValue { $0 }.last, "localhost")
    }

    func testIdentityAndChainArePresentedToTheTargetOfARedirectWhenItIsTheConfiguredHost() throws {
        guard isTestingNIOTS() else { return }

        let identity = try TestIdentityChain.makeLeafIdentity()
        let intermediate = try TestIdentityChain.makeIntermediate()

        // Positive control for the test above: the same redirect succeeds when the destination host is
        // the one the identity is configured for.
        var config = HTTPClient.Configuration(certificateVerification: .none)
        config.tlsLocalIdentityChainProviderNetworkFramework = { host, _ in
            host == "localhost" ? .init(identity: identity, certificates: [intermediate]) : nil
        }

        let redirector = HTTPBin()
        let mTLSServer = try self.makeRootOnlyTrustingServer()
        let httpClient = self.makeClient(config)
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

    // MARK: - The paths that do not use the new property are unchanged

    func testOlderPathsResolveWithoutIntermediates() throws {
        let identity = try TestIdentityChain.makeLeafIdentity()

        var config = HTTPClient.Configuration(certificateVerification: .none)
        XCTAssertNil(config.tlsLocalIdentityChainProviderNetworkFramework)
        XCTAssertNil(config.localIdentityWithCertificatesNetworkFramework(for: (host: "localhost", port: 443)))

        config.tlsLocalIdentityNetworkFramework = identity
        let viaProperty = config.localIdentityWithCertificatesNetworkFramework(for: (host: "localhost", port: 443))
        XCTAssertNotNil(viaProperty)
        XCTAssertEqual(viaProperty?.certificates.count, 0)
        // Even for an origin-less (unix socket) connection, the plain identity property still applies,
        // exactly as it did before the chain provider existed.
        XCTAssertNotNil(config.localIdentityWithCertificatesNetworkFramework(for: nil))

        config.tlsLocalIdentityProviderNetworkFramework = { host, _ in host == "localhost" ? identity : nil }
        let viaProvider = config.localIdentityWithCertificatesNetworkFramework(for: (host: "localhost", port: 443))
        XCTAssertEqual(viaProvider?.certificates.count, 0)
        XCTAssertNil(config.localIdentityWithCertificatesNetworkFramework(for: (host: "example.com", port: 443)))
        XCTAssertNil(config.localIdentityWithCertificatesNetworkFramework(for: nil))
    }

    func testOlderPathStillPresentsTheIdentity() throws {
        guard isTestingNIOTS() else { return }

        // Same server and identity as LocalIdentityNetworkFrameworkTests: a self-signed identity the
        // server trusts directly needs no intermediates.
        let identity = try TestIdentityBuilder.makeIdentity()
        var serverConfig = TestTLS.serverConfiguration
        serverConfig.certificateVerification = .noHostnameVerification
        serverConfig.trustRoots = .certificates([TestTLS.certificate])
        let httpBin = HTTPBin(.http1_1(tlsConfiguration: serverConfig))

        var config = HTTPClient.Configuration(certificateVerification: .none)
        config.tlsLocalIdentityProviderNetworkFramework = { _, _ in identity }

        let httpClient = self.makeClient(config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertEqual(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait().status, .ok)
    }
    #endif
}

#if canImport(Network)
/// Test-only PKI for exercising a client certificate that only validates through an intermediate:
/// `root` → `intermediate` → `leaf` (the client identity). Generated once with OpenSSL (RSA 2048,
/// valid for 100 years, the leaf has `extendedKeyUsage = clientAuth`); nothing outside the tests uses
/// these keys.
enum TestIdentityChain {
    /// The root authority a server trusts. The intermediate and the leaf are *not* known to it.
    static let rootPEM = """
        -----BEGIN CERTIFICATE-----
        MIIC/TCCAeWgAwIBAgIJAMjkm/wEvaupMA0GCSqGSIb3DQEBCwUAMBsxGTAXBgNV
        BAMMEEFIQyBUZXN0IFJvb3QgQ0EwIBcNMjYxMTE3MTE1NjM2WhgPMjEyNjEwMjQx
        MTU2MzZaMBsxGTAXBgNVBAMMEEFIQyBUZXN0IFJvb3QgQ0EwggEiMA0GCSqGSIb3
        DQEBAQUAA4IBDwAwggEKAoIBAQDHBLqi0EAxBXGh6B8Jk7VReOqXXOOSS0spM25s
        4fDiKMK7TptCLL5+F8y/FQg6elY2gw4806YLeoTjqRDa2YaveWfCwqRbRTh5Ii+k
        wo01e9U2awTckQaI0Oe2kzOqETeGY75ZM48GlNHW0v7HTTesf+YOCUknlyCuQhyI
        K33pDpSspRkV8HQTlwEoUPxlCPSsVC7zoI6KPLZ0RGxt/KbVKD3FGjPoy2hQ/RfA
        C1shFxb48+rhCrgA3ZN5VjWQ3y1hE6ie7rB7w8uzqtapJbDQFV18jmwI6ehxJyYM
        QwQaEW5BTLtbpBqQTYUqk0msCg9shcP8jAe+zBiLs28TznANAgMBAAGjQjBAMA8G
        A1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBSUK5oru1m+
        pTKgH0ueluw92ywrBzANBgkqhkiG9w0BAQsFAAOCAQEAmGHjmOERjSCmAs9ocDuD
        RNdfnkQPxfOODdzgDJYgv70z+GbSuPeTMoQGnpmE9/A3tNWlxBpgJLzza9lTu/oL
        x4oZnhgCs3ZpocCNQ1NGjiR+7BRFBPFxOu5hy7RkCOdNPN62U5Ndn6wc02zzKhM5
        g1o0E4FjnpGODiU79mxRqHKhHWHBPQXgFKoZ1beOJoeGpFUGs7y1QawvbOs4yXRW
        zq9BerQwGyGw6y0h9AZ/LvkQakYiO8xEiHJIwRVNV8X0nccWUuKx1vpncv0UWRaB
        Z0Zm8TKlk8T7muGbf7WSz1DDEgvaOqvi+DIO9Mscv7sY9bSOGRlhGtS4GJSqR38A
        Sg==
        -----END CERTIFICATE-----
        """

    /// The intermediate that issued the leaf, DER encoded.
    private static let intermediateBase64 = """
        MIIDKTCCAhGgAwIBAgIJAJZC8PebWbq3MA0GCSqGSIb3DQEBCwUAMBsxGTAXBgNVBAMMEEFIQyBU
        ZXN0IFJvb3QgQ0EwIBcNMjYxMTE3MTE1NjM2WhgPMjEyNjEwMjQxMTU2MzZaMCMxITAfBgNVBAMM
        GEFIQyBUZXN0IEludGVybWVkaWF0ZSBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
        ALZdy6v/iBVZNmUoQit0NyTynNJmzAeiauIFZ0VBQvJ+SxYvoDK2RWFUAmMa8hxO2KcAKnnWuHZc
        P6ObL/bBBC/bQuP8l0gURMiZqngTw4Kjq/0LTbypIkLCINk7uW7+XjVzVboLqE2ttjPoZi2fzyq8
        MT54MywdH+o+xf+hEKwbixklQLP5qJYswkrrRmqXy7NM5ejqQGQQd8DpWNHAdOq/EkO7wCjW3/Fk
        OrQgWOdaJQhoPJa5gyf0n7g0bzYjaCq2J6knHpWYQjdvckVhJLVFYBIg2jDZoOBI8nEa7nQ9tskG
        Sg66gN3w8zD6s7VqMqSHtAG9RVjxqNKCd5qlF5MCAwEAAaNmMGQwEgYDVR0TAQH/BAgwBgEB/wIB
        ADAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFNd1QkIYk1iLn9R3CQm+glKq+3q3MB8GA1UdIwQY
        MBaAFJQrmiu7Wb6lMqAfS56W7D3bLCsHMA0GCSqGSIb3DQEBCwUAA4IBAQCFcUP3q/EZh3MHX9zs
        2q/zSVDqlzLX0dI8F1KY9jUstHi+TJqgVzwmuPHBCtMupGAvgYwjGZ42y1x51W4Qx/hbBzzPVp8k
        BmQkTF4FfWyoSvELkfFHeuOC/QlpgIMox4bltU49xiYFVlGgCBKWHYeZgi88vs7fz7revY9z/CQS
        Kg/HqGStVx94htZNGbzRROEIfGt4//cuT3VOrEfSAxY5RnS7AkO6dh6C6i9MkrigBeU8xtWl8L2s
        MwitXhOaeMUdTTf/ZoDXL7xngjvtV8V+p9y8fapeOQ/eLg8vTb6pIc9VMlunukyWVW99OLPgovqy
        H1ThCcLmnXIScJdC3774
        """

    /// The leaf certificate and its private key, as PKCS#12 with the password `"test"` (3DES/SHA-1,
    /// which `SecPKCS12Import` accepts on every supported OS version).
    private static let leafPKCS12Base64 = """
        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
        """

    static var root: NIOSSLCertificate {
        get throws { try NIOSSLCertificate(bytes: Array(Self.rootPEM.utf8), format: .pem) }
    }

    static func makeIntermediate() throws -> SecCertificate {
        let der = Data(base64Encoded: Self.intermediateBase64, options: .ignoreUnknownCharacters)!
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TestIdentityBuilder.Error.noIdentityInBundle
        }
        return certificate
    }

    static func makeLeafIdentity() throws -> SecIdentity {
        try TestIdentityBuilder.importIdentity(pkcs12Base64: Self.leafPKCS12Base64)
    }
}
#endif
