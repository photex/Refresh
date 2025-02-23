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

#include "../Refresh_driver.h"

/* Defines */

#define METAL_MAX_BUFFER_COUNT      31
#define WINDOW_PROPERTY_DATA        "Refresh_MetalWindowPropertyData"
#define REFRESH_SHADERSTAGE_COMPUTE 2

#define EXPAND_ARRAY_IF_NEEDED(arr, elementType, newCount, capacity, newCapacity) \
    if (newCount >= capacity) {                                                   \
        capacity = newCapacity;                                                   \
        arr = (elementType *)SDL_realloc(                                         \
            arr,                                                                  \
            sizeof(elementType) * capacity);                                      \
    }

#define TRACK_RESOURCE(resource, type, array, count, capacity) \
    Uint32 i;                                                  \
                                                               \
    for (i = 0; i < commandBuffer->count; i += 1) {            \
        if (commandBuffer->array[i] == resource) {             \
            return;                                            \
        }                                                      \
    }                                                          \
                                                               \
    if (commandBuffer->count == commandBuffer->capacity) {     \
        commandBuffer->capacity += 1;                          \
        commandBuffer->array = SDL_realloc(                    \
            commandBuffer->array,                              \
            commandBuffer->capacity * sizeof(type));           \
    }                                                          \
    commandBuffer->array[commandBuffer->count] = resource;     \
    commandBuffer->count += 1;                                 \
    SDL_AtomicIncRef(&resource->referenceCount);

/* Blit Shaders */

static const char *FullscreenVertexShader =
    "using namespace metal;\n"
    "struct VertexToPixel { float4 position [[position]]; float2 texcoord; };\n"
    "vertex VertexToPixel vs_main(uint vI [[vertex_id]]) {\n"
    "   float2 inTexcoord = float2((vI << 1) & 2, vI & 2);\n"
    "   VertexToPixel out;\n"
    "   out.position = float4(inTexcoord * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);\n"
    "   out.texcoord = inTexcoord;\n"
    "   return out;\n"
    "}";

static const char *BlitFrom2DFragmentShader =
    "using namespace metal;\n"
    "struct VertexToPixel { float4 position [[position]]; float2 texcoord; };\n"
    "fragment float4 fs_main(\n"
    "   VertexToPixel input [[stage_in]],\n"
    "   texture2d<float> srcTexture [[texture(0)]],\n"
    "   sampler srcSampler [[sampler(0)]]) {\n"
    "   return srcTexture.sample(srcSampler, input.texcoord);\n"
    "}";

/* Forward Declarations */

static void METAL_Wait(Refresh_Renderer *driverData);
static void METAL_UnclaimWindow(
    Refresh_Renderer *driverData,
    SDL_Window *window);
static void METAL_INTERNAL_DestroyBlitResources(Refresh_Renderer *driverData);

/* Conversions */

static MTLPixelFormat RefreshToMetal_SurfaceFormat[] = {
    MTLPixelFormatRGBA8Unorm,   /* R8G8B8A8 */
    MTLPixelFormatBGRA8Unorm,   /* B8G8R8A8 */
    MTLPixelFormatB5G6R5Unorm,  /* B5G6R5 */
    MTLPixelFormatBGR5A1Unorm,  /* B5G5R5A1 */
    MTLPixelFormatABGR4Unorm,   /* B4G4R4A4 */
    MTLPixelFormatRGB10A2Unorm, /* A2R10G10B10 */
    MTLPixelFormatRG16Unorm,    /* R16G16 */
    MTLPixelFormatRGBA16Unorm,  /* R16G16B16A16 */
    MTLPixelFormatR8Unorm,      /* R8 */
    MTLPixelFormatA8Unorm,      /* A8 */
#ifdef __MACOSX__
    MTLPixelFormatBC1_RGBA,      /* BC1 */
    MTLPixelFormatBC2_RGBA,      /* BC2 */
    MTLPixelFormatBC3_RGBA,      /* BC3 */
    MTLPixelFormatBC7_RGBAUnorm, /* BC7 */
#else
    MTLPixelFormatInvalid, /* BC1 */
    MTLPixelFormatInvalid, /* BC2 */
    MTLPixelFormatInvalid, /* BC3 */
    MTLPixelFormatInvalid, /* BC7 */
#endif
    MTLPixelFormatRG8Snorm,        /* R8G8_SNORM */
    MTLPixelFormatRGBA8Snorm,      /* R8G8B8A8_SNORM */
    MTLPixelFormatR16Float,        /* R16_SFLOAT */
    MTLPixelFormatRG16Float,       /* R16G16_SFLOAT */
    MTLPixelFormatRGBA16Float,     /* R16G16B16A16_SFLOAT */
    MTLPixelFormatR32Float,        /* R32_SFLOAT */
    MTLPixelFormatRG32Float,       /* R32G32_SFLOAT */
    MTLPixelFormatRGBA32Float,     /* R32G32B32A32_SFLOAT */
    MTLPixelFormatR8Uint,          /* R8_UINT */
    MTLPixelFormatRG8Uint,         /* R8G8_UINT */
    MTLPixelFormatRGBA8Uint,       /* R8G8B8A8_UINT */
    MTLPixelFormatR16Uint,         /* R16_UINT */
    MTLPixelFormatRG16Uint,        /* R16G16_UINT */
    MTLPixelFormatRGBA16Uint,      /* R16G16B16A16_UINT */
    MTLPixelFormatRGBA8Unorm_sRGB, /* R8G8B8A8_SRGB*/
    MTLPixelFormatBGRA8Unorm_sRGB, /* B8G8R8A8_SRGB */
#ifdef __MACOSX__
    MTLPixelFormatBC3_RGBA_sRGB,      /* BC3_SRGB */
    MTLPixelFormatBC7_RGBAUnorm_sRGB, /* BC7_SRGB */
#else
    MTLPixelFormatInvalid, /* BC3_SRGB */
    MTLPixelFormatInvalid, /* BC7_SRGB */
#endif
    MTLPixelFormatDepth16Unorm, /* D16_UNORM */
#ifdef __MACOSX__
    MTLPixelFormatDepth24Unorm_Stencil8, /* D24_UNORM */
#else
    MTLPixelFormatInvalid, /* D24_UNORM */
#endif
    MTLPixelFormatDepth32Float, /* D32_SFLOAT */
#ifdef __MACOSX__
    MTLPixelFormatDepth24Unorm_Stencil8, /* D24_UNORM_S8_UINT */
#else
    MTLPixelFormatInvalid, /* D24_UNORM_S8_UINT */
#endif
    MTLPixelFormatDepth32Float_Stencil8, /* D32_SFLOAT_S8_UINT */
};

static MTLVertexFormat RefreshToMetal_VertexFormat[] = {
    MTLVertexFormatUInt,             /* UINT */
    MTLVertexFormatFloat,            /* FLOAT */
    MTLVertexFormatFloat2,           /* VECTOR2 */
    MTLVertexFormatFloat3,           /* VECTOR3 */
    MTLVertexFormatFloat4,           /* VECTOR4 */
    MTLVertexFormatUChar4Normalized, /* COLOR */
    MTLVertexFormatUChar4,           /* BYTE4 */
    MTLVertexFormatShort2,           /* SHORT2 */
    MTLVertexFormatShort4,           /* SHORT4 */
    MTLVertexFormatShort2Normalized, /* NORMALIZEDSHORT2 */
    MTLVertexFormatShort4Normalized, /* NORMALIZEDSHORT4 */
    MTLVertexFormatHalf2,            /* HALFVECTOR2 */
    MTLVertexFormatHalf4,            /* HALFVECTOR4 */
};

static MTLIndexType RefreshToMetal_IndexType[] = {
    MTLIndexTypeUInt16, /* 16BIT */
    MTLIndexTypeUInt32, /* 32BIT */
};

static MTLPrimitiveType RefreshToMetal_PrimitiveType[] = {
    MTLPrimitiveTypePoint,        /* POINTLIST */
    MTLPrimitiveTypeLine,         /* LINELIST */
    MTLPrimitiveTypeLineStrip,    /* LINESTRIP */
    MTLPrimitiveTypeTriangle,     /* TRIANGLELIST */
    MTLPrimitiveTypeTriangleStrip /* TRIANGLESTRIP */
};

static MTLTriangleFillMode RefreshToMetal_PolygonMode[] = {
    MTLTriangleFillModeFill,  /* FILL */
    MTLTriangleFillModeLines, /* LINE */
};

static MTLCullMode RefreshToMetal_CullMode[] = {
    MTLCullModeNone,  /* NONE */
    MTLCullModeFront, /* FRONT */
    MTLCullModeBack,  /* BACK */
};

static MTLWinding RefreshToMetal_FrontFace[] = {
    MTLWindingCounterClockwise, /* COUNTER_CLOCKWISE */
    MTLWindingClockwise,        /* CLOCKWISE */
};

static MTLBlendFactor RefreshToMetal_BlendFactor[] = {
    MTLBlendFactorZero,                     /* ZERO */
    MTLBlendFactorOne,                      /* ONE */
    MTLBlendFactorSourceColor,              /* SRC_COLOR */
    MTLBlendFactorOneMinusSourceColor,      /* ONE_MINUS_SRC_COLOR */
    MTLBlendFactorDestinationColor,         /* DST_COLOR */
    MTLBlendFactorOneMinusDestinationColor, /* ONE_MINUS_DST_COLOR */
    MTLBlendFactorSourceAlpha,              /* SRC_ALPHA */
    MTLBlendFactorOneMinusSourceAlpha,      /* ONE_MINUS_SRC_ALPHA */
    MTLBlendFactorDestinationAlpha,         /* DST_ALPHA */
    MTLBlendFactorOneMinusDestinationAlpha, /* ONE_MINUS_DST_ALPHA */
    MTLBlendFactorBlendColor,               /* CONSTANT_COLOR */
    MTLBlendFactorOneMinusBlendColor,       /* ONE_MINUS_CONSTANT_COLOR */
    MTLBlendFactorSourceAlphaSaturated,     /* SRC_ALPHA_SATURATE */
};

static MTLBlendOperation RefreshToMetal_BlendOp[] = {
    MTLBlendOperationAdd,             /* ADD */
    MTLBlendOperationSubtract,        /* SUBTRACT */
    MTLBlendOperationReverseSubtract, /* REVERSE_SUBTRACT */
    MTLBlendOperationMin,             /* MIN */
    MTLBlendOperationMax,             /* MAX */
};

static MTLCompareFunction RefreshToMetal_CompareOp[] = {
    MTLCompareFunctionNever,        /* NEVER */
    MTLCompareFunctionLess,         /* LESS */
    MTLCompareFunctionEqual,        /* EQUAL */
    MTLCompareFunctionLessEqual,    /* LESS_OR_EQUAL */
    MTLCompareFunctionGreater,      /* GREATER */
    MTLCompareFunctionNotEqual,     /* NOT_EQUAL */
    MTLCompareFunctionGreaterEqual, /* GREATER_OR_EQUAL */
    MTLCompareFunctionAlways,       /* ALWAYS */
};

static MTLStencilOperation RefreshToMetal_StencilOp[] = {
    MTLStencilOperationKeep,           /* KEEP */
    MTLStencilOperationZero,           /* ZERO */
    MTLStencilOperationReplace,        /* REPLACE */
    MTLStencilOperationIncrementClamp, /* INCREMENT_AND_CLAMP */
    MTLStencilOperationDecrementClamp, /* DECREMENT_AND_CLAMP */
    MTLStencilOperationInvert,         /* INVERT */
    MTLStencilOperationIncrementWrap,  /* INCREMENT_AND_WRAP */
    MTLStencilOperationDecrementWrap,  /* DECREMENT_AND_WRAP */
};

static MTLSamplerAddressMode RefreshToMetal_SamplerAddressMode[] = {
    MTLSamplerAddressModeRepeat,       /* REPEAT */
    MTLSamplerAddressModeMirrorRepeat, /* MIRRORED_REPEAT */
    MTLSamplerAddressModeClampToEdge   /* CLAMP_TO_EDGE */
};

static MTLSamplerMinMagFilter RefreshToMetal_MinMagFilter[] = {
    MTLSamplerMinMagFilterNearest, /* NEAREST */
    MTLSamplerMinMagFilterLinear,  /* LINEAR */
};

static MTLSamplerMipFilter RefreshToMetal_MipFilter[] = {
    MTLSamplerMipFilterNearest, /* NEAREST */
    MTLSamplerMipFilterLinear,  /* LINEAR */
};

static MTLLoadAction RefreshToMetal_LoadOp[] = {
    MTLLoadActionLoad,     /* LOAD */
    MTLLoadActionClear,    /* CLEAR */
    MTLLoadActionDontCare, /* DONT_CARE */
};

static MTLVertexStepFunction RefreshToMetal_StepFunction[] = {
    MTLVertexStepFunctionPerVertex,
    MTLVertexStepFunctionPerInstance,
};

static NSUInteger RefreshToMetal_SampleCount[] = {
    1, /* REFRESH_SAMPLECOUNT_1 */
    2, /* REFRESH_SAMPLECOUNT_2 */
    4, /* REFRESH_SAMPLECOUNT_4 */
    8  /* REFRESH_SAMPLECOUNT_8 */
};

static Refresh_TextureFormat SwapchainCompositionToFormat[] = {
    REFRESH_TEXTUREFORMAT_B8G8R8A8,            /* SDR */
    REFRESH_TEXTUREFORMAT_B8G8R8A8_SRGB,       /* SDR_LINEAR */
    REFRESH_TEXTUREFORMAT_R16G16B16A16_SFLOAT, /* HDR_EXTENDED_LINEAR */
    REFRESH_TEXTUREFORMAT_R10G10B10A2,         /* HDR10_ST2048 */
};

static CFStringRef SwapchainCompositionToColorSpace[4]; /* initialized on device creation */

static MTLStoreAction RefreshToMetal_StoreOp(
    Refresh_StoreOp storeOp,
    Uint8 isMultisample)
{
    if (isMultisample) {
        if (storeOp == REFRESH_STOREOP_STORE) {
            return MTLStoreActionStoreAndMultisampleResolve;
        } else {
            return MTLStoreActionMultisampleResolve;
        }
    } else {
        if (storeOp == REFRESH_STOREOP_STORE) {
            return MTLStoreActionStore;
        } else {
            return MTLStoreActionDontCare;
        }
    }
};

static MTLColorWriteMask RefreshToMetal_ColorWriteMask(
    Refresh_ColorComponentFlagBits mask)
{
    MTLColorWriteMask result = 0;
    if (mask & REFRESH_COLORCOMPONENT_R_BIT) {
        result |= MTLColorWriteMaskRed;
    }
    if (mask & REFRESH_COLORCOMPONENT_G_BIT) {
        result |= MTLColorWriteMaskGreen;
    }
    if (mask & REFRESH_COLORCOMPONENT_B_BIT) {
        result |= MTLColorWriteMaskBlue;
    }
    if (mask & REFRESH_COLORCOMPONENT_A_BIT) {
        result |= MTLColorWriteMaskAlpha;
    }
    return result;
}

/* Structs */

typedef struct MetalTexture
{
    id<MTLTexture> handle;
    id<MTLTexture> msaaHandle;
    SDL_atomic_t referenceCount;
} MetalTexture;

typedef struct MetalTextureContainer
{
    Refresh_TextureCreateInfo createInfo;
    MetalTexture *activeTexture;
    Uint8 canBeCycled;

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

    Uint32 samplerCount;
    Uint32 uniformBufferCount;
    Uint32 storageBufferCount;
    Uint32 storageTextureCount;
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

    Uint32 vertexSamplerCount;
    Uint32 vertexUniformBufferCount;
    Uint32 vertexStorageBufferCount;
    Uint32 vertexStorageTextureCount;

    Uint32 fragmentSamplerCount;
    Uint32 fragmentUniformBufferCount;
    Uint32 fragmentStorageBufferCount;
    Uint32 fragmentStorageTextureCount;
} MetalGraphicsPipeline;

typedef struct MetalComputePipeline
{
    id<MTLComputePipelineState> handle;
    Uint32 readOnlyStorageTextureCount;
    Uint32 readWriteStorageTextureCount;
    Uint32 readOnlyStorageBufferCount;
    Uint32 readWriteStorageBufferCount;
    Uint32 uniformBufferCount;
    Uint32 threadCountX;
    Uint32 threadCountY;
    Uint32 threadCountZ;
} MetalComputePipeline;

typedef struct MetalBuffer
{
    id<MTLBuffer> handle;
    SDL_atomic_t referenceCount;
} MetalBuffer;

typedef struct MetalBufferContainer
{
    MetalBuffer *activeBuffer;
    Uint32 size;

    Uint32 bufferCapacity;
    Uint32 bufferCount;
    MetalBuffer **buffers;

    SDL_bool isPrivate;
    SDL_bool isWriteOnly;
    char *debugName;
} MetalBufferContainer;

typedef struct MetalUniformBuffer
{
    id<MTLBuffer> handle;
    Uint32 writeOffset;
    Uint32 drawOffset;
} MetalUniformBuffer;

typedef struct MetalRenderer MetalRenderer;

