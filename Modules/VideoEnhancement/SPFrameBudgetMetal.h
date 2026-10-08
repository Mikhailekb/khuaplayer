// Metal motion analysis and NV12/P010-to-RGBA16F conversion. The dedicated
// FrameBudget.metallib loads lazily. Encoding methods use separate command
// buffers on any thread; the texture cache is internally locked.
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// Matches SPBudgetBlockResult in FrameBudget.metal field for field.
typedef struct SPBudgetBlockResult {
    float sadBest, sadZero, dx, dy, texture, meanA, meanB, pad;
} SPBudgetBlockResult;

typedef struct SPBudgetProbeSummary {
    float benefit;            // Pair benefit in [0,1], used as the planner value.
    float motionPx1080;       // Median motion in pixels/frame, normalized to 1080p width.
    float movingFraction;     // Moving blocks divided by non-flat blocks.
    float unmatchedFraction;  // Unmatched blocks divided by non-flat blocks.
    float meanAbsDiff;        // Absolute block-mean difference for fades and flashes.
    float coherence;          // Fraction agreeing within 1.5 pixels with at least two cardinal neighbors.
    float residualRatio;      // Median sadBest/texture ratio over textured blocks.
    uint32_t blocks;          // Number of non-flat blocks.
    BOOL cut;                 // Scene-cut or flash classification.
    BOOL valid;
} SPBudgetProbeSummary;

@interface SPFrameBudgetMetal : NSObject

/// A nil library lazily loads FrameBudget.metallib from the framework bundle.
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                library:(nullable id<MTLLibrary>)library
                                  width:(uint32_t)width
                                 height:(uint32_t)height
                            pixelFormat:(OSType)pixelFormat
                                  error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
@property (nonatomic, readonly) OSType pixelFormat;
/// Planar input maps to equivalent bi-planar NV12/P010 at the same bit depth
/// and range. Bi-planar input preserves pixelFormat.
@property (nonatomic, readonly) OSType outputPixelFormat;
@property (nonatomic, readonly) BOOL tenBit;
@property (nonatomic, readonly) BOOL planarInput;
@property (nonatomic, readonly) uint32_t probeWidth;
@property (nonatomic, readonly) uint32_t probeHeight;
@property (nonatomic, readonly) uint32_t probeFactor;   // Full-resolution pixels per analysis pixel.

/// Selects the YCbCr matrix from frame attachments, otherwise resolution and
/// bit depth. Forward and inverse conversion use the same coefficients.
- (void)adoptColorMatrixFromFrame:(CVPixelBufferRef)frame;

/// DV-only, before creating FRC/output pools. Lazily loads reconstruction from
/// the renderer library and selects BT.2020 PQ P010 synthetic output.
- (BOOL)enableDoviReconstructionWithError:(NSError **)error;
@property (nonatomic, readonly) BOOL doviReconstruction;

// Motion analysis
- (id<MTLTexture>)newProbeTexture;
- (id<MTLBuffer>)newBlockResultBuffer;
/// Downsamples luma into probeTex. owners keeps textures alive until completion.
- (BOOL)encodeDownsampleOfFrame:(CVPixelBufferRef)frame
                           into:(id<MTLTexture>)probeTex
                  commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                         owners:(NSMutableArray *)owners;
- (void)encodeBlockMatchFrom:(id<MTLTexture>)probeA
                          to:(id<MTLTexture>)probeB
                     results:(id<MTLBuffer>)results
               commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
/// CPU reduction; call after the command buffer completes.
- (SPBudgetProbeSummary)summarizeBlockResults:(id<MTLBuffer>)results;

// Color conversion
- (BOOL)encodeConvertFrame:(CVPixelBufferRef)frame
                    toRGBA:(CVPixelBufferRef)rgba
             commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    owners:(NSMutableArray *)owners;
- (BOOL)encodeConvertRGBA:(CVPixelBufferRef)rgba
                  toFrame:(CVPixelBufferRef)frame
            commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                   owners:(NSMutableArray *)owners;

@end

NS_ASSUME_NONNULL_END
