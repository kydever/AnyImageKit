//
//  CapturePreviewContentView.swift
//  AnyImageKit
//
//  Created by 刘栋 on 2019/12/18.
//  Copyright © 2019-2022 AnyImageKit.org. All rights reserved.
//

import MetalKit
import CoreMedia

final class CapturePreviewContentView: MTKView {
    
    var mirroring = false
    var rotation: Rotation = .rotate0Degrees
    
    private var pixelBuffer: CVPixelBuffer?
    private var textureCache: CVMetalTextureCache?
    private var textureWidth: Int = 0
    private var textureHeight: Int = 0
    private var textureMirroring = false
    private var textureRotation: Rotation = .rotate0Degrees
    private var sampler: MTLSamplerState?
    private var renderPipelineState: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?
    private var vertexCoordBuffer: MTLBuffer?
    private var textCoordBuffer: MTLBuffer?
    private var internalBounds: CGRect = .zero
    private var textureTranform: CGAffineTransform?
    
    init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: device)
        config()
    }
    
    required init(coder: NSCoder) {
        super.init(coder: coder)
        device = MTLCreateSystemDefaultDevice()
        config()
    }
    
    private func config() {
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        configMetal()
        createTextureCache()
    }
    
    private func configMetal() {
        guard let device = device else { return }
        
        do {
            let bundle = BundleHelper.bundle(for: .capture)
            let defaultLibrary = try device.makeDefaultLibrary(bundle: bundle)
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.vertexFunction = defaultLibrary.makeFunction(name: "vertexPassThrough")
            pipelineDescriptor.fragmentFunction = defaultLibrary.makeFunction(name: "fragmentPassThrough")
            
            do {
                renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
                _print("Fail to create preview Metal view pipeline state: \(error)")
            }
        } catch {
            _print("Fail to make default library: \(error)")
        }
        
        // To determine how textures are sampled, create a sampler descriptor to query for a sampler state from the device.
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        
        commandQueue = device.makeCommandQueue()
    }
    
    private func createTextureCache() {
        var newTextureCache: CVMetalTextureCache?
        guard let device = device else { return }
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &newTextureCache)
        if result == kCVReturnSuccess {
            textureCache = newTextureCache
        } else {
            assertionFailure("Fail to allocate Metal texture cache")
        }
    }
}

// MARK: - MTKViewDelegate
extension CapturePreviewContentView: MTKViewDelegate {
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
    
    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let currentRenderPassDescriptor = currentRenderPassDescriptor, let previewPixelBuffer = pixelBuffer else {
            return
        }
        
        pixelBuffer = nil
        
        // Create a Metal texture from the image buffer.
        let width = CVPixelBufferGetWidth(previewPixelBuffer)
        let height = CVPixelBufferGetHeight(previewPixelBuffer)
        
        if textureCache == nil { createTextureCache() }
        guard let textureCache = textureCache else { return }
        
        var cvTextureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               textureCache,
                                                               previewPixelBuffer,
                                                               nil,
                                                               .bgra8Unorm,
                                                               width,
                                                               height,
                                                               0,
                                                               &cvTextureOut)
        guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
            _print("Failed to create Metal preview texture: \(status)")
            CVMetalTextureCacheFlush(textureCache, 0)
            return
        }
        
        if texture.width != textureWidth || texture.height != textureHeight || bounds != internalBounds || mirroring != textureMirroring || rotation != textureRotation {
            setupTransform(width: texture.width, height: texture.height, mirroring: mirroring, rotation: rotation)
        }
        
        // Set up command buffer and encoder
        guard let commandQueue = commandQueue else {
            _print("Failed to create Metal command queue")
            CVMetalTextureCacheFlush(textureCache, 0)
            return
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            _print("Failed to create Metal command buffer")
            CVMetalTextureCacheFlush(textureCache, 0)
            return
        }
        
        guard let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: currentRenderPassDescriptor) else {
            _print("Failed to create Metal command encoder")
            CVMetalTextureCacheFlush(textureCache, 0)
            return
        }
        
        commandEncoder.label = "CapturePreviewContentView Display"
        if let renderPipelineState = renderPipelineState {
            commandEncoder.setRenderPipelineState(renderPipelineState)
        }
        commandEncoder.setVertexBuffer(vertexCoordBuffer, offset: 0, index: 0)
        commandEncoder.setVertexBuffer(textCoordBuffer, offset: 0, index: 1)
        commandEncoder.setFragmentTexture(texture, index: 0)
        commandEncoder.setFragmentSamplerState(sampler, index: 0)
        commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        commandEncoder.endEncoding()
        
        // Draw to the screen.
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - Display
extension CapturePreviewContentView {
    
    func clear() {
        textureCache = nil
    }
    
    func draw(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
        Thread.runOnMain {
            self.setNeedsDisplay()
        }
    }
}

// MARK: - Coordinate
extension CapturePreviewContentView {
    