typedef struct MetalCommandBuffer
{
    CommandBufferCommonHeader common;
    MetalRenderer *renderer;

    /* Native Handle */
    id<MTLCommandBuffer> handle;

    /* Presentation */
    MetalWindowData **windowDatas;
    Uint32 windowDataCount;
    Uint32 windowDataCapacity;

    /* Render Pass */
    id<MTLRenderCommandEncoder> renderEncoder;
    MetalGraphicsPipeline *graphicsPipeline;
    MetalBuffer *indexBuffer;
    Uint32 indexBufferOffset;
    Refresh_IndexElementSize indexElementSize;

    /* Copy Pass */
    id<MTLBlitCommandEncoder> blitEncoder;

    /* Compute Pass */
    id<MTLComputeCommandEncoder> computeEncoder;
    MetalComputePipeline *computePipeline;

    /* Resource slot state */
    SDL_bool needVertexSamplerBind;
    SDL_bool needVertexStorageTextureBind;
    SDL_bool needVertexStorageBufferBind;
    SDL_bool needVertexUniformBind;

    SDL_bool needFragmentSamplerBind;
    SDL_bool needFragmentStorageTextureBind;
    SDL_bool needFragmentStorageBufferBind;
    SDL_bool needFragmentUniformBind;

    SDL_bool needComputeTextureBind;
    SDL_bool needComputeBufferBind;
    SDL_bool needComputeUniformBind;

    id<MTLSamplerState> vertexSamplers[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> vertexTextures[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> vertexStorageTextures[MAX_STORAGE_TEXTURES_PER_STAGE];
    id<MTLBuffer> vertexStorageBuffers[MAX_STORAGE_BUFFERS_PER_STAGE];

    id<MTLSamplerState> fragmentSamplers[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> fragmentTextures[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> fragmentStorageTextures[MAX_STORAGE_TEXTURES_PER_STAGE];
    id<MTLBuffer> fragmentStorageBuffers[MAX_STORAGE_BUFFERS_PER_STAGE];

    id<MTLTexture> computeReadOnlyTextures[MAX_STORAGE_TEXTURES_PER_STAGE];
    id<MTLBuffer> computeReadOnlyBuffers[MAX_STORAGE_BUFFERS_PER_STAGE];
    id<MTLTexture> computeReadWriteTextures[MAX_STORAGE_TEXTURES_PER_STAGE];
    id<MTLBuffer> computeReadWriteBuffers[MAX_STORAGE_BUFFERS_PER_STAGE];

    /* Uniform buffers */
    MetalUniformBuffer *vertexUniformBuffers[MAX_UNIFORM_BUFFERS_PER_STAGE];
    MetalUniformBuffer *fragmentUniformBuffers[MAX_UNIFORM_BUFFERS_PER_STAGE];
    MetalUniformBuffer *computeUniformBuffers[MAX_UNIFORM_BUFFERS_PER_STAGE];

    MetalUniformBuffer **usedUniformBuffers;
    Uint32 usedUniformBufferCount;
    Uint32 usedUniformBufferCapacity;

    /* Fences */
    MetalFence *fence;
    Uint8 autoReleaseFence;

    /* Reference Counting */
    MetalBuffer **usedBuffers;
    Uint32 usedBufferCount;
    Uint32 usedBufferCapacity;

    MetalTexture **usedTextures;
    Uint32 usedTextureCount;
    Uint32 usedTextureCapacity;
} MetalCommandBuffer;

typedef struct MetalSampler
{
    id<MTLSamplerState> handle;
} MetalSampler;

typedef struct BlitPipeline
{
    Refresh_GraphicsPipeline *pipeline;
    Refresh_TextureFormat format;
} BlitPipeline;

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

    MetalUniformBuffer **uniformBufferPool;
    Uint32 uniformBufferPoolCount;
    Uint32 uniformBufferPoolCapacity;

    MetalBufferContainer **bufferContainersToDestroy;
    Uint32 bufferContainersToDestroyCount;
    Uint32 bufferContainersToDestroyCapacity;

    MetalTextureContainer **textureContainersToDestroy;
    Uint32 textureContainersToDestroyCount;
    Uint32 textureContainersToDestroyCapacity;

    /* Blit */
    Refresh_Shader *fullscreenVertexShader;
    Refresh_Shader *blitFrom2DPixelShader;
    Refresh_GraphicsPipeline *blitFrom2DPipeline;
    Refresh_Sampler *blitNearestSampler;
    Refresh_Sampler *blitLinearSampler;

    BlitPipeline *blitPipelines;
    Uint32 blitPipelineCount;
    Uint32 blitPipelineCapacity;

    /* Mutexes */
    SDL_mutex *submitLock;
    SDL_mutex *acquireCommandBufferLock;
    SDL_mutex *acquireUniformBufferLock;
    SDL_mutex *disposeLock;
    SDL_mutex *fenceLock;
    SDL_mutex *windowLock;
};

/* Helper Functions */

static Uint32 METAL_INTERNAL_GetVertexBufferIndex(Uint32 binding)
{
    return METAL_MAX_BUFFER_COUNT - 1 - binding;
}

/* FIXME: This should be moved into Refresh_driver.h */
static inline Uint32 METAL_INTERNAL_NextHighestAlignment(
    Uint32 n,
    Uint32 align)
{
    return align * ((n + align - 1) / align);
}

/* Quit */

static void METAL_DestroyDevice(Refresh_Device *device)
{
    MetalRenderer *renderer = (MetalRenderer *)device->driverData;

    /* Flush any remaining GPU work... */
    METAL_Wait(device->driverData);

    /* Release the window data */
    for (Sint32 i = renderer->claimedWindowCount - 1; i >= 0; i -= 1) {
        METAL_UnclaimWindow(device->driverData, renderer->claimedWindows[i]->window);
    }
    SDL_free(renderer->claimedWindows);

    /* Release the blit resources */
    METAL_INTERNAL_DestroyBlitResources(device->driverData);

    /* Release UBOs */
    for (Uint32 i = 0; i < renderer->uniformBufferPoolCount; i += 1) {
        SDL_free(renderer->uniformBufferPool[i]);
    }
    SDL_free(renderer->uniformBufferPool);

    /* Release command buffer infrastructure */
    for (Uint32 i = 0; i < renderer->availableCommandBufferCount; i += 1) {
        MetalCommandBuffer *commandBuffer = renderer->availableCommandBuffers[i];
        SDL_free(commandBuffer->usedBuffers);
        SDL_free(commandBuffer->usedTextures);
        SDL_free(commandBuffer);
    }
    SDL_free(renderer->availableCommandBuffers);
    SDL_free(renderer->submittedCommandBuffers);

    /* Release fence infrastructure */
    for (Uint32 i = 0; i < renderer->availableFenceCount; i += 1) {
        MetalFence *fence = renderer->availableFences[i];
        SDL_free(fence);
    }
    SDL_free(renderer->availableFences);

    /* Release the mutexes */
    SDL_DestroyMutex(renderer->submitLock);
    SDL_DestroyMutex(renderer->acquireCommandBufferLock);
    SDL_DestroyMutex(renderer->acquireUniformBufferLock);
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
    MetalBuffer *buffer)
{
    TRACK_RESOURCE(
        buffer,
        MetalBuffer *,
        usedBuffers,
        usedBufferCount,
        usedBufferCapacity);
}

static void METAL_INTERNAL_TrackTexture(
    MetalCommandBuffer *commandBuffer,
    MetalTexture *texture)
{
    TRACK_RESOURCE(
        texture,
        MetalTexture *,
        usedTextures,
        usedTextureCount,
        usedTextureCapacity);
}

static void METAL_INTERNAL_TrackUniformBuffer(
    MetalCommandBuffer *commandBuffer,
    MetalUniformBuffer *uniformBuffer)
{
    Uint32 i;
    for (i = 0; i < commandBuffer->usedUniformBufferCount; i += 1) {
        if (commandBuffer->usedUniformBuffers[i] == uniformBuffer) {
            return;
        }
    }

    if (commandBuffer->usedUniformBufferCount == commandBuffer->usedUniformBufferCapacity) {
        commandBuffer->usedUniformBufferCapacity += 1;
        commandBuffer->usedUniformBuffers = SDL_realloc(
            commandBuffer->usedUniformBuffers,
            commandBuffer->usedUniformBufferCapacity * sizeof(MetalUniformBuffer *));
    }

    commandBuffer->usedUniformBuffers[commandBuffer->usedUniformBufferCount] = uniformBuffer;
    commandBuffer->usedUniformBufferCount += 1;
}

/* Shader Compilation */

typedef struct MetalLibraryFunction
{
    id<MTLLibrary> library;
    id<MTLFunction> function;
} MetalLibraryFunction;

static MetalLibraryFunction METAL_INTERNAL_CompileShader(
    MetalRenderer *renderer,
    Refresh_ShaderFormat format,
    const Uint8 *code,
    size_t codeSize,
    const char *entryPointName)
{
    MetalLibraryFunction libraryFunction = { nil, nil };
    id<MTLLibrary> library;
    NSError *error;
    dispatch_data_t data;
    id<MTLFunction> function;

    if (format == REFRESH_SHADERFORMAT_MSL) {
        library = [renderer->device
            newLibraryWithSource:@((const char *)code)
                         options:nil
                           error:&error];
    } else if (format == REFRESH_SHADERFORMAT_METALLIB) {
        data = dispatch_data_create(
            code,
            codeSize,
            dispatch_get_global_queue(0, 0),
            ^{ /* do nothing */ });
        library = [renderer->device newLibraryWithData:data error:&error];
    } else {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Incompatible shader format for Metal");
        return libraryFunction;
    }

    if (library == nil) {
        SDL_LogError(
            SDL_LOG_CATEGORY_APPLICATION,
            "Creating MTLLibrary failed: %s",
            [[error description] cStringUsingEncoding:[NSString defaultCStringEncoding]]);
        return libraryFunction;
    } else if (error != nil) {
        SDL_LogWarn(
            SDL_LOG_CATEGORY_APPLICATION,
            "Creating MTLLibrary failed: %s",
            [[error description] cStringUsingEncoding:[NSString defaultCStringEncoding]]);
    }

    function = [library newFunctionWithName:@(entryPointName)];
    if (function == nil) {
        SDL_LogError(
            SDL_LOG_CATEGORY_APPLICATION,
            "Creating MTLFunction failed");
        return libraryFunction;
    }

    libraryFunction.library = library;
    libraryFunction.function = function;
    return libraryFunction;
}

/* Disposal */

static void METAL_INTERNAL_DestroyTextureContainer(
    MetalTextureContainer *container)
{
    for (Uint32 i = 0; i < container->textureCount; i += 1) {
        SDL_free(container->textures[i]);
    }
    if (container->debugName != NULL) {
        SDL_free(container->debugName);
    }
    SDL_free(container->textures);
    SDL_free(container);
}

static void METAL_ReleaseTexture(
    Refresh_Renderer *driverData,
    Refresh_Texture *texture)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalTextureContainer *container = (MetalTextureContainer *)texture;

    SDL_LockMutex(renderer->disposeLock);

    EXPAND_ARRAY_IF_NEEDED(
        renderer->textureContainersToDestroy,
        MetalTextureContainer *,
        renderer->textureContainersToDestroyCount + 1,
        renderer->textureContainersToDestroyCapacity,
        renderer->textureContainersToDestroyCapacity + 1);

    renderer->textureContainersToDestroy[renderer->textureContainersToDestroyCount] = container;
    renderer->textureContainersToDestroyCount += 1;

    SDL_UnlockMutex(renderer->disposeLock);
}

static void METAL_ReleaseSampler(
    Refresh_Renderer *driverData,
    Refresh_Sampler *sampler)
{
    (void)driverData; /* used by other backends */
    MetalSampler *metalSampler = (MetalSampler *)sampler;
    SDL_free(metalSampler);
}

static void METAL_INTERNAL_DestroyBufferContainer(
    MetalBufferContainer *container)
{
    for (Uint32 i = 0; i < container->bufferCount; i += 1) {
        SDL_free(container->buffers[i]);
    }
    if (container->debugName != NULL) {
        SDL_free(container->debugName);
    }
    SDL_free(container->buffers);
    SDL_free(container);
}

static void METAL_ReleaseBuffer(
    Refresh_Renderer *driverData,
    Refresh_Buffer *buffer)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalBufferContainer *container = (MetalBufferContainer *)buffer;

    SDL_LockMutex(renderer->disposeLock);

    EXPAND_ARRAY_IF_NEEDED(
        renderer->bufferContainersToDestroy,
        MetalBufferContainer *,
        renderer->bufferContainersToDestroyCount + 1,
        renderer->bufferContainersToDestroyCapacity,
        renderer->bufferContainersToDestroyCapacity + 1);

    renderer->bufferContainersToDestroy[renderer->bufferContainersToDestroyCount] = container;
    renderer->bufferContainersToDestroyCount += 1;

    SDL_UnlockMutex(renderer->disposeLock);
}

static void METAL_ReleaseTransferBuffer(
    Refresh_Renderer *driverData,
    Refresh_TransferBuffer *transferBuffer)
{
    METAL_ReleaseBuffer(
        driverData,
        (Refresh_Buffer *)transferBuffer);
}

static void METAL_ReleaseShader(
    Refresh_Renderer *driverData,
    Refresh_Shader *shader)
{
    (void)driverData; /* used by other backends */
    MetalShader *metalShader = (MetalShader *)shader;
    SDL_free(metalShader);
}

static void METAL_ReleaseComputePipeline(
    Refresh_Renderer *driverData,
    Refresh_ComputePipeline *computePipeline)
{
    (void)driverData; /* used by other backends */
    MetalComputePipeline *metalComputePipeline = (MetalComputePipeline *)computePipeline;
    /* TODO: Tear down resource layout structure */
    SDL_free(metalComputePipeline);
}

static void METAL_ReleaseGraphicsPipeline(
    Refresh_Renderer *driverData,
    Refresh_GraphicsPipeline *graphicsPipeline)
{
    (void)driverData; /* used by other backends */
    MetalGraphicsPipeline *metalGraphicsPipeline = (MetalGraphicsPipeline *)graphicsPipeline;
    /* TODO: Tear down resource layout structure */
    SDL_free(metalGraphicsPipeline);
}

/* Pipeline Creation */

static Refresh_ComputePipeline *METAL_CreateComputePipeline(
    Refresh_Renderer *driverData,
    Refresh_ComputePipelineCreateInfo *pipelineCreateInfo)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalLibraryFunction libraryFunction;
    id<MTLComputePipelineState> handle;
    MetalComputePipeline *pipeline;
    NSError *error;

    libraryFunction = METAL_INTERNAL_CompileShader(
        renderer,
        pipelineCreateInfo->format,
        pipelineCreateInfo->code,
        pipelineCreateInfo->codeSize,
        pipelineCreateInfo->entryPointName);

    if (libraryFunction.library == nil || libraryFunction.function == nil) {
        return NULL;
    }

    handle = [renderer->device newComputePipelineStateWithFunction:libraryFunction.function error:&error];
    if (error != NULL) {
        SDL_LogError(
            SDL_LOG_CATEGORY_APPLICATION,
            "Creating compute pipeline failed: %s", [[error description] UTF8String]);
        return NULL;
    }

    pipeline = SDL_malloc(sizeof(MetalComputePipeline));
    pipeline->handle = handle;
    pipeline->readOnlyStorageTextureCount = pipelineCreateInfo->readOnlyStorageTextureCount;
    pipeline->readWriteStorageTextureCount = pipelineCreateInfo->readWriteStorageTextureCount;
    pipeline->readOnlyStorageBufferCount = pipelineCreateInfo->readOnlyStorageBufferCount;
    pipeline->readWriteStorageBufferCount = pipelineCreateInfo->readWriteStorageBufferCount;
    pipeline->uniformBufferCount = pipelineCreateInfo->uniformBufferCount;
    pipeline->threadCountX = pipelineCreateInfo->threadCountX;
    pipeline->threadCountY = pipelineCreateInfo->threadCountY;
    pipeline->threadCountZ = pipelineCreateInfo->threadCountZ;

    return (Refresh_ComputePipeline *)pipeline;
}

