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
import NIOSSL

#if canImport(Network)
import Network
import Security
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Collects when the phases of establishing one connection started and ended.
///
/// One recorder belongs to one connection and is written to while the connection is being established,
/// from the event loop and, for DNS, from the thread that resolves. Every phase keeps only its first mark.
final class HTTPConnectionSetupRecorder: Sendable {
    struct Snapshot: Sendable, Equatable {
        /// When the client started to establish the connection.
        var start: NIODeadline
        var domainLookupStart: NIODeadline?
        var domainLookupEnd: NIODeadline?
        var connectStart: NIODeadline?
        var connectEnd: NIODeadline?
        var secureConnectionStart: NIODeadline?
        var secureConnectionEnd: NIODeadline?
        var isProxyConnection = false
        var tlsVersion: TLSVersion?
        var tlsCipherSuite: UInt16?
    }

    private let state: NIOLockedValueBox<Snapshot>

    init(now: NIODeadline = .now()) {
        self.state = NIOLockedValueBox(Snapshot(start: now))
    }

    func markDomainLookupStart(at time: NIODeadline = .now()) {
        self.state.withLockedValue { $0.domainLookupStart = $0.domainLookupStart ?? time }
    }

    func markDomainLookupEnd(at time: NIODeadline = .now()) {
        self.state.withLockedValue { $0.domainLookupEnd = $0.domainLookupEnd ?? time }
    }

    func markConnectStart(at time: NIODeadline = .now()) {
        self.state.withLockedValue { $0.connectStart = $0.connectStart ?? time }
    }

    func markConnectEnd(at time: NIODeadline = .now()) {
        self.state.withLockedValue { $0.connectEnd = $0.connectEnd ?? time }
    }

    func markSecureConnectionStart(at time: NIODeadline = .now()) {
        self.state.withLockedValue { $0.secureConnectionStart = $0.secureConnectionStart ?? time }
    }

    func markSecureConnectionEnd(at time: NIODeadline = .now()) {
        self.state.withLockedValue { $0.secureConnectionEnd = $0.secureConnectionEnd ?? time }
    }

    /// The tunnel through a proxy was established, which ends the connect phase. Unlike the other marks this one
    /// replaces an earlier mark, the TCP connection to the proxy ended before the tunnel was there.
    func markTunnelEstablished(at time: NIODeadline = .now()) {
        self.state.withLockedValue { $0.connectEnd = time }
    }

    func setTLSVersion(_ version: TLSVersion?) {
        self.state.withLockedValue { $0.tlsVersion = version ?? $0.tlsVersion }
    }

    func setTLSCipherSuite(_ cipherSuite: UInt16?) {
        self.state.withLockedValue { $0.tlsCipherSuite = cipherSuite ?? $0.tlsCipherSuite }
    }

    func markProxyConnection() {
        self.state.withLockedValue { $0.isProxyConnection = true }
    }

    /// Fills in the phases from what the Network framework reports about an established connection.
    ///
    /// Network.framework resolves, connects and does the TLS handshake on its own, so only durations are known.
    /// The phases are laid out one after another starting at `connectStart`.
    func record(
        resolutionDuration: TimeInterval?,
        handshakeDuration: TimeInterval?,
        totalDuration: TimeInterval,
        connectStart: NIODeadline,
        now: NIODeadline = .now()
    ) {
        func offset(_ interval: TimeInterval) -> NIODeadline {
            connectStart + .nanoseconds(Int64((max(interval, 0) * 1_000_000_000).rounded()))
        }

        // never claim to have finished later than we know the connection was ready
        let end = Swift.min(offset(totalDuration), now)

        self.state.withLockedValue { state in
            var cursor = connectStart
            if let resolutionDuration {
                let lookupEnd = Swift.min(offset(resolutionDuration), end)
                state.domainLookupStart = connectStart
                state.domainLookupEnd = lookupEnd
                cursor = lookupEnd
            }

            state.connectStart = cursor
            if let handshakeDuration {
                let secureStart = Swift.max(Swift.min(offset(totalDuration - handshakeDuration), end), cursor)
                state.connectEnd = secureStart
                state.secureConnectionStart = secureStart
                state.secureConnectionEnd = end
            } else {
                state.connectEnd = end
            }
        }
    }

    #if canImport(Network)
    @available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    func record(
        _ report: NWConnection.EstablishmentReport,
        connectStart: NIODeadline,
        now: NIODeadline = .now()
    ) {
        let resolutionDuration = report.resolutions.map(\.duration).max()
        let handshakeDuration = report.handshakes.first { $0.definition == NWProtocolTLS.definition }?
            .handshakeDuration

        self.record(
            resolutionDuration: resolutionDuration,
            handshakeDuration: handshakeDuration,
            totalDuration: report.duration,
            connectStart: connectStart,
            now: now
        )
    }
    #endif

    func snapshot() -> Snapshot {
        var snapshot = self.state.withLockedValue { $0 }
        // With a measured DNS lookup, connecting can only start once there is an address to connect to.
        if let lookupEnd = snapshot.domainLookupEnd, let connectStart = snapshot.connectStart, lookupEnd > connectStart
        {
            snapshot.connectStart = lookupEnd
        }
        return snapshot
    }
}

#if canImport(Network)
extension TLSVersion {
    /// The version the Network framework negotiated, or `nil` for a version that has no equivalent, like DTLS.
    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    init?(_ version: tls_protocol_version_t) {
        switch version {
        case .TLSv10:
            self = .tlsv1
        case .TLSv11:
            self = .tlsv11
        case .TLSv12:
            self = .tlsv12
        case .TLSv13:
            self = .tlsv13
        default:
            return nil
        }
    }
}
#endif
