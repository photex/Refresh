/* Refresh - a cross-platform hardware-accelerated graphics library with modern capabilities
 *
 * Copyright (c) 2020-2024 Evan Hemsley
 *
 * This software is provided 'as-is', without any express or implied warranty.
 * In no event will the authors be held liable for any damages arising from
 * the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 * claim that you wrote the original software. If you use this software in a
 * product, an acknowledgment in the product documentation would be
 * appreciated but is not required.
 *
 * 2. Altered source versions must be plainly marked as such, and must not be
 * misrepresented as being the original software.
 *
 * 3. This notice may not be removed or altered from any source distribution.
 *
 * Evan "cosmonaut" Hemsley <evan@moonside.games>
 *
 */

#if REFRESH_METAL

#include <Metal/Metal.h>
#include <QuartzCore/CoreAnimation.h>

#include "Refresh_driver.h"

 /* Defines */

#define METAL_MAX_BUFFER_COUNT 31
#define WINDOW_PROPERTY_DATA "Refresh_MetalWindowPropertyData"
#define UBO_BUFFER_SIZE 1048576 /* 1 MiB */

#define NOT_IMPLEMENTED SDL_assert(0 && "Not implemented!");

#define EXPAND_ARRAY_IF_NEEDED(arr, elementType, newCount, capacity, newCapacity)    \
    if (newCount >= capacity)                            \
    {                                        \
        capacity = newCapacity;                            \
        arr = (elementType*) SDL_realloc(                    \
            arr,                                \
            sizeof(elementType) * capacity                    \
        );                                    \
    }

#define TRACK_RESOURCE(resource, type, array, count, capacity) \
    Uint32 i; \
    \
    for (i = 0; i < commandBuffer->count; i += 1) \
    { \
        if (commandBuffer->array[i] == resource) \
        { \
            return; \
        } \
    } \
    \
    if (commandBuffer->count == commandBuffer->capacity) \
    { \
        commandBuffer->capacity += 1; \
        commandBuffer->array = SDL_realloc( \
            commandBuffer->array, \
            commandBuffer->capacity * sizeof(type) \
        ); \
    } \
    commandBuffer->array[commandBuffer->count] = resource; \
    commandBuffer->count += 1; \
    SDL_AtomicIncRef(&resource->referenceCount);

/* Forward Declarations */

static void METAL_Wait(Refresh_Renderer *driverData);
static void METAL_UnclaimWindow(
    Refresh_Renderer *driverData,
    SDL_Window *window
);

/* Conversions */

static MTLPixelFormat SDLToMetal_SurfaceFormat[] =
{
    MTLPixelFormatRGBA8Unorm,    /* R8G8B8A8 */
    MTLPixelFormatBGRA8Unorm,    /* B8G8R8A8 */
    MTLPixelFormatB5G6R5Unorm,    /* R5G6B5 */ /* FIXME: Swizzle? */
    MTLPixelFormatA1BGR5Unorm,    /* A1R5G5B5 */ /* FIXME: Swizzle? */
    MTLPixelFormatABGR4Unorm,    /* B4G4R4A4 */
    MTLPixelFormatRGB10A2Unorm,    /* A2R10G10B10 */
    MTLPixelFormatBGR10A2Unorm, /* A2B10G10R10 */
    MTLPixelFormatRG16Unorm,    /* R16G16 */
    MTLPixelFormatRGBA16Unorm,    /* R16G16B16A16 */
    MTLPixelFormatR8Unorm,        /* R8 */
    MTLPixelFormatA8Unorm,        /* A8 */
#ifdef SDL_PLATFORM_MACOS
    MTLPixelFormatBC1_RGBA,        /* BC1 */
    MTLPixelFormatBC2_RGBA,        /* BC2 */
    MTLPixelFormatBC3_RGBA,        /* BC3 */
    MTLPixelFormatBC7_RGBAUnorm,        /* BC7 */
#else
    MTLPixelFormatInvalid,        /* BC1 */
    MTLPixelFormatInvalid,        /* BC2 */
    MTLPixelFormatInvalid,        /* BC3 */
    MTLPixelFormatInvalid,        /* BC7 */
#endif
    MTLPixelFormatRG8Snorm,        /* R8G8_SNORM */
    MTLPixelFormatRGBA8Snorm,    /* R8G8B8A8_SNORM */
    MTLPixelFormatR16Float,        /* R16_SFLOAT */
    MTLPixelFormatRG16Float,    /* R16G16_SFLOAT */
    MTLPixelFormatRGBA16Float,    /* R16G16B16A16_SFLOAT */
    MTLPixelFormatR32Float,        /* R32_SFLOAT */
    MTLPixelFormatRG32Float,    /* R32G32_SFLOAT */
    MTLPixelFormatRGBA32Float,    /* R32G32B32A32_SFLOAT */
    MTLPixelFormatR8Uint,        /* R8_UINT */
    MTLPixelFormatRG8Uint,        /* R8G8_UINT */
    MTLPixelFormatRGBA8Uint,    /* R8G8B8A8_UINT */
    MTLPixelFormatR16Uint,        /* R16_UINT */
    MTLPixelFormatRG16Uint,    /* R16G16_UINT */
    MTLPixelFormatRGBA16Uint,    /* R16G16B16A16_UINT */
    MTLPixelFormatRGBA8Unorm_sRGB, /* R8G8B8A8_SRGB*/
    MTLPixelFormatBGRA8Unorm_sRGB, /* B8G8R8A8_SRGB */
#ifdef SDL_PLATFORM_MACOS
    MTLPixelFormatBC3_RGBA_sRGB, /* BC3_SRGB */
    MTLPixelFormatBC7_RGBAUnorm_sRGB, /* BC7_SRGB */
#else
    MTLPixelFormatInvalid, /* BC3_SRGB */
    MTLPixelFormatInvalid, /* BC7_SRGB */
#endif
    MTLPixelFormatDepth16Unorm,        /* D16_UNORM */
#ifdef SDL_PLATFORM_MACOS
    MTLPixelFormatDepth24Unorm_Stencil8,    /* D24_UNORM */
#else
    MTLPixelFormatInvalid,    /* D24_UNORM */
#endif
    MTLPixelFormatDepth32Float,        /* D32_SFLOAT */
#ifdef SDL_PLATFORM_MACOS
    MTLPixelFormatDepth24Unorm_Stencil8,    /* D24_UNORM_S8_UINT */
#else
    MTLPixelFormatInvalid,    /* D24_UNORM_S8_UINT */
#endif
    MTLPixelFormatDepth32Float_Stencil8,    /* D32_SFLOAT_S8_UINT */
};

static MTLVertexFormat SDLToMetal_VertexFormat[] =
{
    MTLVertexFormatUInt,    /* UINT */
    MTLVertexFormatFloat,	/* FLOAT */
    MTLVertexFormatFloat2,	/* VECTOR2 */
    MTLVertexFormatFloat3,	/* VECTOR3 */
    MTLVertexFormatFloat4,	/* VECTOR4 */
    MTLVertexFormatUChar4Normalized,	/* COLOR */
    MTLVertexFormatUChar4,	/* BYTE4 */
    MTLVertexFormatShort2,	/* SHORT2 */
    MTLVertexFormatShort4,	/* SHORT4 */
    MTLVertexFormatShort2Normalized,	/* NORMALIZEDSHORT2 */
    MTLVertexFormatShort4Normalized,	/* NORMALIZEDSHORT4 */
    MTLVertexFormatHalf2,	/* HALFVECTOR2 */
    MTLVertexFormatHalf4,	/* HALFVECTOR4 */
};

static MTLIndexType SDLToMetal_IndexType[] =
{
    MTLIndexTypeUInt16,	/* 16BIT */
    MTLIndexTypeUInt32,	/* 32BIT */
};

static MTLPrimitiveType SDLToMetal_PrimitiveType[] =
{
    MTLPrimitiveTypePoint,	        /* POINTLIST */
    MTLPrimitiveTypeLine,	        /* LINELIST */
    MTLPrimitiveTypeLineStrip,	    /* LINESTRIP */
    MTLPrimitiveTypeTriangle,	    /* TRIANGLELIST */
    MTLPrimitiveTypeTriangleStrip	/* TRIANGLESTRIP */
};

static MTLTriangleFillMode SDLToMetal_PolygonMode[] =
{
    MTLTriangleFillModeFill,	/* FILL */
    MTLTriangleFillModeLines,	/* LINE */
};

static MTLCullMode SDLToMetal_CullMode[] =
{
    MTLCullModeNone,	/* NONE */
    MTLCullModeFront,	/* FRONT */
    MTLCullModeBack,	/* BACK */
};

static MTLWinding SDLToMetal_FrontFace[] =
{
    MTLWindingCounterClockwise,	/* COUNTER_CLOCKWISE */
    MTLWindingClockwise,	/* CLOCKWISE */
};

static MTLBlendFactor SDLToMetal_BlendFactor[] =
{
    MTLBlendFactorZero,	                /* ZERO */
    MTLBlendFactorOne,	                /* ONE */
    MTLBlendFactorSourceColor,	        /* SRC_COLOR */
    MTLBlendFactorOneMinusSourceColor,	/* ONE_MINUS_SRC_COLOR */
    MTLBlendFactorDestinationColor,	    /* DST_COLOR */
    MTLBlendFactorOneMinusDestinationColor,	/* ONE_MINUS_DST_COLOR */
    MTLBlendFactorSourceAlpha,	        /* SRC_ALPHA */
    MTLBlendFactorOneMinusSourceAlpha,	/* ONE_MINUS_SRC_ALPHA */
    MTLBlendFactorDestinationAlpha,	    /* DST_ALPHA */
    MTLBlendFactorOneMinusDestinationAlpha,	/* ONE_MINUS_DST_ALPHA */
    MTLBlendFactorBlendColor,	        /* CONSTANT_COLOR */
    MTLBlendFactorOneMinusBlendColor,	/* ONE_MINUS_CONSTANT_COLOR */
    MTLBlendFactorSourceAlphaSaturated,	/* SRC_ALPHA_SATURATE */
};

static MTLBlendOperation SDLToMetal_BlendOp[] =
{
    MTLBlendOperationAdd,	/* ADD */
    MTLBlendOperationSubtract,	/* SUBTRACT */
    MTLBlendOperationReverseSubtract,	/* REVERSE_SUBTRACT */
    MTLBlendOperationMin,	/* MIN */
    MTLBlendOperationMax,	/* MAX */
};

static MTLCompareFunction SDLToMetal_CompareOp[] =
{
    MTLCompareFunctionNever,	    /* NEVER */
    MTLCompareFunctionLess,	        /* LESS */
    MTLCompareFunctionEqual,	    /* EQUAL */
    MTLCompareFunctionLessEqual,	/* LESS_OR_EQUAL */
    MTLCompareFunctionGreater,	    /* GREATER */
    MTLCompareFunctionNotEqual,	    /* NOT_EQUAL */
    MTLCompareFunctionGreaterEqual,	/* GREATER_OR_EQUAL */
    MTLCompareFunctionAlways,	    /* ALWAYS */
};

static MTLStencilOperation SDLToMetal_StencilOp[] =
{
    MTLStencilOperationKeep,	        /* KEEP */
    MTLStencilOperationZero,	        /* ZERO */
    MTLStencilOperationReplace,	        /* REPLACE */
    MTLStencilOperationIncrementClamp,	/* INCREMENT_AND_CLAMP */
    MTLStencilOperationDecrementClamp,	/* DECREMENT_AND_CLAMP */
    MTLStencilOperationInvert,	        /* INVERT */
    MTLStencilOperationIncrementWrap,	/* INCREMENT_AND_WRAP */
    MTLStencilOperationDecrementWrap,	/* DECREMENT_AND_WRAP */
};

static MTLSamplerAddressMode SDLToMetal_SamplerAddressMode[] =
{
    MTLSamplerAddressModeRepeat,	        /* REPEAT */
    MTLSamplerAddressModeMirrorRepeat,	    /* MIRRORED_REPEAT */
    MTLSamplerAddressModeClampToEdge,	    /* CLAMP_TO_EDGE */
    MTLSamplerAddressModeClampToBorderColor,/* CLAMP_TO_BORDER */
};

static MTLSamplerBorderColor SDLToMetal_BorderColor[] =
{
    MTLSamplerBorderColorTransparentBlack,	/* FLOAT_TRANSPARENT_BLACK */
    MTLSamplerBorderColorTransparentBlack,	/* INT_TRANSPARENT_BLACK */
    MTLSamplerBorderColorOpaqueBlack,	/* FLOAT_OPAQUE_BLACK */
    MTLSamplerBorderColorOpaqueBlack,	/* INT_OPAQUE_BLACK */
    MTLSamplerBorderColorOpaqueWhite,	/* FLOAT_OPAQUE_WHITE */
    MTLSamplerBorderColorOpaqueWhite,	/* INT_OPAQUE_WHITE */
};