static Refresh_GraphicsPipeline *METAL_CreateGraphicsPipeline(
    Refresh_Renderer *driverData,
    Refresh_GraphicsPipelineCreateInfo *pipelineCreateInfo)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalShader *vertexShader = (MetalShader *)pipelineCreateInfo->vertexShader;
    MetalShader *fragmentShader = (MetalShader *)pipelineCreateInfo->fragmentShader;
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

    for (Uint32 i = 0; i < pipelineCreateInfo->attachmentInfo.colorAttachmentCount; i += 1) {
        blendState = &pipelineCreateInfo->attachmentInfo.colorAttachmentDescriptions[i].blendState;

        pipelineDescriptor.colorAttachments[i].pixelFormat = RefreshToMetal_SurfaceFormat[pipelineCreateInfo->attachmentInfo.colorAttachmentDescriptions[i].format];
        pipelineDescriptor.colorAttachments[i].writeMask = RefreshToMetal_ColorWriteMask(blendState->colorWriteMask);
        pipelineDescriptor.colorAttachments[i].blendingEnabled = blendState->blendEnable;
        pipelineDescriptor.colorAttachments[i].rgbBlendOperation = RefreshToMetal_BlendOp[blendState->colorBlendOp];
        pipelineDescriptor.colorAttachments[i].alphaBlendOperation = RefreshToMetal_BlendOp[blendState->alphaBlendOp];
        pipelineDescriptor.colorAttachments[i].sourceRGBBlendFactor = RefreshToMetal_BlendFactor[blendState->srcColorBlendFactor];
        pipelineDescriptor.colorAttachments[i].sourceAlphaBlendFactor = RefreshToMetal_BlendFactor[blendState->srcAlphaBlendFactor];
        pipelineDescriptor.colorAttachments[i].destinationRGBBlendFactor = RefreshToMetal_BlendFactor[blendState->dstColorBlendFactor];
        pipelineDescriptor.colorAttachments[i].destinationAlphaBlendFactor = RefreshToMetal_BlendFactor[blendState->dstAlphaBlendFactor];
    }

    /* Multisample */

    pipelineDescriptor.rasterSampleCount = RefreshToMetal_SampleCount[pipelineCreateInfo->multisampleState.multisampleCount];

    /* Depth Stencil */

    if (pipelineCreateInfo->attachmentInfo.hasDepthStencilAttachment) {
        pipelineDescriptor.depthAttachmentPixelFormat = RefreshToMetal_SurfaceFormat[pipelineCreateInfo->attachmentInfo.depthStencilFormat];

        if (pipelineCreateInfo->depthStencilState.stencilTestEnable) {
            pipelineDescriptor.stencilAttachmentPixelFormat = RefreshToMetal_SurfaceFormat[pipelineCreateInfo->attachmentInfo.depthStencilFormat];

            frontStencilDescriptor = [MTLStencilDescriptor new];
            frontStencilDescriptor.stencilCompareFunction = RefreshToMetal_CompareOp[pipelineCreateInfo->depthStencilState.frontStencilState.compareOp];
            frontStencilDescriptor.stencilFailureOperation = RefreshToMetal_StencilOp[pipelineCreateInfo->depthStencilState.frontStencilState.failOp];
            frontStencilDescriptor.depthStencilPassOperation = RefreshToMetal_StencilOp[pipelineCreateInfo->depthStencilState.frontStencilState.passOp];
            frontStencilDescriptor.depthFailureOperation = RefreshToMetal_StencilOp[pipelineCreateInfo->depthStencilState.frontStencilState.depthFailOp];
            frontStencilDescriptor.readMask = pipelineCreateInfo->depthStencilState.compareMask;
            frontStencilDescriptor.writeMask = pipelineCreateInfo->depthStencilState.writeMask;

            backStencilDescriptor = [MTLStencilDescriptor new];
            backStencilDescriptor.stencilCompareFunction = RefreshToMetal_CompareOp[pipelineCreateInfo->depthStencilState.backStencilState.compareOp];
            backStencilDescriptor.stencilFailureOperation = RefreshToMetal_StencilOp[pipelineCreateInfo->depthStencilState.backStencilState.failOp];
            backStencilDescriptor.depthStencilPassOperation = RefreshToMetal_StencilOp[pipelineCreateInfo->depthStencilState.backStencilState.passOp];
            backStencilDescriptor.depthFailureOperation = RefreshToMetal_StencilOp[pipelineCreateInfo->depthStencilState.backStencilState.depthFailOp];
            backStencilDescriptor.readMask = pipelineCreateInfo->depthStencilState.compareMask;
            backStencilDescriptor.writeMask = pipelineCreateInfo->depthStencilState.writeMask;
        }

        depthStencilDescriptor = [MTLDepthStencilDescriptor new];
        depthStencilDescriptor.depthCompareFunction = pipelineCreateInfo->depthStencilState.depthTestEnable ? RefreshToMetal_CompareOp[pipelineCreateInfo->depthStencilState.compareOp] : MTLCompareFunctionAlways;
        depthStencilDescriptor.depthWriteEnabled = pipelineCreateInfo->depthStencilState.depthWriteEnable;
        depthStencilDescriptor.frontFaceStencil = frontStencilDescriptor;
        depthStencilDescriptor.backFaceStencil = backStencilDescriptor;

        depthStencilState = [renderer->device newDepthStencilStateWithDescriptor:depthStencilDescriptor];
    }

    /* Shaders */

    pipelineDescriptor.vertexFunction = vertexShader->function;
    pipelineDescriptor.fragmentFunction = fragmentShader->function;

    /* Vertex Descriptor */

    if (pipelineCreateInfo->vertexInputState.vertexBindingCount > 0) {
        vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];

        for (Uint32 i = 0; i < pipelineCreateInfo->vertexInputState.vertexAttributeCount; i += 1) {
            Uint32 loc = pipelineCreateInfo->vertexInputState.vertexAttributes[i].location;
            vertexDescriptor.attributes[loc].format = RefreshToMetal_VertexFormat[pipelineCreateInfo->vertexInputState.vertexAttributes[i].format];
            vertexDescriptor.attributes[loc].offset = pipelineCreateInfo->vertexInputState.vertexAttributes[i].offset;
            vertexDescriptor.attributes[loc].bufferIndex = METAL_INTERNAL_GetVertexBufferIndex(pipelineCreateInfo->vertexInputState.vertexAttributes[i].binding);
        }

        for (Uint32 i = 0; i < pipelineCreateInfo->vertexInputState.vertexBindingCount; i += 1) {
            binding = METAL_INTERNAL_GetVertexBufferIndex(pipelineCreateInfo->vertexInputState.vertexBindings[i].binding);
            vertexDescriptor.layouts[binding].stepFunction = RefreshToMetal_StepFunction[pipelineCreateInfo->vertexInputState.vertexBindings[i].inputRate];
            vertexDescriptor.layouts[binding].stride = pipelineCreateInfo->vertexInputState.vertexBindings[i].stride;
        }

        pipelineDescriptor.vertexDescriptor = vertexDescriptor;
    }

    /* Create the graphics pipeline */

    pipelineState = [renderer->device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if (error != NULL) {
        SDL_LogError(
            SDL_LOG_CATEGORY_APPLICATION,
            "Creating render pipeline failed: %s", [[error description] UTF8String]);
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
    result->vertexSamplerCount = vertexShader->samplerCount;
    result->vertexUniformBufferCount = vertexShader->uniformBufferCount;
    result->vertexStorageBufferCount = vertexShader->storageBufferCount;
    result->vertexStorageTextureCount = vertexShader->storageTextureCount;
    result->fragmentSamplerCount = fragmentShader->samplerCount;
    result->fragmentUniformBufferCount = fragmentShader->uniformBufferCount;
    result->fragmentStorageBufferCount = fragmentShader->storageBufferCount;
    result->fragmentStorageTextureCount = fragmentShader->storageTextureCount;
    return (Refresh_GraphicsPipeline *)result;
}

/* Debug Naming */

static void METAL_INTERNAL_SetBufferName(
    MetalBuffer *buffer,
    const char *text)
{
    buffer->handle.label = @(text);
}

static void METAL_SetBufferName(
    Refresh_Renderer *driverData,
    Refresh_Buffer *buffer,
    const char *text)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalBufferContainer *container = (MetalBufferContainer *)buffer;
    size_t textLength = SDL_strlen(text) + 1;

    if (renderer->debugMode) {
        container->debugName = SDL_realloc(
            container->debugName,
            textLength);

        SDL_utf8strlcpy(
            container->debugName,
            text,
            textLength);

        for (Uint32 i = 0; i < container->bufferCount; i += 1) {
            METAL_INTERNAL_SetBufferName(
                container->buffers[i],
                text);
        }
    }
}

static void METAL_INTERNAL_SetTextureName(
    MetalTexture *texture,
    const char *text)
{
    texture->handle.label = @(text);
}

static void METAL_SetTextureName(
    Refresh_Renderer *driverData,
    Refresh_Texture *texture,
    const char *text)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalTextureContainer *container = (MetalTextureContainer *)texture;
    size_t textLength = SDL_strlen(text) + 1;

    if (renderer->debugMode) {
        container->debugName = SDL_realloc(
            container->debugName,
            textLength);

        SDL_utf8strlcpy(
            container->debugName,
            text,
            textLength);

        for (Uint32 i = 0; i < container->textureCount; i += 1) {
            METAL_INTERNAL_SetTextureName(
                container->textures[i],
                text);
        }
    }
}

static void METAL_InsertDebugLabel(
    Refresh_CommandBuffer *commandBuffer,
    const char *text)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    NSString *label = @(text);

    if (metalCommandBuffer->renderEncoder) {
        [metalCommandBuffer->renderEncoder insertDebugSignpost:label];
    } else if (metalCommandBuffer->blitEncoder) {
        [metalCommandBuffer->blitEncoder insertDebugSignpost:label];
    } else if (metalCommandBuffer->computeEncoder) {
        [metalCommandBuffer->computeEncoder insertDebugSignpost:label];
    } else {
        /* Metal doesn't have insertDebugSignpost for command buffers... */
        [metalCommandBuffer->handle pushDebugGroup:label];
        [metalCommandBuffer->handle popDebugGroup];
    }
}

static void METAL_PushDebugGroup(
    Refresh_CommandBuffer *commandBuffer,
    const char *name)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    NSString *label = @(name);

    if (metalCommandBuffer->renderEncoder) {
        [metalCommandBuffer->renderEncoder pushDebugGroup:label];
    } else if (metalCommandBuffer->blitEncoder) {
        [metalCommandBuffer->blitEncoder pushDebugGroup:label];
    } else if (metalCommandBuffer->computeEncoder) {
        [metalCommandBuffer->computeEncoder pushDebugGroup:label];
    } else {
        [metalCommandBuffer->handle pushDebugGroup:label];
    }
}

static void METAL_PopDebugGroup(
    Refresh_CommandBuffer *commandBuffer)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;

    if (metalCommandBuffer->renderEncoder) {
        [metalCommandBuffer->renderEncoder popDebugGroup];
    } else if (metalCommandBuffer->blitEncoder) {
        [metalCommandBuffer->blitEncoder popDebugGroup];
    } else if (metalCommandBuffer->computeEncoder) {
        [metalCommandBuffer->computeEncoder popDebugGroup];
    } else {
        [metalCommandBuffer->handle popDebugGroup];
    }
}

/* Resource Creation */

static Refresh_Sampler *METAL_CreateSampler(
    Refresh_Renderer *driverData,
    Refresh_SamplerCreateInfo *samplerCreateInfo)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MTLSamplerDescriptor *samplerDesc = [MTLSamplerDescriptor new];
    id<MTLSamplerState> sampler;
    MetalSampler *metalSampler;

    samplerDesc.rAddressMode = RefreshToMetal_SamplerAddressMode[samplerCreateInfo->addressModeU];
    samplerDesc.sAddressMode = RefreshToMetal_SamplerAddressMode[samplerCreateInfo->addressModeV];
    samplerDesc.tAddressMode = RefreshToMetal_SamplerAddressMode[samplerCreateInfo->addressModeW];
    samplerDesc.minFilter = RefreshToMetal_MinMagFilter[samplerCreateInfo->minFilter];
    samplerDesc.magFilter = RefreshToMetal_MinMagFilter[samplerCreateInfo->magFilter];
    samplerDesc.mipFilter = RefreshToMetal_MipFilter[samplerCreateInfo->mipmapMode]; /* FIXME: Is this right with non-mipmapped samplers? */
    samplerDesc.lodMinClamp = samplerCreateInfo->minLod;
    samplerDesc.lodMaxClamp = samplerCreateInfo->maxLod;
    samplerDesc.maxAnisotropy = (NSUInteger)((samplerCreateInfo->anisotropyEnable) ? samplerCreateInfo->maxAnisotropy : 1);
    samplerDesc.compareFunction = (samplerCreateInfo->compareEnable) ? RefreshToMetal_CompareOp[samplerCreateInfo->compareOp] : MTLCompareFunctionAlways;
    samplerDesc.borderColor = MTLSamplerBorderColorTransparentBlack; /* arbitrary, unused */

    sampler = [renderer->device newSamplerStateWithDescriptor:samplerDesc];
    if (sampler == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to create sampler");
        return NULL;
    }

    metalSampler = (MetalSampler *)SDL_malloc(sizeof(MetalSampler));
    metalSampler->handle = sampler;
    return (Refresh_Sampler *)metalSampler;
}

static Refresh_Shader *METAL_CreateShader(
    Refresh_Renderer *driverData,
    Refresh_ShaderCreateInfo *shaderCreateInfo)
{
    MetalLibraryFunction libraryFunction;
    MetalShader *result;

    libraryFunction = METAL_INTERNAL_CompileShader(
        (MetalRenderer *)driverData,
        shaderCreateInfo->format,
        shaderCreateInfo->code,
        shaderCreateInfo->codeSize,
        shaderCreateInfo->entryPointName);

    if (libraryFunction.library == nil || libraryFunction.function == nil) {
        return NULL;
    }

    result = SDL_malloc(sizeof(MetalShader));
    result->library = libraryFunction.library;
    result->function = libraryFunction.function;
    result->samplerCount = shaderCreateInfo->samplerCount;
    result->storageBufferCount = shaderCreateInfo->storageBufferCount;
    result->storageTextureCount = shaderCreateInfo->storageTextureCount;
    result->uniformBufferCount = shaderCreateInfo->uniformBufferCount;
    return (Refresh_Shader *)result;
}

static MetalTexture *METAL_INTERNAL_CreateTexture(
    MetalRenderer *renderer,
    Refresh_TextureCreateInfo *textureCreateInfo)
{
    MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor new];
    id<MTLTexture> texture;
    id<MTLTexture> msaaTexture = NULL;
    MetalTexture *metalTexture;

    if (textureCreateInfo->depth <= 1) {
        if (textureCreateInfo->isCube) {
            textureDescriptor.textureType = MTLTextureTypeCube;
        } else if (textureCreateInfo->layerCount > 1) {
            textureDescriptor.textureType = MTLTextureType2DArray;
        } else {
            textureDescriptor.textureType = MTLTextureType2D;
        }
    } else {
        textureDescriptor.textureType = MTLTextureType3D;
    }

    textureDescriptor.pixelFormat = RefreshToMetal_SurfaceFormat[textureCreateInfo->format];
    /* This format isn't natively supported so let's swizzle! */
    if (textureCreateInfo->format == REFRESH_TEXTUREFORMAT_B4G4R4A4) {
        textureDescriptor.swizzle = MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleBlue,
            MTLTextureSwizzleGreen,
            MTLTextureSwizzleRed,
            MTLTextureSwizzleAlpha);
    }

    textureDescriptor.width = textureCreateInfo->width;
    textureDescriptor.height = textureCreateInfo->height;
    textureDescriptor.depth = textureCreateInfo->depth;
    textureDescriptor.mipmapLevelCount = textureCreateInfo->levelCount;
    textureDescriptor.sampleCount = 1;
    textureDescriptor.arrayLength = (textureCreateInfo->isCube) ? 1 : textureCreateInfo->layerCount; /* FIXME: Cube arrays? */
    textureDescriptor.storageMode = MTLStorageModePrivate;

    textureDescriptor.usage = 0;
    if (textureCreateInfo->usageFlags & (REFRESH_TEXTUREUSAGE_COLOR_TARGET_BIT |
                                         REFRESH_TEXTUREUSAGE_DEPTH_STENCIL_TARGET_BIT)) {
        textureDescriptor.usage |= MTLTextureUsageRenderTarget;
    }
    if (textureCreateInfo->usageFlags & (REFRESH_TEXTUREUSAGE_SAMPLER_BIT |
                                         REFRESH_TEXTUREUSAGE_GRAPHICS_STORAGE_READ_BIT |
                                         REFRESH_TEXTUREUSAGE_COMPUTE_STORAGE_READ_BIT)) {
        textureDescriptor.usage |= MTLTextureUsageShaderRead;
    }
    if (textureCreateInfo->usageFlags & REFRESH_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE_BIT) {
        textureDescriptor.usage |= MTLTextureUsageShaderWrite;
    }

    texture = [renderer->device newTextureWithDescriptor:textureDescriptor];
    if (texture == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to create MTLTexture!");
        return NULL;
    }

    /* Create the MSAA texture, if needed */
    if (textureCreateInfo->sampleCount > REFRESH_SAMPLECOUNT_1 && textureDescriptor.textureType == MTLTextureType2D) {
        textureDescriptor.textureType = MTLTextureType2DMultisample;
        textureDescriptor.sampleCount = RefreshToMetal_SampleCount[textureCreateInfo->sampleCount];
        textureDescriptor.usage = MTLTextureUsageRenderTarget;

        msaaTexture = [renderer->device newTextureWithDescriptor:textureDescriptor];
        if (msaaTexture == NULL) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to create MSAA MTLTexture!");
            return NULL;
        }
    }

    metalTexture = (MetalTexture *)SDL_malloc(sizeof(MetalTexture));
    metalTexture->handle = texture;
    metalTexture->msaaHandle = msaaTexture;
    SDL_AtomicSet(&metalTexture->referenceCount, 0);
    return metalTexture;
}

static Refresh_SampleCount METAL_GetBestSampleCount(
    Refresh_Renderer *driverData,
    Refresh_TextureFormat format,
    Refresh_SampleCount desiredSampleCount)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    Refresh_SampleCount highestSupported = desiredSampleCount;

    if ((format == REFRESH_TEXTUREFORMAT_R32_SFLOAT ||
         format == REFRESH_TEXTUREFORMAT_R32G32_SFLOAT ||
         format == REFRESH_TEXTUREFORMAT_R32G32B32A32_SFLOAT)) {
        if (@available(macOS 11.0, *)) {
            if (![renderer->device supports32BitMSAA]) {
                return REFRESH_SAMPLECOUNT_1;
            }
        } else {
            return REFRESH_SAMPLECOUNT_1;
        }
    }

    while (highestSupported > REFRESH_SAMPLECOUNT_1) {
        if ([renderer->device supportsTextureSampleCount:(1 << highestSupported)]) {
            break;
        }
        highestSupported -= 1;
    }

    return highestSupported;
}

static Refresh_Texture *METAL_CreateTexture(
    Refresh_Renderer *driverData,
    Refresh_TextureCreateInfo *textureCreateInfo)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalTextureContainer *container;
    MetalTexture *texture;
    Refresh_TextureCreateInfo newTextureCreateInfo = *textureCreateInfo;

    newTextureCreateInfo.sampleCount = METAL_GetBestSampleCount(
        driverData,
        textureCreateInfo->format,
        textureCreateInfo->sampleCount);

    texture = METAL_INTERNAL_CreateTexture(
        renderer,
        &newTextureCreateInfo);

    if (texture == NULL) {
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
        container->textureCapacity * sizeof(MetalTexture *));
    container->textures[0] = texture;
    container->debugName = NULL;

    return (Refresh_Texture *)container;
}

static void METAL_INTERNAL_CycleActiveTexture(
    MetalRenderer *renderer,
    MetalTextureContainer *container)
{
    for (Uint32 i = 0; i < container->textureCount; i += 1) {
        container->activeTexture = container->textures[i];
        return;
    }

    EXPAND_ARRAY_IF_NEEDED(
        container->textures,
        MetalTexture *,
        container->textureCount + 1,
        container->textureCapacity,
        container->textureCapacity + 1);

    container->textures[container->textureCount] = METAL_INTERNAL_CreateTexture(
        renderer,
        &container->createInfo);
    container->textureCount += 1;

    container->activeTexture = container->textures[container->textureCount - 1];

    if (renderer->debugMode && container->debugName != NULL) {
        METAL_INTERNAL_SetTextureName(
            container->activeTexture,
            container->debugName);
    }
}

static MetalTexture *METAL_INTERNAL_PrepareTextureForWrite(
    MetalRenderer *renderer,
    MetalTextureContainer *container,
    SDL_bool cycle)
{
    if (cycle && container->canBeCycled) {
        METAL_INTERNAL_CycleActiveTexture(renderer, container);
    }
    return container->activeTexture;
}

