/*
 * Copyright (C) 2019 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "private/backend/CommandStream.h"
#include "CommandStreamDispatcher.h"
#include "metal/MetalDriver.h"

#include "MetalContext.h"
#include "MetalEnums.h"
#include "MetalHandles.h"
#include "MetalState.h"

#include <Metal/Metal.h>
#include <QuartzCore/QuartzCore.h>

#include <utils/Log.h>
#include <utils/Panic.h>

#pragma clang diagnostic push
#pragma ide diagnostic ignored "HidingNonVirtualFunction"

namespace filament {
namespace backend {
namespace metal {

Driver* MetalDriver::create(MetalPlatform* const platform) {
    assert(platform);
    return new MetalDriver(platform);
}

MetalDriver::MetalDriver(backend::MetalPlatform* platform) noexcept
        : DriverBase(new ConcreteDispatcher<MetalDriver>()),
        mPlatform(*platform),
        mContext(new MetalContext) {
    mContext->driverPool = [[NSAutoreleasePool alloc] init];
    mContext->device = MTLCreateSystemDefaultDevice();
    mContext->commandQueue = [mContext->device newCommandQueue];
    mContext->pipelineStateCache.setDevice(mContext->device);
    mContext->depthStencilStateCache.setDevice(mContext->device);
    mContext->samplerStateCache.setDevice(mContext->device);
}

MetalDriver::~MetalDriver() noexcept {
    [mContext->device release];
    delete mContext;
}

#define METAL_DEBUG_COMMANDS 0
#if !defined(NDEBUG)
void MetalDriver::debugCommand(const char *methodName) {
#if METAL_DEBUG_COMMANDS
    utils::slog.d << methodName << utils::io::endl;
#endif
}
#endif

void MetalDriver::beginFrame(int64_t monotonic_clock_ns, uint32_t frameId) {
    mContext->framePool = [[NSAutoreleasePool alloc] init];
    mContext->currentCommandBuffer = [mContext->commandQueue commandBuffer];
}

void MetalDriver::setPresentationTime(int64_t monotonic_clock_ns) {

}

void MetalDriver::endFrame(uint32_t frameId) {
    // Release resources created during frame execution- like commandBuffer and currentDrawable.
    [mContext->framePool drain];
}

void MetalDriver::flush(int dummy) {

}

void MetalDriver::createVertexBufferR(Handle<HwVertexBuffer> vbh, uint8_t bufferCount,
        uint8_t attributeCount, uint32_t vertexCount, AttributeArray attributes,
        BufferUsage usage) {
    // TODO: Take BufferUsage into account when creating the buffer.
    construct_handle<MetalVertexBuffer>(mHandleMap, vbh, mContext->device, bufferCount,
            attributeCount, vertexCount, attributes);
}

void MetalDriver::createIndexBufferR(Handle<HwIndexBuffer> ibh, ElementType elementType,
        uint32_t indexCount, BufferUsage usage) {
    auto elementSize = (uint8_t) getElementTypeSize(elementType);
    construct_handle<MetalIndexBuffer>(mHandleMap, ibh, mContext->device, elementSize, indexCount);
}

void MetalDriver::createTextureR(Handle<HwTexture> th, SamplerType target, uint8_t levels,
        TextureFormat format, uint8_t samples, uint32_t width, uint32_t height,
        uint32_t depth, TextureUsage usage) {
    construct_handle<MetalTexture>(mHandleMap, th, mContext->device, target, levels, format, samples,
            width, height, depth, usage);
}

void MetalDriver::createSamplerGroupR(Handle<HwSamplerGroup> sbh, size_t size) {
    construct_handle<MetalSamplerGroup>(mHandleMap, sbh, size);
}

void MetalDriver::createUniformBufferR(Handle<HwUniformBuffer> ubh, size_t size,
        BufferUsage usage) {
    construct_handle<MetalUniformBuffer>(mHandleMap, ubh, mContext->device, size);
}

void MetalDriver::createRenderPrimitiveR(Handle<HwRenderPrimitive> rph, int dummy) {
    construct_handle<MetalRenderPrimitive>(mHandleMap, rph);
}

void MetalDriver::createProgramR(Handle<HwProgram> rph, Program&& program) {
    construct_handle<MetalProgram>(mHandleMap, rph, mContext->device, program);
}

void MetalDriver::createDefaultRenderTargetR(Handle<HwRenderTarget> rth, int dummy) {
    construct_handle<MetalRenderTarget>(mHandleMap, rth, mContext);
}

void MetalDriver::createRenderTargetR(Handle<HwRenderTarget> rth,
        TargetBufferFlags targetBufferFlags, uint32_t width, uint32_t height,
        uint8_t samples, TextureFormat format, TargetBufferInfo color,
        TargetBufferInfo depth, TargetBufferInfo stencil) {

    auto getColorTexture = [&]() -> id<MTLTexture> {
        if (color.handle) {
            auto colorTexture = handle_cast<MetalTexture>(mHandleMap, color.handle);
            return colorTexture->texture;
        } else if (targetBufferFlags & TargetBufferFlags::COLOR) {
            ASSERT_POSTCONDITION(false, "A color buffer is required for a render target.");
        }
        return nil;
    };

    auto getDepthTexture = [&]() -> id<MTLTexture> {
        if (depth.handle) {
            auto depthTexture = handle_cast<MetalTexture>(mHandleMap, depth.handle);
            return depthTexture->texture;
        } else if (targetBufferFlags & TargetBufferFlags::DEPTH) {
            MTLTextureDescriptor *depthTextureDesc =
                    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                       width:width
                                                                      height:height
                                                                   mipmapped:NO];
            depthTextureDesc.usage = MTLTextureUsageRenderTarget;
            depthTextureDesc.resourceOptions = MTLResourceStorageModePrivate;
            return [[mContext->device newTextureWithDescriptor:depthTextureDesc] autorelease];
        }
        return nil;
    };

    construct_handle<MetalRenderTarget>(mHandleMap, rth, mContext, width, height, samples, format,
            getColorTexture(), getDepthTexture());

    ASSERT_POSTCONDITION(
            !stencil.handle && !(targetBufferFlags & TargetBufferFlags::STENCIL),
            "Stencil buffer not supported.");
}

void MetalDriver::createFenceR(Handle<HwFence>, int dummy) {

}

void MetalDriver::createSwapChainR(Handle<HwSwapChain> sch, void* nativeWindow, uint64_t flags) {
    auto* metalLayer = (CAMetalLayer*) nativeWindow;
    construct_handle<MetalSwapChain>(mHandleMap, sch, mContext->device, metalLayer);
}

void MetalDriver::createStreamFromTextureIdR(Handle<HwStream>, intptr_t externalTextureId,
        uint32_t width, uint32_t height) {

}

Handle<HwVertexBuffer> MetalDriver::createVertexBufferS() noexcept {
    return alloc_handle<MetalVertexBuffer, HwVertexBuffer>();
}

Handle<HwIndexBuffer> MetalDriver::createIndexBufferS() noexcept {
    return alloc_handle<MetalIndexBuffer, HwIndexBuffer>();
}

Handle<HwTexture> MetalDriver::createTextureS() noexcept {
    return alloc_handle<MetalTexture, HwTexture>();
}

Handle<HwSamplerGroup> MetalDriver::createSamplerGroupS() noexcept {
    return alloc_handle<MetalSamplerGroup, HwSamplerGroup>();
}

Handle<HwUniformBuffer> MetalDriver::createUniformBufferS() noexcept {
    return alloc_handle<MetalUniformBuffer, HwUniformBuffer>();
}

Handle<HwRenderPrimitive> MetalDriver::createRenderPrimitiveS() noexcept {
    return alloc_handle<MetalRenderPrimitive, HwRenderPrimitive>();
}

Handle<HwProgram> MetalDriver::createProgramS() noexcept {
    return alloc_handle<MetalProgram, HwProgram>();
}

Handle<HwRenderTarget> MetalDriver::createDefaultRenderTargetS() noexcept {
    return alloc_handle<MetalRenderTarget, HwRenderTarget>();
}

Handle<HwRenderTarget> MetalDriver::createRenderTargetS() noexcept {
    return alloc_handle<MetalRenderTarget, HwRenderTarget>();
}

Handle<HwFence> MetalDriver::createFenceS() noexcept {
    return {};
}

Handle<HwSwapChain> MetalDriver::createSwapChainS() noexcept {
    return alloc_handle<MetalSwapChain, HwSwapChain>();
}

Handle<HwStream> MetalDriver::createStreamFromTextureIdS() noexcept {
    return {};
}

void MetalDriver::destroyVertexBuffer(Handle<HwVertexBuffer> vbh) {
    if (vbh) {
        destruct_handle<MetalVertexBuffer>(mHandleMap, vbh);
    }
}

void MetalDriver::destroyIndexBuffer(Handle<HwIndexBuffer> ibh) {
    if (ibh) {
        destruct_handle<MetalIndexBuffer>(mHandleMap, ibh);
    }
}

void MetalDriver::destroyRenderPrimitive(Handle<HwRenderPrimitive> rph) {
    if (rph) {
        destruct_handle<MetalRenderPrimitive>(mHandleMap, rph);
    }
}

void MetalDriver::destroyProgram(Handle<HwProgram> ph) {
    if (ph) {
        destruct_handle<MetalProgram>(mHandleMap, ph);
    }
}

void MetalDriver::destroySamplerGroup(Handle<HwSamplerGroup> sbh) {
    if (sbh) {
        destruct_handle<MetalSamplerGroup>(mHandleMap, sbh);
    }
}

void MetalDriver::destroyUniformBuffer(Handle<HwUniformBuffer> ubh) {
    if (ubh) {
        destruct_handle<MetalUniformBuffer>(mHandleMap, ubh);
    }
}

void MetalDriver::destroyTexture(Handle<HwTexture> th) {
    if (th) {
        destruct_handle<MetalTexture>(mHandleMap, th);
    }
}

void MetalDriver::destroyRenderTarget(Handle<HwRenderTarget> rth) {
    if (rth) {
        destruct_handle<MetalRenderTarget>(mHandleMap, rth);
    }
}

void MetalDriver::destroySwapChain(Handle<HwSwapChain> sch) {
    if (sch) {
        destruct_handle<MetalSwapChain>(mHandleMap, sch);
    }
}

void MetalDriver::destroyStream(Handle<HwStream> sh) {
    // no-op
}

void MetalDriver::terminate() {
    [mContext->commandQueue release];
    [mContext->driverPool drain];
}

ShaderModel MetalDriver::getShaderModel() const noexcept {
#if defined(IOS)
    return ShaderModel::GL_ES_30;
#else
    return ShaderModel::GL_CORE_41;
#endif
}

Handle<HwStream> MetalDriver::createStream(void* stream) {
    return {};
}

void MetalDriver::setStreamDimensions(Handle<HwStream> stream, uint32_t width,
        uint32_t height) {

}

int64_t MetalDriver::getStreamTimestamp(Handle<HwStream> stream) {
    return 0;
}

void MetalDriver::updateStreams(backend::DriverApi* driver) {

}

void MetalDriver::destroyFence(Handle<HwFence> fh) {

}

FenceStatus MetalDriver::wait(Handle<HwFence> fh, uint64_t timeout) {
    return FenceStatus::ERROR;
}

bool MetalDriver::isTextureFormatSupported(TextureFormat format) {
    return getMetalFormat(format) != MTLPixelFormatInvalid ||
           TextureReshaper::canReshapeTextureFormat(format);
}

bool MetalDriver::isRenderTargetFormatSupported(TextureFormat format) {
    MTLPixelFormat mtlFormat = getMetalFormat(format);
    // RGB9E5 isn't supported on Mac as a color render target.
    return mtlFormat != MTLPixelFormatInvalid && mtlFormat != MTLPixelFormatRGB9E5Float;
}

bool MetalDriver::isFrameTimeSupported() {
    return false;
}

// TODO: the implementations here for updateVertexBuffer and updateIndexBuffer assume static usage.
// Dynamically updated vertex / index buffers will require synchronization.

void MetalDriver::updateVertexBuffer(Handle<HwVertexBuffer> vbh, size_t index,
        BufferDescriptor&& data, uint32_t byteOffset) {
    assert(byteOffset == 0);    // TODO: handle byteOffset for vertex buffers
    auto* vb = handle_cast<MetalVertexBuffer>(mHandleMap, vbh);
    memcpy(vb->buffers[index].contents, data.buffer, data.size);
}

void MetalDriver::updateIndexBuffer(Handle<HwIndexBuffer> ibh, BufferDescriptor&& data,
        uint32_t byteOffset) {
    assert(byteOffset == 0);    // TODO: handle byteOffset for index buffers
    auto* ib = handle_cast<MetalIndexBuffer>(mHandleMap, ibh);
    memcpy(ib->buffer.contents, data.buffer, data.size);
}

void MetalDriver::update2DImage(Handle<HwTexture> th, uint32_t level, uint32_t xoffset,
        uint32_t yoffset, uint32_t width, uint32_t height, PixelBufferDescriptor&& data) {
    auto tex = handle_cast<MetalTexture>(mHandleMap, th);
    tex->load2DImage(level, xoffset, yoffset, width, height, data);
    scheduleDestroy(std::move(data));
}

void MetalDriver::updateCubeImage(Handle<HwTexture> th, uint32_t level,
        PixelBufferDescriptor&& data, FaceOffsets faceOffsets) {
    auto tex = handle_cast<MetalTexture>(mHandleMap, th);
    tex->loadCubeImage(data, faceOffsets, level);
    scheduleDestroy(std::move(data));
}

void MetalDriver::setExternalImage(Handle<HwTexture> th, void* image) {

}

void MetalDriver::setExternalStream(Handle<HwTexture> th, Handle<HwStream> sh) {

}

void MetalDriver::generateMipmaps(Handle<HwTexture> th) {
    // @autoreleasepool is used to release the one-off command buffer and encoder in case this work
    // is done outside a frame.
    @autoreleasepool {
        auto tex = handle_cast<MetalTexture>(mHandleMap, th);
        // Create a one-off command buffer to execute the blit command. Technically, we could re-use
        // this command buffer for later rendering commands, but we'll just commit it here for
        // simplicity.
        id <MTLCommandBuffer> commandBuffer = [mContext->commandQueue commandBuffer];
        id <MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
        [blitEncoder generateMipmapsForTexture:tex->texture];
        [blitEncoder endEncoding];
        [commandBuffer commit];
    }
}

bool MetalDriver::canGenerateMipmaps() {
    return true;
}

void MetalDriver::updateUniformBuffer(Handle<HwUniformBuffer> ubh,
        BufferDescriptor&& data) {
    auto buffer = handle_cast<MetalUniformBuffer>(mHandleMap, ubh);
    buffer->copyIntoBuffer(data.buffer, data.size);
    scheduleDestroy(std::move(data));
}

void MetalDriver::updateSamplerGroup(Handle<HwSamplerGroup> sbh,
        SamplerGroup&& samplerGroup) {
    auto sb = handle_cast<MetalSamplerGroup>(mHandleMap, sbh);
    *sb->sb = samplerGroup;
}

void MetalDriver::beginRenderPass(Handle<HwRenderTarget> rth,
        const RenderPassParams& params) {
    auto renderTarget = handle_cast<MetalRenderTarget>(mHandleMap, rth);
    mContext->currentRenderTarget = renderTarget;
    mContext->currentRenderPassFlags = params.flags;

    MTLRenderPassDescriptor* descriptor = [MTLRenderPassDescriptor renderPassDescriptor];

    // Color

    descriptor.colorAttachments[0].texture = renderTarget->getColor();
    descriptor.colorAttachments[0].resolveTexture = renderTarget->getColorResolve();
    mContext->currentSurfacePixelFormat = descriptor.colorAttachments[0].texture.pixelFormat;

    // Metal clears the entire attachment without respect to viewport or scissor.
    // TODO: Might need to clear the scissor area manually via a draw if we need that functionality.

    const auto clearFlags = (TargetBufferFlags) params.flags.clear;
    const bool clearColor = clearFlags & TargetBufferFlags::COLOR;
    const bool clearDepth = clearFlags & TargetBufferFlags::DEPTH;

    descriptor.colorAttachments[0].loadAction =
            clearColor ? MTLLoadActionClear : MTLLoadActionDontCare;
    descriptor.colorAttachments[0].clearColor = MTLClearColorMake(
            params.clearColor.r, params.clearColor.g, params.clearColor.b, params.clearColor.a);

    // Depth

    descriptor.depthAttachment.texture = renderTarget->getDepth();
    descriptor.depthAttachment.resolveTexture = renderTarget->getDepthResolve();
    descriptor.depthAttachment.loadAction = clearDepth ? MTLLoadActionClear : MTLLoadActionDontCare;
    descriptor.depthAttachment.clearDepth = params.clearDepth;
    mContext->currentDepthPixelFormat = descriptor.depthAttachment.texture.pixelFormat;

    if (renderTarget->isMultisampled()) {
        descriptor.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        // TODO: We don't need to resolve the depth texture if we don't need it.
        descriptor.depthAttachment.storeAction = MTLStoreActionMultisampleResolve;
    }

    mContext->currentCommandEncoder =
            [mContext->currentCommandBuffer renderCommandEncoderWithDescriptor:descriptor];

    // Filament's default winding is counter clockwise.
    [mContext->currentCommandEncoder setFrontFacingWinding:MTLWindingCounterClockwise];

    // Flip the viewport, because Metal's screen space is vertically flipped that of Filament's.
    NSInteger renderTargetHeight =
            mContext->currentRenderTarget->isDefaultRenderTarget() ?
            mContext->currentSurface->surfaceHeight : mContext->currentRenderTarget->height;
    MTLViewport metalViewport {
            .originX = static_cast<double>(params.viewport.left),
            .originY = renderTargetHeight - static_cast<double>(params.viewport.bottom) -
                       static_cast<double>(params.viewport.height),
            .width = static_cast<double>(params.viewport.width),
            .height = static_cast<double>(params.viewport.height),
            .znear = 0.0,
            .zfar = 1.0
    };
    [mContext->currentCommandEncoder setViewport:metalViewport];

    // Metal requires a new command encoder for each render pass, and they cannot be reused.
    // We must bind certain states for each command encoder, so we dirty the states here to force a
    // rebinding at the first the draw call of this pass.
    for (auto& i : mContext->uniformState) {
        i.invalidate();
    }
    mContext->pipelineState.invalidate();
    mContext->depthStencilState.invalidate();
    mContext->cullModeState.invalidate();
}

void MetalDriver::endRenderPass(int dummy) {
    [mContext->currentCommandEncoder endEncoding];

    // Command encoders are one time use. Set it to nullptr so we don't accidentally use it again.
    mContext->currentCommandEncoder = nullptr;
}

void MetalDriver::discardSubRenderTargetBuffers(Handle<HwRenderTarget> rth,
        TargetBufferFlags targetBufferFlags, uint32_t left, uint32_t bottom, uint32_t width,
        uint32_t height) {

}

void MetalDriver::resizeRenderTarget(Handle<HwRenderTarget> rth, uint32_t width,
        uint32_t height) {

}

void MetalDriver::setRenderPrimitiveBuffer(Handle<HwRenderPrimitive> rph,
        Handle<HwVertexBuffer> vbh, Handle<HwIndexBuffer> ibh, uint32_t enabledAttributes) {
    auto primitive = handle_cast<MetalRenderPrimitive>(mHandleMap, rph);
    auto vertexBuffer = handle_cast<MetalVertexBuffer>(mHandleMap, vbh);
    auto indexBuffer = handle_cast<MetalIndexBuffer>(mHandleMap, ibh);
    primitive->setBuffers(vertexBuffer, indexBuffer, enabledAttributes);
}

void MetalDriver::setRenderPrimitiveRange(Handle<HwRenderPrimitive> rph,
        PrimitiveType pt, uint32_t offset, uint32_t minIndex, uint32_t maxIndex,
        uint32_t count) {
    auto primitive = handle_cast<MetalRenderPrimitive>(mHandleMap, rph);
    primitive->type = pt;
    primitive->offset = offset * primitive->indexBuffer->elementSize;
    primitive->count = count;
    primitive->minIndex = minIndex;
    primitive->maxIndex = maxIndex > minIndex ? maxIndex : primitive->maxVertexCount - 1;
}

void MetalDriver::setViewportScissor(int32_t left, int32_t bottom, uint32_t width,
        uint32_t height) {

}

void MetalDriver::makeCurrent(Handle<HwSwapChain> schDraw, Handle<HwSwapChain> schRead) {
    ASSERT_PRECONDITION_NON_FATAL(schDraw == schRead,
                                  "Metal driver does not support distinct draw/read swap chains.");
    auto* swapChain = handle_cast<MetalSwapChain>(mHandleMap, schDraw);
    mContext->currentSurface = swapChain;
}

void MetalDriver::commit(Handle<HwSwapChain> sch) {
    [mContext->currentCommandBuffer presentDrawable:mContext->currentDrawable];
    [mContext->currentCommandBuffer commit];
    mContext->currentDrawable = nil;
}

void MetalDriver::bindUniformBuffer(size_t index, Handle<HwUniformBuffer> ubh) {
    mContext->uniformState[index].updateState(UniformBufferState {
        .bound = true,
        .ubh = ubh,
        .offset = 0
    });
}

void MetalDriver::bindUniformBufferRange(size_t index, Handle<HwUniformBuffer> ubh,
        size_t offset, size_t size) {
    mContext->uniformState[index].updateState(UniformBufferState {
        .bound = true,
        .ubh = ubh,
        .offset = offset
    });
}

void MetalDriver::bindSamplers(size_t index, Handle<HwSamplerGroup> sbh) {
    auto sb = handle_cast<MetalSamplerGroup>(mHandleMap, sbh);
    mContext->samplerBindings[index] = sb;
}

void MetalDriver::insertEventMarker(const char* string, size_t len) {

}

void MetalDriver::pushGroupMarker(const char* string, size_t len) {

}

void MetalDriver::popGroupMarker(int dummy) {

}

void MetalDriver::readPixels(Handle<HwRenderTarget> src, uint32_t x, uint32_t y, uint32_t width,
        uint32_t height, PixelBufferDescriptor&& data) {

}

void MetalDriver::readStreamPixels(Handle<HwStream> sh, uint32_t x, uint32_t y, uint32_t width,
        uint32_t height, PixelBufferDescriptor&& data) {

}

void MetalDriver::blit(TargetBufferFlags buffers,
        Handle<HwRenderTarget> dst, backend::Viewport dstRect,
        Handle<HwRenderTarget> src, backend::Viewport srcRect,
        SamplerMagFilter filter) {
    ASSERT_POSTCONDITION(false, "Blitting not implemented.");
}

void MetalDriver::draw(backend::PipelineState ps, Handle<HwRenderPrimitive> rph) {
    ASSERT_PRECONDITION(mContext->currentCommandEncoder != nullptr,
            "Attempted to draw without a valid command encoder.");
    auto primitive = handle_cast<MetalRenderPrimitive>(mHandleMap, rph);
    auto program = handle_cast<MetalProgram>(mHandleMap, ps.program);
    const auto& rs = ps.rasterState;

    // Pipeline state
    metal::PipelineState pipelineState {
        .vertexFunction = program->vertexFunction,
        .fragmentFunction = program->fragmentFunction,
        .vertexDescription = primitive->vertexDescription,
        .colorAttachmentPixelFormat = mContext->currentSurfacePixelFormat,
        .depthAttachmentPixelFormat = mContext->currentDepthPixelFormat,
        .sampleCount = mContext->currentRenderTarget->getSamples(),
        .blendState = BlendState {
            .blendingEnabled = rs.hasBlending(),
            .rgbBlendOperation = getMetalBlendOperation(rs.blendEquationRGB),
            .alphaBlendOperation = getMetalBlendOperation(rs.blendEquationAlpha),
            .sourceRGBBlendFactor = getMetalBlendFactor(rs.blendFunctionSrcRGB),
            .sourceAlphaBlendFactor = getMetalBlendFactor(rs.blendFunctionSrcAlpha),
            .destinationRGBBlendFactor = getMetalBlendFactor(rs.blendFunctionDstRGB),
            .destinationAlphaBlendFactor = getMetalBlendFactor(rs.blendFunctionDstAlpha)
        }
    };
    mContext->pipelineState.updateState(pipelineState);
    if (mContext->pipelineState.stateChanged()) {
        id<MTLRenderPipelineState> pipeline =
                mContext->pipelineStateCache.getOrCreateState(pipelineState);
        assert(pipeline != nil);
        [mContext->currentCommandEncoder setRenderPipelineState:pipeline];
    }

    // Cull mode
    MTLCullMode cullMode = getMetalCullMode(rs.culling);
    mContext->cullModeState.updateState(cullMode);
    if (mContext->cullModeState.stateChanged()) {
        [mContext->currentCommandEncoder setCullMode:cullMode];
    }

    // Set the depth-stencil state, if a state change is needed.
    DepthStencilState depthState {
        .compareFunction = getMetalCompareFunction(rs.depthFunc),
        .depthWriteEnabled = rs.depthWrite,
    };
    mContext->depthStencilState.updateState(depthState);
    if (mContext->depthStencilState.stateChanged()) {
        id<MTLDepthStencilState> state =
                mContext->depthStencilStateCache.getOrCreateState(depthState);
        assert(state != nil);
        [mContext->currentCommandEncoder setDepthStencilState:state];
    }

    // Depth bias. Use a depth bias of 1.0 / 1.0 for the shadow pass.
    TargetBufferFlags clearFlags = (TargetBufferFlags) mContext->currentRenderPassFlags.clear;
    if ((clearFlags & TargetBufferFlags::SHADOW) == TargetBufferFlags::SHADOW) {
        [mContext->currentCommandEncoder setDepthBias:1.0f
                                         slopeScale:1.0f
                                              clamp:0.0];
    }
    if (ps.polygonOffset.constant != 0.0 || ps.polygonOffset.slope != 0.0) {
        [mContext->currentCommandEncoder setDepthBias:ps.polygonOffset.constant
                                         slopeScale:ps.polygonOffset.slope
                                              clamp:0.0];
    }

    // Bind any uniform buffers that have changed since the last draw call.
    for (uint32_t i = 0; i < VERTEX_BUFFER_START; i++) {
        auto& thisUniform = mContext->uniformState[i];
        if (thisUniform.stateChanged()) {
            const auto& uniformState = thisUniform.getState();
            if (!uniformState.bound) {
                continue;
            }

            const auto* uniform = handle_const_cast<MetalUniformBuffer>(mHandleMap,
                    uniformState.ubh);

            // We have no way of knowing which uniform buffers will be used by which shader stage
            // so for now, bind the uniform buffer to both the vertex and fragment stages.

            if (uniform->buffer) {
                [mContext->currentCommandEncoder setVertexBuffer:uniform->buffer
                                                        offset:uniformState.offset
                                                       atIndex:i];

                [mContext->currentCommandEncoder setFragmentBuffer:uniform->buffer
                                                          offset:uniformState.offset
                                                         atIndex:i];
            } else {
                assert(uniform->cpuBuffer);
                uint8_t* bytes = static_cast<uint8_t*>(uniform->cpuBuffer) + uniformState.offset;
                [mContext->currentCommandEncoder setVertexBytes:bytes
                                                       length:(uniform->size - uniformState.offset)
                                                      atIndex:i];
                [mContext->currentCommandEncoder setFragmentBytes:bytes
                                                         length:(uniform->size - uniformState.offset)
                                                        atIndex:i];
            }
        }
    }

    // Enumerate all the sampler buffers for the program and check which textures and samplers need
    // to be bound.

    id<MTLTexture> texturesToBind[SAMPLER_BINDING_COUNT] = {};
    id<MTLSamplerState> samplersToBind[SAMPLER_BINDING_COUNT] = {};

    enumerateSamplerGroups(program, [this, &texturesToBind, &samplersToBind](
            const SamplerGroup::Sampler* sampler,
            uint8_t binding) {
        const auto metalTexture = handle_const_cast<MetalTexture>(mHandleMap, sampler->t);
        texturesToBind[binding] = metalTexture->texture;

        id <MTLSamplerState> samplerState = mContext->samplerStateCache.getOrCreateState(sampler->s);
        samplersToBind[binding] = samplerState;
    });

    // Similar to uniforms, we can't tell which stage will use the textures / samplers, so bind
    // to both the vertex and fragment stages.

    NSRange range {
        .length = SAMPLER_BINDING_COUNT,
        .location = 0
    };
    [mContext->currentCommandEncoder setFragmentTextures:texturesToBind
                                             withRange:range];
    [mContext->currentCommandEncoder setVertexTextures:texturesToBind
                                           withRange:range];
    [mContext->currentCommandEncoder setFragmentSamplerStates:samplersToBind
                                                  withRange:range];
    [mContext->currentCommandEncoder setVertexSamplerStates:samplersToBind
                                                withRange:range];

    // Bind the vertex buffers.
    NSRange bufferRange = NSMakeRange(VERTEX_BUFFER_START, primitive->buffers.size());
    [mContext->currentCommandEncoder setVertexBuffers:primitive->buffers.data()
                                            offsets:primitive->offsets.data()
                                          withRange:bufferRange];

    MetalIndexBuffer* indexBuffer = primitive->indexBuffer;

    [mContext->currentCommandEncoder drawIndexedPrimitives:getMetalPrimitiveType(primitive->type)
                                              indexCount:primitive->count
                                               indexType:getIndexType(indexBuffer->elementSize)
                                             indexBuffer:indexBuffer->buffer
                                       indexBufferOffset:primitive->offset];
}

void MetalDriver::enumerateSamplerGroups(
        const MetalProgram* program,
        const std::function<void(const SamplerGroup::Sampler*, size_t)>& f) {
    for (uint8_t samplerGroupIdx = 0; samplerGroupIdx < SAMPLER_GROUP_COUNT; samplerGroupIdx++) {
        const auto& samplerGroup = program->samplerGroupInfo[samplerGroupIdx];
        if (samplerGroup.empty()) {
            continue;
        }
        const auto* metalSamplerGroup = mContext->samplerBindings[samplerGroupIdx];
        if (!metalSamplerGroup) {
            utils::slog.w << "Program has non-empty samplerGroup (index " << samplerGroupIdx <<
                    ") but has not bound any samplers." << utils::io::endl;
            continue;
        }
        SamplerGroup* sb = metalSamplerGroup->sb.get();
        assert(sb->getSize() == samplerGroup.size());
        size_t samplerIdx = 0;
        for (const auto& sampler : samplerGroup) {
            size_t bindingPoint = sampler.binding;
            const SamplerGroup::Sampler* boundSampler = sb->getSamplers() + samplerIdx;
            samplerIdx++;

            if (!boundSampler->t) {
                continue;
            }

            f(boundSampler, bindingPoint);
        }
    }
}

} // namespace metal

// explicit instantiation of the Dispatcher
template class ConcreteDispatcher<metal::MetalDriver>;

} // namespace backend
} // namespace filament

#pragma clang diagnostic pop