static MTLSamplerMinMagFilter SDLToMetal_MinMagFilter[] =
{
    MTLSamplerMinMagFilterNearest,  /* NEAREST */
    MTLSamplerMinMagFilterLinear,   /* LINEAR */
};

static MTLSamplerMipFilter SDLToMetal_MipFilter[] =
{
    MTLSamplerMipFilterNearest,  /* NEAREST */
    MTLSamplerMipFilterLinear,   /* LINEAR */
};

static MTLLoadAction SDLToMetal_LoadOp[] =
{
    MTLLoadActionLoad,  /* LOAD */
    MTLLoadActionClear, /* CLEAR */
    MTLLoadActionDontCare,  /* DONT_CARE */
};

static MTLVertexStepFunction SDLToMetal_StepFunction[] =
{
    MTLVertexStepFunctionPerVertex,
    MTLVertexStepFunctionPerInstance,
};

static MTLStoreAction SDLToMetal_StoreOp(
    Refresh_StoreOp storeOp,
    SDL_bool isMultisample
) {
    if (isMultisample)
    {
        if (storeOp == REFRESH_STOREOP_STORE)
        {
            return MTLStoreActionStoreAndMultisampleResolve;
        }
        else
        {
            return MTLStoreActionMultisampleResolve;
        }
    }
    else
    {
        if (storeOp == REFRESH_STOREOP_STORE)
        {
            return MTLStoreActionStore;
        }
        else
        {
            return MTLStoreActionDontCare;
        }
    }
};

static MTLColorWriteMask SDLToMetal_ColorWriteMask(
    Refresh_ColorComponentFlagBits mask
) {
    MTLColorWriteMask result = 0;
    if (mask & REFRESH_COLORCOMPONENT_R_BIT)
    {
        result |= MTLColorWriteMaskRed;
    }
    if (mask & REFRESH_COLORCOMPONENT_G_BIT)
    {
        result |= MTLColorWriteMaskGreen;
    }
    if (mask & REFRESH_COLORCOMPONENT_B_BIT)
    {
        result |= MTLColorWriteMaskBlue;
    }
    if (mask & REFRESH_COLORCOMPONENT_A_BIT)
    {
        result |= MTLColorWriteMaskAlpha;
    }
    return result;
}

/* Structs */

typedef struct MetalTexture
{
    id<MTLTexture> handle;
    SDL_atomic_t referenceCount;
} MetalTexture;

typedef struct MetalTextureContainer
{
    Refresh_TextureCreateInfo createInfo;
    MetalTexture *activeTexture;
    SDL_bool canBeCycled;

    Uint32 textureCapacity;
    Uint32 textureCount;
    MetalTexture **textures;

    char *debugName;
} MetalTextureContainer;

typedef struct MetalFence
{
    SDL_atomic_t complete;
} MetalFence;

typedef struct MetalWindowData
{
    SDL_Window *window;
    SDL_MetalView view;
    CAMetalLayer *layer;
    id<CAMetalDrawable> drawable;
    MetalTexture texture;
    MetalTextureContainer textureContainer;
} MetalWindowData;

typedef struct MetalShader
{
    id<MTLLibrary> library;
    id<MTLFunction> function;
} MetalShader;

typedef struct MetalGraphicsPipeline
{
    id<MTLRenderPipelineState> handle;

    float blendConstants[4];
    Uint32 sampleMask;

    Refresh_RasterizerState rasterizerState;
    Refresh_PrimitiveType primitiveType;

    id<MTLDepthStencilState> depthStencilState;
    Uint32 stencilReference;

    MetalShader *vertexShader;
    MetalShader *fragmentShader;
} MetalGraphicsPipeline;

typedef struct MetalBuffer
{
    id<MTLBuffer> handle;
    Uint32 size;
    SDL_atomic_t referenceCount;
} MetalBuffer;

typedef struct MetalBufferContainer
{
    MetalBuffer *activeBuffer;

    Uint32 bufferCapacity;
    Uint32 bufferCount;
    MetalBuffer **buffers;

    char *debugName;
} MetalBufferContainer;

typedef struct MetalTransferBuffer
{
    id<MTLBuffer> stagingBuffer;
    Uint32 size;
    SDL_atomic_t referenceCount;
} MetalTransferBuffer;

typedef struct MetalTransferBufferContainer
{
    Refresh_TransferUsage usage;
    Refresh_TransferBufferMapFlags mapFlags;
    MetalTransferBuffer *activeBuffer;

    /* These are all the buffers that have been used by this container.
     * If the resource is bound and then updated with DISCARD, a new resource
     * will be added to this list.
     * These can be reused after they are submitted and command processing is complete.
     */
    Uint32 bufferCapacity;
    Uint32 bufferCount;
    MetalTransferBuffer **buffers;
} MetalTransferBufferContainer;

typedef struct MetalRenderer MetalRenderer;

typedef struct MetalCommandBuffer
{
    CommandBufferCommonHeader common;
    MetalRenderer *renderer;

    /* Native Handle */
    id<MTLCommandBuffer> handle;

    /* Window */
    MetalWindowData *windowData;

    /* Render Pass */
    id<MTLRenderCommandEncoder> renderEncoder;
    MetalGraphicsPipeline *graphicsPipeline;
    MetalBuffer *indexBuffer;
    Uint32 indexBufferOffset;
    Refresh_IndexElementSize indexElementSize;

    /* Copy Pass */
    id<MTLBlitCommandEncoder> blitEncoder;

    /* Fences */
    MetalFence *fence;
    SDL_bool autoReleaseFence;

    /* Reference Counting */
    MetalBuffer **usedBuffers;
    Uint32 usedBufferCount;
    Uint32 usedBufferCapacity;

    MetalTransferBuffer **usedTransferBuffers;
    Uint32 usedTransferBufferCount;
    Uint32 usedTransferBufferCapacity;

    MetalTexture **usedTextures;
    Uint32 usedTextureCount;
    Uint32 usedTextureCapacity;
} MetalCommandBuffer;

typedef struct MetalSampler
{
    id<MTLSamplerState> handle;
} MetalSampler;

struct MetalRenderer
{
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;

    SDL_bool debugMode;

    MetalWindowData **claimedWindows;
    Uint32 claimedWindowCount;
    Uint32 claimedWindowCapacity;

    MetalCommandBuffer **availableCommandBuffers;
    Uint32 availableCommandBufferCount;
    Uint32 availableCommandBufferCapacity;

    MetalCommandBuffer **submittedCommandBuffers;
    Uint32 submittedCommandBufferCount;
    Uint32 submittedCommandBufferCapacity;

    MetalFence **availableFences;
    Uint32 availableFenceCount;
    Uint32 availableFenceCapacity;

    MetalTransferBufferContainer **transferBufferContainersToDestroy;
    Uint32 transferBufferContainersToDestroyCount;
    Uint32 transferBufferContainersToDestroyCapacity;

    MetalBufferContainer **bufferContainersToDestroy;
    Uint32 bufferContainersToDestroyCount;
    Uint32 bufferContainersToDestroyCapacity;

    MetalTextureContainer **textureContainersToDestroy;
    Uint32 textureContainersToDestroyCount;
    Uint32 textureContainersToDestroyCapacity;

    SDL_mutex *submitLock;
    SDL_mutex *acquireCommandBufferLock;
    SDL_mutex *disposeLock;
    SDL_mutex *fenceLock;
    SDL_mutex *windowLock;
};

/* Helper Functions */

static Uint32 METAL_INTERNAL_GetVertexBufferIndex(Uint32 binding)
{
    return METAL_MAX_BUFFER_COUNT - 1 - binding;
}

/* FIXME: This should be moved into SDL_gpu_driver.h */
static inline Uint32 METAL_INTERNAL_NextHighestAlignment(
    Uint32 n,
    Uint32 align
) {
    return align * ((n + align - 1) / align);
}

/* Quit */

static void METAL_DestroyDevice(Refresh_Device *device)
{
    MetalRenderer *renderer = (MetalRenderer*) device->driverData;

    /* Flush any remaining GPU work... */
    METAL_Wait(device->driverData);

    /* Release the window data */
    for (Sint32 i = renderer->claimedWindowCount - 1; i >= 0; i -= 1)
    {
        METAL_UnclaimWindow(device->driverData, renderer->claimedWindows[i]->window);
    }
    SDL_free(renderer->claimedWindows);

    /* Release command buffer infrastructure */
    for (Uint32 i = 0; i < renderer->availableCommandBufferCount; i += 1)
    {
        MetalCommandBuffer *commandBuffer = renderer->availableCommandBuffers[i];
        SDL_free(commandBuffer->usedBuffers);
        SDL_free(commandBuffer->usedTransferBuffers);
        SDL_free(commandBuffer->usedTextures);
        SDL_free(commandBuffer);
    }
    SDL_free(renderer->availableCommandBuffers);
    SDL_free(renderer->submittedCommandBuffers);

    /* Release fence infrastructure */
    for (Uint32 i = 0; i < renderer->availableFenceCount; i += 1)
    {
        MetalFence *fence = renderer->availableFences[i];
        SDL_free(fence);
    }
    SDL_free(renderer->availableFences);

    /* Release the mutexes */
    SDL_DestroyMutex(renderer->submitLock);
    SDL_DestroyMutex(renderer->acquireCommandBufferLock);
    SDL_DestroyMutex(renderer->disposeLock);
    SDL_DestroyMutex(renderer->fenceLock);
    SDL_DestroyMutex(renderer->windowLock);

    /* Free the primary structures */
    SDL_free(renderer);
    SDL_free(device);
}

/* Resource tracking */

static void METAL_INTERNAL_TrackBuffer(
    MetalCommandBuffer *commandBuffer,
    MetalBuffer *buffer
) {
    TRACK_RESOURCE(
        buffer,
        MetalBuffer*,
        usedBuffers,
        usedBufferCount,
        usedBufferCapacity
    );
}

static void METAL_INTERNAL_TrackTransferBuffer(
    MetalCommandBuffer *commandBuffer,
    MetalTransferBuffer *buffer
) {
    TRACK_RESOURCE(
        buffer,
        MetalTransferBuffer*,
        usedTransferBuffers,
        usedTransferBufferCount,
        usedTransferBufferCapacity
    );
}

static void METAL_INTERNAL_TrackTexture(
    MetalCommandBuffer *commandBuffer,
    MetalTexture *texture
) {
    TRACK_RESOURCE(
        texture,
        MetalTexture*,
        usedTextures,
        usedTextureCount,
        usedTextureCapacity
    );
}

/* Disposal */

static void METAL_INTERNAL_DestroyTextureContainer(
    MetalTextureContainer *container
) {
    for (Uint32 i = 0; i < container->textureCount; i += 1)
    {
        SDL_free(container->textures[i]);
    }
    SDL_free(container->textures);
    SDL_free(container);
}

static void METAL_ReleaseTexture(
    Refresh_Renderer *driverData,
    Refresh_Texture *texture
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    MetalTextureContainer *container = (MetalTextureContainer*) texture;

    SDL_LockMutex(renderer->disposeLock);

    EXPAND_ARRAY_IF_NEEDED(
        renderer->textureContainersToDestroy,
        MetalTextureContainer*,
        renderer->textureContainersToDestroyCount + 1,
        renderer->textureContainersToDestroyCapacity,
        renderer->textureContainersToDestroyCapacity + 1
    );

    renderer->textureContainersToDestroy[
        renderer->textureContainersToDestroyCount
    ] = container;
    renderer->textureContainersToDestroyCount += 1;

    SDL_UnlockMutex(renderer->disposeLock);
}

static void METAL_ReleaseSampler(
    Refresh_Renderer *driverData,
    Refresh_Sampler *sampler
) {
    (void) driverData; /* used by other backends */
    MetalSampler *metalSampler = (MetalSampler*) sampler;
    SDL_free(metalSampler);
}

static void METAL_INTERNAL_DestroyBufferContainer(
    MetalBufferContainer *container
) {
    for (Uint32 i = 0; i < container->bufferCount; i += 1)
    {
        MetalBuffer *buffer = container->buffers[i];
        SDL_free(buffer);
    }
    SDL_free(container->buffers);
    SDL_free(container);
}

static void METAL_ReleaseBuffer(
    Refresh_Renderer *driverData,
    Refresh_Buffer *buffer
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    MetalBufferContainer *container = (MetalBufferContainer*) buffer;

    SDL_LockMutex(renderer->disposeLock);

    EXPAND_ARRAY_IF_NEEDED(
        renderer->bufferContainersToDestroy,
        MetalBufferContainer*,
        renderer->bufferContainersToDestroyCount + 1,
        renderer->bufferContainersToDestroyCapacity,
        renderer->bufferContainersToDestroyCapacity + 1
    );

    renderer->bufferContainersToDestroy[
        renderer->bufferContainersToDestroyCount
    ] = container;
    renderer->bufferContainersToDestroyCount += 1;

    SDL_UnlockMutex(renderer->disposeLock);
}