static MetalBuffer *METAL_INTERNAL_CreateBuffer(
    MetalRenderer *renderer,
    Uint32 sizeInBytes,
    MTLResourceOptions resourceOptions)
{
    id<MTLBuffer> bufferHandle;
    MetalBuffer *metalBuffer;

    /* Storage buffers have to be 4-aligned, so might as well align them all */
    sizeInBytes = METAL_INTERNAL_NextHighestAlignment(sizeInBytes, 4);

    bufferHandle = [renderer->device newBufferWithLength:sizeInBytes options:resourceOptions];
    if (bufferHandle == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Could not create buffer");
        return NULL;
    }

    metalBuffer = SDL_malloc(sizeof(MetalBuffer));
    metalBuffer->handle = bufferHandle;
    SDL_AtomicSet(&metalBuffer->referenceCount, 0);

    return metalBuffer;
}

static MetalBufferContainer *METAL_INTERNAL_CreateBufferContainer(
    MetalRenderer *renderer,
    Uint32 sizeInBytes,
    SDL_bool isPrivate,
    SDL_bool isWriteOnly)
{
    MetalBufferContainer *container = SDL_malloc(sizeof(MetalBufferContainer));
    MTLResourceOptions resourceOptions;

    container->size = sizeInBytes;
    container->bufferCapacity = 1;
    container->bufferCount = 1;
    container->buffers = SDL_malloc(
        container->bufferCapacity * sizeof(MetalBuffer *));
    container->isPrivate = isPrivate;
    container->isWriteOnly = isWriteOnly;
    container->debugName = NULL;

    if (isPrivate) {
        resourceOptions = MTLResourceStorageModePrivate;
    } else {
        if (isWriteOnly) {
            resourceOptions = MTLResourceCPUCacheModeWriteCombined;
        } else {
            resourceOptions = MTLResourceCPUCacheModeDefaultCache;
        }
    }

    container->buffers[0] = METAL_INTERNAL_CreateBuffer(
        renderer,
        sizeInBytes,
        resourceOptions);
    container->activeBuffer = container->buffers[0];

    return container;
}

static Refresh_Buffer *METAL_CreateBuffer(
    Refresh_Renderer *driverData,
    Refresh_BufferUsageFlags usageFlags,
    Uint32 sizeInBytes)
{
    (void)usageFlags;
    return (Refresh_Buffer *)METAL_INTERNAL_CreateBufferContainer(
        (MetalRenderer *)driverData,
        sizeInBytes,
        SDL_TRUE,
        SDL_FALSE);
}

static Refresh_TransferBuffer *METAL_CreateTransferBuffer(
    Refresh_Renderer *driverData,
    Refresh_TransferBufferUsage usage,
    Uint32 sizeInBytes)
{
    return (Refresh_TransferBuffer *)METAL_INTERNAL_CreateBufferContainer(
        (MetalRenderer *)driverData,
        sizeInBytes,
        SDL_FALSE,
        usage == REFRESH_TRANSFERBUFFERUSAGE_UPLOAD);
}

static MetalUniformBuffer *METAL_INTERNAL_CreateUniformBuffer(
    MetalRenderer *renderer,
    Uint32 sizeInBytes)
{
    MetalUniformBuffer *uniformBuffer;
    id<MTLBuffer> bufferHandle;

    bufferHandle = [renderer->device newBufferWithLength:sizeInBytes options:MTLResourceCPUCacheModeWriteCombined];
    if (bufferHandle == nil) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Could not create uniform buffer");
        return NULL;
    }

    uniformBuffer = SDL_malloc(sizeof(MetalUniformBuffer));
    uniformBuffer->handle = bufferHandle;
    uniformBuffer->writeOffset = 0;
    uniformBuffer->drawOffset = 0;

    return uniformBuffer;
}

static void METAL_INTERNAL_CycleActiveBuffer(
    MetalRenderer *renderer,
    MetalBufferContainer *container)
{
    MTLResourceOptions resourceOptions;

    for (Uint32 i = 0; i < container->bufferCount; i += 1) {
        if (SDL_AtomicGet(&container->buffers[i]->referenceCount) == 0) {
            container->activeBuffer = container->buffers[i];
            return;
        }
    }

    EXPAND_ARRAY_IF_NEEDED(
        container->buffers,
        MetalBuffer *,
        container->bufferCount + 1,
        container->bufferCapacity,
        container->bufferCapacity + 1);

    if (container->isPrivate) {
        resourceOptions = MTLResourceStorageModePrivate;
    } else {
        if (container->isWriteOnly) {
            resourceOptions = MTLResourceCPUCacheModeWriteCombined;
        } else {
            resourceOptions = MTLResourceCPUCacheModeDefaultCache;
        }
    }

    container->buffers[container->bufferCount] = METAL_INTERNAL_CreateBuffer(
        renderer,
        container->size,
        resourceOptions);
    container->bufferCount += 1;

    container->activeBuffer = container->buffers[container->bufferCount - 1];

    if (renderer->debugMode && container->debugName != NULL) {
        METAL_INTERNAL_SetBufferName(
            container->activeBuffer,
            container->debugName);
    }
}

static MetalBuffer *METAL_INTERNAL_PrepareBufferForWrite(
    MetalRenderer *renderer,
    MetalBufferContainer *container,
    SDL_bool cycle)
{
    if (cycle && SDL_AtomicGet(&container->activeBuffer->referenceCount) > 0) {
        METAL_INTERNAL_CycleActiveBuffer(
            renderer,
            container);
    }

    return container->activeBuffer;
}

/* TransferBuffer Data */

static void METAL_MapTransferBuffer(
    Refresh_Renderer *driverData,
    Refresh_TransferBuffer *transferBuffer,
    SDL_bool cycle,
    void **ppData)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalBufferContainer *container = (MetalBufferContainer *)transferBuffer;
    MetalBuffer *buffer = container->activeBuffer;

    /* Rotate the transfer buffer if necessary */
    if (
        cycle &&
        SDL_AtomicGet(&container->activeBuffer->referenceCount) > 0) {
        METAL_INTERNAL_CycleActiveBuffer(
            renderer,
            container);
        buffer = container->activeBuffer;
    }

    *ppData = [buffer->handle contents];
}

static void METAL_UnmapTransferBuffer(
    Refresh_Renderer *driverData,
    Refresh_TransferBuffer *transferBuffer)
{
#ifdef __MACOSX__
    /* FIXME: Is this necessary? */
    MetalBufferContainer *container = (MetalBufferContainer *)transferBuffer;
    MetalBuffer *buffer = container->activeBuffer;
    if (buffer->handle.storageMode == MTLStorageModeManaged) {
        [buffer->handle didModifyRange:NSMakeRange(0, container->size)];
    }
#endif
}

static void METAL_SetTransferData(
    Refresh_Renderer *driverData,
    const void *source,
    Refresh_TransferBufferRegion *destination,
    SDL_bool cycle)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalBufferContainer *container = (MetalBufferContainer *)destination->transferBuffer;
    MetalBuffer *buffer = container->activeBuffer;

    /* Rotate the transfer buffer if necessary */
    if (cycle && SDL_AtomicGet(&container->activeBuffer->referenceCount) > 0) {
        METAL_INTERNAL_CycleActiveBuffer(
            renderer,
            container);
        buffer = container->activeBuffer;
    }

    SDL_memcpy(
        ((Uint8 *)buffer->handle.contents) + destination->offset,
        ((Uint8 *)source),
        destination->size);

#ifdef __MACOSX__
    /* FIXME: Is this necessary? */
    if (buffer->handle.storageMode == MTLStorageModeManaged) {
        [buffer->handle didModifyRange:NSMakeRange(destination->offset, destination->size)];
    }
#endif
}

static void METAL_GetTransferData(
    Refresh_Renderer *driverData,
    Refresh_TransferBufferRegion *source,
    void *destination)
{
    MetalBufferContainer *transferBufferContainer = (MetalBufferContainer *)source->transferBuffer;
    SDL_memcpy(
        ((Uint8 *)destination),
        ((Uint8 *)transferBufferContainer->activeBuffer->handle.contents) + source->offset,
        source->size);
}

/* Copy Pass */

static void METAL_BeginCopyPass(
    Refresh_CommandBuffer *commandBuffer)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    metalCommandBuffer->blitEncoder = [metalCommandBuffer->handle blitCommandEncoder];
}

static void METAL_UploadToTexture(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_TextureTransferInfo *source,
    Refresh_TextureRegion *destination,
    SDL_bool cycle)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalRenderer *renderer = metalCommandBuffer->renderer;
    MetalBufferContainer *bufferContainer = (MetalBufferContainer *)source->transferBuffer;
    MetalTextureContainer *textureContainer = (MetalTextureContainer *)destination->textureSlice.texture;

    MetalTexture *metalTexture = METAL_INTERNAL_PrepareTextureForWrite(renderer, textureContainer, cycle);

    [metalCommandBuffer->blitEncoder
             copyFromBuffer:bufferContainer->activeBuffer->handle
               sourceOffset:source->offset
          sourceBytesPerRow:BytesPerRow(destination->w, textureContainer->createInfo.format)
        sourceBytesPerImage:BytesPerImage(destination->w, destination->h, textureContainer->createInfo.format)
                 sourceSize:MTLSizeMake(destination->w, destination->h, destination->d)
                  toTexture:metalTexture->handle
           destinationSlice:destination->textureSlice.layer
           destinationLevel:destination->textureSlice.mipLevel
          destinationOrigin:MTLOriginMake(destination->x, destination->y, destination->z)];

    METAL_INTERNAL_TrackTexture(metalCommandBuffer, metalTexture);
    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, bufferContainer->activeBuffer);
}

static void METAL_UploadToBuffer(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_TransferBufferLocation *source,
    Refresh_BufferRegion *destination,
    SDL_bool cycle)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalRenderer *renderer = metalCommandBuffer->renderer;
    MetalBufferContainer *transferContainer = (MetalBufferContainer *)source->transferBuffer;
    MetalBufferContainer *bufferContainer = (MetalBufferContainer *)destination->buffer;

    MetalBuffer *metalBuffer = METAL_INTERNAL_PrepareBufferForWrite(
        renderer,
        bufferContainer,
        cycle);

    [metalCommandBuffer->blitEncoder
           copyFromBuffer:transferContainer->activeBuffer->handle
             sourceOffset:source->offset
                 toBuffer:metalBuffer->handle
        destinationOffset:destination->offset
                     size:destination->size];

    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalBuffer);
    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, transferContainer->activeBuffer);
}

static void METAL_CopyTextureToTexture(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_TextureLocation *source,
    Refresh_TextureLocation *destination,
    Uint32 w,
    Uint32 h,
    Uint32 d,
    SDL_bool cycle)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalRenderer *renderer = metalCommandBuffer->renderer;
    MetalTextureContainer *srcContainer = (MetalTextureContainer *)source->textureSlice.texture;
    MetalTextureContainer *dstContainer = (MetalTextureContainer *)destination->textureSlice.texture;

    MetalTexture *srcTexture = srcContainer->activeTexture;
    MetalTexture *dstTexture = METAL_INTERNAL_PrepareTextureForWrite(
        renderer,
        dstContainer,
        cycle);

    [metalCommandBuffer->blitEncoder
          copyFromTexture:srcTexture->handle
              sourceSlice:source->textureSlice.layer
              sourceLevel:source->textureSlice.mipLevel
             sourceOrigin:MTLOriginMake(source->x, source->y, source->z)
               sourceSize:MTLSizeMake(w, h, d)
                toTexture:dstTexture->handle
         destinationSlice:destination->textureSlice.layer
         destinationLevel:destination->textureSlice.mipLevel
        destinationOrigin:MTLOriginMake(destination->x, destination->y, destination->z)];

    METAL_INTERNAL_TrackTexture(metalCommandBuffer, srcTexture);
    METAL_INTERNAL_TrackTexture(metalCommandBuffer, dstTexture);
}

static void METAL_CopyBufferToBuffer(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_BufferLocation *source,
    Refresh_BufferLocation *destination,
    Uint32 size,
    SDL_bool cycle)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalRenderer *renderer = metalCommandBuffer->renderer;
    MetalBufferContainer *srcContainer = (MetalBufferContainer *)source->buffer;
    MetalBufferContainer *dstContainer = (MetalBufferContainer *)destination->buffer;

    MetalBuffer *srcBuffer = srcContainer->activeBuffer;
    MetalBuffer *dstBuffer = METAL_INTERNAL_PrepareBufferForWrite(
        renderer,
        dstContainer,
        cycle);

    [metalCommandBuffer->blitEncoder
           copyFromBuffer:srcBuffer->handle
             sourceOffset:source->offset
                 toBuffer:dstBuffer->handle
        destinationOffset:destination->offset
                     size:size];

    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, srcBuffer);
    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, dstBuffer);
}

static void METAL_GenerateMipmaps(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_Texture *texture)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *container = (MetalTextureContainer *)texture;
    MetalTexture *metalTexture = container->activeTexture;

    if (container->createInfo.levelCount <= 1) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Cannot generate mipmaps for texture with levelCount <= 1!");
        return;
    }

    [metalCommandBuffer->blitEncoder
        generateMipmapsForTexture:metalTexture->handle];

    METAL_INTERNAL_TrackTexture(metalCommandBuffer, metalTexture);
}

static void METAL_DownloadFromTexture(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_TextureRegion *source,
    Refresh_TextureTransferInfo *destination)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalRenderer *renderer = metalCommandBuffer->renderer;
    Refresh_TextureSlice *textureSlice = &source->textureSlice;
    MetalTextureContainer *textureContainer = (MetalTextureContainer *)textureSlice->texture;
    MetalTexture *metalTexture = textureContainer->activeTexture;
    MetalBufferContainer *bufferContainer = (MetalBufferContainer *)destination->transferBuffer;
    Uint32 bufferStride = destination->imagePitch;
    Uint32 bufferImageHeight = destination->imageHeight;
    Uint32 bytesPerRow, bytesPerDepthSlice;

    MetalBuffer *dstBuffer = METAL_INTERNAL_PrepareBufferForWrite(
        renderer,
        bufferContainer,
        SDL_FALSE);

    MTLOrigin regionOrigin = MTLOriginMake(
        source->x,
        source->y,
        source->z);

    MTLSize regionSize = MTLSizeMake(
        source->w,
        source->h,
        source->d);

    if (bufferStride == 0 || bufferImageHeight == 0) {
        bufferStride = source->w;
        bufferImageHeight = source->h;
    }

    bytesPerRow = BytesPerRow(bufferStride, textureContainer->createInfo.format);
    bytesPerDepthSlice = bytesPerRow * bufferImageHeight;

    [metalCommandBuffer->blitEncoder
                 copyFromTexture:metalTexture->handle
                     sourceSlice:textureSlice->layer
                     sourceLevel:textureSlice->mipLevel
                    sourceOrigin:regionOrigin
                      sourceSize:regionSize
                        toBuffer:dstBuffer->handle
               destinationOffset:destination->offset
          destinationBytesPerRow:bytesPerRow
        destinationBytesPerImage:bytesPerDepthSlice];

    METAL_INTERNAL_TrackTexture(metalCommandBuffer, metalTexture);
    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, dstBuffer);
}

static void METAL_DownloadFromBuffer(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_BufferRegion *source,
    Refresh_TransferBufferLocation *destination)
{
    Refresh_BufferLocation sourceLocation;
    sourceLocation.buffer = source->buffer;
    sourceLocation.offset = source->offset;

    METAL_CopyBufferToBuffer(
        commandBuffer,
        &sourceLocation,
        (Refresh_BufferLocation *)destination,
        source->size,
        SDL_FALSE);
}

static void METAL_EndCopyPass(
    Refresh_CommandBuffer *commandBuffer)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    [metalCommandBuffer->blitEncoder endEncoding];
    metalCommandBuffer->blitEncoder = nil;
}

/* Graphics State */

static void METAL_INTERNAL_AllocateCommandBuffers(
    MetalRenderer *renderer,
    Uint32 allocateCount)
{
    MetalCommandBuffer *commandBuffer;

    renderer->availableCommandBufferCapacity += allocateCount;

    renderer->availableCommandBuffers = SDL_realloc(
        renderer->availableCommandBuffers,
        sizeof(MetalCommandBuffer *) * renderer->availableCommandBufferCapacity);

    for (Uint32 i = 0; i < allocateCount; i += 1) {
        commandBuffer = SDL_calloc(1, sizeof(MetalCommandBuffer));
        commandBuffer->renderer = renderer;

        /* The native Metal command buffer is created in METAL_AcquireCommandBuffer */

        commandBuffer->windowDataCapacity = 1;
        commandBuffer->windowDataCount = 0;
        commandBuffer->windowDatas = SDL_malloc(
            commandBuffer->windowDataCapacity * sizeof(MetalWindowData *));

        /* Reference Counting */
        commandBuffer->usedBufferCapacity = 4;
        commandBuffer->usedBufferCount = 0;
        commandBuffer->usedBuffers = SDL_malloc(
            commandBuffer->usedBufferCapacity * sizeof(MetalBuffer *));

        commandBuffer->usedTextureCapacity = 4;
        commandBuffer->usedTextureCount = 0;
        commandBuffer->usedTextures = SDL_malloc(
            commandBuffer->usedTextureCapacity * sizeof(MetalTexture *));

        renderer->availableCommandBuffers[renderer->availableCommandBufferCount] = commandBuffer;
        renderer->availableCommandBufferCount += 1;
    }
}

static MetalCommandBuffer *METAL_INTERNAL_GetInactiveCommandBufferFromPool(
    MetalRenderer *renderer)
{
    MetalCommandBuffer *commandBuffer;

    if (renderer->availableCommandBufferCount == 0) {
        METAL_INTERNAL_AllocateCommandBuffers(
            renderer,
            renderer->availableCommandBufferCapacity);
    }

    commandBuffer = renderer->availableCommandBuffers[renderer->availableCommandBufferCount - 1];
    renderer->availableCommandBufferCount -= 1;

    return commandBuffer;
}

