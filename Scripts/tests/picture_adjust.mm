#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <array>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <random>
using Pixel=std::array<float,4>;
size_t assertions=0;
void expect(bool ok,const char*msg){++assertions;if(!ok){fprintf(stderr,"FAIL %s\n",msg);exit(1);}}
struct FragmentRenderer {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLTexture> planes[3], subtitle;
    static constexpr int width = 96, height = 8;

    explicit FragmentRenderer(id<MTLDevice> d) : device(d), queue([d newCommandQueue]) {
        for (int p = 0; p < 3; ++p) {
            auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Unorm
                                                                               width:width height:height mipmapped:NO];
            descriptor.storageMode = MTLStorageModeShared;
            descriptor.usage = MTLTextureUsageShaderRead;
            planes[p] = [device newTextureWithDescriptor:descriptor];
            std::vector<uint16_t> pixels(width * height);
            for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
                pixels[y * width + x] = p == 0 ? uint16_t(64 + x * 876 / (width - 1))
                                             : uint16_t(512 + (y - height / 2) * (p == 1 ? 11 : -9));
            }
            [planes[p] replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0
                           withBytes:pixels.data() bytesPerRow:width * 2];
        }
        auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                           width:1 height:1 mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        subtitle = [device newTextureWithDescriptor:descriptor];
        const Pixel red = {.5f, 0, 0, .5f};
        [subtitle replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:red.data() bytesPerRow:16];
    }

    std::vector<Pixel> render(id<MTLLibrary> library, bool dovi, int transfer, bool hdr,
                              bool edr, bool enabled, bool manual = false, bool captions = false,
                              MTLPixelFormat format = MTLPixelFormatRGBA32Float, float brightness = 0, float contrast = 1, float gamma = 1, float saturation = 1, float hue = 0) {
        float uniforms[40] = {}, dv[992] = {};
        uniforms[0] = uniforms[2] = width; uniforms[1] = uniforms[3] = height;
        uniforms[4] = 1; uniforms[5] = transfer; uniforms[7] = 10; uniforms[8] = hdr;
        uniforms[9] = 1000; uniforms[10] = 1; uniforms[11] = dovi;
        uniforms[21] = contrast; uniforms[20] = brightness;
        uniforms[22] = saturation; uniforms[23] = gamma; uniforms[32] = hue; uniforms[24] = 656.477f;
        uniforms[25] = edr; uniforms[26] = 1; uniforms[30] = 1; uniforms[33] = enabled;
        dv[126] = dovi; // Motion-reconstructed P010: retain display management, skip RPU reshaping.
        if (captions) { uniforms[14] = width; uniforms[15] = height; uniforms[16] = 1; }
        MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
        int doviConstant = dovi;
        [constants setConstantValue:&doviConstant type:MTLDataTypeInt atIndex:5];
        NSError *error = nil;
        auto vertex = [library newFunctionWithName:@"videoVertex" constantValues:constants error:&error];
        auto fragment = [library newFunctionWithName:@"videoFragment" constantValues:constants error:&error];
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment;
        descriptor.colorAttachments[0].pixelFormat = format;
        auto pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline) std::fprintf(stderr, "%s\n", error.description.UTF8String);
        expect(pipeline != nil, "full production fragment pipeline");
        auto textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                  width:width height:height mipmapped:NO];
        textureDescriptor.storageMode = MTLStorageModeShared;
        textureDescriptor.usage = MTLTextureUsageRenderTarget;
        auto output = [device newTextureWithDescriptor:textureDescriptor];
        auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = output;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        auto command = [queue commandBuffer];
        auto encoder = [command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:pipeline];
        [encoder setVertexBytes:uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentBytes:uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentBytes:dv length:sizeof(dv) atIndex:1];
        [encoder setFragmentTexture:planes[0] atIndex:0];
        [encoder setFragmentTexture:planes[1] atIndex:1];
        [encoder setFragmentTexture:subtitle atIndex:2];
        [encoder setFragmentTexture:planes[2] atIndex:3];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        expect(command.status == MTLCommandBufferStatusCompleted, "full fragment executes on Metal");
        std::vector<Pixel> result(width * height);
        if (format == MTLPixelFormatRGBA32Float) {
            [output getBytes:result.data() bytesPerRow:width * sizeof(Pixel)
                  fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        } else {
            std::vector<_Float16> half(width * height * 4);
            [output getBytes:half.data() bytesPerRow:width * 8
                  fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
            for (size_t i = 0; i < result.size(); ++i) for (int c = 0; c < 4; ++c) result[i][c] = half[i * 4 + c];
        }
        return result;
    }
};