static void METAL_ReleaseTransferBuffer(
    Refresh_Renderer *driverData,
    Refresh_TransferBuffer *transferBuffer
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;

    SDL_LockMutex(renderer->disposeLock);

    EXPAND_ARRAY_IF_NEEDED(
        renderer->transferBufferContainersToDestroy,
        MetalTransferBufferContainer*,
        renderer->transferBufferContainersToDestroyCount + 1,
        renderer->transferBufferContainersToDestroyCapacity,
        renderer->transferBufferContainersToDestroyCapacity + 1
    );

    renderer->transferBufferContainersToDestroy[
        renderer->transferBufferContainersToDestroyCount
    ] = (MetalTransferBufferContainer*) transferBuffer;
    renderer->transferBufferContainersToDestroyCount += 1;

    SDL_UnlockMutex(renderer->disposeLock);
}

static void METAL_INTERNAL_DestroyTransferBufferContainer(
    MetalTransferBufferContainer *transferBufferContainer
) {
    for (Uint32 i = 0; i < transferBufferContainer->bufferCount; i += 1)
    {
        SDL_free(transferBufferContainer->buffers[i]);
    }
    SDL_free(transferBufferContainer->buffers);
}

static void METAL_ReleaseShader(
    Refresh_Renderer *driverData,
    Refresh_Shader *shader
) {
    (void) driverData; /* used by other backends */
    MetalShader *metalShader = (MetalShader*) shader;
    SDL_free(metalShader);
}

static void METAL_ReleaseComputePipeline(
    Refresh_Renderer *driverData,
    Refresh_ComputePipeline *computePipeline
) {
    NOT_IMPLEMENTED
}

static void METAL_ReleaseGraphicsPipeline(
    Refresh_Renderer *driverData,
    Refresh_GraphicsPipeline *graphicsPipeline
) {
    (void) driverData; /* used by other backends */
    MetalGraphicsPipeline *metalGraphicsPipeline = (MetalGraphicsPipeline*) graphicsPipeline;
    /* TODO: Tear down resource layout structure */
    SDL_free(metalGraphicsPipeline);
}

static void METAL_ReleaseOcclusionQuery(
    Refresh_Renderer *renderer,
    Refresh_OcclusionQuery *query
) {
    NOT_IMPLEMENTED
}

/* Pipeline Creation */

static Refresh_ComputePipeline* METAL_CreateComputePipeline(
    Refresh_Renderer *driverData,
    Refresh_ComputePipelineCreateInfo *pipelineCreateInfo
) {
    NOT_IMPLEMENTED
    return NULL;
}

static Refresh_GraphicsPipeline* METAL_CreateGraphicsPipeline(
    Refresh_Renderer *driverData,
    Refresh_GraphicsPipelineCreateInfo *pipelineCreateInfo
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    MetalShader *vertexShader = (MetalShader*) pipelineCreateInfo->vertexShader;
    MetalShader *fragmentShader = (MetalShader*) pipelineCreateInfo->fragmentShader;
    MTLRenderPipelineDescriptor *pipelineDescriptor;
    Refresh_ColorAttachmentBlendState *blendState;
    MTLVertexDescriptor *vertexDescriptor;
    Uint32 binding;
    MTLDepthStencilDescriptor *depthStencilDescriptor;
    MTLStencilDescriptor *frontStencilDescriptor = NULL;
    MTLStencilDescriptor *backStencilDescriptor = NULL;
    id<MTLDepthStencilState> depthStencilState = nil;
    id<MTLRenderPipelineState> pipelineState = nil;
    NSError *error = NULL;
    MetalGraphicsPipeline *result = NULL;

    pipelineDescriptor = [MTLRenderPipelineDescriptor new];

    /* Blend */

    for (Uint32 i = 0; i < pipelineCreateInfo->attachmentInfo.colorAttachmentCount; i += 1)
    {
        blendState = &pipelineCreateInfo->attachmentInfo.colorAttachmentDescriptions[i].blendState;

        pipelineDescriptor.colorAttachments[i].pixelFormat = SDLToMetal_SurfaceFormat[
            pipelineCreateInfo->attachmentInfo.colorAttachmentDescriptions[i].format
        ];
        pipelineDescriptor.colorAttachments[i].writeMask = SDLToMetal_ColorWriteMask(blendState->colorWriteMask);
        pipelineDescriptor.colorAttachments[i].blendingEnabled = blendState->blendEnable;
        pipelineDescriptor.colorAttachments[i].rgbBlendOperation = SDLToMetal_BlendOp[blendState->colorBlendOp];
        pipelineDescriptor.colorAttachments[i].alphaBlendOperation = SDLToMetal_BlendOp[blendState->alphaBlendOp];
        pipelineDescriptor.colorAttachments[i].sourceRGBBlendFactor = SDLToMetal_BlendFactor[blendState->srcColorBlendFactor];
        pipelineDescriptor.colorAttachments[i].sourceAlphaBlendFactor = SDLToMetal_BlendFactor[blendState->srcAlphaBlendFactor];
        pipelineDescriptor.colorAttachments[i].destinationRGBBlendFactor = SDLToMetal_BlendFactor[blendState->dstColorBlendFactor];
        pipelineDescriptor.colorAttachments[i].destinationAlphaBlendFactor = SDLToMetal_BlendFactor[blendState->dstAlphaBlendFactor];
    }

    /* FIXME: Multisample */

    /* Depth Stencil */

    /* FIXME: depthTestEnable? depth min/max? */
    if (pipelineCreateInfo->attachmentInfo.hasDepthStencilAttachment)
    {
        if (IsStencilFormat(pipelineCreateInfo->attachmentInfo.depthStencilFormat))
        {
            pipelineDescriptor.stencilAttachmentPixelFormat = SDLToMetal_SurfaceFormat[pipelineCreateInfo->attachmentInfo.depthStencilFormat];

            frontStencilDescriptor = [MTLStencilDescriptor new];
            frontStencilDescriptor.stencilCompareFunction = SDLToMetal_CompareOp[pipelineCreateInfo->depthStencilState.frontStencilState.compareOp];
            frontStencilDescriptor.stencilFailureOperation = SDLToMetal_StencilOp [pipelineCreateInfo->depthStencilState.frontStencilState.failOp];
            frontStencilDescriptor.depthStencilPassOperation = SDLToMetal_StencilOp[pipelineCreateInfo->depthStencilState.frontStencilState.passOp];
            frontStencilDescriptor.depthFailureOperation = SDLToMetal_StencilOp[pipelineCreateInfo->depthStencilState.frontStencilState.depthFailOp];
            frontStencilDescriptor.readMask = pipelineCreateInfo->depthStencilState.compareMask;
            frontStencilDescriptor.writeMask = pipelineCreateInfo->depthStencilState.writeMask;

            backStencilDescriptor = [MTLStencilDescriptor new];
            backStencilDescriptor.stencilCompareFunction = SDLToMetal_CompareOp[pipelineCreateInfo->depthStencilState.backStencilState.compareOp];
            backStencilDescriptor.stencilFailureOperation = SDLToMetal_StencilOp [pipelineCreateInfo->depthStencilState.backStencilState.failOp];
            backStencilDescriptor.depthStencilPassOperation = SDLToMetal_StencilOp[pipelineCreateInfo->depthStencilState.backStencilState.passOp];
            backStencilDescriptor.depthFailureOperation = SDLToMetal_StencilOp[pipelineCreateInfo->depthStencilState.backStencilState.depthFailOp];
            backStencilDescriptor.readMask = pipelineCreateInfo->depthStencilState.compareMask;
            backStencilDescriptor.writeMask = pipelineCreateInfo->depthStencilState.writeMask;
        }

        pipelineDescriptor.depthAttachmentPixelFormat = SDLToMetal_SurfaceFormat[pipelineCreateInfo->attachmentInfo.depthStencilFormat];

        depthStencilDescriptor = [MTLDepthStencilDescriptor new];
        depthStencilDescriptor.depthCompareFunction = SDLToMetal_CompareOp[pipelineCreateInfo->depthStencilState.compareOp];
        depthStencilDescriptor.depthWriteEnabled = pipelineCreateInfo->depthStencilState.depthWriteEnable;
        depthStencilDescriptor.frontFaceStencil = frontStencilDescriptor;
        depthStencilDescriptor.backFaceStencil = backStencilDescriptor;

        depthStencilState = [renderer->device newDepthStencilStateWithDescriptor:depthStencilDescriptor];
    }

    /* Shaders */

    pipelineDescriptor.vertexFunction = vertexShader->function;
    pipelineDescriptor.fragmentFunction = fragmentShader->function;

    /* Vertex Descriptor */

    if (pipelineCreateInfo->vertexInputState.vertexBindingCount > 0)
    {
        vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];

        for (Uint32 i = 0; i < pipelineCreateInfo->vertexInputState.vertexAttributeCount; i += 1)
        {
            Uint32 loc = pipelineCreateInfo->vertexInputState.vertexAttributes[i].location;
            vertexDescriptor.attributes[loc].format = SDLToMetal_VertexFormat[pipelineCreateInfo->vertexInputState.vertexAttributes[i].format];
            vertexDescriptor.attributes[loc].offset = pipelineCreateInfo->vertexInputState.vertexAttributes[i].offset;
            vertexDescriptor.attributes[loc].bufferIndex = METAL_INTERNAL_GetVertexBufferIndex(pipelineCreateInfo->vertexInputState.vertexAttributes[i].binding);
        }

        for (Uint32 i = 0; i < pipelineCreateInfo->vertexInputState.vertexBindingCount; i += 1)
        {
            binding = METAL_INTERNAL_GetVertexBufferIndex(pipelineCreateInfo->vertexInputState.vertexBindings[i].binding);
            vertexDescriptor.layouts[binding].stepFunction = SDLToMetal_StepFunction[pipelineCreateInfo->vertexInputState.vertexBindings[i].inputRate];
            vertexDescriptor.layouts[binding].stride = pipelineCreateInfo->vertexInputState.vertexBindings[i].stride;
        }

        pipelineDescriptor.vertexDescriptor = vertexDescriptor;
    }

    /* Resource Layout */

    /* FIXME */

    /* Create the graphics pipeline */

    pipelineState = [renderer->device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if (error != NULL)
    {
        SDL_LogError(
            SDL_LOG_CATEGORY_APPLICATION,
            "Creating render pipeline failed: %s", [[error description] UTF8String]
        );
        return NULL;
    }

    result = SDL_malloc(sizeof(MetalGraphicsPipeline));
    result->handle = pipelineState;
    result->blendConstants[0] = pipelineCreateInfo->blendConstants[0];
    result->blendConstants[1] = pipelineCreateInfo->blendConstants[1];
    result->blendConstants[2] = pipelineCreateInfo->blendConstants[2];
    result->blendConstants[3] = pipelineCreateInfo->blendConstants[3];
    result->sampleMask = pipelineCreateInfo->multisampleState.sampleMask;
    result->depthStencilState = depthStencilState;
    result->stencilReference = pipelineCreateInfo->depthStencilState.reference;
    result->rasterizerState = pipelineCreateInfo->rasterizerState;
    result->primitiveType = pipelineCreateInfo->primitiveType;
    return (Refresh_GraphicsPipeline*) result;
}

/* Debug Naming */

static void METAL_INTERNAL_SetBufferName(
    MetalRenderer *renderer,
    MetalBuffer *buffer,
    const char *text
) {
    if (renderer->debugMode)
    {
        NOT_IMPLEMENTED
    }
}

static void METAL_SetBufferName(
    Refresh_Renderer *driverData,
    Refresh_Buffer *buffer,
    const char *text
) {
    NOT_IMPLEMENTED
}

static void METAL_INTERNAL_SetTextureName(
    MetalRenderer *renderer,
    MetalTexture *texture,
    const char *text
) {
    if (renderer->debugMode)
    {
        NOT_IMPLEMENTED
    }
}

static void METAL_SetTextureName(
    Refresh_Renderer *driverData,
    Refresh_Texture *texture,
    const char *text
) {
    NOT_IMPLEMENTED
}

static void METAL_SetStringMarker(
    Refresh_CommandBuffer *commandBuffer,
    const char *text
) {
    NOT_IMPLEMENTED
}

/* Resource Creation */

