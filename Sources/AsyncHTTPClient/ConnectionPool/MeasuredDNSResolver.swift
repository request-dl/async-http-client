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
import NIOPosix

#if canImport(Dispatch)
import Dispatch
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// Resolves host names through another resolver and records when the lookup started and ended.
///
/// The lookup starts with the first query and ends when the first query completes. The system resolver
/// answers both queries from the same lookup, so they complete together.
final class MeasuredDNSResolver: Resolver, Sendable {
    private let underlying: any (Resolver & Sendable)
    private let setup: HTTPConnectionSetupRecorder

    init(_ underlying: any (Resolver & Sendable), setup: HTTPConnectionSetupRecorder) {
        self.underlying = underlying
        self.setup = setup
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.setup.markDomainLookupStart()
        return self.underlying.initiateAQuery(host: host, port: port).always { [setup] _ in
            setup.markDomainLookupEnd()
        }
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.setup.markDomainLookupStart()
        return self.underlying.initiateAAAAQuery(host: host, port: port).always { [setup] _ in
            setup.markDomainLookupEnd()
        }
    }

    func cancelQueries() {
        self.underlying.cancelQueries()
    }
}

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)

/// Does what SwiftNIO's default resolver does: one `getaddrinfo` call per connection attempt for TCP
/// addresses, run off the event loop, with the result split into IPv4 and IPv6 addresses.
///
/// SwiftNIO does not make its default resolver available, which is why there is a copy of it here. Errors
/// are produced by SwiftNIO itself, see ``SystemDNSResolver/resolveBlocking(host:port:)``, so callers see the same
/// errors they would see with the default resolver.
final class SystemDNSResolver: Resolver, Sendable {
    private struct Promises {
        var v4: EventLoopPromise<[SocketAddress]>
        var v6: EventLoopPromise<[SocketAddress]>
    }

    private let loop: EventLoop

    /// Created with the first query. A resolver that is never asked, because the target is an IP address, must not
    /// leave promises behind that are never completed.
    private let promises = NIOLockedValueBox<Promises?>(nil)

    init(loop: EventLoop) {
        self.loop = loop
    }

    private func currentPromises() -> Promises {
        self.promises.withLockedValue { promises in
            if let promises {
                return promises
            }
            let created = Promises(v4: self.loop.makePromise(), v6: self.loop.makePromise())
            promises = created
            return created
        }
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.currentPromises().v4.futureResult
    }

    /// Both queries are answered by the one lookup that is started here, like SwiftNIO's resolver does it.
    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        let promises = self.currentPromises()
        DispatchQueue.global().async {
            self.resolveBlocking(host: host, port: port, promises: promises)
        }
        return promises.v6.futureResult
    }

    func cancelQueries() {}

    private func resolveBlocking(host: String, port: Int, promises: Promises) {
        var info: UnsafeMutablePointer<addrinfo>?

        var hint = addrinfo()
        #if canImport(Glibc)
        hint.ai_socktype = CInt(SOCK_STREAM.rawValue)
        #else
        hint.ai_socktype = CInt(SOCK_STREAM)
        #endif
        hint.ai_protocol = CInt(IPPROTO_TCP)

        guard getaddrinfo(host, String(port), &hint, &info) == 0, let info else {
            // `UnknownHost` can only be created by SwiftNIO. Resolving the host again through it makes it report
            // the failure the way it does for its own resolver. This is the failure path, so the second call is cheap.
            do {
                _ = try SocketAddress.makeAddressResolvingHost(host, port: port)
                self.fail(SocketAddressError.unsupported, promises)
            } catch {
                self.fail(error, promises)
            }
            return
        }
        defer { freeaddrinfo(info) }

        var v4Results: [SocketAddress] = []
        var v6Results: [SocketAddress] = []

        var current: UnsafeMutablePointer<addrinfo> = info
        while true {
            let addressBytes = UnsafeRawPointer(current.pointee.ai_addr)
            switch NIOBSDSocket.AddressFamily(rawValue: current.pointee.ai_family) {
            case .inet:
                // `getaddrinfo` fills in an address of the family it reports
                v4Results.append(SocketAddress(addressBytes!.load(as: sockaddr_in.self), host: host))
            case .inet6:
                v6Results.append(SocketAddress(addressBytes!.load(as: sockaddr_in6.self), host: host))
            default:
                self.fail(SocketAddressError.unsupported, promises)
                return
            }

            guard let next = current.pointee.ai_next else {
                break
            }
            current = next
        }

        // Both promises are completed in the same tick, so neither is left behind.
        self.loop.execute { [v4Results, v6Results] in
            promises.v6.succeed(v6Results)
            promises.v4.succeed(v4Results)
        }
    }

    private func fail(_ error: Error, _ promises: Promises) {
        self.loop.execute {
            promises.v6.fail(error)
            promises.v4.fail(error)
        }
    }
}

#endif
