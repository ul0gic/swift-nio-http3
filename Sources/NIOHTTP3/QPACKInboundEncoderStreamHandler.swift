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

@_spi(PackageInternal) import HTTP3
import NIOCore
@_spi(PackageInternal) import QPACK

@available(anyAppleOS 27, *)
protocol QPACKInboundEncoderStreamDelegate: ~Copyable {
    /// - Throws: A connection error, if the instruction can't be applied.
    func onReceivedInstruction(_ instruction: QPACKEncoderInstruction) throws(QPACKError)

    func onError(_ error: HTTP3Error)
}

/// Read encoder instructions from a channel and give them to a callback.
/// This belongs on the incoming encoder stream.
/// The encoder instructions come from the remote encoder and should be fed into the local decoder.
@available(anyAppleOS 27, *)
final class QPACKInboundEncoderStreamHandler<Delegate: QPACKInboundEncoderStreamDelegate>: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    let decoder: NIOSingleStepByteToMessageProcessor<QPACKEncoderInstructionDecoder>
    let delegate: Delegate
    private let inboundMemory: HTTP3InboundMemoryConfiguration?
    private let storageReservation: (any HTTP3InboundStorageReservation)?

    init(delegate: consuming Delegate) {
        self.decoder = NIOSingleStepByteToMessageProcessor(QPACKEncoderInstructionDecoder())
        self.delegate = delegate
        self.inboundMemory = nil
        self.storageReservation = nil
    }

    init(delegate: consuming Delegate, inboundMemory: HTTP3InboundMemoryConfiguration?) throws {
        self.storageReservation = try inboundMemory.map { memory in
            try memory.makeStorageReservation(memory.requiredStorageBytes(
                maximumDecodedFieldSectionBytes: 0,
                maximumBufferedPayloadBytes: 16
            ))
        }
        self.inboundMemory = inboundMemory
        self.decoder = NIOSingleStepByteToMessageProcessor(
            QPACKEncoderInstructionDecoder(allowInsertions: inboundMemory == nil),
            maximumBufferSize: inboundMemory.map { $0.maximumBytesPerRead + 16 }
        )
        self.delegate = delegate
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        let streamError = HTTP3Error(
            code: .qpackEncoderStreamError,
            message: "Inbound QPACK encoder instruction stream error",
            cause: error,
            errorCode: .qpackEncoderStreamError,
            location: .here()
        )
        self.delegate.onError(streamError)
        context.fireErrorCaught(error)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let byteBuffer = Self.unwrapInboundIn(data)
        do {
            if let inboundMemory, byteBuffer.capacity > inboundMemory.maximumBytesPerRead {
                throw ByteToMessageDecoderError.PayloadTooLargeError()
            }
            try self.decoder.process(buffer: byteBuffer) { instruction in
                try self.delegate.onReceivedInstruction(instruction)
            }
        } catch let error as QPACKError {
            // The instruction parsed, but the decoder can't apply it.
            assert(error.isConnectionError)
            self.delegate.onError(HTTP3Error(error, location: .here()))
        } catch {
            let streamError = HTTP3Error(
                code: .qpackEncoderStreamError,
                message: "Invalid QPACK encoder instruction",
                cause: error,
                errorCode: .qpackEncoderStreamError,
                location: .here()
            )
            self.delegate.onError(streamError)
            context.fireErrorCaught(error)
        }
    }
}