static Refresh_Sampler* METAL_CreateSampler(
    Refresh_Renderer *driverData,
    Refresh_SamplerCreateInfo *samplerCreateInfo
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    MTLSamplerDescriptor *samplerDesc = [MTLSamplerDescriptor new];
    id<MTLSamplerState> sampler;
    MetalSampler *metalSampler;

    samplerDesc.rAddressMode = SDLToMetal_SamplerAddressMode[samplerCreateInfo->addressModeU];
    samplerDesc.sAddressMode = SDLToMetal_SamplerAddressMode[samplerCreateInfo->addressModeV];
    samplerDesc.tAddressMode = SDLToMetal_SamplerAddressMode[samplerCreateInfo->addressModeW];
    samplerDesc.borderColor = SDLToMetal_BorderColor[samplerCreateInfo->borderColor];
    samplerDesc.minFilter = SDLToMetal_MinMagFilter[samplerCreateInfo->minFilter];
    samplerDesc.magFilter = SDLToMetal_MinMagFilter[samplerCreateInfo->magFilter];
    samplerDesc.mipFilter = SDLToMetal_MipFilter[samplerCreateInfo->mipmapMode]; /* FIXME: Is this right with non-mipmapped samplers? */
    samplerDesc.lodMinClamp = samplerCreateInfo->minLod;
    samplerDesc.lodMaxClamp = samplerCreateInfo->maxLod;
    samplerDesc.maxAnisotropy = (samplerCreateInfo->anisotropyEnable) ? samplerCreateInfo->maxAnisotropy : 1;
    samplerDesc.compareFunction = (samplerCreateInfo->compareEnable) ? SDLToMetal_CompareOp[samplerCreateInfo->compareOp] : MTLCompareFunctionAlways;

    sampler = [renderer->device newSamplerStateWithDescriptor:samplerDesc];
    if (sampler == NULL)
    {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to create sampler");
        return NULL;
    }

    metalSampler = (MetalSampler*) SDL_malloc(sizeof(MetalSampler));
    metalSampler->handle = sampler;
    return (Refresh_Sampler*) metalSampler;
}

static Refresh_Shader* METAL_CreateShader(
    Refresh_Renderer *driverData,
    Refresh_ShaderCreateInfo *shaderCreateInfo
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;;
    id<MTLLibrary> library;
    NSError *error;
    dispatch_data_t data;
    id<MTLFunction> function;
    MetalShader *result;

    if (shaderCreateInfo->format == REFRESH_SHADERFORMAT_MSL)
    {
        library = [renderer->device
            newLibraryWithSource:@((const char*) shaderCreateInfo->code)
            options:nil /* FIXME: Do we need any compile options? */
            error:&error];
    }
    else if (shaderCreateInfo->format == REFRESH_SHADERFORMAT_METALLIB)
    {
        data = dispatch_data_create(
            shaderCreateInfo->code,
            shaderCreateInfo->codeSize,
            dispatch_get_global_queue(0, 0),
            ^{} /* FIXME: is this right? */
        );
        library = [renderer->device newLibraryWithData:data error:&error];
    }
    else
    {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Incompatible shader format for Metal");
        return NULL;
    }

    if (error != NULL)
    {
        SDL_LogError(
            SDL_LOG_CATEGORY_APPLICATION,
            "Creating MTLLibrary failed: %s",
                [[error description] cStringUsingEncoding:[NSString defaultCStringEncoding]]
        );
        return NULL;
    }

    function = [library newFunctionWithName:@(shaderCreateInfo->entryPointName)];
    if (function == nil)
    {
        SDL_LogError(
            SDL_LOG_CATEGORY_APPLICATION,
            "Creating MTLFunction failed"
        );
        return NULL;
    }

    result = SDL_malloc(sizeof(MetalShader));
    result->library = library;
    result->function = function;
    return (Refresh_Shader*) result;
}

static MetalTexture* METAL_INTERNAL_CreateTexture(
  MetalRenderer *renderer,
  Refresh_TextureCreateInfo *textureCreateInfo
) {
    MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor new];
    id<MTLTexture> texture;
    MetalTexture *metalTexture;

    /* FIXME: MSAA? */
    if (textureCreateInfo->depth > 1)
    {
        textureDescriptor.textureType = MTLTextureType3D;
    }
    else if (textureCreateInfo->isCube)
    {
        textureDescriptor.textureType = MTLTextureTypeCube;
    }
    else
    {
        textureDescriptor.textureType = MTLTextureType2D;
    }

    textureDescriptor.pixelFormat = SDLToMetal_SurfaceFormat[textureCreateInfo->format];
    textureDescriptor.width = textureCreateInfo->width;
    textureDescriptor.height = textureCreateInfo->height;
    textureDescriptor.depth = textureCreateInfo->depth;
    textureDescriptor.mipmapLevelCount = textureCreateInfo->levelCount;
    textureDescriptor.sampleCount = 1; /* FIXME */
    textureDescriptor.arrayLength = textureCreateInfo->layerCount; /* FIXME: Is this used outside of cubes? */
    textureDescriptor.resourceOptions = MTLResourceCPUCacheModeDefaultCache | MTLResourceStorageModePrivate | MTLResourceHazardTrackingModeDefault;
    textureDescriptor.allowGPUOptimizedContents = true;

    textureDescriptor.usage = 0;
    if (textureCreateInfo->usageFlags & (REFRESH_TEXTUREUSAGE_COLOR_TARGET_BIT | REFRESH_TEXTUREUSAGE_DEPTH_STENCIL_TARGET_BIT))
    {
        textureDescriptor.usage |= MTLTextureUsageRenderTarget;
    }
    if (textureCreateInfo->usageFlags & REFRESH_TEXTUREUSAGE_SAMPLER_BIT)
    {
        textureDescriptor.usage |= MTLTextureUsageShaderRead;
    }
    if (textureCreateInfo->usageFlags & REFRESH_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE_BIT)
    {
        textureDescriptor.usage |= MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    }
    /* FIXME: Other usages! */

    texture = [renderer->device newTextureWithDescriptor:textureDescriptor];
    if (texture == NULL)
    {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to create MTLTexture!");
        return NULL;
    }

    metalTexture = (MetalTexture*) SDL_malloc(sizeof(MetalTexture));
    metalTexture->handle = texture;
    return metalTexture;
}

static Refresh_Texture* METAL_CreateTexture(
    Refresh_Renderer *driverData,
    Refresh_TextureCreateInfo *textureCreateInfo
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    MetalTextureContainer *container;
    MetalTexture *texture;

    texture = METAL_INTERNAL_CreateTexture(
        renderer,
        textureCreateInfo
    );

    if (texture == NULL)
    {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to create texture!");
        return NULL;
    }

    container = SDL_malloc(sizeof(MetalTextureContainer));
    container->canBeCycled = 1;
    container->createInfo = *textureCreateInfo;
    container->activeTexture = texture;
    container->textureCapacity = 1;
    container->textureCount = 1;
    container->textures = SDL_malloc(
        container->textureCapacity * sizeof(MetalTexture*)
    );
    container->textures[0] = texture;
    container->debugName = NULL;

    return (Refresh_Texture*) container;
}

static void METAL_INTERNAL_CycleActiveTexture(
    MetalRenderer *renderer,
    MetalTextureContainer *container
) {
    for (Uint32 i = 0; i < container->textureCount; i += 1)
    {
        container->activeTexture = container->textures[i];
        return;
    }

    EXPAND_ARRAY_IF_NEEDED(
        container->textures,
        MetalTexture*,
        container->textureCount + 1,
        container->textureCapacity,
        container->textureCapacity + 1
    );

    container->textures[container->textureCount] = METAL_INTERNAL_CreateTexture(
        renderer,
        &container->createInfo
    );
    container->textureCount += 1;

    container->activeTexture = container->textures[container->textureCount - 1];

    if (renderer->debugMode && container->debugName != NULL)
    {
        METAL_INTERNAL_SetTextureName(
            renderer,
            container->activeTexture,
            container->debugName
        );
    }
}

static MetalTexture* METAL_INTERNAL_PrepareTextureForWrite(
     MetalRenderer *renderer,
     MetalTextureContainer *container,
     SDL_bool cycle
) {
    if (cycle && container->canBeCycled)
    {
        METAL_INTERNAL_CycleActiveTexture(renderer, container);
    }
    return container->activeTexture;
}

static MetalBuffer* METAL_INTERNAL_CreateBuffer(
    MetalRenderer *renderer,
    Uint32 sizeInBytes
) {
    id<MTLBuffer> bufferHandle;
    MetalBuffer *metalBuffer;

    /* Storage buffers have to be 4-aligned, so might as well align them all */
    sizeInBytes = METAL_INTERNAL_NextHighestAlignment(sizeInBytes, 4);

    bufferHandle = [renderer->device newBufferWithLength:sizeInBytes options:MTLResourceStorageModePrivate];
    if (bufferHandle == NULL)
    {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Could not create buffer");
        return NULL;
    }

    metalBuffer = SDL_malloc(sizeof(MetalBuffer));
    metalBuffer->handle = bufferHandle;
    metalBuffer->size = sizeInBytes;
    SDL_AtomicSet(&metalBuffer->referenceCount, 0);

    return metalBuffer;
}

static Refresh_Buffer* METAL_CreateBuffer(
    Refresh_Renderer *driverData,
    Refresh_BufferUsageFlags usageFlags,
    Uint32 sizeInBytes
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    MetalBuffer *buffer;
    MetalBufferContainer *container;

    buffer = METAL_INTERNAL_CreateBuffer(
        renderer,
        sizeInBytes
    );

    if (buffer == NULL)
    {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to create buffer!");
        return NULL;
    }

    container = SDL_malloc(sizeof(MetalBufferContainer));
    container->activeBuffer = buffer;
    container->bufferCapacity = 1;
    container->bufferCount = 1;
    container->buffers = SDL_malloc(
        container->bufferCapacity * sizeof(MetalBuffer*)
    );
    container->buffers[0] = container->activeBuffer;
    container->debugName = NULL;

    return (Refresh_Buffer*) container;
}

static void METAL_INTERNAL_CycleActiveBuffer(
    MetalRenderer *renderer,
    MetalBufferContainer *container
) {
    Uint32 size = container->activeBuffer->size;

    for (Uint32 i = 0; i < container->bufferCount; i += 1)
    {
        if (SDL_AtomicGet(&container->buffers[i]->referenceCount) == 0)
        {
            container->activeBuffer = container->buffers[i];
            return;
        }
    }

    EXPAND_ARRAY_IF_NEEDED(
        container->buffers,
        MetalBuffer*,
        container->bufferCount + 1,
        container->bufferCapacity,
        container->bufferCapacity + 1
    );

    container->buffers[container->bufferCount] = METAL_INTERNAL_CreateBuffer(
        renderer,
        size
    );
    container->bufferCount += 1;

    container->activeBuffer = container->buffers[container->bufferCount - 1];

    if (renderer->debugMode && container->debugName != NULL)
    {
        METAL_INTERNAL_SetBufferName(
            renderer,
            container->activeBuffer,
            container->debugName
        );
    }
}

static MetalBuffer* METAL_INTERNAL_PrepareBufferForWrite(
    MetalRenderer *renderer,
    MetalBufferContainer *container,
    SDL_bool cycle
) {
    if (cycle && SDL_AtomicGet(&container->activeBuffer->referenceCount) > 0)
    {
        METAL_INTERNAL_CycleActiveBuffer(
            renderer,
            container
        );
    }

    return container->activeBuffer;
}

static MetalTransferBuffer* METAL_INTERNAL_CreateTransferBuffer(
    MetalRenderer *renderer,
    Uint32 sizeInBytes,
    int writeOnly
) {
    id<MTLBuffer> stagingBuffer = nil;
    MetalTransferBuffer *transferBuffer;

    if (writeOnly)
    {
        stagingBuffer = [renderer->device newBufferWithLength:sizeInBytes options:MTLResourceCPUCacheModeWriteCombined];
    }
    else
    {
        stagingBuffer = [renderer->device newBufferWithLength:sizeInBytes options:MTLResourceCPUCacheModeDefaultCache];
    }
    if (stagingBuffer == nil)
    {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Could not create transfer buffer");
        return NULL;
    }

    transferBuffer = SDL_malloc(sizeof(MetalTransferBuffer));
    transferBuffer->stagingBuffer = stagingBuffer;
    transferBuffer->size = sizeInBytes;
    SDL_AtomicSet(&transferBuffer->referenceCount, 0);

    return transferBuffer;
}

/* This actually returns a container handle so we can rotate buffers on Cycle. */
static Refresh_TransferBuffer* METAL_CreateTransferBuffer(
    Refresh_Renderer *driverData,
    Refresh_TransferUsage usage,
    Refresh_TransferBufferMapFlags mapFlags,
    Uint32 sizeInBytes
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    MetalTransferBufferContainer *container = SDL_malloc(sizeof(MetalTransferBufferContainer));

    container->usage = usage;
    container->mapFlags = mapFlags;
    container->bufferCapacity = 1;
    container->bufferCount = 1;
    container->buffers = SDL_malloc(
        container->bufferCapacity * sizeof(MetalTransferBuffer*)
    );

    container->buffers[0] = METAL_INTERNAL_CreateTransferBuffer(
        renderer,
        sizeInBytes,
        (mapFlags & REFRESH_TRANSFER_MAP_WRITE) && !(mapFlags & REFRESH_TRANSFER_MAP_READ)
    );

    container->activeBuffer = container->buffers[0];

    return (Refresh_TransferBuffer*) container;
}

