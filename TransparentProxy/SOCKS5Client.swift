// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
@preconcurrency import Network

/// Errors thrown by the shared SOCKS5 / NWConnection helpers.
enum SOCKS5Error: LocalizedError {
    case connectionCancelled
    case unexpectedEOF
    case socks5AuthFailed
    case socks5ConnectFailed

    var errorDescription: String? {
        switch self {
        case .connectionCancelled: return "Connection was cancelled"
        case .unexpectedEOF:       return "Unexpected end of data"
        case .socks5AuthFailed:    return "SOCKS5 authentication failed"
        case .socks5ConnectFailed: return "SOCKS5 CONNECT failed"
        }
    }
}

/// Shared NWConnection + SOCKS5 primitives used by both the TCP relay path
/// and the TCP-DNS client. Kept as free-standing functions so callers can
/// reuse them without depending on TransparentProxyProvider.
enum SOCKS5Client {

    // MARK: - NWConnection helpers

    static func connectTCP(host: String, port: UInt16) async throws -> NWConnection {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let connection = NWConnection(to: endpoint, using: .tcp)

        return try await withCheckedThrowingContinuation { cont in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    cont.resume(returning: connection)
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: SOCKS5Error.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    static func sendAll(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                })
        }
    }

    static func readExact(connection: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(
                minimumIncompleteLength: count,
                maximumLength: count
            ) { data, _, _, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let data = data, data.count >= count {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: SOCKS5Error.unexpectedEOF)
                }
            }
        }
    }

    static func readSome(connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 65536
            ) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let data = data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: Data())
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    // MARK: - SOCKS5 handshake (RFC 1928)

    /// Perform SOCKS5 handshake — supports IPv4, IPv6, and domain CONNECT.
    static func handshake(
        connection: NWConnection,
        destHost: String,
        destPort: UInt16
    ) async throws {
        // Step 1: Greeting — no auth
        let greeting = Data([0x05, 0x01, 0x00])
        try await sendAll(connection: connection, data: greeting)

        let authResp = try await readExact(connection: connection, count: 2)
        guard authResp[0] == 0x05, authResp[1] == 0x00 else {
            throw SOCKS5Error.socks5AuthFailed
        }

        // Step 2: CONNECT request
        var request = Data([0x05, 0x01, 0x00])

        if IPv4Address(destHost) != nil {
            request.append(0x01)
            let parts = destHost.split(separator: ".").compactMap { UInt8($0) }
            request.append(contentsOf: parts)
        } else if let ipv6 = IPv6Address(destHost) {
            request.append(0x04)
            withUnsafeBytes(of: ipv6.rawValue) { request.append(contentsOf: $0) }
        } else {
            request.append(0x03)
            let domainBytes = Array(destHost.utf8)
            request.append(UInt8(domainBytes.count))
            request.append(contentsOf: domainBytes)
        }

        // Port (big-endian)
        request.append(UInt8(destPort >> 8))
        request.append(UInt8(destPort & 0xFF))

        try await sendAll(connection: connection, data: request)

        // Read response: version, status, rsv, atyp
        let connResp = try await readExact(connection: connection, count: 4)
        guard connResp[0] == 0x05, connResp[1] == 0x00 else {
            throw SOCKS5Error.socks5ConnectFailed
        }

        // Skip bound address
        switch connResp[3] {
        case 0x01:  // IPv4
            _ = try await readExact(connection: connection, count: 4 + 2)
        case 0x03:  // Domain
            let lenData = try await readExact(connection: connection, count: 1)
            _ = try await readExact(
                connection: connection, count: Int(lenData[0]) + 2
            )
        case 0x04:  // IPv6
            _ = try await readExact(connection: connection, count: 16 + 2)
        default:
            break
        }
    }
}