    private func setupTransform(width: Int, height: Int, mirroring: Bool, rotation: Rotation) {
        var scaleX: Float = 1.0
        var scaleY: Float = 1.0
        var resizeAspect: Float = 1.0
        
        internalBounds = self.bounds
        textureWidth = width
        textureHeight = height
        textureMirroring = mirroring
        textureRotation = rotation
        
        if textureWidth > 0 && textureHeight > 0 {
            switch textureRotation {
            case .rotate0Degrees, .rotate180Degrees:
                scaleX = Float(internalBounds.width / CGFloat(textureWidth))
                scaleY = Float(internalBounds.height / CGFloat(textureHeight))
                
            case .rotate90Degrees, .rotate270Degrees:
                scaleX = Float(internalBounds.width / CGFloat(textureHeight))
                scaleY = Float(internalBounds.height / CGFloat(textureWidth))
            }
        }
        // Resize aspect ratio.
        resizeAspect = min(scaleX, scaleY)
        if scaleX < scaleY {
            scaleY = scaleX / scaleY
            scaleX = 1.0
        } else {
            scaleX = scaleY / scaleX
            scaleY = 1.0
        }
        
        if textureMirroring {
            scaleX *= -1.0
        }
        
        // Vertex coordinate takes the gravity into account.
        let vertexData: [Float] = [
            -scaleX, -scaleY, 0.0, 1.0,
            scaleX, -scaleY, 0.0, 1.0,
            -scaleX, scaleY, 0.0, 1.0,
            scaleX, scaleY, 0.0, 1.0
        ]
        vertexCoordBuffer = device?.makeBuffer(bytes: vertexData, length: vertexData.count * MemoryLayout<Float>.size, options: [])
        
        // Texture coordinate takes the rotation into account.
        var textData: [Float]
        switch textureRotation {
        case .rotate0Degrees:
            textData = [
                0.0, 1.0,
                1.0, 1.0,
                0.0, 0.0,
                1.0, 0.0
            ]
            
        case .rotate180Degrees:
            textData = [
                1.0, 0.0,
                0.0, 0.0,
                1.0, 1.0,
                0.0, 1.0
            ]
            
        case .rotate90Degrees:
            textData = [
                1.0, 1.0,
                1.0, 0.0,
                0.0, 1.0,
                0.0, 0.0
            ]
            
        case .rotate270Degrees:
            textData = [
                0.0, 0.0,
                0.0, 1.0,
                1.0, 0.0,
                1.0, 1.0
            ]
        }
        textCoordBuffer = device?.makeBuffer(bytes: textData, length: textData.count * MemoryLayout<Float>.size, options: [])
        
        // Calculate the transform from texture coordinates to view coordinates
        var transform = CGAffineTransform.identity
        if textureMirroring {
            transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1))
            transform = transform.concatenating(CGAffineTransform(translationX: CGFloat(textureWidth), y: 0))
        }
        
        switch textureRotation {
        case .rotate0Degrees:
            transform = transform.concatenating(CGAffineTransform(rotationAngle: CGFloat(0)))
            
        case .rotate180Degrees:
            transform = transform.concatenating(CGAffineTransform(rotationAngle: .pi))
            transform = transform.concatenating(CGAffineTransform(translationX: CGFloat(textureWidth), y: CGFloat(textureHeight)))
            
        case .rotate90Degrees:
            transform = transform.concatenating(CGAffineTransform(rotationAngle: .pi / 2))
            transform = transform.concatenating(CGAffineTransform(translationX: CGFloat(textureHeight), y: 0))
            
        case .rotate270Degrees:
            transform = transform.concatenating(CGAffineTransform(rotationAngle: 3 * .pi / 2))
            transform = transform.concatenating(CGAffineTransform(translationX: 0, y: CGFloat(textureWidth)))
        }
        
        transform = transform.concatenating(CGAffineTransform(scaleX: CGFloat(resizeAspect), y: CGFloat(resizeAspect)))
        let tranformRect = CGRect(origin: .zero, size: CGSize(width: textureWidth, height: textureHeight)).applying(transform)
        let xShift = (internalBounds.size.width - tranformRect.size.width) / 2
        let yShift = (internalBounds.size.height - tranformRect.size.height) / 2
        
        transform = transform.concatenating(CGAffineTransform(translationX: xShift, y: yShift))
        textureTranform = transform.inverted()
    }
    
    func texturePoint(for viewPoint: CGPoint) -> CGPoint? {
        var result: CGPoint?
        guard let transform = textureTranform else {
            return nil
        }
        let transformPoint = viewPoint.applying(transform)
        
        if CGRect(origin: .zero, size: CGSize(width: textureWidth, height: textureHeight)).contains(transformPoint) {
            result = transformPoint
        } else {
            _print("Invalid point \(viewPoint) result point \(transformPoint)")
        }
        
        return result
    }
    
    func viewPoint(for texturePoint: CGPoint) -> CGPoint? {
        var result: CGPoint?
        guard let transform = textureTranform?.inverted() else {
            return nil
        }
        let transformPoint = texturePoint.applying(transform)
        
        if internalBounds.contains(transformPoint) {
            result = transformPoint
        } else {
            _print("Invalid point \(texturePoint) result point \(transformPoint)")
        }
        
        return result
    }
}

extension CapturePreviewContentView {
    
    enum Rotation: Int {
        case rotate0Degrees
        case rotate90Degrees
        case rotate180Degrees
        case rotate270Degrees
    }
}