static void METAL_INTERNAL_CycleActiveTransferBuffer(
    MetalRenderer *renderer,
    MetalTransferBufferContainer *container
) {
    Uint32 size = container->activeBuffer->size;

    for (Uint32 i = 0; i < container->bufferCount; i += 1)
    {
        if (SDL_AtomicGet(&container->buffers[i]->referenceCount) == 0)
        {
            container->activeBuffer = container->buffers[i];
            return;
        }
    }

    EXPAND_ARRAY_IF_NEEDED(
        container->buffers,
        MetalTransferBuffer*,
        container->bufferCount + 1,
        container->bufferCapacity,
        container->bufferCapacity + 1
    );

    container->buffers[container->bufferCount] = METAL_INTERNAL_CreateTransferBuffer(
        renderer,
        size,
        (container->mapFlags & REFRESH_TRANSFER_MAP_WRITE) && !(container->mapFlags & REFRESH_TRANSFER_MAP_READ)
    );
    container->bufferCount += 1;

    container->activeBuffer = container->buffers[container->bufferCount - 1];
}

/* TransferBuffer Data */

static void METAL_MapTransferBuffer(
    Refresh_Renderer *driverData,
    Refresh_TransferBuffer *transferBuffer,
    SDL_bool cycle,
    void **ppData
) {
    NOT_IMPLEMENTED
}

static void METAL_UnmapTransferBuffer(
    Refresh_Renderer *driverData,
    Refresh_TransferBuffer *transferBuffer
) {
    NOT_IMPLEMENTED
}

static void METAL_SetTransferData(
    Refresh_Renderer *driverData,
    void* data,
    Refresh_TransferBuffer *transferBuffer,
    Refresh_BufferCopy *copyParams,
    SDL_bool cycle
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    MetalTransferBufferContainer *container = (MetalTransferBufferContainer*) transferBuffer;
    MetalTransferBuffer *buffer = container->activeBuffer;

    /* Rotate the transfer buffer if necessary */
    if (cycle && SDL_AtomicGet(&container->activeBuffer->referenceCount) > 0)
    {
        METAL_INTERNAL_CycleActiveTransferBuffer(
            renderer,
            container
        );
        buffer = container->activeBuffer;
    }

    SDL_memcpy(
        ((Uint8*) buffer->stagingBuffer.contents) + copyParams->dstOffset,
        ((Uint8*) data) + copyParams->srcOffset,
        copyParams->size
    );

#ifdef SDL_PLATFORM_MACOS
    if (buffer->stagingBuffer.storageMode == MTLStorageModeManaged)
    {
        [buffer->stagingBuffer didModifyRange:NSMakeRange(copyParams->dstOffset, copyParams->size)];
    }
#endif
}

static void METAL_GetTransferData(
    Refresh_Renderer *driverData,
    Refresh_TransferBuffer *transferBuffer,
    void* data,
    Refresh_BufferCopy *copyParams
) {
    NOT_IMPLEMENTED
}

/* Copy Pass */

static void METAL_BeginCopyPass(
    Refresh_CommandBuffer *commandBuffer
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    metalCommandBuffer->blitEncoder = [metalCommandBuffer->handle blitCommandEncoder];
}

static void METAL_UploadToTexture(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_TransferBuffer *transferBuffer,
    Refresh_TextureRegion *textureRegion,
    Refresh_BufferImageCopy *copyParams,
    SDL_bool cycle
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    MetalRenderer *renderer = metalCommandBuffer->renderer;
    MetalTransferBufferContainer *metalTransferBufferContainer = (MetalTransferBufferContainer*) transferBuffer;
    MetalTextureContainer *metalTextureContainer = (MetalTextureContainer*) textureRegion->textureSlice.texture;

    MetalTexture *metalTexture = METAL_INTERNAL_PrepareTextureForWrite(renderer, metalTextureContainer, cycle);

    [metalCommandBuffer->blitEncoder
     copyFromBuffer:metalTransferBufferContainer->activeBuffer->stagingBuffer
     sourceOffset:copyParams->bufferOffset
     sourceBytesPerRow:BytesPerRow(textureRegion->w, metalTextureContainer->createInfo.format)
     sourceBytesPerImage:BytesPerImage(textureRegion->w, textureRegion->h, metalTextureContainer->createInfo.format)
     sourceSize:MTLSizeMake(textureRegion->w, textureRegion->h, textureRegion->d)
     toTexture:metalTexture->handle
     destinationSlice:textureRegion->textureSlice.layer
     destinationLevel:textureRegion->textureSlice.mipLevel
     destinationOrigin:MTLOriginMake(textureRegion->x, textureRegion->y, textureRegion->z)];

    METAL_INTERNAL_TrackTexture(metalCommandBuffer, metalTexture);
    METAL_INTERNAL_TrackTransferBuffer(metalCommandBuffer, metalTransferBufferContainer->activeBuffer);
}

static void METAL_UploadToBuffer(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_TransferBuffer *transferBuffer,
    Refresh_Buffer *buffer,
    Refresh_BufferCopy *copyParams,
    SDL_bool cycle
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    MetalRenderer *renderer = metalCommandBuffer->renderer;
    MetalTransferBufferContainer *metalTransferContainer = (MetalTransferBufferContainer*) transferBuffer;
    MetalBufferContainer *metalBufferContainer = (MetalBufferContainer*) buffer;

    MetalBuffer *metalBuffer = METAL_INTERNAL_PrepareBufferForWrite(
            renderer,
            metalBufferContainer,
            cycle
    );

    [metalCommandBuffer->blitEncoder
     copyFromBuffer:metalTransferContainer->activeBuffer->stagingBuffer
     sourceOffset:copyParams->srcOffset
     toBuffer:metalBuffer->handle
     destinationOffset:copyParams->dstOffset
     size:copyParams->size];

    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalBuffer);
    METAL_INTERNAL_TrackTransferBuffer(metalCommandBuffer, metalTransferContainer->activeBuffer);
}

static void METAL_CopyTextureToTexture(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_TextureRegion *source,
    Refresh_TextureRegion *destination,
    SDL_bool cycle
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    MetalRenderer *renderer = metalCommandBuffer->renderer;
    MetalTextureContainer* srcContainer = (MetalTextureContainer*) source->textureSlice.texture;
    MetalTextureContainer* dstContainer = (MetalTextureContainer*) destination->textureSlice.texture;

    MetalTexture *srcTexture = srcContainer->activeTexture;
    MetalTexture *dstTexture = METAL_INTERNAL_PrepareTextureForWrite(
        renderer,
        dstContainer,
        cycle
    );

    [metalCommandBuffer->blitEncoder
     copyFromTexture:srcTexture->handle
     sourceSlice:source->textureSlice.layer
     sourceLevel:source->textureSlice.mipLevel
     sourceOrigin:MTLOriginMake(source->x, source->y, source->z)
     sourceSize:MTLSizeMake(source->w, source->h, source->d)
     toTexture:dstTexture->handle
     destinationSlice:destination->textureSlice.layer
     destinationLevel:destination->textureSlice.mipLevel
     destinationOrigin:MTLOriginMake(destination->x, destination->y, destination->z)];

    METAL_INTERNAL_TrackTexture(metalCommandBuffer, srcTexture);
    METAL_INTERNAL_TrackTexture(metalCommandBuffer, dstTexture);
}

static void METAL_CopyBufferToBuffer(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_Buffer *source,
    Refresh_Buffer *destination,
    Refresh_BufferCopy *copyParams,
    SDL_bool cycle
) {
    NOT_IMPLEMENTED
}

static void METAL_GenerateMipmaps(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_Texture *texture
) {
    NOT_IMPLEMENTED
}

static void METAL_DownloadFromTexture(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_TextureRegion *textureSlice,
    Refresh_TransferBuffer *transferBuffer,
    Refresh_BufferImageCopy *copyParams
) {
    NOT_IMPLEMENTED
}

static void METAL_DownloadFromBuffer(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_Buffer *buffer,
    Refresh_TransferBuffer *transferBuffer,
    Refresh_BufferCopy *copyParams
) {
    NOT_IMPLEMENTED
}

static void METAL_EndCopyPass(
    Refresh_CommandBuffer *commandBuffer
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    [metalCommandBuffer->blitEncoder endEncoding];
}

/* Graphics State */

static void METAL_INTERNAL_AllocateCommandBuffers(
    MetalRenderer *renderer,
    Uint32 allocateCount
) {
    MetalCommandBuffer *commandBuffer;

    renderer->availableCommandBufferCapacity += allocateCount;

    renderer->availableCommandBuffers = SDL_realloc(
        renderer->availableCommandBuffers,
        sizeof(MetalCommandBuffer*) * renderer->availableCommandBufferCapacity
    );

    for (Uint32 i = 0; i < allocateCount; i += 1)
    {
        commandBuffer = SDL_malloc(sizeof(MetalCommandBuffer));
        commandBuffer->renderer = renderer;

        /* The native Metal command buffer is created later */

        /* Reference Counting */
        commandBuffer->usedBufferCapacity = 4;
        commandBuffer->usedBufferCount = 0;
        commandBuffer->usedBuffers = SDL_malloc(
            commandBuffer->usedBufferCapacity * sizeof(MetalBuffer*)
        );

        commandBuffer->usedTransferBufferCapacity = 4;
        commandBuffer->usedTransferBufferCount = 0;
        commandBuffer->usedTransferBuffers = SDL_malloc(
            commandBuffer->usedTransferBufferCapacity * sizeof(MetalTransferBuffer*)
        );

        commandBuffer->usedTextureCapacity = 4;
        commandBuffer->usedTextureCount = 0;
        commandBuffer->usedTextures = SDL_malloc(
            commandBuffer->usedTextureCapacity * sizeof(MetalTexture*)
        );

        renderer->availableCommandBuffers[renderer->availableCommandBufferCount] = commandBuffer;
        renderer->availableCommandBufferCount += 1;
    }
}

static MetalCommandBuffer* METAL_INTERNAL_GetInactiveCommandBufferFromPool(
    MetalRenderer *renderer
) {
    MetalCommandBuffer *commandBuffer;

    if (renderer->availableCommandBufferCount == 0)
    {
        METAL_INTERNAL_AllocateCommandBuffers(
            renderer,
            renderer->availableCommandBufferCapacity
        );
    }

    commandBuffer = renderer->availableCommandBuffers[renderer->availableCommandBufferCount - 1];
    renderer->availableCommandBufferCount -= 1;

    return commandBuffer;
}

static SDL_bool METAL_INTERNAL_CreateFence(
    MetalRenderer *renderer
) {
    MetalFence* fence;

    fence = SDL_malloc(sizeof(MetalFence));
    SDL_AtomicSet(&fence->complete, 0);

    /* Add it to the available pool */
    /* FIXME: Should this be EXPAND_IF_NEEDED? */
    if (renderer->availableFenceCount >= renderer->availableFenceCapacity)
    {
        renderer->availableFenceCapacity *= 2;

        renderer->availableFences = SDL_realloc(
            renderer->availableFences,
            sizeof(MetalFence*) * renderer->availableFenceCapacity
        );
    }

    renderer->availableFences[renderer->availableFenceCount] = fence;
    renderer->availableFenceCount += 1;

    return 1;
}

static SDL_bool METAL_INTERNAL_AcquireFence(
    MetalRenderer *renderer,
    MetalCommandBuffer *commandBuffer
) {
    MetalFence *fence;

    /* Acquire a fence from the pool */
    SDL_LockMutex(renderer->fenceLock);

    if (renderer->availableFenceCount == 0)
    {
        if (!METAL_INTERNAL_CreateFence(renderer))
        {
            SDL_UnlockMutex(renderer->fenceLock);
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to create fence!");
            return 0;
        }
    }

    fence = renderer->availableFences[renderer->availableFenceCount - 1];
    renderer->availableFenceCount -= 1;

    SDL_UnlockMutex(renderer->fenceLock);

    /* Associate the fence with the command buffer */
    commandBuffer->fence = fence;
    SDL_AtomicSet(&fence->complete, 0); /* FIXME: Is this right? */

    return 1;
}

static Refresh_CommandBuffer* METAL_AcquireCommandBuffer(
    Refresh_Renderer *driverData
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    MetalCommandBuffer *commandBuffer;

    SDL_LockMutex(renderer->acquireCommandBufferLock);

    commandBuffer = METAL_INTERNAL_GetInactiveCommandBufferFromPool(renderer);
    commandBuffer->windowData = NULL; /* FIXME: This should probably happen in CleanCommandBuffer */
    commandBuffer->indexBuffer = NULL;
    commandBuffer->handle = [renderer->queue commandBuffer];

    METAL_INTERNAL_AcquireFence(renderer, commandBuffer);
    commandBuffer->autoReleaseFence = 1;

    SDL_UnlockMutex(renderer->acquireCommandBufferLock);

    return (Refresh_CommandBuffer*) commandBuffer;
}

