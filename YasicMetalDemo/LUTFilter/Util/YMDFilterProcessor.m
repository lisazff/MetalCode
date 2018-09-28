//
//  YMDFilterProcessor.m
//  YasicMetalDemo
//
//  Created by yasic on 2018/9/27.
//  Copyright © 2018年 yasic. All rights reserved.
//

#import "YMDFilterProcessor.h"
#import <MetalKit/MTKTextureLoader.h>

static const float vertexArrayData[] = {
    -1.0, -1.0, 0.0, 1.0, 0, 1,
    -1.0, 1.0, 0.0, 1.0, 0, 0,
    1.0, -1.0, 0.0, 1.0, 1, 1,
    -1.0, 1.0, 0.0, 1.0, 0, 0,
    1.0, 1.0, 0.0, 1.0, 1, 0,
    1.0, -1.0, 0.0, 1.0, 1, 1
};

@interface YMDFilterProcessor()

@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) id<MTLBuffer> vertexBuffer; // 顶点缓存
@property (nonatomic, strong) id <MTLRenderPipelineState> pipelineState; // 渲染管道状态描述位
@property (nonatomic, strong) id <MTLCommandQueue> commandQueue;

@property (nonatomic, strong) id<MTLTexture> lutTexture;
@property (nonatomic, strong) id<MTLTexture> originalTexture;
@property (nonatomic, strong) dispatch_semaphore_t renderSemaphore;

@end

@implementation YMDFilterProcessor

- (instancetype)init
{
    self = [super init];
    if (self){
        self.mtlDevice = MTLCreateSystemDefaultDevice(); // 获取 GPU 接口
        self.vertexBuffer = [self.mtlDevice newBufferWithBytes:vertexArrayData length:sizeof(vertexArrayData) options:0]; // 利用数组初始化一个顶点缓存，MTLResourceStorageModeShared 资源存储在CPU和GPU都可访问的系统存储器中
        
        id<MTLLibrary> library = [self.mtlDevice newDefaultLibraryWithBundle:[NSBundle mainBundle] error:nil];
        id<MTLFunction> vertextFunc = [library newFunctionWithName:@"vertex_func"];
        id<MTLFunction> fragFunc = [library newFunctionWithName:@"fragment_func"]; //从 bundle 中获取顶点着色器和片段着色器
        
        MTLRenderPipelineDescriptor *pipelineDescriptor = [MTLRenderPipelineDescriptor new];
        pipelineDescriptor.vertexFunction = vertextFunc;
        pipelineDescriptor.fragmentFunction = fragFunc;
        pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; //此设置配置像素格式，以便通过渲染管线的所有内容都符合相同的颜色分量顺序（在本例中为Blue(蓝色)，Green(绿色)，Red(红色)，Alpha(阿尔法)）以及尺寸（在这种情况下，8-bit(8位)颜色值变为 从0到255）
        self.pipelineState = [self.mtlDevice newRenderPipelineStateWithDescriptor:pipelineDescriptor error:nil]; // 初始化一个渲染管线状态描述位，相当于 CPU 和 GPU 之间建立的管道
        
        self.commandQueue = [self.mtlDevice newCommandQueue]; // 获取一个渲染队列，其中装载需要渲染的指令 MTLCommandBuffer
        
        self.renderSemaphore = dispatch_semaphore_create(1);
    }
    return self;
}