static Uint8 METAL_INTERNAL_CreateFence(
    MetalRenderer *renderer)
{
    MetalFence *fence;

    fence = SDL_malloc(sizeof(MetalFence));
    SDL_AtomicSet(&fence->complete, 0);

    /* Add it to the available pool */
    /* FIXME: Should this be EXPAND_IF_NEEDED? */
    if (renderer->availableFenceCount >= renderer->availableFenceCapacity) {
        renderer->availableFenceCapacity *= 2;

        renderer->availableFences = SDL_realloc(
            renderer->availableFences,
            sizeof(MetalFence *) * renderer->availableFenceCapacity);
    }

    renderer->availableFences[renderer->availableFenceCount] = fence;
    renderer->availableFenceCount += 1;

    return 1;
}

static Uint8 METAL_INTERNAL_AcquireFence(
    MetalRenderer *renderer,
    MetalCommandBuffer *commandBuffer)
{
    MetalFence *fence;

    /* Acquire a fence from the pool */
    SDL_LockMutex(renderer->fenceLock);

    if (renderer->availableFenceCount == 0) {
        if (!METAL_INTERNAL_CreateFence(renderer)) {
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

static Refresh_CommandBuffer *METAL_AcquireCommandBuffer(
    Refresh_Renderer *driverData)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalCommandBuffer *commandBuffer;

    SDL_LockMutex(renderer->acquireCommandBufferLock);

    commandBuffer = METAL_INTERNAL_GetInactiveCommandBufferFromPool(renderer);
    commandBuffer->handle = [renderer->queue commandBuffer];

    commandBuffer->graphicsPipeline = NULL;
    commandBuffer->computePipeline = NULL;
    for (Uint32 i = 0; i < MAX_UNIFORM_BUFFERS_PER_STAGE; i += 1) {
        commandBuffer->vertexUniformBuffers[i] = NULL;
        commandBuffer->fragmentUniformBuffers[i] = NULL;
        commandBuffer->computeUniformBuffers[i] = NULL;
    }

    /* FIXME: Do we actually need to set this? */
    commandBuffer->needVertexSamplerBind = SDL_TRUE;
    commandBuffer->needVertexStorageTextureBind = SDL_TRUE;
    commandBuffer->needVertexStorageBufferBind = SDL_TRUE;
    commandBuffer->needVertexUniformBind = SDL_TRUE;
    commandBuffer->needFragmentSamplerBind = SDL_TRUE;
    commandBuffer->needFragmentStorageTextureBind = SDL_TRUE;
    commandBuffer->needFragmentStorageBufferBind = SDL_TRUE;
    commandBuffer->needFragmentUniformBind = SDL_TRUE;
    commandBuffer->needComputeBufferBind = SDL_TRUE;
    commandBuffer->needComputeTextureBind = SDL_TRUE;
    commandBuffer->needComputeUniformBind = SDL_TRUE;

    METAL_INTERNAL_AcquireFence(renderer, commandBuffer);
    commandBuffer->autoReleaseFence = 1;

    SDL_UnlockMutex(renderer->acquireCommandBufferLock);

    return (Refresh_CommandBuffer *)commandBuffer;
}

static MetalUniformBuffer *METAL_INTERNAL_AcquireUniformBufferFromPool(
    MetalCommandBuffer *commandBuffer)
{
    MetalRenderer *renderer = commandBuffer->renderer;
    MetalUniformBuffer *uniformBuffer;

    SDL_LockMutex(renderer->acquireUniformBufferLock);

    if (renderer->uniformBufferPoolCount > 0) {
        uniformBuffer = renderer->uniformBufferPool[renderer->uniformBufferPoolCount - 1];
        renderer->uniformBufferPoolCount -= 1;
    } else {
        uniformBuffer = METAL_INTERNAL_CreateUniformBuffer(
            renderer,
            UNIFORM_BUFFER_SIZE);
    }

    SDL_UnlockMutex(renderer->acquireUniformBufferLock);

    METAL_INTERNAL_TrackUniformBuffer(commandBuffer, uniformBuffer);

    return uniformBuffer;
}

static void METAL_INTERNAL_ReturnUniformBufferToPool(
    MetalRenderer *renderer,
    MetalUniformBuffer *uniformBuffer)
{
    if (renderer->uniformBufferPoolCount >= renderer->uniformBufferPoolCapacity) {
        renderer->uniformBufferPoolCapacity *= 2;
        renderer->uniformBufferPool = SDL_realloc(
            renderer->uniformBufferPool,
            renderer->uniformBufferPoolCapacity * sizeof(MetalUniformBuffer *));
    }

    renderer->uniformBufferPool[renderer->uniformBufferPoolCount] = uniformBuffer;
    renderer->uniformBufferPoolCount += 1;

    uniformBuffer->writeOffset = 0;
    uniformBuffer->drawOffset = 0;
}

static void METAL_BeginRenderPass(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_ColorAttachmentInfo *colorAttachmentInfos,
    Uint32 colorAttachmentCount,
    Refresh_DepthStencilAttachmentInfo *depthStencilAttachmentInfo)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalRenderer *renderer = metalCommandBuffer->renderer;
    MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    Uint32 vpWidth = UINT_MAX;
    Uint32 vpHeight = UINT_MAX;
    MTLViewport viewport;
    MTLScissorRect scissorRect;

    for (Uint32 i = 0; i < colorAttachmentCount; i += 1) {
        MetalTextureContainer *container = (MetalTextureContainer *)colorAttachmentInfos[i].textureSlice.texture;
        MetalTexture *texture = METAL_INTERNAL_PrepareTextureForWrite(
            renderer,
            container,
            colorAttachmentInfos[i].cycle);

        if (texture->msaaHandle) {
            passDescriptor.colorAttachments[i].texture = texture->msaaHandle;
            passDescriptor.colorAttachments[i].resolveTexture = texture->handle;
        } else {
            passDescriptor.colorAttachments[i].texture = texture->handle;
        }
        passDescriptor.colorAttachments[i].level = colorAttachmentInfos[i].textureSlice.mipLevel;
        passDescriptor.colorAttachments[i].slice = colorAttachmentInfos[i].textureSlice.layer;
        passDescriptor.colorAttachments[i].clearColor = MTLClearColorMake(
            colorAttachmentInfos[i].clearColor.r,
            colorAttachmentInfos[i].clearColor.g,
            colorAttachmentInfos[i].clearColor.b,
            colorAttachmentInfos[i].clearColor.a);
        passDescriptor.colorAttachments[i].loadAction = RefreshToMetal_LoadOp[colorAttachmentInfos[i].loadOp];
        passDescriptor.colorAttachments[i].storeAction = RefreshToMetal_StoreOp(
            colorAttachmentInfos[i].storeOp,
            texture->msaaHandle ? 1 : 0);

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, texture);
    }

    if (depthStencilAttachmentInfo != NULL) {
        MetalTextureContainer *container = (MetalTextureContainer *)depthStencilAttachmentInfo->textureSlice.texture;
        MetalTexture *texture = METAL_INTERNAL_PrepareTextureForWrite(
            renderer,
            container,
            depthStencilAttachmentInfo->cycle);

        if (texture->msaaHandle) {
            passDescriptor.depthAttachment.texture = texture->msaaHandle;
            passDescriptor.depthAttachment.resolveTexture = texture->handle;
        } else {
            passDescriptor.depthAttachment.texture = texture->handle;
        }
        passDescriptor.depthAttachment.level = depthStencilAttachmentInfo->textureSlice.mipLevel;
        passDescriptor.depthAttachment.slice = depthStencilAttachmentInfo->textureSlice.layer;
        passDescriptor.depthAttachment.loadAction = RefreshToMetal_LoadOp[depthStencilAttachmentInfo->loadOp];
        passDescriptor.depthAttachment.storeAction = RefreshToMetal_StoreOp(
            depthStencilAttachmentInfo->storeOp,
            texture->msaaHandle ? 1 : 0);
        passDescriptor.depthAttachment.clearDepth = depthStencilAttachmentInfo->depthStencilClearValue.depth;

        if (IsStencilFormat(container->createInfo.format)) {
            if (texture->msaaHandle) {
                passDescriptor.stencilAttachment.texture = texture->msaaHandle;
                passDescriptor.stencilAttachment.resolveTexture = texture->handle;
            } else {
                passDescriptor.stencilAttachment.texture = texture->handle;
            }
            passDescriptor.stencilAttachment.level = depthStencilAttachmentInfo->textureSlice.mipLevel;
            passDescriptor.stencilAttachment.slice = depthStencilAttachmentInfo->textureSlice.layer;
            passDescriptor.stencilAttachment.loadAction = RefreshToMetal_LoadOp[depthStencilAttachmentInfo->loadOp];
            passDescriptor.stencilAttachment.storeAction = RefreshToMetal_StoreOp(
                depthStencilAttachmentInfo->storeOp,
                texture->msaaHandle ? 1 : 0);
            passDescriptor.stencilAttachment.clearStencil = depthStencilAttachmentInfo->depthStencilClearValue.stencil;
        }

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, texture);
    }

    metalCommandBuffer->renderEncoder = [metalCommandBuffer->handle renderCommandEncoderWithDescriptor:passDescriptor];

    /* The viewport cannot be larger than the smallest attachment. */
    for (Uint32 i = 0; i < colorAttachmentCount; i += 1) {
        MetalTextureContainer *container = (MetalTextureContainer *)colorAttachmentInfos[i].textureSlice.texture;
        Uint32 w = container->createInfo.width >> colorAttachmentInfos[i].textureSlice.mipLevel;
        Uint32 h = container->createInfo.height >> colorAttachmentInfos[i].textureSlice.mipLevel;

        if (w < vpWidth) {
            vpWidth = w;
        }

        if (h < vpHeight) {
            vpHeight = h;
        }
    }

    if (depthStencilAttachmentInfo != NULL) {
        MetalTextureContainer *container = (MetalTextureContainer *)depthStencilAttachmentInfo->textureSlice.texture;
        Uint32 w = container->createInfo.width >> depthStencilAttachmentInfo->textureSlice.mipLevel;
        Uint32 h = container->createInfo.height >> depthStencilAttachmentInfo->textureSlice.mipLevel;

        if (w < vpWidth) {
            vpWidth = w;
        }

        if (h < vpHeight) {
            vpHeight = h;
        }
    }

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
    scissorRect.width = vpWidth;
    scissorRect.height = vpHeight;
    [metalCommandBuffer->renderEncoder setScissorRect:scissorRect];
}

static void METAL_BindGraphicsPipeline(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_GraphicsPipeline *graphicsPipeline)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalGraphicsPipeline *metalGraphicsPipeline = (MetalGraphicsPipeline *)graphicsPipeline;
    Refresh_RasterizerState *rast = &metalGraphicsPipeline->rasterizerState;

    metalCommandBuffer->graphicsPipeline = metalGraphicsPipeline;

    [metalCommandBuffer->renderEncoder setRenderPipelineState:metalGraphicsPipeline->handle];

    /* Apply rasterizer state */
    [metalCommandBuffer->renderEncoder setTriangleFillMode:RefreshToMetal_PolygonMode[metalGraphicsPipeline->rasterizerState.fillMode]];
    [metalCommandBuffer->renderEncoder setCullMode:RefreshToMetal_CullMode[metalGraphicsPipeline->rasterizerState.cullMode]];
    [metalCommandBuffer->renderEncoder setFrontFacingWinding:RefreshToMetal_FrontFace[metalGraphicsPipeline->rasterizerState.frontFace]];
    [metalCommandBuffer->renderEncoder
        setDepthBias:((rast->depthBiasEnable) ? rast->depthBiasConstantFactor : 0)
          slopeScale:((rast->depthBiasEnable) ? rast->depthBiasSlopeFactor : 0)
          clamp:((rast->depthBiasEnable) ? rast->depthBiasClamp : 0)];

    /* Apply blend constants */
    [metalCommandBuffer->renderEncoder
        setBlendColorRed:metalGraphicsPipeline->blendConstants[0]
                   green:metalGraphicsPipeline->blendConstants[1]
                    blue:metalGraphicsPipeline->blendConstants[2]
                   alpha:metalGraphicsPipeline->blendConstants[3]];

    /* Apply depth-stencil state */
    if (metalGraphicsPipeline->depthStencilState != NULL) {
        [metalCommandBuffer->renderEncoder
            setDepthStencilState:metalGraphicsPipeline->depthStencilState];
        [metalCommandBuffer->renderEncoder
            setStencilReferenceValue:metalGraphicsPipeline->stencilReference];
    }

    for (Uint32 i = 0; i < metalGraphicsPipeline->vertexUniformBufferCount; i += 1) {
        if (metalCommandBuffer->vertexUniformBuffers[i] == NULL) {
            metalCommandBuffer->vertexUniformBuffers[i] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                metalCommandBuffer);
        }
    }

    for (Uint32 i = 0; i < metalGraphicsPipeline->fragmentUniformBufferCount; i += 1) {
        if (metalCommandBuffer->fragmentUniformBuffers[i] == NULL) {
            metalCommandBuffer->fragmentUniformBuffers[i] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                metalCommandBuffer);
        }
    }

    metalCommandBuffer->needVertexUniformBind = SDL_TRUE;
    metalCommandBuffer->needFragmentUniformBind = SDL_TRUE;
}

static void METAL_SetViewport(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_Viewport *viewport)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
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
    Refresh_Rect *scissor)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
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
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    id<MTLBuffer> metalBuffers[MAX_BUFFER_BINDINGS];
    NSUInteger bufferOffsets[MAX_BUFFER_BINDINGS];
    NSRange range = NSMakeRange(METAL_INTERNAL_GetVertexBufferIndex(firstBinding), bindingCount);

    if (range.length == 0) {
        return;
    }

    for (Uint32 i = 0; i < range.length; i += 1) {
        MetalBuffer *currentBuffer = ((MetalBufferContainer *)pBindings[i].buffer)->activeBuffer;
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
    Refresh_IndexElementSize indexElementSize)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    metalCommandBuffer->indexBuffer = ((MetalBufferContainer *)pBinding->buffer)->activeBuffer;
    metalCommandBuffer->indexBufferOffset = pBinding->offset;
    metalCommandBuffer->indexElementSize = indexElementSize;

    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalCommandBuffer->indexBuffer);
}

static void METAL_BindVertexSamplers(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_TextureSamplerBinding *textureSamplerBindings,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        textureContainer = (MetalTextureContainer *)textureSamplerBindings[i].texture;

        METAL_INTERNAL_TrackTexture(
            metalCommandBuffer,
            textureContainer->activeTexture);

        metalCommandBuffer->vertexSamplers[firstSlot + i] =
            ((MetalSampler *)textureSamplerBindings[i].sampler)->handle;

        metalCommandBuffer->vertexTextures[firstSlot + i] =
            textureContainer->activeTexture->handle;
    }

    metalCommandBuffer->needVertexSamplerBind = SDL_TRUE;
}

static void METAL_BindVertexStorageTextures(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_TextureSlice *storageTextureSlices,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        textureContainer = (MetalTextureContainer *)storageTextureSlices[i].texture;

        METAL_INTERNAL_TrackTexture(
            metalCommandBuffer,
            textureContainer->activeTexture);

        metalCommandBuffer->vertexStorageTextures[firstSlot + i] =
            textureContainer->activeTexture->handle;
    }

    metalCommandBuffer->needVertexStorageTextureBind = SDL_TRUE;
}

static void METAL_BindVertexStorageBuffers(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_Buffer **storageBuffers,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalBufferContainer *bufferContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        bufferContainer = (MetalBufferContainer *)storageBuffers[i];

        METAL_INTERNAL_TrackBuffer(
            metalCommandBuffer,
            bufferContainer->activeBuffer);

        metalCommandBuffer->vertexStorageBuffers[firstSlot + i] =
            bufferContainer->activeBuffer->handle;
    }

    metalCommandBuffer->needVertexStorageBufferBind = SDL_TRUE;
}

static void METAL_BindFragmentSamplers(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_TextureSamplerBinding *textureSamplerBindings,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        textureContainer = (MetalTextureContainer *)textureSamplerBindings[i].texture;

        METAL_INTERNAL_TrackTexture(
            metalCommandBuffer,
            textureContainer->activeTexture);

        metalCommandBuffer->fragmentSamplers[firstSlot + i] =
            ((MetalSampler *)textureSamplerBindings[i].sampler)->handle;

        metalCommandBuffer->fragmentTextures[firstSlot + i] =
            textureContainer->activeTexture->handle;
    }

    metalCommandBuffer->needFragmentSamplerBind = SDL_TRUE;
}

static void METAL_BindFragmentStorageTextures(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_TextureSlice *storageTextureSlices,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        textureContainer = (MetalTextureContainer *)storageTextureSlices[i].texture;

        METAL_INTERNAL_TrackTexture(
            metalCommandBuffer,
            textureContainer->activeTexture);

        metalCommandBuffer->fragmentStorageTextures[firstSlot + i] =
            textureContainer->activeTexture->handle;
    }

    metalCommandBuffer->needFragmentStorageTextureBind = SDL_TRUE;
}

static void METAL_BindFragmentStorageBuffers(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_Buffer **storageBuffers,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalBufferContainer *bufferContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        bufferContainer = (MetalBufferContainer *)storageBuffers[i];

        METAL_INTERNAL_TrackBuffer(
            metalCommandBuffer,
            bufferContainer->activeBuffer);

        metalCommandBuffer->fragmentStorageBuffers[firstSlot + i] =
            bufferContainer->activeBuffer->handle;
    }

    metalCommandBuffer->needFragmentStorageBufferBind = SDL_TRUE;
}

