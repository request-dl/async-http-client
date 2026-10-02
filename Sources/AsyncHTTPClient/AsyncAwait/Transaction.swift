//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOSSL
import Synchronization
import Tracing

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@usableFromInline
final class Transaction:
    // until NIOLockedValueBox learns `sending` because StateMachine cannot be Sendable
    @unchecked Sendable
{
    let logger: Logger

    let request: HTTPClientRequest.Prepared

    let connectionDeadline: NIODeadline
    let preferredEventLoop: EventLoop
    let requestOptions: RequestOptions

    private let state: NIOLockedValueBox<StateMachine>

    private let metrics: NIOLockedValueBox<HTTPRequestMetricsRecorder>
    private let metricsHandler: (@Sendable (HTTPClientTransactionMetrics) -> Void)?

    init(
        request: HTTPClientRequest.Prepared,
        requestOptions: RequestOptions,
        logger: Logger,
        connectionDeadline: NIODeadline,
        preferredEventLoop: EventLoop,
        responseContinuation: CheckedContinuation<HTTPClientResponse, Error>,
        metricsHandler: (@Sendable (HTTPClientTransactionMetrics) -> Void)? = nil
    ) {
        self.request = request
        self.requestOptions = requestOptions
        self.logger = logger
        self.connectionDeadline = connectionDeadline
        self.preferredEventLoop = preferredEventLoop
        self.state = NIOLockedValueBox(StateMachine(responseContinuation))
        self.metrics = NIOLockedValueBox(HTTPRequestMetricsRecorder(url: request.url))
        self.metricsHandler = metricsHandler
    }

    /// Hands the recorded metrics to the handler. Only the first call has an effect, so every path
    /// that ends the transaction can call this without coordinating with the others.
    private func deliverMetrics(error: (any Error)?) {
        guard let metricsHandler = self.metricsHandler else {
            return
        }
        let metrics = self.metrics.withLockedValue { $0.finish(error: error) }
        if let metrics {
            metricsHandler(metrics)
        }
    }

    func cancel() {
        self.fail(CancellationError())
    }

    // MARK: Request body helpers

    private func writeOnceAndOneTimeOnly(byteBuffer: ByteBuffer) {
        // This method is synchronously invoked after sending the request head. For this reason we
        // can make a number of assumptions, how the state machine will react.
        let writeAction = self.state.withLockedValue { state in
            state.writeNextRequestPart()
        }

        switch writeAction {
        case .writeAndWait(let executor), .writeAndContinue(let executor):
            self.metrics.withLockedValue { $0.requestBodyBytesWritten(byteBuffer.readableBytes) }
            executor.writeRequestBodyPart(.byteBuffer(byteBuffer), request: self, promise: nil)

        case .fail:
            // an error/cancellation has happened. we don't need to continue here
            return
        }

        self.requestBodyStreamFinished(trailers: nil)
    }

    private func continueRequestBodyStream(
        _ allocator: ByteBufferAllocator,
        makeAsyncIterator: @Sendable @escaping () -> ((ByteBufferAllocator) async throws -> ByteBuffer?)
    ) {
        Task {
            let next = makeAsyncIterator()

            do {
                while let part = try await next(allocator) {
                    do {
                        try await self.writeRequestBodyPart(part)
                    } catch {
                        // If a write fails, the request has failed somewhere else. We must exit the
                        // write loop though. We don't need to report the error somewhere.
                        return
                    }
                }

                self.requestBodyStreamFinished(trailers: nil)
            } catch {
                // The only chance of reaching this catch block, is an error thrown in the `next`
                // call above.
                self.requestBodyStreamFailed(error)
            }
        }
    }

    struct BreakTheWriteLoopError: Swift.Error {}

    @usableFromInline
    func writeRequestBodyPart(_ part: ByteBuffer) async throws {
        let action = self.state.withLockedValue { state in
            state.writeNextRequestPart()
        }

        switch action {
        case .writeAndContinue(let executor):
            self.metrics.withLockedValue { $0.requestBodyBytesWritten(part.readableBytes) }
            executor.writeRequestBodyPart(.byteBuffer(part), request: self, promise: nil)
        case .writeAndWait:
            // Holding the lock here *should* be safe but because of a bug in the runtime
            // it isn't, so drop the lock, create the continuation and try again.
            //
            // See https://github.com/swiftlang/swift/issues/85668
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let action = self.state.withLockedValue { state in
                    // Check that nothing has changed between dropping and re-acquiring the lock.
                    let action = state.writeNextRequestPart()
                    switch action {
                    case .writeAndContinue, .fail:
                        ()
                    case .writeAndWait:
                        state.waitForRequestBodyDemand(continuation: continuation)
                    }
                    return action
                }

                switch action {
                case .writeAndContinue(let executor):
                    self.metrics.withLockedValue { $0.requestBodyBytesWritten(part.readableBytes) }
                    executor.writeRequestBodyPart(.byteBuffer(part), request: self, promise: nil)
                    continuation.resume()
                case .writeAndWait(let executor):
                    self.metrics.withLockedValue { $0.requestBodyBytesWritten(part.readableBytes) }
                    executor.writeRequestBodyPart(.byteBuffer(part), request: self, promise: nil)
                case .fail:
                    continuation.resume(throwing: BreakTheWriteLoopError())
                }
            }
        case .fail:
            throw BreakTheWriteLoopError()
        }
    }

    @usableFromInline
    func requestBodyStreamFinished(trailers: HTTPHeaders?) {
        let finishAction = self.state.withLockedValue { state in
            state.finishRequestBodyStream()
        }

        switch finishAction {
        case .none:
            // an error/cancellation has happened. nothing to do.
            break

        case .forwardStreamFinished(let executor):
            executor.finishRequestBodyStream(trailers: trailers, request: self, promise: nil)
        }
        return
    }

    private func requestBodyStreamFailed(_ error: Error) {
        self.fail(error)
    }
}

