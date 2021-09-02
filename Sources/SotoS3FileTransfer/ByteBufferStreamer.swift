//===----------------------------------------------------------------------===//
//
// This source file is part of the Soto for AWS open source project
//
// Copyright (c) 2020-2021 the Soto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Soto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

/// Request body streamer. `HBHTTPDecodeHandler` feeds this with ByteBuffers while the Router consumes them
public class ByteBufferStreamer {
    public enum StreamerError: Swift.Error {
        case bodyDropped
    }

    /// Values we can feed the streamer with
    public enum FeedInput {
        case byteBuffer(ByteBuffer)
        case error(Error)
        case end
    }

    /// Values returned when we consume the contents of the streamer
    public enum ConsumeOutput {
        case byteBuffer(ByteBuffer)
        case end
    }

    /// Queue of promises for each ByteBuffer fed to the streamer. Last entry is always waiting for the next buffer or end tag
    var queue: CircularBuffer<EventLoopPromise<ConsumeOutput>>
    /// EventLoop everything is running on
    let eventLoop: EventLoop
    /// called every time a ByteBuffer is consumed
    var onConsume: ((ByteBufferStreamer) -> Void)?
    /// has request streamer data been dropped
    var dropped: Bool

    init(eventLoop: EventLoop) {
        self.queue = .init(initialCapacity: 8)
        self.queue.append(eventLoop.makePromise())
        self.eventLoop = eventLoop
        self.onConsume = nil
        self.dropped = false
    }

    /// Feed a ByteBuffer to the request
    /// - Parameter result: Bytebuffer or end tag
    func feed(_ result: FeedInput) {
        self.eventLoop.assertInEventLoop()

        // queue most have at least one promise on it, or something has gone wrong
        assert(self.queue.last != nil)
        let promise = self.queue.last!

        switch result {
        case .byteBuffer(let byteBuffer):
            // don't add more ByteBuffers to queue if we are dropped
            guard self.dropped == false else { return }

            self.queue.append(self.eventLoop.makePromise())

            promise.succeed(.byteBuffer(byteBuffer))
        case .error(let error):
            promise.fail(error)
        case .end:
            promise.succeed(.end)
        }
    }

    /// Consume what has been fed to the request
    /// - Parameter eventLoop: EventLoop to return future on
    /// - Returns: Returns an EventLoopFuture that will be fulfilled with array of ByteBuffers that has so far been fed to th request body
    ///     and whether we have consumed everything
    public func consume(on eventLoop: EventLoop) -> EventLoopFuture<ConsumeOutput> {
        self.consume().hop(to: eventLoop)
    }

    /// Consume the request body, calling `process` on each buffer until you receive an end tag
    /// - Returns: EventLoopFuture that will be fulfilled when all ByteBuffers have been consumed
    /// - Parameters:
    ///   - eventLoop: EventLoop to run on
    ///   - process: Closure to call to process ByteBuffer
    public func consumeAll(on eventLoop: EventLoop, _ process: @escaping (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        let promise = self.eventLoop.makePromise(of: Void.self)
        func _consumeAll() {
            self.consume(on: eventLoop).map { output in
                switch output {
                case .byteBuffer(let buffer):
                    process(buffer).whenComplete { result in
                        switch result {
                        case .failure(let error):
                            promise.fail(error)
                        case .success:
                            _consumeAll()
                        }
                    }

                case .end:
                    promise.succeed(())
                }
            }
            .cascadeFailure(to: promise)
        }
        _consumeAll()
        return promise.futureResult
    }

    /// Consume the request body, but ignore contents
    /// - Returns: EventLoopFuture that will be fulfilled when all ByteBuffers have been consumed
    /// - Parameters:
    ///   - eventLoop: EventLoop to run on
    func drop() -> EventLoopFuture<Void> {
        self.eventLoop.assertInEventLoop()
        self.dropped = true

        let promise = self.eventLoop.makePromise(of: Void.self)
        func _dropAll() {
            self.consume(on: self.eventLoop).map { output in
                switch output {
                case .byteBuffer:
                    _dropAll()

                case .end:
                    promise.succeed(())
                }
            }
            .cascadeFailure(to: promise)
        }
        if self.queue.last != nil {
            _dropAll()
        } else {
            promise.succeed(())
        }
        return promise.futureResult
    }

    /// Consume what has been fed to the request
    /// - Returns: Returns an EventLoopFuture that will be fulfilled with first ByteBuffer on list
    ///     and whether we have consumed an end tag
    func consume() -> EventLoopFuture<ConsumeOutput> {
        assert(self.queue.first != nil)
        let promise = self.queue.first!
        return promise.futureResult.map { result in
            _ = self.queue.popFirst()
            self.onConsume?(self)
            return result
        }
    }
}