static void METAL_INTERNAL_BindGraphicsResources(
    MetalCommandBuffer *commandBuffer)
{
    MetalGraphicsPipeline *graphicsPipeline = commandBuffer->graphicsPipeline;
    NSUInteger offsets[MAX_STORAGE_BUFFERS_PER_STAGE] = { 0 };

    /* Vertex Samplers+Textures */

    if (graphicsPipeline->vertexSamplerCount > 0 && commandBuffer->needVertexSamplerBind) {
        [commandBuffer->renderEncoder setVertexSamplerStates:commandBuffer->vertexSamplers
                                                   withRange:NSMakeRange(0, graphicsPipeline->vertexSamplerCount)];
        [commandBuffer->renderEncoder setVertexTextures:commandBuffer->vertexTextures
                                              withRange:NSMakeRange(0, graphicsPipeline->vertexSamplerCount)];
        commandBuffer->needVertexSamplerBind = SDL_FALSE;
    }

    /* Vertex Storage Textures */

    if (graphicsPipeline->vertexStorageTextureCount > 0 && commandBuffer->needVertexStorageTextureBind) {
        [commandBuffer->renderEncoder setVertexTextures:commandBuffer->vertexStorageTextures
                                              withRange:NSMakeRange(graphicsPipeline->vertexSamplerCount,
                                                                    graphicsPipeline->vertexStorageTextureCount)];
        commandBuffer->needVertexStorageTextureBind = SDL_FALSE;
    }

    /* Vertex Storage Buffers */

    if (graphicsPipeline->vertexStorageBufferCount > 0 && commandBuffer->needVertexStorageBufferBind) {
        [commandBuffer->renderEncoder setVertexBuffers:commandBuffer->vertexStorageBuffers
                                               offsets:offsets
                                             withRange:NSMakeRange(graphicsPipeline->vertexUniformBufferCount,
                                                                   graphicsPipeline->vertexStorageBufferCount)];
        commandBuffer->needVertexStorageBufferBind = SDL_FALSE;
    }

    /* Vertex Uniform Buffers */

    if (graphicsPipeline->vertexUniformBufferCount > 0 && commandBuffer->needVertexUniformBind) {
        for (Uint32 i = 0; i < graphicsPipeline->vertexUniformBufferCount; i += 1) {
            [commandBuffer->renderEncoder
                setVertexBuffer:commandBuffer->vertexUniformBuffers[i]->handle
                         offset:commandBuffer->vertexUniformBuffers[i]->drawOffset
                        atIndex:i];
        }

        commandBuffer->needVertexUniformBind = SDL_FALSE;
    }

    /* Fragment Samplers+Textures */

    if (graphicsPipeline->fragmentSamplerCount > 0 && commandBuffer->needFragmentSamplerBind) {
        [commandBuffer->renderEncoder setFragmentSamplerStates:commandBuffer->fragmentSamplers
                                                     withRange:NSMakeRange(0, graphicsPipeline->fragmentSamplerCount)];
        [commandBuffer->renderEncoder setFragmentTextures:commandBuffer->fragmentTextures
                                                withRange:NSMakeRange(0, graphicsPipeline->fragmentSamplerCount)];
        commandBuffer->needFragmentSamplerBind = SDL_FALSE;
    }

    /* Fragment Storage Textures */

    if (graphicsPipeline->fragmentStorageTextureCount > 0 && commandBuffer->needFragmentStorageTextureBind) {
        [commandBuffer->renderEncoder setFragmentTextures:commandBuffer->fragmentStorageTextures
                                                withRange:NSMakeRange(graphicsPipeline->fragmentSamplerCount,
                                                                      graphicsPipeline->fragmentStorageTextureCount)];
        commandBuffer->needFragmentStorageTextureBind = SDL_FALSE;
    }

    /* Fragment Storage Buffers */

    if (graphicsPipeline->fragmentStorageBufferCount > 0 && commandBuffer->needFragmentStorageBufferBind) {
        [commandBuffer->renderEncoder setFragmentBuffers:commandBuffer->fragmentStorageBuffers
                                                 offsets:offsets
                                               withRange:NSMakeRange(graphicsPipeline->fragmentUniformBufferCount,
                                                                     graphicsPipeline->fragmentStorageBufferCount)];
        commandBuffer->needFragmentStorageBufferBind = SDL_FALSE;
    }

    /* Fragment Uniform Buffers */
    if (graphicsPipeline->fragmentUniformBufferCount > 0 && commandBuffer->needFragmentUniformBind) {
        for (Uint32 i = 0; i < graphicsPipeline->fragmentUniformBufferCount; i += 1) {
            [commandBuffer->renderEncoder
                setFragmentBuffer:commandBuffer->fragmentUniformBuffers[i]->handle
                           offset:commandBuffer->fragmentUniformBuffers[i]->drawOffset
                          atIndex:i];
        }

        commandBuffer->needFragmentUniformBind = SDL_FALSE;
    }
}

static void METAL_INTERNAL_BindComputeResources(
    MetalCommandBuffer *commandBuffer)
{
    MetalComputePipeline *computePipeline = commandBuffer->computePipeline;
    NSUInteger offsets[MAX_STORAGE_BUFFERS_PER_STAGE] = { 0 };

    if (commandBuffer->needComputeTextureBind) {
        /* Bind read-only textures */
        if (computePipeline->readOnlyStorageTextureCount > 0) {
            [commandBuffer->computeEncoder setTextures:commandBuffer->computeReadOnlyTextures
                                             withRange:NSMakeRange(0, computePipeline->readOnlyStorageTextureCount)];
        }

        /* Bind read-write textures */
        if (computePipeline->readWriteStorageTextureCount > 0) {
            [commandBuffer->computeEncoder setTextures:commandBuffer->computeReadWriteTextures
                                             withRange:NSMakeRange(
                                                           computePipeline->readOnlyStorageTextureCount,
                                                           computePipeline->readWriteStorageTextureCount)];
        }

        commandBuffer->needComputeTextureBind = SDL_FALSE;
    }

    if (commandBuffer->needComputeBufferBind) {
        /* Bind read-only buffers */
        if (computePipeline->readOnlyStorageBufferCount > 0) {
            [commandBuffer->computeEncoder setBuffers:commandBuffer->computeReadOnlyBuffers
                                              offsets:offsets
                                            withRange:NSMakeRange(computePipeline->uniformBufferCount,
                                                                  computePipeline->readOnlyStorageBufferCount)];
        }
        /* Bind read-write buffers */
        if (computePipeline->readWriteStorageBufferCount > 0) {
            [commandBuffer->computeEncoder setBuffers:commandBuffer->computeReadWriteBuffers
                                              offsets:offsets
                                            withRange:NSMakeRange(
                                                          computePipeline->uniformBufferCount +
                                                              computePipeline->readOnlyStorageBufferCount,
                                                          computePipeline->readWriteStorageBufferCount)];
        }
        commandBuffer->needComputeBufferBind = SDL_FALSE;
    }

    if (commandBuffer->needComputeUniformBind) {
        for (Uint32 i = 0; i < computePipeline->uniformBufferCount; i += 1) {
            [commandBuffer->computeEncoder
                setBuffer:commandBuffer->computeUniformBuffers[i]->handle
                   offset:commandBuffer->computeUniformBuffers[i]->drawOffset
                  atIndex:i];
        }

        commandBuffer->needComputeUniformBind = SDL_FALSE;
    }
}

static void METAL_DrawIndexedPrimitives(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 baseVertex,
    Uint32 startIndex,
    Uint32 primitiveCount,
    Uint32 instanceCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    Refresh_PrimitiveType primitiveType = metalCommandBuffer->graphicsPipeline->primitiveType;
    Uint32 indexSize = IndexSize(metalCommandBuffer->indexElementSize);

    METAL_INTERNAL_BindGraphicsResources(metalCommandBuffer);

    [metalCommandBuffer->renderEncoder
        drawIndexedPrimitives:RefreshToMetal_PrimitiveType[primitiveType]
                   indexCount:PrimitiveVerts(primitiveType, primitiveCount)
                    indexType:RefreshToMetal_IndexType[metalCommandBuffer->indexElementSize]
                  indexBuffer:metalCommandBuffer->indexBuffer->handle
            indexBufferOffset:metalCommandBuffer->indexBufferOffset + (startIndex * indexSize)
                instanceCount:instanceCount
                   baseVertex:baseVertex
                 baseInstance:0];
}

static void METAL_DrawPrimitives(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 vertexStart,
    Uint32 primitiveCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    Refresh_PrimitiveType primitiveType = metalCommandBuffer->graphicsPipeline->primitiveType;

    METAL_INTERNAL_BindGraphicsResources(metalCommandBuffer);

    [metalCommandBuffer->renderEncoder
        drawPrimitives:RefreshToMetal_PrimitiveType[primitiveType]
           vertexStart:vertexStart
           vertexCount:PrimitiveVerts(primitiveType, primitiveCount)];
}

static void METAL_DrawPrimitivesIndirect(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_Buffer *buffer,
    Uint32 offsetInBytes,
    Uint32 drawCount,
    Uint32 stride)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalBuffer *metalBuffer = ((MetalBufferContainer *)buffer)->activeBuffer;
    Refresh_PrimitiveType primitiveType = metalCommandBuffer->graphicsPipeline->primitiveType;

    METAL_INTERNAL_BindGraphicsResources(metalCommandBuffer);

    /* Metal: "We have multi-draw at home!"
     * Multi-draw at home:
     */
    for (Uint32 i = 0; i < drawCount; i += 1) {
        [metalCommandBuffer->renderEncoder
                  drawPrimitives:RefreshToMetal_PrimitiveType[primitiveType]
                  indirectBuffer:metalBuffer->handle
            indirectBufferOffset:offsetInBytes + (stride * i)];
    }

    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalBuffer);
}

static void METAL_DrawIndexedPrimitivesIndirect(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_Buffer *buffer,
    Uint32 offsetInBytes,
    Uint32 drawCount,
    Uint32 stride)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalBuffer *metalBuffer = ((MetalBufferContainer *)buffer)->activeBuffer;
    Refresh_PrimitiveType primitiveType = metalCommandBuffer->graphicsPipeline->primitiveType;

    METAL_INTERNAL_BindGraphicsResources(metalCommandBuffer);

    for (Uint32 i = 0; i < drawCount; i += 1) {
        [metalCommandBuffer->renderEncoder
            drawIndexedPrimitives:RefreshToMetal_PrimitiveType[primitiveType]
                        indexType:RefreshToMetal_IndexType[metalCommandBuffer->indexElementSize]
                      indexBuffer:metalCommandBuffer->indexBuffer->handle
                indexBufferOffset:metalCommandBuffer->indexBufferOffset
                   indirectBuffer:metalBuffer->handle
             indirectBufferOffset:offsetInBytes + (stride * i)];
    }

    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalBuffer);
}

static void METAL_EndRenderPass(
    Refresh_CommandBuffer *commandBuffer)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    [metalCommandBuffer->renderEncoder endEncoding];
    metalCommandBuffer->renderEncoder = nil;
}

static void METAL_INTERNAL_PushUniformData(
    MetalCommandBuffer *metalCommandBuffer,
    Refresh_ShaderStage shaderStage,
    Uint32 slotIndex,
    const void *data,
    Uint32 dataLengthInBytes)
{
    MetalUniformBuffer *metalUniformBuffer;
    Uint32 alignedDataLength;

    if (shaderStage == REFRESH_SHADERSTAGE_VERTEX) {
        if (metalCommandBuffer->vertexUniformBuffers[slotIndex] == NULL) {
            metalCommandBuffer->vertexUniformBuffers[slotIndex] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                metalCommandBuffer);
        }
        metalUniformBuffer = metalCommandBuffer->vertexUniformBuffers[slotIndex];
    } else if (shaderStage == REFRESH_SHADERSTAGE_FRAGMENT) {
        if (metalCommandBuffer->fragmentUniformBuffers[slotIndex] == NULL) {
            metalCommandBuffer->fragmentUniformBuffers[slotIndex] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                metalCommandBuffer);
        }
        metalUniformBuffer = metalCommandBuffer->fragmentUniformBuffers[slotIndex];
    } else if (shaderStage == REFRESH_SHADERSTAGE_COMPUTE) {
        if (metalCommandBuffer->computeUniformBuffers[slotIndex] == NULL) {
            metalCommandBuffer->computeUniformBuffers[slotIndex] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                metalCommandBuffer);
        }
        metalUniformBuffer = metalCommandBuffer->computeUniformBuffers[slotIndex];
    } else {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Unrecognized shader stage!");
        return;
    }

    alignedDataLength = METAL_INTERNAL_NextHighestAlignment(
        dataLengthInBytes,
        256);

    if (metalUniformBuffer->writeOffset + alignedDataLength >= UNIFORM_BUFFER_SIZE) {
        metalUniformBuffer = METAL_INTERNAL_AcquireUniformBufferFromPool(
            metalCommandBuffer);

        metalUniformBuffer->writeOffset = 0;
        metalUniformBuffer->drawOffset = 0;

        if (shaderStage == REFRESH_SHADERSTAGE_VERTEX) {
            metalCommandBuffer->vertexUniformBuffers[slotIndex] = metalUniformBuffer;
        } else if (shaderStage == REFRESH_SHADERSTAGE_FRAGMENT) {
            metalCommandBuffer->fragmentUniformBuffers[slotIndex] = metalUniformBuffer;
        } else if (shaderStage == REFRESH_SHADERSTAGE_COMPUTE) {
            metalCommandBuffer->computeUniformBuffers[slotIndex] = metalUniformBuffer;
        } else {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Unrecognized shader stage!");
            return;
        }
    }

    metalUniformBuffer->drawOffset = metalUniformBuffer->writeOffset;

    SDL_memcpy(
        (metalUniformBuffer->handle).contents + metalUniformBuffer->writeOffset,
        data,
        dataLengthInBytes);

    metalUniformBuffer->writeOffset += alignedDataLength;

    if (shaderStage == REFRESH_SHADERSTAGE_VERTEX) {
        metalCommandBuffer->needVertexUniformBind = SDL_TRUE;
    } else if (shaderStage == REFRESH_SHADERSTAGE_FRAGMENT) {
        metalCommandBuffer->needFragmentUniformBind = SDL_TRUE;
    } else if (shaderStage == REFRESH_SHADERSTAGE_COMPUTE) {
        metalCommandBuffer->needComputeUniformBind = SDL_TRUE;
    } else {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Unrecognized shader stage!");
    }
}

static void METAL_PushVertexUniformData(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 slotIndex,
    const void *data,
    Uint32 dataLengthInBytes)
{
    METAL_INTERNAL_PushUniformData(
        (MetalCommandBuffer *)commandBuffer,
        REFRESH_SHADERSTAGE_VERTEX,
        slotIndex,
        data,
        dataLengthInBytes);
}

static void METAL_PushFragmentUniformData(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 slotIndex,
    const void *data,
    Uint32 dataLengthInBytes)
{
    METAL_INTERNAL_PushUniformData(
        (MetalCommandBuffer *)commandBuffer,
        REFRESH_SHADERSTAGE_FRAGMENT,
        slotIndex,
        data,
        dataLengthInBytes);
}

/* Blit */

static Refresh_GraphicsPipeline *METAL_INTERNAL_FetchBlitPipeline(
    MetalRenderer *renderer,
    Refresh_TextureFormat destinationFormat)
{
    Refresh_GraphicsPipelineCreateInfo blitPipelineCreateInfo;
    Refresh_ColorAttachmentDescription colorAttachmentDesc;
    Refresh_GraphicsPipeline *pipeline;

    /* FIXME: is there a better lock we can use? */
    SDL_LockMutex(renderer->submitLock);

    /* Try to use an existing pipeline */
    for (Uint32 i = 0; i < renderer->blitPipelineCount; i += 1) {
        if (renderer->blitPipelines[i].format == destinationFormat) {
            SDL_UnlockMutex(renderer->submitLock);
            return renderer->blitPipelines[i].pipeline;
        }
    }

    /* Create a new pipeline! */
    SDL_zero(blitPipelineCreateInfo);

    SDL_zero(colorAttachmentDesc);
    colorAttachmentDesc.format = destinationFormat;
    colorAttachmentDesc.blendState.blendEnable = 0;
    colorAttachmentDesc.blendState.colorWriteMask = 0xFF;

    blitPipelineCreateInfo.attachmentInfo.colorAttachmentDescriptions = &colorAttachmentDesc;
    blitPipelineCreateInfo.attachmentInfo.colorAttachmentCount = 1;

    blitPipelineCreateInfo.vertexShader = renderer->fullscreenVertexShader;
    blitPipelineCreateInfo.fragmentShader = renderer->blitFrom2DPixelShader;

    blitPipelineCreateInfo.multisampleState.multisampleCount = REFRESH_SAMPLECOUNT_1;
    blitPipelineCreateInfo.multisampleState.sampleMask = 0xFFFFFFFF;

    blitPipelineCreateInfo.primitiveType = REFRESH_PRIMITIVETYPE_TRIANGLELIST;

    blitPipelineCreateInfo.blendConstants[0] = 1.0f;
    blitPipelineCreateInfo.blendConstants[1] = 1.0f;
    blitPipelineCreateInfo.blendConstants[2] = 1.0f;
    blitPipelineCreateInfo.blendConstants[3] = 1.0f;

    pipeline = METAL_CreateGraphicsPipeline(
        (Refresh_Renderer *)renderer,
        &blitPipelineCreateInfo);
    if (pipeline == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to create blit pipeline!");
        SDL_UnlockMutex(renderer->submitLock);
        return NULL;
    }

    if (renderer->blitPipelineCount >= renderer->blitPipelineCapacity) {
        renderer->blitPipelineCapacity *= 2;
        renderer->blitPipelines = SDL_realloc(
            renderer->blitPipelines,
            sizeof(BlitPipeline) * renderer->blitPipelineCapacity);
    }
    renderer->blitPipelines[renderer->blitPipelineCount].pipeline = pipeline;
    renderer->blitPipelines[renderer->blitPipelineCount].format = destinationFormat;
    renderer->blitPipelineCount += 1;

    SDL_UnlockMutex(renderer->submitLock);
    return pipeline;
}