// MARK: - Protocol Methods -

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction: HTTPSchedulableRequest {
    var poolKey: ConnectionPool.Key { self.request.poolKey }
    var tlsConfiguration: TLSConfiguration? { self.request.tlsConfiguration }
    var requiredEventLoop: EventLoop? { nil }

    func requestWasQueued(_ scheduler: HTTPRequestScheduler) {
        let time = NIODeadline.now()
        self.metrics.withLockedValue { $0.requestWasQueued(at: time) }
        self.state.withLockedValue { state in
            state.requestWasQueued(scheduler)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction: HTTPExecutableRequest {
    var requestHead: HTTPRequestHead { self.request.head }

    var requestFramingMetadata: RequestFramingMetadata { self.request.requestFramingMetadata }

    // MARK: Request

    func connectionAcquired(_ info: HTTPConnectionMetricsInfo) {
        self.metrics.withLockedValue { $0.connectionAcquired(info) }
    }

    func willExecuteRequest(_ executor: HTTPRequestExecutor) {
        let action = self.state.withLockedValue { state in
            state.willExecuteRequest(executor)
        }

        switch action {
        case .cancel(let executor):
            executor.cancelRequest(self)
        case .cancelAndFail(let executor, let continuation, with: let error):
            executor.cancelRequest(self)
            self.deliverMetrics(error: error)
            continuation.resume(throwing: error)
        case .none:
            break
        }
    }

    func requestHeadSent() {
        // A request without a body is complete as soon as its head was sent, `requestBodyStreamSent`
        // is not called for it.
        let isComplete = self.requestFramingMetadata.body == .fixedSize(0)
        let time = NIODeadline.now()
        self.metrics.withLockedValue {
            $0.requestHeadSent()
            if isComplete {
                $0.requestEnded(at: time)
            }
        }
    }

    func resumeRequestBodyStream() {
        let action = self.state.withLockedValue { state in
            state.resumeRequestBodyStream()
        }

        switch action {
        case .none:
            break

        case .startStream(let allocator):
            switch self.request.body {
            case .asyncSequence(_, let makeAsyncIterator):
                // it is safe to call this async here. it dispatches...
                self.continueRequestBodyStream(allocator, makeAsyncIterator: makeAsyncIterator)

            case .byteBuffer(let byteBuffer):
                self.writeOnceAndOneTimeOnly(byteBuffer: byteBuffer)

            case .sequence(_, _, let create):
                let byteBuffer = create(allocator)
                self.writeOnceAndOneTimeOnly(byteBuffer: byteBuffer)

            #if UnstableHTTPAPIsSupport
            case .httpClientRequestBody(_, let continuation):
                continuation.continuation.yield(HTTPClientRequest.Body.RequestWriter(transaction: self))
            #endif

            case .none:
                break
            }

        case .resumeStream(let continuation):
            continuation.resume(returning: ())
        }
    }

    func pauseRequestBodyStream() {
        self.state.withLockedValue { state in
            state.pauseRequestBodyStream()
        }
    }

    func requestBodyStreamSent() {
        let time = NIODeadline.now()
        self.metrics.withLockedValue { $0.requestEnded(at: time) }

        let action = self.state.withLockedValue { state in
            state.requestBodyStreamSent()
        }

        switch action {
        case .none:
            break
        case .failure(let error):
            self.fail(error)
        }
    }

    // MARK: Response

    func receiveResponseHead(_ head: HTTPResponseHead) {
        let time = NIODeadline.now()
        self.metrics.withLockedValue { $0.responseHeadReceived(at: time) }

        let action = self.state.withLockedValue { state in
            state.receiveResponseHead(head, delegate: self)
        }

        switch action {
        case .none:
            break

        case .succeedResponseHead(let body, let continuation):
            let response = HTTPClientResponse(
                requestMethod: self.requestHead.method,
                version: head.version,
                status: head.status,
                headers: head.headers,
                transaction: self,
                body: body,
                history: []
            )
            continuation.resume(returning: response)
        }
    }

    func receiveResponseBodyParts(_ buffer: CircularBuffer<ByteBuffer>) {
        let bytes = buffer.reduce(0) { $0 + $1.readableBytes }
        self.metrics.withLockedValue { $0.responseBodyBytesDelivered(bytes) }

        let action = self.state.withLockedValue { state in
            state.receiveResponseBodyParts(buffer)
        }
        switch action {
        case .none:
            break
        case .yieldResponseBodyParts(let source, let responseBodyParts, let executer):
            switch source.yield(contentsOf: responseBodyParts) {
            case .dropped, .stopProducing:
                break
            case .produceMore:
                executer.demandResponseBodyStream(self)
            }
        }
    }

    func receiveResponseEnd(_ buffer: CircularBuffer<ByteBuffer>?, trailers: HTTPHeaders?) {
        let time = NIODeadline.now()
        let bytes = buffer?.reduce(0) { $0 + $1.readableBytes } ?? 0
        self.metrics.withLockedValue {
            $0.responseEnded(at: time)
            $0.responseBodyBytesDelivered(bytes)
        }

        let receiveResponseEndAction = self.state.withLockedValue { state in
            state.receiveResponseEnd(buffer, trailers: trailers)
        }
        switch receiveResponseEndAction {
        case .finishResponseStream(let source, let finalResponse):
            self.deliverMetrics(error: nil)
            if let finalResponse = finalResponse {
                _ = source.yield(contentsOf: finalResponse)
            }
            source.finish()

        case .none:
            break
        }
    }

    var trailers: HTTPHeaders? {
        self.state.withLockedValue {
            $0.trailers
        }
    }

    func httpResponseStreamTerminated() {
        let action = self.state.withLockedValue { state in
            state.httpResponseStreamTerminated()
        }
        self.performFailAction(action)
    }

    @usableFromInline
    func fail(_ error: Error) {
        let action = self.state.withLockedValue { state in
            state.fail(error)
        }
        self.performFailAction(action)
    }

    private func performFailAction(_ action: StateMachine.FailAction) {
        switch action {
        case .none:
            break

        case .failResponseHead(let continuation, let error, let scheduler, let executor, let bodyStreamContinuation):
            scheduler?.cancelRequest(self)  // NOTE: scheduler and executor are exclusive here
            executor?.cancelRequest(self)
            self.deliverMetrics(error: error)
            continuation.resume(throwing: error)
            bodyStreamContinuation?.resume(throwing: error)

        case .failResponseStream(let source, let error, let executor, let requestBodyStreamContinuation):
            executor.cancelRequest(self)
            self.deliverMetrics(error: error)
            source.finish(error)
            requestBodyStreamContinuation?.resume(throwing: error)

        case .failRequestStreamContinuation(let bodyStreamContinuation, let error, let executor):
            executor.cancelRequest(self)
            self.deliverMetrics(error: error)
            bodyStreamContinuation.resume(throwing: error)

        case .cancelExecutor(let executor):
            executor.cancelRequest(self)
            self.deliverMetrics(error: HTTPClientError.cancelled)
        }
    }

    func deadlineExceeded() {
        let action = self.state.withLockedValue { state in
            state.deadlineExceeded()
        }
        self.performDeadlineExceededAction(action)
    }

    private func performDeadlineExceededAction(_ action: StateMachine.DeadlineExceededAction) {
        switch action {
        case .cancel(let requestContinuation, let scheduler, let executor, let bodyStreamContinuation):
            scheduler?.cancelRequest(self)
            executor?.cancelRequest(self)
            self.deliverMetrics(error: HTTPClientError.deadlineExceeded)
            requestContinuation.resume(throwing: HTTPClientError.deadlineExceeded)
            bodyStreamContinuation?.resume(throwing: HTTPClientError.deadlineExceeded)
        case .cancelSchedulerOnly(let scheduler):
            scheduler.cancelRequest(self)
        case .none:
            break
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction: NIOAsyncSequenceProducerDelegate {
    @usableFromInline
    func produceMore() {
        let action = self.state.withLockedValue { state in
            state.produceMore()
        }
        switch action {
        case .none:
            break
        case .requestMoreResponseBodyParts(let executer):
            executer.demandResponseBodyStream(self)
        }
    }

    @usableFromInline
    func didTerminate() {
        self.httpResponseStreamTerminated()
    }
}
