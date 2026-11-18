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

import AsyncHTTPClient  // NOT @testable - the public API is what matters here
import XCTest

final class HTTPClientProxyTests: XCTestCase {
    typealias Proxy = HTTPClient.Configuration.Proxy

    private func hash(_ proxy: Proxy) -> Int {
        var hasher = Hasher()
        proxy.hash(into: &hasher)
        return hasher.finalize()
    }

    func testSOCKSServerWithoutCredentialsStillWorks() {
        let proxy = Proxy.socksServer(host: "socks.example.com")
        XCTAssertEqual(proxy.host, "socks.example.com")
        XCTAssertEqual(proxy.port, 1080)
        XCTAssertNil(proxy.authorization)
        XCTAssertEqual(proxy, .socksServer(host: "socks.example.com", port: 1080))
    }

    func testSOCKSServerWithCredentials() throws {
        let proxy = try Proxy.socksServer(host: "socks.example.com", username: "alice", password: "pw")
        XCTAssertEqual(proxy.host, "socks.example.com")
        XCTAssertEqual(proxy.port, 1080)
        XCTAssertNil(proxy.authorization)

        let customPort = try Proxy.socksServer(host: "socks.example.com", port: 9050, username: "alice", password: "pw")
        XCTAssertEqual(customPort.port, 9050)
    }

    func testCredentialsParticipateInEqualityAndHashing() throws {
        let alice = try Proxy.socksServer(host: "h", port: 1, username: "alice", password: "pw")
        let aliceAgain = try Proxy.socksServer(host: "h", port: 1, username: "alice", password: "pw")
        let otherPassword = try Proxy.socksServer(host: "h", port: 1, username: "alice", password: "pw2")
        let otherUsername = try Proxy.socksServer(host: "h", port: 1, username: "bob", password: "pw")
        let anonymous = Proxy.socksServer(host: "h", port: 1)

        XCTAssertEqual(alice, aliceAgain)
        XCTAssertEqual(self.hash(alice), self.hash(aliceAgain))

        for other in [otherPassword, otherUsername, anonymous] {
            XCTAssertNotEqual(alice, other)
            XCTAssertNotEqual(self.hash(alice), self.hash(other))
        }
        XCTAssertNotEqual(otherPassword, otherUsername)
        XCTAssertEqual(Set([alice, aliceAgain, otherPassword, otherUsername, anonymous]).count, 4)
    }

    func testSOCKSProxyIsNotAnHTTPProxy() throws {
        let socks = Proxy.socksServer(host: "h", port: 1)
        let http = Proxy.server(host: "h", port: 1)
        XCTAssertNotEqual(socks, http)
    }

    func testCredentialLengthLimits() throws {
        // RFC 1929: 1...255 *bytes* each
        XCTAssertNoThrow(try Proxy.socksServer(host: "h", username: "u", password: "p"))
        XCTAssertNoThrow(
            try Proxy.socksServer(
                host: "h",
                username: String(repeating: "u", count: 255),
                password: String(repeating: "p", count: 255)
            )
        )
        // 85 * 3 bytes = 255 bytes
        XCTAssertNoThrow(
            try Proxy.socksServer(host: "h", username: String(repeating: "€", count: 85), password: "p")
        )

        let invalid: [(String, String)] = [
            ("", "p"),
            ("u", ""),
            ("", ""),
            (String(repeating: "u", count: 256), "p"),
            ("u", String(repeating: "p", count: 256)),
            // 128 * 2 bytes = 256 bytes: 128 characters, but too long
            (String(repeating: "é", count: 128), "p"),
            ("u", String(repeating: "é", count: 128)),
        ]
        for (username, password) in invalid {
            XCTAssertThrowsError(try Proxy.socksServer(host: "h", username: username, password: password)) {
                XCTAssertEqual($0 as? HTTPClientError, .invalidProxyConfiguration)
            }
        }
    }

    func testDescriptionNeverContainsThePassword() throws {
        let socks = try Proxy.socksServer(
            host: "socks.example.com",
            port: 9050,
            username: "alice",
            password: "hunter2-secret"
        )
        let http = Proxy.server(
            host: "proxy.example.com",
            port: 8080,
            authorization: .basic(username: "bob", password: "http-secret")
        )

        for text in ["\(socks)", String(describing: socks), String(reflecting: socks), "\(http)", String(reflecting: http)]
        {
            XCTAssertFalse(text.contains("hunter2-secret"), text)
            XCTAssertFalse(text.contains("http-secret"), text)
            XCTAssertFalse(text.contains("Ym9iOmh0dHAtc2VjcmV0"), text)  // base64 of "bob:http-secret"
        }
        XCTAssertTrue("\(socks)".contains("alice"))
        XCTAssertTrue("\(socks)".contains("socks.example.com"))
        XCTAssertTrue("\(socks)".contains("<redacted>"))
        XCTAssertEqual(
            "\(Proxy.socksServer(host: "h", port: 1))",
            "Proxy(socks, host: h, port: 1, no credentials)"
        )
    }

    func testAuthorizationSetterOnHTTPProxy() {
        var proxy = Proxy.server(host: "h", port: 1)
        XCTAssertNil(proxy.authorization)
        proxy.authorization = .bearer(tokens: "token")
        XCTAssertEqual(proxy.authorization, .bearer(tokens: "token"))
        proxy.authorization = nil
        XCTAssertEqual(proxy, .server(host: "h", port: 1))
    }

    func testClearingTheAuthorizationOfASOCKSProxyKeepsItsCredentials() throws {
        var proxy = try Proxy.socksServer(host: "h", port: 1, username: "alice", password: "pw")
        proxy.authorization = nil  // used to trap, there is nothing to clear
        XCTAssertNil(proxy.authorization)
        XCTAssertEqual(proxy, try .socksServer(host: "h", port: 1, username: "alice", password: "pw"))
    }
}