static void METAL_Blit(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_TextureRegion *source,
    Refresh_TextureRegion *destination,
    Refresh_Filter filterMode,
    SDL_bool cycle)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalRenderer *renderer = (MetalRenderer *)metalCommandBuffer->renderer;
    MetalTextureContainer *sourceTextureContainer = (MetalTextureContainer *)source->textureSlice.texture;
    MetalTextureContainer *destinationTextureContainer = (MetalTextureContainer *)destination->textureSlice.texture;
    Refresh_GraphicsPipeline *pipeline;
    Refresh_ColorAttachmentInfo colorAttachmentInfo;
    Refresh_Viewport viewport;
    Refresh_TextureSamplerBinding textureSamplerBinding;

    /* FIXME: cube copies? texture arrays? */

    if (sourceTextureContainer->createInfo.depth > 1) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "3D blit source not implemented!");
        return;
    }

    if (destinationTextureContainer->createInfo.depth > 1) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "3D blit destination not implemented!");
        return;
    }

    if ((sourceTextureContainer->createInfo.usageFlags & REFRESH_TEXTUREUSAGE_SAMPLER_BIT) == 0) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Blit source texture must be created with SAMPLER bit!");
        return;
    }

    pipeline = METAL_INTERNAL_FetchBlitPipeline(
        renderer,
        destinationTextureContainer->createInfo.format);
    if (pipeline == NULL) {
        /* Drop the blit if the pipeline fetch failed! */
        return;
    }

    /* Unused */
    colorAttachmentInfo.clearColor.r = 0;
    colorAttachmentInfo.clearColor.g = 0;
    colorAttachmentInfo.clearColor.b = 0;
    colorAttachmentInfo.clearColor.a = 0;

    /* If the entire destination is blitted, we don't have to load */
    if (
        destinationTextureContainer->createInfo.levelCount == 1 &&
        destination->w == destinationTextureContainer->createInfo.width &&
        destination->h == destinationTextureContainer->createInfo.height &&
        destination->d == destinationTextureContainer->createInfo.depth) {
        colorAttachmentInfo.loadOp = REFRESH_LOADOP_DONT_CARE;
    } else {
        colorAttachmentInfo.loadOp = REFRESH_LOADOP_LOAD;
    }

    colorAttachmentInfo.storeOp = REFRESH_STOREOP_STORE;
    colorAttachmentInfo.textureSlice = destination->textureSlice;
    colorAttachmentInfo.cycle = cycle;

    METAL_BeginRenderPass(
        commandBuffer,
        &colorAttachmentInfo,
        1,
        NULL);

    viewport.x = (float)destination->x;
    viewport.y = (float)destination->y;
    viewport.w = (float)destination->w;
    viewport.h = (float)destination->h;
    viewport.minDepth = 0;
    viewport.maxDepth = 1;

    METAL_SetViewport(commandBuffer, &viewport);
    METAL_BindGraphicsPipeline(commandBuffer, pipeline);

    textureSamplerBinding.texture = source->textureSlice.texture;
    textureSamplerBinding.sampler = (filterMode == REFRESH_FILTER_NEAREST)
                                        ? renderer->blitNearestSampler
                                        : renderer->blitLinearSampler;

    METAL_BindFragmentSamplers(
        commandBuffer,
        0,
        &textureSamplerBinding,
        1);

    METAL_DrawPrimitives(commandBuffer, 0, 1);
    METAL_EndRenderPass(commandBuffer);
}

/* Compute State */

static void METAL_BeginComputePass(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_StorageTextureReadWriteBinding *storageTextureBindings,
    Uint32 storageTextureBindingCount,
    Refresh_StorageBufferReadWriteBinding *storageBufferBindings,
    Uint32 storageBufferBindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;
    MetalTexture *texture;
    MetalBufferContainer *bufferContainer;
    MetalBuffer *buffer;

    metalCommandBuffer->computeEncoder = [metalCommandBuffer->handle computeCommandEncoder];

    for (Uint32 i = 0; i < storageTextureBindingCount; i += 1) {
        textureContainer = (MetalTextureContainer *)storageTextureBindings[i].textureSlice.texture;

        texture = METAL_INTERNAL_PrepareTextureForWrite(
            metalCommandBuffer->renderer,
            textureContainer,
            storageTextureBindings[i].cycle);

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, texture);

        metalCommandBuffer->computeReadWriteTextures[i] = texture->handle;
        metalCommandBuffer->needComputeTextureBind = SDL_TRUE;
    }

    for (Uint32 i = 0; i < storageBufferBindingCount; i += 1) {
        bufferContainer = (MetalBufferContainer *)storageBufferBindings[i].buffer;

        buffer = METAL_INTERNAL_PrepareBufferForWrite(
            metalCommandBuffer->renderer,
            bufferContainer,
            storageBufferBindings[i].cycle);

        METAL_INTERNAL_TrackBuffer(
            metalCommandBuffer,
            buffer);

        metalCommandBuffer->computeReadWriteBuffers[i] = buffer->handle;
        metalCommandBuffer->needComputeBufferBind = SDL_TRUE;
    }
}

static void METAL_BindComputePipeline(
    Refresh_CommandBuffer *commandBuffer,
    Refresh_ComputePipeline *computePipeline)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalComputePipeline *pipeline = (MetalComputePipeline *)computePipeline;

    metalCommandBuffer->computePipeline = pipeline;

    [metalCommandBuffer->computeEncoder setComputePipelineState:pipeline->handle];

    for (Uint32 i = 0; i < pipeline->uniformBufferCount; i += 1) {
        if (metalCommandBuffer->computeUniformBuffers[i] == NULL) {
            metalCommandBuffer->computeUniformBuffers[i] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                metalCommandBuffer);
        }
    }

    metalCommandBuffer->needComputeUniformBind = SDL_TRUE;
}

static void METAL_BindComputeStorageTextures(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_TextureSlice *storageTextureSlices,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        textureContainer = (MetalTextureContainer *)storageTextureSlices[i].texture;

        METAL_INTERNAL_TrackTexture(
            metalCommandBuffer,
            textureContainer->activeTexture);

        metalCommandBuffer->computeReadOnlyTextures[firstSlot + i] =
            textureContainer->activeTexture->handle;
    }

    metalCommandBuffer->needComputeTextureBind = SDL_TRUE;
}

static void METAL_BindComputeStorageBuffers(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 firstSlot,
    Refresh_Buffer **storageBuffers,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalBufferContainer *bufferContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        bufferContainer = (MetalBufferContainer *)storageBuffers[i];

        METAL_INTERNAL_TrackBuffer(
            metalCommandBuffer,
            bufferContainer->activeBuffer);

        metalCommandBuffer->computeReadOnlyBuffers[firstSlot + i] =
            bufferContainer->activeBuffer->handle;
    }

    metalCommandBuffer->needComputeBufferBind = SDL_TRUE;
}

static void METAL_PushComputeUniformData(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 slotIndex,
    const void *data,
    Uint32 dataLengthInBytes)
{
    METAL_INTERNAL_PushUniformData(
        (MetalCommandBuffer *)commandBuffer,
        REFRESH_SHADERSTAGE_COMPUTE,
        slotIndex,
        data,
        dataLengthInBytes);
}

static void METAL_DispatchCompute(
    Refresh_CommandBuffer *commandBuffer,
    Uint32 groupCountX,
    Uint32 groupCountY,
    Uint32 groupCountZ)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MTLSize threadgroups = MTLSizeMake(groupCountX, groupCountY, groupCountZ);
    MTLSize threadsPerThreadgroup = MTLSizeMake(
        metalCommandBuffer->computePipeline->threadCountX,
        metalCommandBuffer->computePipeline->threadCountY,
        metalCommandBuffer->computePipeline->threadCountZ);

    METAL_INTERNAL_BindComputeResources(metalCommandBuffer);

    [metalCommandBuffer->computeEncoder
         dispatchThreadgroups:threadgroups
        threadsPerThreadgroup:threadsPerThreadgroup];
}

static void METAL_EndComputePass(
    Refresh_CommandBuffer *commandBuffer)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    [metalCommandBuffer->computeEncoder endEncoding];
    metalCommandBuffer->computeEncoder = nil;
}

/* Fence Cleanup */

static void METAL_INTERNAL_ReleaseFenceToPool(
    MetalRenderer *renderer,
    MetalFence *fence)
{
    SDL_LockMutex(renderer->fenceLock);

    /* FIXME: Should this use EXPAND_IF_NEEDED? */
    if (renderer->availableFenceCount == renderer->availableFenceCapacity) {
        renderer->availableFenceCapacity *= 2;
        renderer->availableFences = SDL_realloc(
            renderer->availableFences,
            renderer->availableFenceCapacity * sizeof(MetalFence *));
    }
    renderer->availableFences[renderer->availableFenceCount] = fence;
    renderer->availableFenceCount += 1;

    SDL_UnlockMutex(renderer->fenceLock);
}

static void METAL_ReleaseFence(
    Refresh_Renderer *driverData,
    Refresh_Fence *fence)
{
    METAL_INTERNAL_ReleaseFenceToPool(
        (MetalRenderer *)driverData,
        (MetalFence *)fence);
}

/* Cleanup */

static void METAL_INTERNAL_CleanCommandBuffer(
    MetalRenderer *renderer,
    MetalCommandBuffer *commandBuffer)
{
    /* Reference Counting */
    for (Uint32 i = 0; i < commandBuffer->usedBufferCount; i += 1) {
        (void)SDL_AtomicDecRef(&commandBuffer->usedBuffers[i]->referenceCount);
    }
    commandBuffer->usedBufferCount = 0;

    for (Uint32 i = 0; i < commandBuffer->usedTextureCount; i += 1) {
        (void)SDL_AtomicDecRef(&commandBuffer->usedTextures[i]->referenceCount);
    }
    commandBuffer->usedTextureCount = 0;

    /* Uniform buffers are now available */

    SDL_LockMutex(renderer->acquireUniformBufferLock);

    for (Uint32 i = 0; i < commandBuffer->usedUniformBufferCount; i += 1) {
        METAL_INTERNAL_ReturnUniformBufferToPool(
            renderer,
            commandBuffer->usedUniformBuffers[i]);
    }
    commandBuffer->usedUniformBufferCount = 0;

    SDL_UnlockMutex(renderer->acquireUniformBufferLock);

    /* Reset presentation */
    commandBuffer->windowDataCount = 0;

    /* Reset bindings */
    commandBuffer->indexBuffer = NULL;
    SDL_zeroa(commandBuffer->vertexSamplers);
    SDL_zeroa(commandBuffer->vertexTextures);
    SDL_zeroa(commandBuffer->fragmentSamplers);
    SDL_zeroa(commandBuffer->fragmentTextures);
    SDL_zeroa(commandBuffer->computeReadWriteBuffers);
    SDL_zeroa(commandBuffer->computeReadWriteTextures);

    /* The fence is now available (unless SubmitAndAcquireFence was called) */
    if (commandBuffer->autoReleaseFence) {
        METAL_ReleaseFence(
            (Refresh_Renderer *)renderer,
            (Refresh_Fence *)commandBuffer->fence);
    }

    /* Return command buffer to pool */
    SDL_LockMutex(renderer->acquireCommandBufferLock);
    /* FIXME: Should this use EXPAND_IF_NEEDED? */
    if (renderer->availableCommandBufferCount == renderer->availableCommandBufferCapacity) {
        renderer->availableCommandBufferCapacity += 1;
        renderer->availableCommandBuffers = SDL_realloc(
            renderer->availableCommandBuffers,
            renderer->availableCommandBufferCapacity * sizeof(MetalCommandBuffer *));
    }
    renderer->availableCommandBuffers[renderer->availableCommandBufferCount] = commandBuffer;
    renderer->availableCommandBufferCount += 1;
    SDL_UnlockMutex(renderer->acquireCommandBufferLock);

    /* Remove this command buffer from the submitted list */
    for (Uint32 i = 0; i < renderer->submittedCommandBufferCount; i += 1) {
        if (renderer->submittedCommandBuffers[i] == commandBuffer) {
            renderer->submittedCommandBuffers[i] = renderer->submittedCommandBuffers[renderer->submittedCommandBufferCount - 1];
            renderer->submittedCommandBufferCount -= 1;
        }
    }
}

static void METAL_INTERNAL_PerformPendingDestroys(
    MetalRenderer *renderer)
{
    Sint32 referenceCount = 0;
    Sint32 i;
    Uint32 j;

    for (i = renderer->bufferContainersToDestroyCount - 1; i >= 0; i -= 1) {
        referenceCount = 0;
        for (j = 0; j < renderer->bufferContainersToDestroy[i]->bufferCount; j += 1) {
            referenceCount += SDL_AtomicGet(&renderer->bufferContainersToDestroy[i]->buffers[j]->referenceCount);
        }

        if (referenceCount == 0) {
            METAL_INTERNAL_DestroyBufferContainer(
                renderer->bufferContainersToDestroy[i]);

            renderer->bufferContainersToDestroy[i] = renderer->bufferContainersToDestroy[renderer->bufferContainersToDestroyCount - 1];
            renderer->bufferContainersToDestroyCount -= 1;
        }
    }

    for (i = renderer->textureContainersToDestroyCount - 1; i >= 0; i -= 1) {
        referenceCount = 0;
        for (j = 0; j < renderer->textureContainersToDestroy[i]->textureCount; j += 1) {
            referenceCount += SDL_AtomicGet(&renderer->textureContainersToDestroy[i]->textures[j]->referenceCount);
        }

        if (referenceCount == 0) {
            METAL_INTERNAL_DestroyTextureContainer(
                renderer->textureContainersToDestroy[i]);

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
    Uint32 fenceCount)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    SDL_bool waiting;

    if (waitAll) {
        for (Uint32 i = 0; i < fenceCount; i += 1) {
            while (!SDL_AtomicGet(&((MetalFence *)pFences[i])->complete)) {
                /* Spin! */
            }
        }
    } else {
        waiting = 1;
        while (waiting) {
            for (Uint32 i = 0; i < fenceCount; i += 1) {
                if (SDL_AtomicGet(&((MetalFence *)pFences[i])->complete) > 0) {
                    waiting = 0;
                    break;
                }
            }
        }
    }

    METAL_INTERNAL_PerformPendingDestroys(renderer);
}

static SDL_bool METAL_QueryFence(
    Refresh_Renderer *driverData,
    Refresh_Fence *fence)
{
    MetalFence *metalFence = (MetalFence *)fence;
    return SDL_AtomicGet(&metalFence->complete) == 1;
}

/* Window and Swapchain Management */

static MetalWindowData *METAL_INTERNAL_FetchWindowData(SDL_Window *window)
{
	return (MetalWindowData*) SDL_GetWindowData(window, WINDOW_PROPERTY_DATA);
}

static SDL_bool METAL_SupportsSwapchainComposition(
    Refresh_Renderer *driverData,
    SDL_Window *window,
    Refresh_SwapchainComposition swapchainComposition)
{
#ifndef __MACOSX__
    if (swapchainComposition == REFRESH_SWAPCHAINCOMPOSITION_HDR10_ST2048) {
        return SDL_FALSE;
    }
#endif

    if (@available(macOS 11.0, *)) {
        return SDL_TRUE;
    } else {
        return swapchainComposition != REFRESH_SWAPCHAINCOMPOSITION_HDR10_ST2048;
    }
}

static Uint8 METAL_INTERNAL_CreateSwapchain(
    MetalRenderer *renderer,
    MetalWindowData *windowData,
    Refresh_SwapchainComposition swapchainComposition,
    Refresh_PresentMode presentMode)
{
    CGColorSpaceRef colorspace;
    CGSize drawableSize;

    windowData->view = SDL_Metal_CreateView(windowData->window);
    windowData->drawable = nil;

    windowData->layer = (__bridge CAMetalLayer *)(SDL_Metal_GetLayer(windowData->view));
    windowData->layer.device = renderer->device;
    windowData->layer.framebufferOnly = false; /* Allow sampling swapchain textures, at the expense of performance */
#ifdef __MACOSX__
    windowData->layer.displaySyncEnabled = (presentMode != REFRESH_PRESENTMODE_IMMEDIATE);
#endif
    windowData->layer.pixelFormat = RefreshToMetal_SurfaceFormat[SwapchainCompositionToFormat[swapchainComposition]];
#ifndef __TVOS__
    windowData->layer.wantsExtendedDynamicRangeContent = (swapchainComposition != REFRESH_SWAPCHAINCOMPOSITION_SDR);
#endif

    colorspace = CGColorSpaceCreateWithName(SwapchainCompositionToColorSpace[swapchainComposition]);
    windowData->layer.colorspace = colorspace;
    CGColorSpaceRelease(colorspace);

    windowData->texture.handle = nil; /* This will be set in AcquireSwapchainTexture. */

    /* Set up the texture container */
    SDL_zero(windowData->textureContainer);
    windowData->textureContainer.canBeCycled = 0;
    windowData->textureContainer.activeTexture = &windowData->texture;
    windowData->textureContainer.textureCapacity = 1;
    windowData->textureContainer.textureCount = 1;
    windowData->textureContainer.createInfo.format = SwapchainCompositionToFormat[swapchainComposition];
    windowData->textureContainer.createInfo.levelCount = 1;
    windowData->textureContainer.createInfo.depth = 1;
    windowData->textureContainer.createInfo.isCube = 0;
    windowData->textureContainer.createInfo.usageFlags = REFRESH_TEXTUREUSAGE_COLOR_TARGET_BIT | REFRESH_TEXTUREUSAGE_SAMPLER_BIT;

    drawableSize = windowData->layer.drawableSize;
    windowData->textureContainer.createInfo.width = (Uint32)drawableSize.width;
    windowData->textureContainer.createInfo.height = (Uint32)drawableSize.height;

    return 1;
}

static SDL_bool METAL_SupportsPresentMode(
    Refresh_Renderer *driverData,
    SDL_Window *window,
    Refresh_PresentMode presentMode)
{
    switch (presentMode) {
#ifdef __MACOSX__
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
    Refresh_PresentMode presentMode)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);

    if (windowData == NULL) {
        windowData = (MetalWindowData *)SDL_malloc(sizeof(MetalWindowData));
        windowData->window = window;

        if (METAL_INTERNAL_CreateSwapchain(renderer, windowData, swapchainComposition, presentMode)) {
            SDL_SetWindowData(window, WINDOW_PROPERTY_DATA, windowData);

            SDL_LockMutex(renderer->windowLock);

            if (renderer->claimedWindowCount >= renderer->claimedWindowCapacity) {
                renderer->claimedWindowCapacity *= 2;
                renderer->claimedWindows = SDL_realloc(
                    renderer->claimedWindows,
                    renderer->claimedWindowCapacity * sizeof(MetalWindowData *));
            }
            renderer->claimedWindows[renderer->claimedWindowCount] = windowData;
            renderer->claimedWindowCount += 1;

            SDL_UnlockMutex(renderer->windowLock);

            return SDL_TRUE;
        } else {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Could not create swapchain, failed to claim window!");
            SDL_free(windowData);
            return SDL_FALSE;
        }
    } else {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Window already claimed!");
        return SDL_FALSE;
    }
}