static void METAL_BeginRenderPass(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_ColorAttachmentInfo *colorAttachmentInfos,
    Uint32 colorAttachmentCount,
    Refresh_DepthStencilAttachmentInfo *depthStencilAttachmentInfo
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    Refresh_ColorAttachmentInfo *attachmentInfo;
    MetalTexture *texture;
    Uint32 vpWidth = UINT_MAX;
    Uint32 vpHeight = UINT_MAX;
    MTLViewport viewport;
    MTLScissorRect scissorRect;

    for (Uint32 i = 0; i < colorAttachmentCount; i += 1)
    {
        attachmentInfo = &colorAttachmentInfos[i];
        texture = ((MetalTextureContainer*) attachmentInfo->textureSlice.texture)->activeTexture;

        /* FIXME: cycle! */
        passDescriptor.colorAttachments[i].texture = texture->handle;
        passDescriptor.colorAttachments[i].level = attachmentInfo->textureSlice.mipLevel;
        passDescriptor.colorAttachments[i].slice = attachmentInfo->textureSlice.layer;
        passDescriptor.colorAttachments[i].clearColor = MTLClearColorMake(
            attachmentInfo->clearColor.r,
            attachmentInfo->clearColor.g,
            attachmentInfo->clearColor.b,
            attachmentInfo->clearColor.a
        );
        passDescriptor.colorAttachments[i].loadAction = SDLToMetal_LoadOp[attachmentInfo->loadOp];
        passDescriptor.colorAttachments[i].storeAction = SDLToMetal_StoreOp(attachmentInfo->storeOp, 0);
        /* FIXME: Resolve texture! Also affects ^! */

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, texture);
    }

    if (depthStencilAttachmentInfo != NULL)
    {
        MetalTextureContainer *container = (MetalTextureContainer*) depthStencilAttachmentInfo->textureSlice.texture;
        texture = container->activeTexture;

        /* FIXME: cycle! */
        passDescriptor.depthAttachment.texture = texture->handle;
        passDescriptor.depthAttachment.level = depthStencilAttachmentInfo->textureSlice.mipLevel;
        passDescriptor.depthAttachment.slice = depthStencilAttachmentInfo->textureSlice.layer;
        passDescriptor.depthAttachment.loadAction = SDLToMetal_LoadOp[depthStencilAttachmentInfo->loadOp];
        passDescriptor.depthAttachment.storeAction = SDLToMetal_StoreOp(depthStencilAttachmentInfo->storeOp, 0);
        passDescriptor.depthAttachment.clearDepth = depthStencilAttachmentInfo->depthStencilClearValue.depth;

        if (IsStencilFormat(container->createInfo.format))
        {
            /* FIXME: cycle! */
            passDescriptor.stencilAttachment.texture = passDescriptor.stencilAttachment.texture;
            passDescriptor.stencilAttachment.level = depthStencilAttachmentInfo->textureSlice.mipLevel;
            passDescriptor.stencilAttachment.slice = depthStencilAttachmentInfo->textureSlice.layer;
            passDescriptor.stencilAttachment.loadAction = SDLToMetal_LoadOp[depthStencilAttachmentInfo->loadOp];
            passDescriptor.stencilAttachment.storeAction = SDLToMetal_StoreOp(depthStencilAttachmentInfo->storeOp, 0);
            passDescriptor.stencilAttachment.clearStencil = depthStencilAttachmentInfo->depthStencilClearValue.stencil;
        }

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, texture);
    }

    metalCommandBuffer->renderEncoder = [metalCommandBuffer->handle renderCommandEncoderWithDescriptor:passDescriptor];

    /* The viewport cannot be larger than the smallest attachment. */
    for (Uint32 i = 0; i < colorAttachmentCount; i += 1)
    {
        MetalTextureContainer *container = (MetalTextureContainer*) colorAttachmentInfos[i].textureSlice.texture;
        Uint32 w = container->createInfo.width >> colorAttachmentInfos[i].textureSlice.mipLevel;
        Uint32 h = container->createInfo.height >> colorAttachmentInfos[i].textureSlice.mipLevel;

        if (w < vpWidth)
        {
            vpWidth = w;
        }

        if (h < vpHeight)
        {
            vpHeight = h;
        }
    }

    /* FIXME: check depth/stencil attachment size too */

    /* Set default viewport and scissor state */
    viewport.originX = 0;
    viewport.originY = 0;
    viewport.width = vpWidth;
    viewport.height = vpHeight;
    viewport.znear = 0;
    viewport.zfar = 1;
    [metalCommandBuffer->renderEncoder setViewport:viewport];

    scissorRect.x = 0;
    scissorRect.y = 0;
    scissorRect.width = viewport.width;
    scissorRect.height = viewport.height;
    [metalCommandBuffer->renderEncoder setScissorRect:scissorRect];
}

static void METAL_BindGraphicsPipeline(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_GraphicsPipeline *graphicsPipeline
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    MetalGraphicsPipeline *metalGraphicsPipeline = (MetalGraphicsPipeline*) graphicsPipeline;
    Refresh_RasterizerState *rast = &metalGraphicsPipeline->rasterizerState;

    metalCommandBuffer->graphicsPipeline = metalGraphicsPipeline;

    [metalCommandBuffer->renderEncoder setRenderPipelineState:metalGraphicsPipeline->handle];

    /* Apply rasterizer state */
    [metalCommandBuffer->renderEncoder setTriangleFillMode: SDLToMetal_PolygonMode[metalGraphicsPipeline->rasterizerState.fillMode]];
    [metalCommandBuffer->renderEncoder setCullMode: SDLToMetal_CullMode[metalGraphicsPipeline->rasterizerState.cullMode]];
    [metalCommandBuffer->renderEncoder setFrontFacingWinding: SDLToMetal_FrontFace[metalGraphicsPipeline->rasterizerState.frontFace]];
    [metalCommandBuffer->renderEncoder
        setDepthBias: ((rast->depthBiasEnable) ? rast->depthBiasConstantFactor : 0)
        slopeScale: ((rast->depthBiasEnable) ? rast->depthBiasSlopeFactor : 0)
        clamp: ((rast->depthBiasEnable) ? rast->depthBiasClamp : 0)];

    /* Apply blend constants */
    [metalCommandBuffer->renderEncoder
        setBlendColorRed: metalGraphicsPipeline->blendConstants[0]
        green:metalGraphicsPipeline->blendConstants[1]
        blue:metalGraphicsPipeline->blendConstants[2]
        alpha:metalGraphicsPipeline->blendConstants[3]];

    /* Apply depth-stencil state */
    if (metalGraphicsPipeline->depthStencilState != NULL)
    {
        [metalCommandBuffer->renderEncoder
         setDepthStencilState:metalGraphicsPipeline->depthStencilState];
        [metalCommandBuffer->renderEncoder
         setStencilReferenceValue:metalGraphicsPipeline->stencilReference];
    }
}

static void METAL_SetViewport(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_Viewport *viewport
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    MTLViewport metalViewport;

    metalViewport.originX = viewport->x;
    metalViewport.originY = viewport->y;
    metalViewport.width = viewport->w;
    metalViewport.height = viewport->h;
    metalViewport.znear = viewport->minDepth;
    metalViewport.zfar = viewport->maxDepth;

    [metalCommandBuffer->renderEncoder setViewport:metalViewport];
}

static void METAL_SetScissor(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_Rect *scissor
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    MTLScissorRect metalScissor;

    metalScissor.x = scissor->x;
    metalScissor.y = scissor->y;
    metalScissor.width = scissor->w;
    metalScissor.height = scissor->h;

    [metalCommandBuffer->renderEncoder setScissorRect:metalScissor];
}

static void METAL_BindVertexBuffers(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstBinding,
    Refresh_BufferBinding *pBindings,
    Uint32 bindingCount
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    id<MTLBuffer> metalBuffers[MAX_BUFFER_BINDINGS];
    NSUInteger bufferOffsets[MAX_BUFFER_BINDINGS];
    NSRange range = NSMakeRange(METAL_INTERNAL_GetVertexBufferIndex(firstBinding), bindingCount);

    if (range.length == 0)
    {
        return;
    }

    for (Uint32 i = 0; i < range.length; i += 1)
    {
        MetalBuffer *currentBuffer = ((MetalBufferContainer*) pBindings[i].buffer)->activeBuffer;
        NSUInteger bindingIndex = range.length - 1 - i;
        metalBuffers[bindingIndex] = currentBuffer->handle;
        bufferOffsets[bindingIndex] = pBindings[i].offset;
        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, currentBuffer);
    }

    [metalCommandBuffer->renderEncoder setVertexBuffers:metalBuffers offsets:bufferOffsets withRange:range];
}

static void METAL_BindIndexBuffer(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_BufferBinding *pBinding,
    Refresh_IndexElementSize indexElementSize
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    metalCommandBuffer->indexBuffer = ((MetalBufferContainer*) pBinding->buffer)->activeBuffer;
    metalCommandBuffer->indexBufferOffset = pBinding->offset;
    metalCommandBuffer->indexElementSize = indexElementSize;

    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalCommandBuffer->indexBuffer);
}

static void METAL_BindVertexSamplers(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_TextureSamplerBinding *textureSamplerBindings,
    Uint32 bindingCount
) {
    NOT_IMPLEMENTED
}

static void METAL_BindVertexStorageTextures(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_TextureSlice *storageTextureSlices,
    Uint32 bindingCount
) {
    NOT_IMPLEMENTED
}

static void METAL_BindVertexStorageBuffers(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_Buffer **storageBuffers,
    Uint32 bindingCount
) {
    NOT_IMPLEMENTED
}

static void METAL_BindFragmentSamplers(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_TextureSamplerBinding *textureSamplerBindings,
    Uint32 bindingCount
) {
    NOT_IMPLEMENTED
}

static void METAL_BindFragmentStorageTextures(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_TextureSlice *storageTextureSlices,
    Uint32 bindingCount
) {
    NOT_IMPLEMENTED
}

static void METAL_BindFragmentStorageBuffers(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_Buffer **storageBuffers,
    Uint32 bindingCount
) {
    NOT_IMPLEMENTED
}

static void METAL_DrawIndexedPrimitives(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 baseVertex,
    Uint32 startIndex,
    Uint32 primitiveCount,
    Uint32 instanceCount
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    Refresh_PrimitiveType primitiveType = metalCommandBuffer->graphicsPipeline->primitiveType;
    Uint32 indexSize = IndexSize(metalCommandBuffer->indexElementSize);

    [metalCommandBuffer->renderEncoder
     drawIndexedPrimitives:SDLToMetal_PrimitiveType[primitiveType]
     indexCount:PrimitiveVerts(primitiveType, primitiveCount)
     indexType:SDLToMetal_IndexType[metalCommandBuffer->indexElementSize]
     indexBuffer:metalCommandBuffer->indexBuffer->handle
     indexBufferOffset:metalCommandBuffer->indexBufferOffset + (startIndex * indexSize)
     instanceCount:instanceCount
     baseVertex:baseVertex
     baseInstance:0];
}

static void METAL_DrawPrimitives(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 vertexStart,
    Uint32 primitiveCount
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    Refresh_PrimitiveType primitiveType = metalCommandBuffer->graphicsPipeline->primitiveType;

    [metalCommandBuffer->renderEncoder
        drawPrimitives:SDLToMetal_PrimitiveType[primitiveType]
        vertexStart:vertexStart
        vertexCount:PrimitiveVerts(primitiveType, primitiveCount)];
}

static void METAL_DrawPrimitivesIndirect(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_Buffer *buffer,
    Uint32 offsetInBytes,
    Uint32 drawCount,
    Uint32 stride
) {
    NOT_IMPLEMENTED
}

static void METAL_DrawIndexedPrimitivesIndirect(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_Buffer *buffer,
    Uint32 offsetInBytes,
    Uint32 drawCount,
    Uint32 stride
) {
    NOT_IMPLEMENTED
}

static void METAL_EndRenderPass(
    Refresh_CommandBuffer *commandBuffer
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    [metalCommandBuffer->renderEncoder endEncoding];

    /* FIXME: Anything else to do here? */
}

static void METAL_PushVertexUniformData(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 slotIndex,
    void *data,
    Uint32 dataLengthInBytes
) {
    NOT_IMPLEMENTED
}

static void METAL_PushFragmentUniformData(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 slotIndex,
    void *data,
    Uint32 dataLengthInBytes
) {
    NOT_IMPLEMENTED
}

/* Blit */