- (void)renderImage
{
    dispatch_semaphore_wait(self.renderSemaphore, DISPATCH_TIME_FOREVER);
    id<CAMetalDrawable> drawable = [(CAMetalLayer*)[self.mtlView layer] nextDrawable]; // 获取下一个可用的内容区缓存，用于绘制内容
    if (!drawable) {
        dispatch_semaphore_signal(self.renderSemaphore);
        return;
    }
    MTLRenderPassDescriptor *renderPassDescriptor = [self.mtlView currentRenderPassDescriptor]; // 获取当前的渲染描述符
    if (!renderPassDescriptor) {
        dispatch_semaphore_signal(self.renderSemaphore);
        return;
    }
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.5, 0.5, 0.5, 1.0); // 设置颜色附件的清除颜色
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear; // 用于避免渲染新的帧时附带上旧的内容
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer]; // 获取一个可用的命令 buffer
    id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor]; // 通过渲染描述符构建 encoder
    [commandEncoder setCullMode:MTLCullModeBack]; // 设置剔除背面
    [commandEncoder setFrontFacingWinding:MTLWindingClockwise]; // 设定按顺时针顺序绘制顶点的图元是朝前的
    [commandEncoder setViewport:(MTLViewport){0.0, 0.0, self.mtlView.drawableSize.width, self.mtlView.drawableSize.height, -1.0, 1.0 }]; // 设置可视区域
    [commandEncoder setRenderPipelineState:self.pipelineState];// 设置渲染管线状态位
    [commandEncoder setVertexBuffer:self.vertexBuffer offset:0 atIndex:0]; // 设置顶点buffer
    [commandEncoder setFragmentTexture:self.originalTexture atIndex:0]; // 设置纹理 0，即原图
    [commandEncoder setFragmentTexture:self.lutTexture atIndex:1]; // 设置纹理 1，即 LUT 图
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; // 绘制三角形图元
    [commandEncoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    dispatch_semaphore_signal(self.renderSemaphore);
}

- (void)loadLUTImage:(UIImage *)lutImage
{
    MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:self.mtlDevice];
    NSError* err;
    unsigned char *imageBytes = [self bitmapFromImage:lutImage];
    NSData *imageData = [self imageDataFromBitmap:imageBytes imageSize:CGSizeMake(CGImageGetWidth(lutImage.CGImage), CGImageGetHeight(lutImage.CGImage))];
    free(imageBytes);
    self.lutTexture = [loader newTextureWithData:imageData options:@{MTKTextureLoaderOptionSRGB:@(NO)} error:&err]; // 生成 LUT 滤镜纹理
}

- (void)loadOriginalImage:(UIImage *)originalImage
{
    unsigned char *imageBytes = [self bitmapFromImage:originalImage];
    NSData *imageData = [self imageDataFromBitmap:imageBytes imageSize:CGSizeMake(CGImageGetWidth(originalImage.CGImage), CGImageGetHeight(originalImage.CGImage))];
    free(imageBytes);
    MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:self.mtlDevice];
    NSError* err;
    self.originalTexture = [loader newTextureWithData:imageData options:@{MTKTextureLoaderOptionSRGB:@(NO)} error:&err];
}

- (unsigned char *)bitmapFromImage:(UIImage *)targetImage
{
    CGImageRef imageRef = targetImage.CGImage;
    
    NSUInteger iWidth = CGImageGetWidth(imageRef);
    NSUInteger iHeight = CGImageGetHeight(imageRef);
    NSUInteger iBytesPerPixel = 4;
    NSUInteger iBytesPerRow = iBytesPerPixel * iWidth;
    NSUInteger iBitsPerComponent = 8;
    unsigned char *imageBytes = malloc(iWidth * iHeight * iBytesPerPixel);
    
    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    
    CGContextRef context = CGBitmapContextCreate(imageBytes,
                                                 iWidth,
                                                 iHeight,
                                                 iBitsPerComponent,
                                                 iBytesPerRow,
                                                 colorspace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst); // 转 BGRA 格式
    
    CGRect rect = CGRectMake(0, 0, iWidth, iHeight);
    CGContextDrawImage(context, rect, imageRef);
    CGColorSpaceRelease(colorspace);
    CGContextRelease(context);
    return imageBytes;
}

- (NSData *)imageDataFromBitmap:(unsigned char *)imageBytes imageSize:(CGSize)imageSize
{
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(imageBytes,
                                                 imageSize.width,
                                                 imageSize.height,
                                                 8,
                                                 imageSize.width * 4,
                                                 colorSpace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef imageRef = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    UIImage *result = [UIImage imageWithCGImage:imageRef];
    NSData *imageData = UIImagePNGRepresentation(result);
    CGImageRelease(imageRef);
    return imageData;
}

@end