static void METAL_INTERNAL_DestroySwapchain(
    MetalRenderer *renderer,
    MetalWindowData *windowData)
{
    METAL_Wait((Refresh_Renderer *)renderer);
    SDL_Metal_DestroyView(windowData->view);
}

static void METAL_UnclaimWindow(
    Refresh_Renderer *driverData,
    SDL_Window *window)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);

    if (windowData == NULL) {
        return;
    }

    METAL_INTERNAL_DestroySwapchain(
        renderer,
        windowData);

    SDL_LockMutex(renderer->windowLock);
    for (Uint32 i = 0; i < renderer->claimedWindowCount; i += 1) {
        if (renderer->claimedWindows[i]->window == window) {
            renderer->claimedWindows[i] = renderer->claimedWindows[renderer->claimedWindowCount - 1];
            renderer->claimedWindowCount -= 1;
            break;
        }
    }
    SDL_UnlockMutex(renderer->windowLock);

    SDL_free(windowData);

    SDL_SetWindowData(window, WINDOW_PROPERTY_DATA, NULL);
}

static Refresh_Texture *METAL_AcquireSwapchainTexture(
    Refresh_CommandBuffer *commandBuffer,
    SDL_Window *window,
    Uint32 *pWidth,
    Uint32 *pHeight)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalWindowData *windowData;
    CGSize drawableSize;

    windowData = METAL_INTERNAL_FetchWindowData(window);
    if (windowData == NULL) {
        return NULL;
    }

    /* Get the drawable and its underlying texture */
    windowData->drawable = [windowData->layer nextDrawable];
    windowData->texture.handle = [windowData->drawable texture];

    /* Update the window size */
    drawableSize = windowData->layer.drawableSize;
    windowData->textureContainer.createInfo.width = (Uint32)drawableSize.width;
    windowData->textureContainer.createInfo.height = (Uint32)drawableSize.height;

    /* Send the dimensions to the out parameters. */
    *pWidth = (Uint32)drawableSize.width;
    *pHeight = (Uint32)drawableSize.height;

    /* Set up presentation */
    if (metalCommandBuffer->windowDataCount == metalCommandBuffer->windowDataCapacity) {
        metalCommandBuffer->windowDataCapacity += 1;
        metalCommandBuffer->windowDatas = SDL_realloc(
            metalCommandBuffer->windowDatas,
            metalCommandBuffer->windowDataCapacity * sizeof(MetalWindowData *));
    }
    metalCommandBuffer->windowDatas[metalCommandBuffer->windowDataCount] = windowData;
    metalCommandBuffer->windowDataCount += 1;

    /* Return the swapchain texture */
    return (Refresh_Texture *)&windowData->textureContainer;
}

static Refresh_TextureFormat METAL_GetSwapchainTextureFormat(
    Refresh_Renderer *driverData,
    SDL_Window *window)
{
    MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);

    if (windowData == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Cannot get swapchain format, window has not been claimed!");
        return 0;
    }

    return windowData->textureContainer.createInfo.format;
}

static SDL_bool METAL_SetSwapchainParameters(
    Refresh_Renderer *driverData,
    SDL_Window *window,
    Refresh_SwapchainComposition swapchainComposition,
    Refresh_PresentMode presentMode)
{
    MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);
    CGColorSpaceRef colorspace;

    if (windowData == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Cannot set swapchain parameters, window has not been claimed!");
        return SDL_FALSE;
    }

    if (!METAL_SupportsSwapchainComposition(driverData, window, swapchainComposition)) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Swapchain composition not supported!");
        return SDL_FALSE;
    }

    if (!METAL_SupportsPresentMode(driverData, window, presentMode)) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Present mode not supported!");
        return SDL_FALSE;
    }

    METAL_Wait(driverData);

#ifdef __MACOSX__
    windowData->layer.displaySyncEnabled = (presentMode != REFRESH_PRESENTMODE_IMMEDIATE);
#endif
    windowData->layer.pixelFormat = RefreshToMetal_SurfaceFormat[SwapchainCompositionToFormat[swapchainComposition]];
#ifndef __TVOS__
    windowData->layer.wantsExtendedDynamicRangeContent = (swapchainComposition != REFRESH_SWAPCHAINCOMPOSITION_SDR);
#endif

    colorspace = CGColorSpaceCreateWithName(SwapchainCompositionToColorSpace[swapchainComposition]);
    windowData->layer.colorspace = colorspace;
    CGColorSpaceRelease(colorspace);

    windowData->textureContainer.createInfo.format = SwapchainCompositionToFormat[swapchainComposition];

    return SDL_TRUE;
}

/* Submission */

static void METAL_Submit(
    Refresh_CommandBuffer *commandBuffer)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalRenderer *renderer = metalCommandBuffer->renderer;

    SDL_LockMutex(renderer->submitLock);

    /* Enqueue present requests, if applicable */
    for (Uint32 i = 0; i < metalCommandBuffer->windowDataCount; i += 1) {
        [metalCommandBuffer->handle presentDrawable:metalCommandBuffer->windowDatas[i]->drawable];
    }

    /* Notify the fence when the command buffer has completed */
    [metalCommandBuffer->handle addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
      SDL_AtomicIncRef(&metalCommandBuffer->fence->complete);
    }];

    /* Submit the command buffer */
    [metalCommandBuffer->handle commit];
    metalCommandBuffer->handle = nil;

    /* Mark the command buffer as submitted */
    if (renderer->submittedCommandBufferCount >= renderer->submittedCommandBufferCapacity) {
        renderer->submittedCommandBufferCapacity = renderer->submittedCommandBufferCount + 1;

        renderer->submittedCommandBuffers = SDL_realloc(
            renderer->submittedCommandBuffers,
            sizeof(MetalCommandBuffer *) * renderer->submittedCommandBufferCapacity);
    }
    renderer->submittedCommandBuffers[renderer->submittedCommandBufferCount] = metalCommandBuffer;
    renderer->submittedCommandBufferCount += 1;

    /* Check if we can perform any cleanups */
    for (Sint32 i = renderer->submittedCommandBufferCount - 1; i >= 0; i -= 1) {
        if (SDL_AtomicGet(&renderer->submittedCommandBuffers[i]->fence->complete)) {
            METAL_INTERNAL_CleanCommandBuffer(
                renderer,
                renderer->submittedCommandBuffers[i]);
        }
    }

    METAL_INTERNAL_PerformPendingDestroys(renderer);

    SDL_UnlockMutex(renderer->submitLock);
}

static Refresh_Fence *METAL_SubmitAndAcquireFence(
    Refresh_CommandBuffer *commandBuffer)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalFence *fence = metalCommandBuffer->fence;

    metalCommandBuffer->autoReleaseFence = 0;
    METAL_Submit(commandBuffer);

    return (Refresh_Fence *)fence;
}

static void METAL_Wait(
    Refresh_Renderer *driverData)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalCommandBuffer *commandBuffer;

    /*
     * Wait for all submitted command buffers to complete.
     * Sort of equivalent to vkDeviceWaitIdle.
     */
    for (Uint32 i = 0; i < renderer->submittedCommandBufferCount; i += 1) {
        while (!SDL_AtomicGet(&renderer->submittedCommandBuffers[i]->fence->complete)) {
            /* Spin! */
        }
    }

    SDL_LockMutex(renderer->submitLock);

    for (Sint32 i = renderer->submittedCommandBufferCount - 1; i >= 0; i -= 1) {
        commandBuffer = renderer->submittedCommandBuffers[i];
        METAL_INTERNAL_CleanCommandBuffer(renderer, commandBuffer);
    }

    METAL_INTERNAL_PerformPendingDestroys(renderer);

    SDL_UnlockMutex(renderer->submitLock);
}

/* Format Info */

static SDL_bool METAL_IsTextureFormatSupported(
    Refresh_Renderer *driverData,
    Refresh_TextureFormat format,
    Refresh_TextureType type,
    Refresh_TextureUsageFlags usage)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;

    /* Only depth textures can be used as... depth textures */
    if ((usage & REFRESH_TEXTUREUSAGE_DEPTH_STENCIL_TARGET_BIT)) {
        if (!IsDepthFormat(format)) {
            return SDL_FALSE;
        }
    }

    switch (format) {
    /* Apple GPU exclusive */
    case REFRESH_TEXTUREFORMAT_B5G6R5:
    case REFRESH_TEXTUREFORMAT_B5G5R5A1:
    case REFRESH_TEXTUREFORMAT_B4G4R4A4:
        return ![renderer->device supportsFamily:MTLGPUFamilyMac2];

    /* Requires BC compression support */
    case REFRESH_TEXTUREFORMAT_BC1:
    case REFRESH_TEXTUREFORMAT_BC2:
    case REFRESH_TEXTUREFORMAT_BC3:
    case REFRESH_TEXTUREFORMAT_BC7:
    case REFRESH_TEXTUREFORMAT_BC3_SRGB:
    case REFRESH_TEXTUREFORMAT_BC7_SRGB:
#ifdef __MACOSX__
        if (@available(macOS 11.0, *)) {
            return (
                [renderer->device supportsBCTextureCompression] &&
                !(usage & REFRESH_TEXTUREUSAGE_COLOR_TARGET_BIT));
        } else {
            return SDL_FALSE;
        }
#else
        /* FIXME: iOS 16.4+ allows these formats! */
        return SDL_FALSE;
#endif

    /* Requires D24S8 support */
    case REFRESH_TEXTUREFORMAT_D24_UNORM:
    case REFRESH_TEXTUREFORMAT_D24_UNORM_S8_UINT:
#ifdef __MACOSX__
        return [renderer->device isDepth24Stencil8PixelFormatSupported];
#else
        return SDL_FALSE;
#endif

    default:
        return SDL_TRUE;
    }
}

/* Device Creation */

static SDL_bool METAL_PrepareDriver()
{
    /* FIXME: Add a macOS / iOS version check! Maybe support >= 10.14? */
    return SDL_TRUE;
}

static void METAL_INTERNAL_InitBlitResources(
    MetalRenderer *renderer)
{
    Refresh_ShaderCreateInfo shaderModuleCreateInfo;
    Refresh_SamplerCreateInfo samplerCreateInfo;

    /* Allocate the dynamic blit pipeline list */
    renderer->blitPipelineCapacity = 1;
    renderer->blitPipelineCount = 0;
    renderer->blitPipelines = SDL_malloc(
        sizeof(BlitPipeline) * renderer->blitPipelineCapacity);

    /* Fullscreen vertex shader */
    SDL_zero(shaderModuleCreateInfo);
    shaderModuleCreateInfo.code = (Uint8 *)FullscreenVertexShader;
    shaderModuleCreateInfo.codeSize = sizeof(FullscreenVertexShader);
    shaderModuleCreateInfo.stage = REFRESH_SHADERSTAGE_VERTEX;
    shaderModuleCreateInfo.format = REFRESH_SHADERFORMAT_MSL;
    shaderModuleCreateInfo.entryPointName = "vs_main";

    renderer->fullscreenVertexShader = METAL_CreateShader(
        (Refresh_Renderer *)renderer,
        &shaderModuleCreateInfo);

    if (renderer->fullscreenVertexShader == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to compile fullscreen vertex shader!");
    }

    /* Blit from 2D pixel shader */
    shaderModuleCreateInfo.code = (Uint8 *)BlitFrom2DFragmentShader;
    shaderModuleCreateInfo.codeSize = sizeof(BlitFrom2DFragmentShader);
    shaderModuleCreateInfo.stage = REFRESH_SHADERSTAGE_FRAGMENT;
    shaderModuleCreateInfo.entryPointName = "fs_main";
    shaderModuleCreateInfo.samplerCount = 1;

    renderer->blitFrom2DPixelShader = METAL_CreateShader(
        (Refresh_Renderer *)renderer,
        &shaderModuleCreateInfo);

    if (renderer->blitFrom2DPixelShader == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to compile blit from 2D fragment shader!");
    }

    /* Create samplers */
    samplerCreateInfo.addressModeU = REFRESH_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    samplerCreateInfo.addressModeV = REFRESH_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    samplerCreateInfo.addressModeW = REFRESH_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    samplerCreateInfo.anisotropyEnable = 0;
    samplerCreateInfo.compareEnable = 0;
    samplerCreateInfo.magFilter = REFRESH_FILTER_NEAREST;
    samplerCreateInfo.minFilter = REFRESH_FILTER_NEAREST;
    samplerCreateInfo.mipmapMode = REFRESH_SAMPLERMIPMAPMODE_NEAREST;
    samplerCreateInfo.mipLodBias = 0.0f;
    samplerCreateInfo.minLod = 0;
    samplerCreateInfo.maxLod = 1000;

    renderer->blitNearestSampler = METAL_CreateSampler(
        (Refresh_Renderer *)renderer,
        &samplerCreateInfo);

    if (renderer->blitNearestSampler == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to create blit nearest sampler!");
    }

    samplerCreateInfo.magFilter = REFRESH_FILTER_LINEAR;
    samplerCreateInfo.minFilter = REFRESH_FILTER_LINEAR;
    samplerCreateInfo.mipmapMode = REFRESH_SAMPLERMIPMAPMODE_LINEAR;

    renderer->blitLinearSampler = METAL_CreateSampler(
        (Refresh_Renderer *)renderer,
        &samplerCreateInfo);

    if (renderer->blitLinearSampler == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to create blit linear sampler!");
    }
}

static void METAL_INTERNAL_DestroyBlitResources(
    Refresh_Renderer *driverData)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;

    METAL_ReleaseShader(driverData, renderer->fullscreenVertexShader);
    METAL_ReleaseShader(driverData, renderer->blitFrom2DPixelShader);

    METAL_ReleaseSampler(driverData, renderer->blitLinearSampler);
    METAL_ReleaseSampler(driverData, renderer->blitNearestSampler);

    for (Uint32 i = 0; i < renderer->blitPipelineCount; i += 1) {
        METAL_ReleaseGraphicsPipeline(
            driverData,
            renderer->blitPipelines[i].pipeline);
    }
    SDL_free(renderer->blitPipelines);
}

static Refresh_Device *METAL_CreateDevice(SDL_bool debugMode, SDL_bool preferLowPower)
{
    MetalRenderer *renderer;

    /* Allocate and zero out the renderer */
    renderer = (MetalRenderer *)SDL_calloc(1, sizeof(MetalRenderer));

    /* Create the Metal device and command queue */
#ifdef __MACOSX__
    if (preferLowPower) {
        NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
        for (id<MTLDevice> device in devices) {
            if (device.isLowPower) {
                renderer->device = device;
                break;
            }
        }
    }
#endif
    if (renderer->device == NULL) {
        renderer->device = MTLCreateSystemDefaultDevice();
    }
    renderer->queue = [renderer->device newCommandQueue];

    /* Print driver info */
    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Refresh_ Driver: Metal");
    SDL_LogInfo(
        SDL_LOG_CATEGORY_APPLICATION,
        "Metal Device: %s",
        [renderer->device.name UTF8String]);

    /* Remember debug mode */
    renderer->debugMode = debugMode;

    /* Set up colorspace array */
    SwapchainCompositionToColorSpace[0] = kCGColorSpaceSRGB;
    SwapchainCompositionToColorSpace[1] = kCGColorSpaceSRGB;
    SwapchainCompositionToColorSpace[2] = kCGColorSpaceExtendedLinearSRGB;
    if (@available(macOS 11.0, *)) {
        SwapchainCompositionToColorSpace[3] = kCGColorSpaceITUR_2100_PQ;
    } else {
        SwapchainCompositionToColorSpace[3] = NULL;
    }

    /* Create mutexes */
    renderer->submitLock = SDL_CreateMutex();
    renderer->acquireCommandBufferLock = SDL_CreateMutex();
    renderer->acquireUniformBufferLock = SDL_CreateMutex();
    renderer->disposeLock = SDL_CreateMutex();
    renderer->fenceLock = SDL_CreateMutex();
    renderer->windowLock = SDL_CreateMutex();

    /* Create command buffer pool */
    METAL_INTERNAL_AllocateCommandBuffers(renderer, 2);

    /* Create fence pool */
    renderer->availableFenceCapacity = 2;
    renderer->availableFences = SDL_malloc(
        sizeof(MetalFence *) * renderer->availableFenceCapacity);

    /* Create uniform buffer pool */
    renderer->uniformBufferPoolCapacity = 32;
    renderer->uniformBufferPoolCount = 32;
    renderer->uniformBufferPool = SDL_malloc(
        renderer->uniformBufferPoolCapacity * sizeof(MetalUniformBuffer *));

    for (Uint32 i = 0; i < renderer->uniformBufferPoolCount; i += 1) {
        renderer->uniformBufferPool[i] = METAL_INTERNAL_CreateUniformBuffer(
            renderer,
            UNIFORM_BUFFER_SIZE);
    }

    /* Create deferred destroy arrays */
    renderer->bufferContainersToDestroyCapacity = 2;
    renderer->bufferContainersToDestroyCount = 0;
    renderer->bufferContainersToDestroy = SDL_malloc(
        renderer->bufferContainersToDestroyCapacity * sizeof(MetalBufferContainer *));

    renderer->textureContainersToDestroyCapacity = 2;
    renderer->textureContainersToDestroyCount = 0;
    renderer->textureContainersToDestroy = SDL_malloc(
        renderer->textureContainersToDestroyCapacity * sizeof(MetalTextureContainer *));

    /* Create claimed window list */
    renderer->claimedWindowCapacity = 1;
    renderer->claimedWindows = SDL_malloc(
        sizeof(MetalWindowData *) * renderer->claimedWindowCapacity);

    /* Initialize blit resources */
    METAL_INTERNAL_InitBlitResources(renderer);

    Refresh_Device *result = SDL_malloc(sizeof(Refresh_Device));
    ASSIGN_DRIVER(METAL)
    result->driverData = (Refresh_Renderer *)renderer;
    return result;
}

Refresh_Driver MetalDriver = {
    "Metal",
    REFRESH_BACKEND_METAL,
    METAL_PrepareDriver,
    METAL_CreateDevice
};

#endif /*REFRESH_METAL*/