static void METAL_Blit(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_TextureRegion *source,
    Refresh_TextureRegion *destination,
    Refresh_Filter filterMode,
    SDL_bool cycle
) {
    NOT_IMPLEMENTED
}

/* Compute State */

static void METAL_BeginComputePass(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_StorageTextureReadWriteBinding *storageTextureBindings,
    Uint32 storageTextureBindingCount,
    Refresh_StorageBufferReadWriteBinding *storageBufferBindings,
    Uint32 storageBufferBindingCount
) {
    NOT_IMPLEMENTED
}

static void METAL_BindComputePipeline(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_ComputePipeline *computePipeline
) {
    NOT_IMPLEMENTED
}

static void METAL_BindComputeStorageTextures(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_TextureSlice *storageTextureSlices,
    Uint32 bindingCount
) {
    NOT_IMPLEMENTED
}

static void METAL_BindComputeStorageBuffers(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_Buffer **storageBuffers,
    Uint32 bindingCount
) {
    NOT_IMPLEMENTED
}

static void METAL_PushComputeUniformData(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 slotIndex,
    void *data,
    Uint32 dataLengthInBytes
) {
    NOT_IMPLEMENTED
}

static void METAL_DispatchCompute(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 groupCountX,
    Uint32 groupCountY,
    Uint32 groupCountZ
) {
    NOT_IMPLEMENTED
}

static void METAL_EndComputePass(
    Refresh_CommandBuffer *commandBuffer
) {
    NOT_IMPLEMENTED
}

/* Fence Cleanup */

static void METAL_INTERNAL_ReleaseFenceToPool(
    MetalRenderer *renderer,
    MetalFence *fence
) {
    SDL_LockMutex(renderer->fenceLock);

    /* FIXME: Should this use EXPAND_IF_NEEDED? */
    if (renderer->availableFenceCount == renderer->availableFenceCapacity)
    {
        renderer->availableFenceCapacity *= 2;
        renderer->availableFences = SDL_realloc(
            renderer->availableFences,
            renderer->availableFenceCapacity * sizeof(MetalFence*)
        );
    }
    renderer->availableFences[renderer->availableFenceCount] = fence;
    renderer->availableFenceCount += 1;

    SDL_UnlockMutex(renderer->fenceLock);
}

static void METAL_ReleaseFence(
    Refresh_Renderer *driverData,
    Refresh_Fence *fence
) {
    METAL_INTERNAL_ReleaseFenceToPool(
        (MetalRenderer*) driverData,
        (MetalFence*) fence
    );
}

/* Cleanup */

static void METAL_INTERNAL_CleanCommandBuffer(
    MetalRenderer *renderer,
    MetalCommandBuffer *commandBuffer
) {
    /* Reference Counting */

    for (Uint32 i = 0; i < commandBuffer->usedBufferCount; i += 1)
    {
        (void)SDL_AtomicDecRef(&commandBuffer->usedBuffers[i]->referenceCount);
    }
    commandBuffer->usedBufferCount = 0;

    for (Uint32 i = 0; i < commandBuffer->usedTransferBufferCount; i += 1)
    {
        (void)SDL_AtomicDecRef(&commandBuffer->usedTransferBuffers[i]->referenceCount);
    }
    commandBuffer->usedTransferBufferCount = 0;

    for (Uint32 i = 0; i < commandBuffer->usedTextureCount; i += 1)
    {
        (void)SDL_AtomicDecRef(&commandBuffer->usedTextures[i]->referenceCount);
    }
    commandBuffer->usedTextureCount = 0;

    /* The fence is now available (unless SubmitAndAcquireFence was called) */
    if (commandBuffer->autoReleaseFence)
    {
        METAL_ReleaseFence(
            (Refresh_Renderer*) renderer,
            (Refresh_Fence*) commandBuffer->fence
        );
    }

    /* Return command buffer to pool */
    SDL_LockMutex(renderer->acquireCommandBufferLock);
    /* FIXME: Should this use EXPAND_IF_NEEDED? */
    if (renderer->availableCommandBufferCount == renderer->availableCommandBufferCapacity)
    {
        renderer->availableCommandBufferCapacity += 1;
        renderer->availableCommandBuffers = SDL_realloc(
            renderer->availableCommandBuffers,
            renderer->availableCommandBufferCapacity * sizeof(MetalCommandBuffer*)
        );
    }
    renderer->availableCommandBuffers[renderer->availableCommandBufferCount] = commandBuffer;
    renderer->availableCommandBufferCount += 1;
    SDL_UnlockMutex(renderer->acquireCommandBufferLock);

    /* Remove this command buffer from the submitted list */
    for (Uint32 i = 0; i < renderer->submittedCommandBufferCount; i += 1)
    {
        if (renderer->submittedCommandBuffers[i] == commandBuffer)
        {
            renderer->submittedCommandBuffers[i] = renderer->submittedCommandBuffers[renderer->submittedCommandBufferCount - 1];
            renderer->submittedCommandBufferCount -= 1;
        }
    }
}

static void METAL_INTERNAL_PerformPendingDestroys(
    MetalRenderer *renderer
) {
    Sint32 referenceCount = 0;
    Sint32 i;
    Uint32 j;

    for (i = renderer->transferBufferContainersToDestroyCount - 1; i >= 0; i -= 1)
    {
        referenceCount = 0;
        for (j = 0; j < renderer->transferBufferContainersToDestroy[i]->bufferCount; j += 1)
        {
            referenceCount += SDL_AtomicGet(&renderer->transferBufferContainersToDestroy[i]->buffers[j]->referenceCount);
        }

        if (referenceCount == 0)
        {
            METAL_INTERNAL_DestroyTransferBufferContainer(
                renderer->transferBufferContainersToDestroy[i]
            );

            renderer->transferBufferContainersToDestroy[i] = renderer->transferBufferContainersToDestroy[renderer->transferBufferContainersToDestroyCount - 1];
            renderer->transferBufferContainersToDestroyCount -= 1;
        }
    }

    for (i = renderer->bufferContainersToDestroyCount - 1; i >= 0; i -= 1)
    {
        referenceCount = 0;
        for (j = 0; j < renderer->bufferContainersToDestroy[i]->bufferCount; j += 1)
        {
            referenceCount += SDL_AtomicGet(&renderer->bufferContainersToDestroy[i]->buffers[j]->referenceCount);
        }

        if (referenceCount == 0)
        {
            METAL_INTERNAL_DestroyBufferContainer(
                renderer->bufferContainersToDestroy[i]
            );

            renderer->bufferContainersToDestroy[i] = renderer->bufferContainersToDestroy[renderer->bufferContainersToDestroyCount - 1];
            renderer->bufferContainersToDestroyCount -= 1;
        }
    }

    for (i = renderer->textureContainersToDestroyCount - 1; i >= 0; i -= 1)
    {
        referenceCount = 0;
        for (j = 0; j < renderer->textureContainersToDestroy[i]->textureCount; j += 1)
        {
            referenceCount += SDL_AtomicGet(&renderer->textureContainersToDestroy[i]->textures[j]->referenceCount);
        }

        if (referenceCount == 0)
        {
            METAL_INTERNAL_DestroyTextureContainer(
                renderer->textureContainersToDestroy[i]
            );

            renderer->textureContainersToDestroy[i] = renderer->textureContainersToDestroy[renderer->textureContainersToDestroyCount - 1];
            renderer->textureContainersToDestroyCount -= 1;
        }
    }
}

/* Fences */

static void METAL_WaitForFences(
    Refresh_Renderer *driverData,
    SDL_bool waitAll,
    Refresh_Fence **pFences,
    Uint32 fenceCount
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    SDL_bool waiting;

    if (waitAll)
    {
        for (Uint32 i = 0; i < fenceCount; i += 1)
        {
            while (!SDL_AtomicGet(&((MetalFence*) pFences[i])->complete))
            {
                /* Spin! */
            }
        }
    }
    else
    {
        waiting = 1;
        while (waiting)
        {
            for (Uint32 i = 0; i < fenceCount; i += 1)
            {
                if (SDL_AtomicGet(&((MetalFence*) pFences[i])->complete) > 0)
                {
                    waiting = 0;
                    break;
                }
            }
        }
    }

    METAL_INTERNAL_PerformPendingDestroys(renderer);
}

static int METAL_QueryFence(
    Refresh_Renderer *driverData,
    Refresh_Fence *fence
) {
    NOT_IMPLEMENTED
    return 0;
}

/* Window and Swapchain Management */

static MetalWindowData* METAL_INTERNAL_FetchWindowData(SDL_Window *window)
{
    return (MetalWindowData*) SDL_GetWindowData(window, WINDOW_PROPERTY_DATA);
}

static SDL_bool METAL_SupportsSwapchainComposition(
    Refresh_Renderer *driverData,
    SDL_Window *window,
    Refresh_SwapchainComposition swapchainComposition
) {
    NOT_IMPLEMENTED
    return SDL_FALSE;
}

static SDL_bool METAL_INTERNAL_CreateSwapchain(
    MetalRenderer *renderer,
    MetalWindowData *windowData,
    Refresh_PresentMode presentMode
) {
    CGSize drawableSize;

    windowData->view = SDL_Metal_CreateView(windowData->window);
    windowData->drawable = nil;

    windowData->layer = (__bridge CAMetalLayer *)(SDL_Metal_GetLayer(windowData->view));
    windowData->layer.device = renderer->device;
#ifdef SDL_PLATFORM_MACOS
    windowData->layer.displaySyncEnabled = (presentMode != REFRESH_PRESENTMODE_IMMEDIATE);
#endif
    windowData->layer.framebufferOnly = FALSE; /* Allow sampling swapchain textures, at the expense of performance */
    windowData->layer.pixelFormat = MTLPixelFormatRGBA8Unorm;

    windowData->texture.handle = nil; /* This will be set in AcquireSwapchainTexture. */

    /* Set up the texture container */
    SDL_zero(windowData->textureContainer);
    windowData->textureContainer.canBeCycled = 0;
    windowData->textureContainer.activeTexture = &windowData->texture;
    windowData->textureContainer.textureCapacity = 1;
    windowData->textureContainer.textureCount = 1;
    windowData->textureContainer.createInfo.levelCount = 1;
    windowData->textureContainer.createInfo.depth = 1;
    windowData->textureContainer.createInfo.isCube = 0;
    windowData->textureContainer.createInfo.usageFlags =
        REFRESH_TEXTUREUSAGE_COLOR_TARGET_BIT | REFRESH_TEXTUREUSAGE_SAMPLER_BIT | REFRESH_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE_BIT; /* FIXME: Other bits? */

    drawableSize = windowData->layer.drawableSize;
    windowData->textureContainer.createInfo.width = (Uint32) drawableSize.width;
    windowData->textureContainer.createInfo.height = (Uint32) drawableSize.height;

    return 1;
}

/* FIXME: ResizeSwapchain? */

static SDL_bool METAL_SupportsPresentMode(
    Refresh_Renderer *driverData,
    SDL_Window *window,
    Refresh_PresentMode presentMode
) {
    switch (presentMode)
    {
#ifdef SDL_PLATFORM_MACOS
    case REFRESH_PRESENTMODE_IMMEDIATE:
#endif
    case REFRESH_PRESENTMODE_VSYNC:
        return SDL_TRUE;
    default:
        return SDL_FALSE;
    }
}

static SDL_bool METAL_ClaimWindow(
    Refresh_Renderer *driverData,
    SDL_Window *window,
    Refresh_SwapchainComposition swapchainComposition,
    Refresh_PresentMode presentMode
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);

    if (windowData == NULL)
    {
        windowData = (MetalWindowData*) SDL_malloc(sizeof(MetalWindowData));
        windowData->window = window; /* FIXME: needed? */

        if (METAL_INTERNAL_CreateSwapchain(renderer, windowData, presentMode))
        {
            SDL_SetWindowData(window, WINDOW_PROPERTY_DATA, windowData);

            SDL_LockMutex(renderer->windowLock);

            if (renderer->claimedWindowCount >= renderer->claimedWindowCapacity)
            {
                renderer->claimedWindowCapacity *= 2;
                renderer->claimedWindows = SDL_realloc(
                    renderer->claimedWindows,
                    renderer->claimedWindowCapacity * sizeof(MetalWindowData*)
                );
            }
            renderer->claimedWindows[renderer->claimedWindowCount] = windowData;
            renderer->claimedWindowCount += 1;

            SDL_UnlockMutex(renderer->windowLock);

            return SDL_TRUE;
        }
        else
        {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Could not create swapchain, failed to claim window!");
            SDL_free(windowData);
            return SDL_FALSE;
        }
    }
    else
    {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Window already claimed!");
        return SDL_FALSE;
    }
}

/* FIXME: DestroySwapchain? */