struct Input { Pixel rgb, tonal, color; };
std::vector<Pixel> adjust(id<MTLDevice> device,id<MTLLibrary> library,const std::vector<Input>& input) {
 NSError *e=nil; auto fn=[library newFunctionWithName:@"pictureAudit"];
 auto pipe=[device newComputePipelineStateWithFunction:fn error:&e];expect(pipe!=nil,"picture helper pipeline");
 auto ib=[device newBufferWithBytes:input.data() length:input.size()*sizeof(Input) options:MTLResourceStorageModeShared];
 auto ob=[device newBufferWithLength:input.size()*sizeof(Pixel) options:MTLResourceStorageModeShared];
 auto queue=[device newCommandQueue];auto cmd=[queue commandBuffer];auto enc=[cmd computeCommandEncoder];
 [enc setComputePipelineState:pipe];[enc setBuffer:ib offset:0 atIndex:0];[enc setBuffer:ob offset:0 atIndex:1];
 [enc dispatchThreads:MTLSizeMake(input.size(),1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];[enc endEncoding];[cmd commit];[cmd waitUntilCompleted];
 expect(cmd.status==MTLCommandBufferStatusCompleted,"actual picture helper executes on Metal");
 std::vector<Pixel>result(input.size());memcpy(result.data(),ob.contents,input.size()*sizeof(Pixel));return result;
}
Input sample(float r,float g,float b,float brightness=0,float contrast=1,float gamma=1,float saturation=1,float hue=0,int gamut=0,float headroom=1) {
 return {{r,g,b,1},{brightness,contrast,gamma,saturation},{hue,float(gamut),headroom,0}};
}
int main(int argc,char**argv){@autoreleasepool {
 expect(argc==2,"production shader path");auto device=MTLCreateSystemDefaultDevice();
 if(!device) {
  std::fprintf(stderr,"SKIP: no native Metal device; picture GPU checks were not run.\n");
  return 77;
 }
 NSError *error=nil;NSString *source=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];expect(source!=nil,"read production shader");
 NSString *extra=@"\nstruct PictureAuditInput {float4 rgb;float4 tonal;float4 color;};\nkernel void pictureAudit(device const PictureAuditInput* input [[buffer(0)]],device float4* output [[buffer(1)]],uint i [[thread_position_in_grid]]){auto p=input[i];output[i]=float4(spPictureAdjust(p.rgb.rgb,p.tonal.x,p.tonal.y,p.tonal.w,p.tonal.z,p.color.x,int(p.color.y),p.color.z),p.rgb.a);}\n";
 auto library=[device newLibraryWithSource:[source stringByAppendingString:extra] options:nil error:&error];
 if(!library)fprintf(stderr,"%s\n",error.description.UTF8String);expect(library!=nil,"production shader compiles with runtime Metal");
 std::vector<Input>input;
 // Neutral must preserve bytes, including extended HDR and source-gamut values.
 for(auto rgb:{Pixel{0,0,0,1},Pixel{.01f,.3f,.8f,1},Pixel{1,1,1,1},Pixel{4,2,.5f,1},Pixel{-.01f,.2f,1.2f,1}})input.push_back({rgb,{0,1,1,1},{0,4,2.5f,0}});
 auto identity=adjust(device,library,input);for(size_t i=0;i<input.size();i++)expect(memcmp(input[i].rgb.data(),identity[i].data(),sizeof(Pixel))==0,"neutral returns exact input bytes");
 input.clear();
 for(float b:{-.5f,0.f,.5f})for(float c:{.5f,1.f,2.f})for(float g:{.5f,1.f,2.f})for(float x:{0.f,1.f,2.f,4.f})input.push_back(sample(x,x,x,b,c,g,1,0,4,2.5f));
 auto endpoints=adjust(device,library,input);for(size_t i=0;i<input.size();i++)for(int c=0;c<3;c++)expect(endpoints[i][c]==input[i].rgb[c],"black, reference white and HDR whites stay fixed under tonal controls");
 input.clear();
 constexpr float numericalFloor = 1e-7f;
 for(float b:{-.5f,.5f})for(float c:{.5f,2.f})for(float g:{.5f,2.f}) {
  for(float x:{std::nextafter(numericalFloor,0.f),numericalFloor,std::nextafter(numericalFloor,1.f)})input.push_back(sample(x,x,x,b,c,g));
 }
 auto floorBoundary=adjust(device,library,input);
 for(size_t i=0;i<floorBoundary.size();i+=3) {
  expect(floorBoundary[i][0]<=floorBoundary[i+1][0]&&floorBoundary[i+1][0]<=floorBoundary[i+2][0],"interpolated near-black values remain monotonic across the numerical floor");
  expect(floorBoundary[i+1][0]==numericalFloor,"the numerical floor joins its original pixel exactly");
  expect(floorBoundary[i+2][0]-floorBoundary[i+1][0]<.001,"one float ULP above black cannot create the former .01 encoded contour");
 }
 input.clear();struct Ray {size_t start;int count;};std::vector<Ray>rays;
 for(float b:{-.5f,0.f,.5f})for(float c:{.5f,1.f,2.f})for(float g:{.5f,1.f,2.f}) {
  rays.push_back({input.size(),4097});for(int n=0;n<=4096;n++){float x=float(n)/4096;input.push_back(sample(x,x,x,b,c,g));}
 }
 auto gray=adjust(device,library,input);for(auto ray:rays)for(int n=0;n<ray.count;n++) {
  auto p=gray[ray.start+n];for(int c=0;c<3;c++)expect(std::isfinite(p[c])&&p[c]>=0&&p[c]<=1.000001,"tonal gray remains finite and within display bounds");
  expect(std::abs(p[0]-p[1])<2e-6&&std::abs(p[1]-p[2])<2e-6,"gray remains neutral");
  if(n)expect(p[0]>=gray[ray.start+n-1][0],"tonal gray ramp remains monotonic");
 }
 std::vector<Input>behavior={sample(.1,.1,.1,.25),sample(.1,.1,.1,0,.5),sample(.8,.8,.8,0,.5),sample(.5,.5,.5,0,.5),sample(.1,.1,.1,0,1,1.8),sample(.2,.1,.05,.5),sample(.2,.1,.05,0,.5,1.8),sample(.2,.1,.05,0,1,.5)};
 auto result=adjust(device,library,behavior);
 expect(result[0][0]>.1&&result[0][0]<.3,"brightness raises shadow detail without an additive gray veil");
 expect(result[1][0]>.1&&result[2][0]<.8,"reduced contrast opens shadows and lowers highlights");expect(std::abs(result[3][0]-.5)<1e-6,"contrast pivot remains middle gray within numerical-floor precision");expect(result[4][0]>.1,"positive gamma raises midtones");
 for(size_t i=5;i<behavior.size();i++){expect(std::abs(result[i][0]/result[i][1]-2)<1e-5&&std::abs(result[i][1]/result[i][2]-2)<1e-5,"tonal gain preserves RGB channel ratios");}
 input.clear();
 for(float b:{-.5f,.5f})for(float c:{.5f,2.f})for(float g:{.5f,2.f})input.push_back(sample(1.8f,.12f,.04f,b,c,g,1,0,4,2.5f));
 auto coloredHdr=adjust(device,library,input);
 bool aboveWhite=false;for(auto p:coloredHdr) {
  aboveWhite=aboveWhite||p[0]>1;
  expect(p[0]>0&&p[0]<=2.5f&&p[1]>0&&p[2]>0,"colored HDR remains positive and headroom bounded under tonal controls");
  expect(std::abs(p[0]/p[1]-15)<3e-5&&std::abs(p[1]/p[2]-3)<1e-5,"colored HDR tone changes preserve channel ratios without clipping");
 }
 expect(aboveWhite,"colored HDR retains values above white instead of clipping to SDR");
 input.clear();std::mt19937 random(20261025);std::uniform_real_distribution<float>value(0,1),angle(-180,180),parameter(-.5,.5);
 for(int gamut=0;gamut<6;gamut++)for(int i=0;i<1000;i++){float headroom=i%2?2.5:1;input.push_back(sample(value(random)*headroom,value(random)*headroom,value(random)*headroom,parameter(random),std::exp2(parameter(random)*2),std::exp2(parameter(random)*2),value(random)*2,angle(random),gamut,headroom));}
 auto all=adjust(device,library,input);for(size_t i=0;i<all.size();i++)for(int c=0;c<3;c++)expect(std::isfinite(all[i][c])&&all[i][c]>=-1e-6&&all[i][c]<=input[i].color[2]+1e-5,"all controls remain finite and gamut bounded");
 input.clear();const Pixel weights[2]={{.2126f,.7152f,.0722f,0},{.22897f,.69174f,.07929f,0}};
 for(int p3=0;p3<2;p3++)for(float h:{-180.f,-60.f,0.f,30.f,120.f,180.f})for(float saturation:{0.f,.5f,1.f,2.f}) {
  input.push_back(sample(.8f,.1f,.2f,0,1,1,saturation,h,p3?4:0,2.5f));
  input.push_back(sample(.3f,.3f,.3f,0,1,1,saturation,h,p3?4:0,2.5f));
 }
 auto chroma=adjust(device,library,input);size_t ix=0;for(int p3=0;p3<2;p3++)for(float h:{-180.f,-60.f,0.f,30.f,120.f,180.f})for(float saturation:{0.f,.5f,1.f,2.f})for(int neutral=0;neutral<2;neutral++,ix++) {
  float before=0,after=0;for(int c=0;c<3;c++){before+=input[ix].rgb[c]*weights[p3][c];after+=chroma[ix][c]*weights[p3][c];}
  expect(std::abs(before-after)<2e-6,"hue and saturation preserve actual output-gamut weighted luma");
  if(neutral)expect(std::abs(chroma[ix][0]-.3f)<1e-6&&std::abs(chroma[ix][1]-.3f)<1e-6&&std::abs(chroma[ix][2]-.3f)<1e-6,"hue and saturation preserve neutral gray");
 }
 // Exercise full YUV-to-display fragments; subtitle ordering has its own HDR suite.
 FragmentRenderer renderer(device);
 NSString *begin=@"    if (u.uvals[20] != 0.0 || u.uvals[21] != 1.0 || u.uvals[22] != 1.0";
 NSRange a=[source rangeOfString:begin],z=[source rangeOfString:@"    if ((hasHdr || sdrBoost) && edrOut)" options:0 range:NSMakeRange(a.location,source.length-a.location)];
 expect(a.location!=NSNotFound&&z.location!=NSNotFound,"locate exact production adjustment block");
 NSString *without=[source stringByReplacingCharactersInRange:NSMakeRange(a.location,z.location-a.location) withString:@""];
 auto oldLibrary=[device newLibraryWithSource:without options:nil error:&error];expect(oldLibrary!=nil,"compile control shader without picture controls");
 for(int mode=0;mode<5;mode++){bool dv=mode==3,hdr=mode!=0,edr=mode!=0&&mode!=4;int transfer=mode==2?2:(hdr?1:0);
  for(auto format:{MTLPixelFormatRGBA16Float,MTLPixelFormatRGBA32Float}) {
   auto neutral16=renderer.render(library,dv,transfer,hdr,edr,false,false,false,format),bypass16=renderer.render(oldLibrary,dv,transfer,hdr,edr,false,false,false,format);
   expect(memcmp(neutral16.data(),bypass16.data(),neutral16.size()*sizeof(Pixel))==0,"neutral preserves actual 16/32-bit render target bytes for all playback branches");
  }
  auto neutral=renderer.render(library,dv,transfer,hdr,edr,false),bypass=renderer.render(oldLibrary,dv,transfer,hdr,edr,false);
  expect(memcmp(neutral.data(),bypass.data(),neutral.size()*sizeof(Pixel))==0,"neutral full fragment is byte-identical in SDR/PQ/HLG/Motion-DV/HDR-to-SDR");
  auto bright=renderer.render(library,dv,transfer,hdr,edr,false,false,false,MTLPixelFormatRGBA32Float,.5f,1,1.8f);
  auto lowContrast=renderer.render(library,dv,transfer,hdr,edr,false,false,false,MTLPixelFormatRGBA32Float,0,.5f,1.8f);
  for(auto *image:{&bright,&lowContrast}){auto black=(*image)[4*renderer.width];if(!(black[0]<1.0/4096&&black[1]<1.0/4096&&black[2]<1.0/4096))fprintf(stderr,"mode%d black %.9g %.9g %.9g\n",mode,black[0],black[1],black[2]);expect(black[0]<1.0/4096&&black[1]<1.0/4096&&black[2]<1.0/4096,"full fragment black stays below one quarter of a 10-bit code; no visible gray veil");}
  if(edr){auto white=neutral[4*renderer.width+renderer.width-1],changed=bright[4*renderer.width+renderer.width-1];expect(white[0]>1&&memcmp(white.data(),changed.data(),sizeof(Pixel))==0,"full fragment retains extended HDR highlight values");}
 }
 FragmentRenderer blackRenderer(device);
 for(int plane=0;plane<3;plane++) {
  std::vector<uint16_t> samples(blackRenderer.width*blackRenderer.height,plane==0?64:512);
  [blackRenderer.planes[plane] replaceRegion:MTLRegionMake2D(0,0,blackRenderer.width,blackRenderer.height) mipmapLevel:0 withBytes:samples.data() bytesPerRow:blackRenderer.width*2];
 }
 for(int mode=0;mode<5;mode++) {
  bool dv=mode==3,hdr=mode!=0,edr=mode!=0&&mode!=4;int transfer=mode==2?2:(hdr?1:0);
  auto image=blackRenderer.render(library,dv,transfer,hdr,edr,false,false,false,MTLPixelFormatRGBA32Float,.5f,.5f,1.8f);
  for(auto pixel:image)for(int channel=0;channel<3;channel++)expect(pixel[channel]<1e-6,"constant digital black texture stays black under combined brightness, low contrast and gamma");
 }
 printf("Picture adjustment checks passed (%zu assertions) on %s.\n",assertions,device.name.UTF8String);return 0;
}}
