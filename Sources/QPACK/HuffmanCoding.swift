//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct NIOCore.ByteBuffer

extension QPACKEncodedLength {
    /// The number of bytes ``OutputRawSpan/appendHuffmanEncoded(_:encodedByteLength:)`` appends for `bytes`.
    @available(anyAppleOS 27, *)
    static func huffman(of bytes: Span<UInt8>) -> Int {
        var numberOfBits = 0
        // Iterating by index on purpose: on Swift 6.4, `for ch in span` leaves an extra outer loop and a
        // trap around this one, which makes the equivalent encode loops slower.
        // TODO: Revisit `for byte in bytes` once Swift 6.5 has landed.
        for i in bytes.indices {
            numberOfBits &+= HuffmanEncoderTable[bytes[i]].nbits
        }
        // round up to a whole number of bytes to account for EOS prefix
        return (numberOfBits &+ 7) / 8
    }
}

extension OutputRawSpan {
    /// Appends `bytes`, using QPACK Huffman encoding.
    ///
    /// - Parameters:
    ///   - bytes: The data to encode.
    ///   - encodedByteLength: The encoded length of `bytes`, as returned by ``QPACKEncodedLength/huffman(of:)``.
    /// - Precondition: The span has room for `encodedByteLength` more bytes.
    @available(anyAppleOS 27, *)
    mutating func appendHuffmanEncoded(_ bytes: Span<UInt8>, encodedByteLength: Int) {
        assert(encodedByteLength == QPACKEncodedLength.huffman(of: bytes))
        precondition(self.freeCapacity >= encodedByteLength, "Not enough room for the Huffman encoded bytes")

        // The loop writes through an `UnsafeMutableRawBufferPointer` rather than calling `append(_:)`, which
        // bounds-checks and bumps the span's count on every byte: that costs 7% more instructions on a full field
        // section encode of a browser GET. The writes are in bounds as long as `encodedByteLength` is right.
        self.withUnsafeMutableBytes { buffer, initializedCount in
            // Codes are at most 30 bits long, and fewer than 8 bits are left over after each symbol, so the pending
            // bits always fit into 64 bits. Bits above them are left over from earlier symbols and are never written.
            var pending: UInt64 = 0
            var pendingBitCount = 0
            // Iterating by index on purpose: on Swift 6.4, `for ch in span` leaves an extra outer loop and a
            // trap around this one, which makes the equivalent encode loops slower.
            // TODO: Revisit `for byte in bytes` once Swift 6.5 has landed.
            for i in bytes.indices {
                let entry = HuffmanEncoderTable[bytes[i]]
                pending = (pending &<< entry.nbits) | UInt64(entry.bits)
                pendingBitCount &+= entry.nbits
                while pendingBitCount >= 8 {
                    pendingBitCount &-= 8
                    buffer[initializedCount] = UInt8(truncatingIfNeeded: pending &>> pendingBitCount)
                    initializedCount &+= 1
                }
            }
            if pendingBitCount > 0 {
                // Pad the last byte with the most significant bits of the EOS symbol, which are all 1.
                let padding = UInt8(0xFF) &>> pendingBitCount
                buffer[initializedCount] = UInt8(truncatingIfNeeded: pending &<< (8 &- pendingBitCount)) | padding
                initializedCount &+= 1
            }
        }
    }
}

/// Adds QPACK-conformant Huffman decoding to `ByteBuffer`.
extension ByteBuffer {
    /// The largest number of bytes that `encodedLength` Huffman-encoded octets can decode to.
    ///
    /// The shortest code in the QPACK Huffman table is 5 bits, so `encodedLength` octets carry
    /// `floor(encodedLength * 8 / 5)` symbols at most. We round up, which is one byte of slack
    /// at most and keeps the arithmetic obviously non-negative.
    ///
    /// This bound is load-bearing for memory safety, not just a heuristic: ``getHuffmanEncodedString(at:length:into:)``
    /// writes into its destination without bounds checks, relying on the destination having
    /// been sized with this function.
    fileprivate static func maxHuffmanDecodedLength(ofEncodedLength encodedLength: Int) -> Int {
        (encodedLength * 8 + 4) / 5
    }