static void METAL_UnclaimWindow(
    Refresh_Renderer *driverData,
    SDL_Window *window
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);

    if (windowData == NULL)
    {
        return;
    }

    /* FIXME */
    windowData->layer = nil;
    SDL_Metal_DestroyView(windowData->view);

    SDL_LockMutex(renderer->windowLock);
    for (Uint32 i = 0; i < renderer->claimedWindowCount; i += 1)
    {
        if (renderer->claimedWindows[i]->window == window)
        {
            renderer->claimedWindows[i] = renderer->claimedWindows[renderer->claimedWindowCount - 1];
            renderer->claimedWindowCount -= 1;
            break;
        }
    }
    SDL_UnlockMutex(renderer->windowLock);

    SDL_free(windowData);
    SDL_SetWindowData(window, WINDOW_PROPERTY_DATA, NULL);
}

static Refresh_Texture* METAL_AcquireSwapchainTexture(
    Refresh_CommandBuffer *commandBuffer,
    SDL_Window *window,
    Uint32 *pWidth,
    Uint32 *pHeight
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    MetalWindowData *windowData;
    CGSize drawableSize;

    windowData = METAL_INTERNAL_FetchWindowData(window);
    if (windowData == NULL)
    {
        *pWidth = 0;
        *pHeight = 0;
        return NULL;
    }

    /* FIXME: Handle minimization! */
    /* FIXME: Handle acquisition for different present modes */

    /* Get the drawable and its underlying texture */
    windowData->drawable = [windowData->layer nextDrawable];
    windowData->texture.handle = [windowData->drawable texture];

    /* Let the command buffer know it's associated with this swapchain. */
    metalCommandBuffer->windowData = windowData;

    /* Update the window size */
    drawableSize = windowData->layer.drawableSize;
    windowData->textureContainer.createInfo.width = (Uint32) drawableSize.width;
    windowData->textureContainer.createInfo.height = (Uint32) drawableSize.height;

    /* Send the dimensions to the out parameters. */
    *pWidth = windowData->textureContainer.createInfo.width;
    *pHeight = windowData->textureContainer.createInfo.height;

    /* Return the swapchain texture */
    return (Refresh_Texture*) &windowData->textureContainer;
}

static Refresh_TextureFormat METAL_GetSwapchainTextureFormat(
    Refresh_Renderer *driverData,
    SDL_Window *window
) {
    NOT_IMPLEMENTED
    return REFRESH_TEXTUREFORMAT_R8;
}

static void METAL_SetSwapchainParameters(
    Refresh_Renderer *driverData,
    SDL_Window *window,
    Refresh_SwapchainComposition swapchainComposition,
    Refresh_PresentMode presentMode
) {
    NOT_IMPLEMENTED
}

/* Submission */

static void METAL_Submit(
    Refresh_CommandBuffer *commandBuffer
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    MetalRenderer *renderer = metalCommandBuffer->renderer;

    SDL_LockMutex(renderer->submitLock);

    /* Enqueue a present request, if applicable */
    if (metalCommandBuffer->windowData)
    {
        [metalCommandBuffer->handle presentDrawable:metalCommandBuffer->windowData->drawable];
        metalCommandBuffer->windowData->drawable = nil;
        metalCommandBuffer->windowData->texture.handle = nil;
    }

    /* Notify the fence when the command buffer has completed */
    [metalCommandBuffer->handle addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        SDL_AtomicIncRef(&metalCommandBuffer->fence->complete);
    }];

    /* Submit the command buffer */
    [metalCommandBuffer->handle commit];
    metalCommandBuffer->handle = nil;

    /* Mark the command buffer as submitted */
    if (renderer->submittedCommandBufferCount >= renderer->submittedCommandBufferCapacity)
    {
        renderer->submittedCommandBufferCapacity = renderer->submittedCommandBufferCount + 1;

        renderer->submittedCommandBuffers = SDL_realloc(
            renderer->submittedCommandBuffers,
            sizeof(MetalCommandBuffer*) * renderer->submittedCommandBufferCapacity
        );
    }
    renderer->submittedCommandBuffers[renderer->submittedCommandBufferCount] = metalCommandBuffer;
    renderer->submittedCommandBufferCount += 1;

    /* Check if we can perform any cleanups */
    for (Sint32 i = renderer->submittedCommandBufferCount - 1; i >= 0; i -= 1)
    {
        if (SDL_AtomicGet(&renderer->submittedCommandBuffers[i]->fence->complete))
        {
            METAL_INTERNAL_CleanCommandBuffer(
                renderer,
                renderer->submittedCommandBuffers[i]
            );
        }
    }

    METAL_INTERNAL_PerformPendingDestroys(renderer);

    SDL_UnlockMutex(renderer->submitLock);
}

static Refresh_Fence* METAL_SubmitAndAcquireFence(
    Refresh_CommandBuffer *commandBuffer
) {
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer*) commandBuffer;
    MetalFence *fence = metalCommandBuffer->fence;

    metalCommandBuffer->autoReleaseFence = 0;
    METAL_Submit(commandBuffer);

    return (Refresh_Fence*) fence;
}

static void METAL_Wait(
    Refresh_Renderer *driverData
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    MetalCommandBuffer *commandBuffer;

    /*
     * Wait for all submitted command buffers to complete.
     * Sort of equivalent to vkDeviceWaitIdle.
     */
    for (Uint32 i = 0; i < renderer->submittedCommandBufferCount; i += 1)
    {
        while (!SDL_AtomicGet(&renderer->submittedCommandBuffers[i]->fence->complete))
        {
            /* Spin! */
        }
    }

    SDL_LockMutex(renderer->submitLock);

    for (Sint32 i = renderer->submittedCommandBufferCount - 1; i >= 0; i -= 1)
    {
        commandBuffer = renderer->submittedCommandBuffers[i];
        METAL_INTERNAL_CleanCommandBuffer(renderer, commandBuffer);
    }

    METAL_INTERNAL_PerformPendingDestroys(renderer);

    SDL_UnlockMutex(renderer->submitLock);
}

/* Queries */

static Refresh_OcclusionQuery* METAL_CreateOcclusionQuery(
    Refresh_Renderer *driverData
) {
    NOT_IMPLEMENTED
    return NULL;
}

static void METAL_OcclusionQueryBegin(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_OcclusionQuery *query
) {
    NOT_IMPLEMENTED
}

static void METAL_OcclusionQueryEnd(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_OcclusionQuery *query
) {
    NOT_IMPLEMENTED
}

static SDL_bool METAL_OcclusionQueryPixelCount(
    Refresh_Renderer *driverData,
    Refresh_OcclusionQuery *query,
    Uint32 *pixelCount
) {
    NOT_IMPLEMENTED
    return SDL_FALSE;
}

/* Format Info */

static SDL_bool METAL_IsTextureFormatSupported(
    Refresh_Renderer *driverData,
    Refresh_TextureFormat format,
    Refresh_TextureType type,
    Refresh_TextureUsageFlags usage
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;

    /* Only depth textures can be used as... depth textures */
    if ((usage & REFRESH_TEXTUREUSAGE_DEPTH_STENCIL_TARGET_BIT))
    {
        if (!IsDepthFormat(format))
        {
            return SDL_FALSE;
        }
    }

    switch (format)
    {
        /* Apple GPU exclusive */
        case REFRESH_TEXTUREFORMAT_R5G6B5:
        case REFRESH_TEXTUREFORMAT_A1R5G5B5:
        case REFRESH_TEXTUREFORMAT_B4G4R4A4:
            return ![renderer->device supportsFamily:MTLGPUFamilyMac2];

        /* Requires BC compression support */
        case REFRESH_TEXTUREFORMAT_BC1:
        case REFRESH_TEXTUREFORMAT_BC2:
        case REFRESH_TEXTUREFORMAT_BC3:
        case REFRESH_TEXTUREFORMAT_BC7:
#ifdef SDL_PLATFORM_MACOS
            return (
                [renderer->device supportsBCTextureCompression] &&
                !(usage & REFRESH_TEXTUREUSAGE_COLOR_TARGET_BIT) );
#else
            return SDL_FALSE;
#endif

        /* Requires D24S8 support */
        case REFRESH_TEXTUREFORMAT_D24_UNORM:
        case REFRESH_TEXTUREFORMAT_D24_UNORM_S8_UINT:
#ifdef SDL_PLATFORM_MACOS
            return [renderer->device isDepth24Stencil8PixelFormatSupported];
#else
            return SDL_FALSE;
#endif

        default:
            return SDL_TRUE;
    }
}

static Refresh_SampleCount METAL_GetBestSampleCount(
    Refresh_Renderer *driverData,
    Refresh_TextureFormat format,
    Refresh_SampleCount desiredSampleCount
) {
    MetalRenderer *renderer = (MetalRenderer*) driverData;
    Refresh_SampleCount highestSupported = desiredSampleCount;

    if ((format == REFRESH_TEXTUREFORMAT_R32_SFLOAT ||
        format == REFRESH_TEXTUREFORMAT_R32G32_SFLOAT ||
        format == REFRESH_TEXTUREFORMAT_R32G32B32A32_SFLOAT)
        && [renderer->device supports32BitMSAA ])
    {
        return REFRESH_SAMPLECOUNT_1;
    }

    while (highestSupported > REFRESH_SAMPLECOUNT_1)
    {
        if ([renderer->device supportsTextureSampleCount: (1 << highestSupported)])
        {
            break;
        }
        highestSupported -= 1;
    }

    return highestSupported;
}

/* SPIR-V Cross Interop */

static Refresh_Shader* METAL_CompileFromSPIRVCross(
    Refresh_Renderer *driverData,
    Refresh_ShaderStage shader_stage,
    const char *entryPointName,
    const char *source
) {
    Refresh_ShaderCreateInfo createInfo;
    createInfo.code = (const Uint8*) source;
    createInfo.codeSize = SDL_strlen(source);
    createInfo.format = REFRESH_SHADERFORMAT_MSL;
    createInfo.stage = shader_stage;
    createInfo.entryPointName = entryPointName;
    return METAL_CreateShader(driverData, &createInfo);
}

/* Device Creation */

static SDL_bool METAL_PrepareDriver()
{
    /* FIXME: Add a macOS / iOS version check! Maybe support >= 10.14? */
    return 1;
}

static Refresh_Device* METAL_CreateDevice(SDL_bool debugMode)
{
    MetalRenderer *renderer;

    /* Allocate and zero out the renderer */
    renderer = (MetalRenderer*) SDL_calloc(1, sizeof(MetalRenderer));

    /* Create the Metal device and command queue */
    renderer->device = MTLCreateSystemDefaultDevice();
    renderer->queue = [renderer->device newCommandQueue];

    /* Print driver info */
    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "SDL GPU Driver: Metal");
    /* FIXME: Can we log more here? */

    /* Remember debug mode */
    renderer->debugMode = debugMode;

    /* Create mutexes */
    renderer->submitLock = SDL_CreateMutex();
    renderer->acquireCommandBufferLock = SDL_CreateMutex();
    renderer->disposeLock = SDL_CreateMutex();
    renderer->fenceLock = SDL_CreateMutex();
    renderer->windowLock = SDL_CreateMutex();

    /* Create command buffer pool */
    METAL_INTERNAL_AllocateCommandBuffers(renderer, 2);

    /* Create fence pool */
    renderer->availableFenceCapacity = 2;
    renderer->availableFences = SDL_malloc(
        sizeof(MetalFence*) * renderer->availableFenceCapacity
    );

    /* Create deferred destroy arrays */
    renderer->transferBufferContainersToDestroyCapacity = 2;
    renderer->transferBufferContainersToDestroyCount = 0;
    renderer->transferBufferContainersToDestroy = SDL_malloc(
        renderer->transferBufferContainersToDestroyCapacity * sizeof(MetalTransferBufferContainer*)
    );

    renderer->bufferContainersToDestroyCapacity = 2;
    renderer->bufferContainersToDestroyCount = 0;
    renderer->bufferContainersToDestroy = SDL_malloc(
        renderer->bufferContainersToDestroyCapacity * sizeof(MetalBufferContainer*)
    );

    renderer->textureContainersToDestroyCapacity = 2;
    renderer->textureContainersToDestroyCount = 0;
    renderer->textureContainersToDestroy = SDL_malloc(
        renderer->textureContainersToDestroyCapacity * sizeof(MetalTextureContainer*)
    );

    /* Create claimed window list */
    renderer->claimedWindowCapacity = 1;
    renderer->claimedWindows = SDL_malloc(
        sizeof(MetalWindowData*) * renderer->claimedWindowCapacity
    );

    Refresh_Device *result = SDL_malloc(sizeof(Refresh_Device));
    ASSIGN_DRIVER(METAL)
    result->driverData = (Refresh_Renderer*) renderer;
    return result;
}

Refresh_Driver MetalDriver = {
    "Metal",
    REFRESH_BACKEND_METAL,
    METAL_PrepareDriver,
    METAL_CreateDevice
};

#endif /* REFRESH_METAL */
