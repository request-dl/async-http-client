//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHTTP1
import NIOSOCKS

extension HTTPClient.Configuration {
    /// Proxy server configuration
    /// Specifies the remote address of an HTTP proxy.
    ///
    /// Adding an `Proxy` to your client's `HTTPClient.Configuration`
    /// will cause requests to be passed through the specified proxy using the
    /// HTTP `CONNECT` method.
    ///
    /// If a `TLSConfiguration` is used in conjunction with `HTTPClient.Configuration.Proxy`,
    /// TLS will be established _after_ successful proxy, between your client
    /// and the destination server.
    ///
    /// SOCKSv5 proxies are created with `socksServer(host:port:)`, or with
    /// `socksServer(host:port:username:password:)` for proxies that require
    /// username/password authentication (RFC 1929).
    public struct Proxy: Sendable, Hashable {
        enum ProxyType: Hashable {
            case http(HTTPClient.Authorization?)
            /// A SOCKSv5 proxy, with the credentials to use if it asks for username/password authentication.
            case socks(UsernamePasswordCredentials?)
        }

        /// Specifies Proxy server host.
        public var host: String
        /// Specifies Proxy server port.
        public var port: Int
        /// Specifies Proxy server authorization.
        ///
        /// This is the HTTP `Proxy-Authorization` sent on the `CONNECT` request of an HTTP proxy.
        /// It is always `nil` for a SOCKS proxy: those authenticate with a username and a password that
        /// are passed to `socksServer(host:port:username:password:)` when the proxy is created.
        ///
        /// - Important: Setting a non-`nil` authorization on a SOCKS proxy is a programmer error and traps,
        ///   because a setter cannot throw and silently dropping the authorization would hide a
        ///   misconfiguration. Setting `nil` on a SOCKS proxy does nothing, there is nothing to remove.
        public var authorization: HTTPClient.Authorization? {
            set {
                switch self.type {
                case .http:
                    self.type = .http(newValue)
                case .socks:
                    precondition(
                        newValue == nil,
                        "HTTP authorization cannot be used with a SOCKS proxy. "
                            + "Use Proxy.socksServer(host:port:username:password:) to authenticate with a SOCKS proxy."
                    )
                }
            }

            get {
                switch self.type {
                case .http(let authorization):
                    return authorization
                case .socks:
                    return nil
                }
            }
        }

        var type: ProxyType

        /// Extra headers sent only on the HTTP `CONNECT` request to the proxy.
        ///
        /// These headers are not sent to the
        /// destination server, and are ignored for SOCKS proxies.
        /// The `host` and `proxy-authorization` headers cannot be overridden through this property
        /// Note: Excluded from hash, because HTTPHeaders are not hashable.
        public var connectHeaders: HTTPHeaders = [:]

        /// Create an HTTP proxy configuration.
        ///
        /// - parameters:
        ///     - host: proxy server host.
        ///     - port: proxy server port.
        public static func server(host: String, port: Int) -> Proxy {
            .init(host: host, port: port, type: .http(nil))
        }

        /// Create an HTTP proxy configuration.
        ///
        /// - parameters:
        ///     - host: proxy server host.
        ///     - port: proxy server port.
        ///     - authorization: proxy server authorization.
        public static func server(host: String, port: Int, authorization: HTTPClient.Authorization? = nil) -> Proxy {
            .init(host: host, port: port, type: .http(authorization))
        }

        /// Create an HTTP proxy configuration.
        ///
        /// - parameters:
        ///     - host: proxy server host.
        ///     - port: proxy server port.
        ///     - authorization: proxy server authorization.
        ///     - connectHeaders: extra headers sent only on the `CONNECT` request to the proxy.
        public static func server(
            host: String,
            port: Int,
            authorization: HTTPClient.Authorization? = nil,
            connectHeaders: HTTPHeaders
        ) -> Self {
            var proxy = Self(host: host, port: port, type: .http(authorization))
            proxy.connectHeaders = connectHeaders
            return proxy
        }

        /// Create a SOCKSv5 proxy configuration.
        /// - parameter host: The SOCKSv5 proxy address.
        /// - parameter port: The SOCKSv5 proxy port, defaults to 1080.
        /// - returns: A new instance of `Proxy` configured to connect to a `SOCKSv5` server.
        public static func socksServer(host: String, port: Int = 1080) -> Proxy {
            .init(host: host, port: port, type: .socks(nil))
        }

        /// Create a SOCKSv5 proxy configuration that authenticates with a username and a password (RFC 1929).
        ///
        /// The credentials are only sent if the proxy selects username/password authentication. A proxy that
        /// does not require authentication is used without them, so this is also safe to use with such a proxy.
        /// If the proxy rejects the credentials, the request fails with the error of the failed connection
        /// attempt, and the connection to the proxy is closed.
        ///
        /// - Important: SOCKSv5 sends the username and the password to the proxy in clear text. Only use this
        ///   with a proxy you reach over a trusted network.
        ///
        /// The password is never part of the `description` of the returned `Proxy`.
        ///
        /// - parameters:
        ///     - host: The SOCKSv5 proxy address.
        ///     - port: The SOCKSv5 proxy port, defaults to 1080.
        ///     - username: The username. RFC 1929 requires 1 to 255 bytes when encoded as UTF-8.
        ///     - password: The password. RFC 1929 requires 1 to 255 bytes when encoded as UTF-8.
        /// - returns: A new instance of `Proxy` configured to connect to a `SOCKSv5` server.
        /// - throws: `HTTPClientError.invalidProxyConfiguration` if the username or the password is empty,
        ///   or longer than 255 bytes when encoded as UTF-8.
        public static func socksServer(
            host: String,
            port: Int = 1080,
            username: String,
            password: String
        ) throws -> Proxy {
            let credentials: UsernamePasswordCredentials
            do {
                credentials = try UsernamePasswordCredentials(username: username, password: password)
            } catch {
                throw HTTPClientError.invalidProxyConfiguration
            }
            return .init(host: host, port: port, type: .socks(credentials))
        }

        // `connectHeaders` is omitted (HTTPHeaders is not hashable)
        public func hash(into hasher: inout Hasher) {
            hasher.combine(self.host)
            hasher.combine(self.port)
            hasher.combine(self.type)
        }
    }
}

extension HTTPClient.Configuration.Proxy: CustomStringConvertible, CustomDebugStringConvertible {
    /// A description of the proxy that is safe to log: the SOCKS password and the HTTP authorization
    /// are redacted.
    public var description: String {
        switch self.type {
        case .http(let authorization):
            let authorization = authorization == nil ? "nil" : "<redacted>"
            return "Proxy(http, host: \(self.host), port: \(self.port), authorization: \(authorization))"
        case .socks(let credentials):
            let credentials = credentials.map { "username: \($0.username.debugDescription), password: <redacted>" }
            return "Proxy(socks, host: \(self.host), port: \(self.port), \(credentials ?? "no credentials"))"
        }
    }

    public var debugDescription: String {
        self.description
    }
}