    @available(anyAppleOS 27, *)
    func getHuffmanEncodedString(at index: Int, length: Int, budget: QPACKFieldSectionBudget? = nil) -> String? {
        guard let bytes = self.getHuffmanEncodedBytes(at: index, length: length, budget: budget) else { return nil }
        return String(validating: bytes.bytes, as: UTF8.self)
    }

    @available(anyAppleOS 27, *)
    func getHuffmanEncodedBytes(at index: Int, length: Int, budget: QPACKFieldSectionBudget? = nil) -> QPACKBytes? {
        let start = index - self.readerIndex
        guard start >= 0, start <= self.readableBytes, length >= 0, length <= self.readableBytes - start else {
            assertionFailure("Requested range out of bounds: \(index) + \(length) vs. \(self.readerIndex)..<\(self.writerIndex)")
            return nil
        }
        if length == 0 { return "" }
        let capacity = min(Self.maxHuffmanDecodedLength(ofEncodedLength: length), budget?.remainingBytes ?? Int.max)
        var valid = false
        let bytes = [UInt8](unsafeUninitializedCapacity: capacity) { storage, initializedCount in
            var output = OutputSpan(buffer: storage, initializedCount: 0)
            valid = self._getHuffmanEncodedString(at: index, length: length, into: &output, budget: budget)
            initializedCount = output.finalize(for: storage)
        }
        guard valid else { return nil }
        // Do not retain the Huffman worst-case capacity in the decoded field section.
        return bytes.withUnsafeBufferPointer { QPACKBytes($0) }
    }

    /// Decode `length` Huffman-encoded octets starting at `index`, appending the decoded bytes to
    /// `destination`.
    ///
    /// - Precondition: `index..<index + length` must lie within the readable bytes; the caller is
    ///   expected to have validated that.
    /// - Precondition: `destination` must have room for
    ///   ``maxHuffmanDecodedLength(ofEncodedLength:)`` bytes; the writes below are unchecked.
    /// - Returns: `true` if the input was a valid Huffman encoding, in which case `destination`
    ///   holds the decoded bytes. On `false` the contents of `destination` are unspecified.
    @available(anyAppleOS 27, *)
    private func _getHuffmanEncodedString(
        at index: Int,
        length: Int,
        into destination: inout OutputSpan<UInt8>,
        budget: QPACKFieldSectionBudget?
    ) -> Bool {
        assert(budget != nil || destination.freeCapacity >= Self.maxHuffmanDecodedLength(ofEncodedLength: length))

        // The loop writes through an `UnsafeMutableRawBufferPointer` rather than calling
        // `destination.append(_:)`. `append` bounds-checks and bumps the span's count on every
        // symbol, and that is sadly more expensive: +4.6% instructions on a full field-section
        // decode of a browser GET, +10.0% on a response whose values run past the inline-`String`
        // window.
        return destination.withUnsafeMutableBufferPointer { buffer, initializedCount in
            // The input span has to be formed in here: `Span` is non-escapable and so cannot be
            // captured by this closure.
            let start = index - self.readerIndex
            let span = self.readableBytesUInt8Span.extracting(start..<(start &+ length))

            var state: UInt8 = 0
            var acceptable = false

            // Iterating by index on purpose: on Swift 6.4, `for ch in span` leaves an extra outer loop and a
            // trap around this one, which makes the equivalent encode loops slower.
            // TODO: Revisit `for ch in span` once Swift 6.5 has landed.
            for i in span.indices {
                let ch = span[i]
                var t = HuffmanDecoderTable[state: state, nybble: ch >> 4]
                if t.flags.contains(.failure) {
                    return false
                }
                if t.flags.contains(.symbol) {
                    if initializedCount == buffer.count {
                        budget?.exceededLimit = true
                        return false
                    }
                    buffer[initializedCount] = t.sym
                    initializedCount &+= 1
                }

                t = HuffmanDecoderTable[state: t.state, nybble: ch & 0xf]
                if t.flags.contains(.failure) {
                    return false
                }
                if t.flags.contains(.symbol) {
                    if initializedCount == buffer.count {
                        budget?.exceededLimit = true
                        return false
                    }
                    buffer[initializedCount] = t.sym
                    initializedCount &+= 1
                }

                state = t.state
                acceptable = t.flags.contains(.accepted)
            }

            return acceptable
        }
    }
}

