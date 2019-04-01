// Copyright 2018-2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//
// HTTP1ChannelInboundHandler.swift
// SmokeHTTP1
//

import Foundation
import NIO
import NIOHTTP1
import NIOFoundationCompat
import LoggerAPI
import SmokeOperations

/**
 Handler that manages the inbound channel for a HTTP Request.
 */
class HTTP1ChannelInboundHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    
    /**
     Internal state variable that tracks the progress
     of the HTTP Request and Response.
     */
    private enum State {
        case idle
        case waitingForRequestBody
        case sendingResponse

        mutating func requestReceived() {
            precondition(self == .idle, "Invalid state for request received: \(self)")
            self = .waitingForRequestBody
        }

        mutating func requestComplete() {
            precondition(self == .waitingForRequestBody, "Invalid state for request complete: \(self)")
            self = .sendingResponse
        }

        mutating func responseComplete() {
            precondition(self == .sendingResponse, "Invalid state for response complete: \(self)")
            self = .idle
        }
    }
    
    private let handler: HTTP1RequestHandler
    private let invocationStrategy: InvocationStrategy
    private var requestHead: HTTPRequestHead?
    
    var partialBody: Data?
    private var keepAliveStatus = KeepAliveStatus()
    private var state = State.idle
    
    init(handler: HTTP1RequestHandler,
         invocationStrategy: InvocationStrategy) {
        self.handler = handler
        self.invocationStrategy = invocationStrategy
    }

    private func reset() {
        requestHead = nil
        partialBody = nil
        keepAliveStatus = KeepAliveStatus()
        state = State.idle
    }
    
    /**
     Function called when the inbound channel receives data.
     */
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let requestPart = self.unwrapInboundIn(data)
        
        switch requestPart {
        case .head(let request):
            reset()
            // if this is the request head, store it and the keep alive status
            requestHead = request
            Log.verbose("Request head received.")
            keepAliveStatus.state = request.isKeepAlive
            self.state.requestReceived()
        case .body(var byteBuffer):
            let byteBufferSize = byteBuffer.readableBytes
            let newData = byteBuffer.readData(length: byteBufferSize)
            
            if var newPartialBody = partialBody,
                let newData = newData {
                newPartialBody += newData
                partialBody = newPartialBody
            } else if let newData = newData {
                partialBody = newData
            }
            
            Log.verbose("Request body part of \(byteBufferSize) bytes received.")
        case .end:
            Log.verbose("Request end received.")
            // this signals that the head and all possible body parts have been received
            self.state.requestComplete()
            handleCompleteRequest(context: ctx, bodyData: partialBody)
            reset()
        }
    }
    
    /**
     Is called when the request has been completed received
     and can be passed to the request hander.
     */
    func handleCompleteRequest(context ctx: ChannelHandlerContext, bodyData: Data?) {
        self.state.responseComplete()
        
        Log.verbose("Handling request body with \(bodyData?.count ?? 0) size.")
        
        // make sure we have received the head
        guard let requestHead = requestHead else {
            Log.error("Unable to complete Http request as the head was not received")
            
            handleResponseAsError(ctx: ctx,
                                  responseString: "Missing request head.",
                                  status: .badRequest)
            
            return
        }
        
        // create a response handler for this request
        let responseHandler = StandardHTTP1ResponseHandler(
            requestHead: requestHead,
            keepAliveStatus: keepAliveStatus,
            context: ctx,
            wrapOutboundOut: wrapOutboundOut)
    
        let currentHandler = handler
        
        // pass to the request handler to complete
        invocationStrategy.invoke {
            currentHandler.handle(requestHead: requestHead,
                                  body: bodyData,
                                  responseHandler: responseHandler)
        }
    }
    
    /**
     Called when reading from the channel is completed.
     */
    func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush()
    }
    
    /**
     Writes a error to the response and closes the channel.
     */
    func handleResponseAsError(ctx: ChannelHandlerContext,
                               responseString: String,
                               status: HTTPResponseStatus) {
        var headers = HTTPHeaders()
        var buffer = ctx.channel.allocator.buffer(capacity: responseString.utf8.count)
        buffer.set(string: responseString, at: 0)
        
        headers.add(name: HTTP1Headers.contentLength, value: "\(responseString.utf8.count)")
        ctx.write(self.wrapOutboundOut(.head(HTTPResponseHead(version: requestHead!.version,
                                                              status: status,
                                                              headers: headers))), promise: nil)
        ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        ctx.writeAndFlush(self.wrapOutboundOut(HTTPServerResponsePart.end(nil)),
                          promise: nil)
        ctx.close(promise: nil)
    }
    
    /**
     Called when an inbound event occurs.
     */
    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        switch event {
        // if the remote peer half-closed the channel.
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            switch self.state {
            case .idle, .waitingForRequestBody:
                // not waiting on anything else, channel can be closed
                // immediately
                ctx.close(promise: nil)
            case .sendingResponse:
                // waiting on sending the response, signal that the
                // channel should be closed after sending the response.
                self.keepAliveStatus.state = false
            }
        default:
            ctx.fireUserInboundEventTriggered(event)
        }
    }
}
