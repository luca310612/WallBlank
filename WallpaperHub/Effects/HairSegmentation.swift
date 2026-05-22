import Foundation
import Vision
import AppKit
import CoreImage

/// 髪検出結果
struct HairSegmentationResult {
    let maskData: MaskData
    let confidence: Float
    let processingTime: TimeInterval
}

/// 髪セグメンテーションエラー
enum HairSegmentationError: Error, LocalizedError {
    case imageLoadFailed
    case segmentationFailed(String)
    case noPersonDetected
    case maskGenerationFailed

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed:
            return "画像の読み込みに失敗しました"
        case .segmentationFailed(let message):
            return "セグメンテーションに失敗しました: \(message)"
        case .noPersonDetected:
            return "人物が検出されませんでした"
        case .maskGenerationFailed:
            return "マスクの生成に失敗しました"
        }
    }
}

/// Vision + CoreMLを使用した髪検出クラス
class HairSegmentation {

    static let shared = HairSegmentation()

    private init() {}

    // MARK: - Public Methods

    /// 画像から髪領域を検出してマスクを生成
    /// - Parameters:
    ///   - image: 入力画像
    ///   - completion: 完了コールバック
    func detectHair(from image: NSImage, completion: @escaping (Result<HairSegmentationResult, HairSegmentationError>) -> Void) {
        let startTime = CACurrentMediaTime()

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion(.failure(.imageLoadFailed))
            return
        }

        // 人物セグメンテーションリクエストを作成
        let request = VNGeneratePersonSegmentationRequest { [weak self] request, error in
            if let error = error {
                completion(.failure(.segmentationFailed(error.localizedDescription)))
                return
            }

            guard let observation = request.results?.first as? VNPixelBufferObservation else {
                completion(.failure(.noPersonDetected))
                return
            }

            // 人物マスクから髪領域を抽出（顔検出に元画像も渡す）
            self?.extractHairRegion(from: observation.pixelBuffer,
                                    imageWidth: cgImage.width,
                                    imageHeight: cgImage.height,
                                    cgImage: cgImage,
                                    startTime: startTime,
                                    completion: completion)
        }

        // 高品質モードを設定
        request.qualityLevel = .accurate

        // リクエストを実行
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.segmentationFailed(error.localizedDescription)))
                }
            }
        }
    }

    /// URLから画像を読み込んで髪領域を検出
    func detectHair(from url: URL, completion: @escaping (Result<HairSegmentationResult, HairSegmentationError>) -> Void) {
        guard let image = NSImage(contentsOf: url) else {
            completion(.failure(.imageLoadFailed))
            return
        }
        detectHair(from: image, completion: completion)
    }

    // MARK: - Private Methods

    /// 人物マスクから髪領域を抽出
    private func extractHairRegion(from pixelBuffer: CVPixelBuffer,
                                   imageWidth: Int,
                                   imageHeight: Int,
                                   cgImage: CGImage? = nil,
                                   startTime: CFTimeInterval,
                                   completion: @escaping (Result<HairSegmentationResult, HairSegmentationError>) -> Void) {

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let maskWidth = CVPixelBufferGetWidth(pixelBuffer)
        let maskHeight = CVPixelBufferGetHeight(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            DispatchQueue.main.async {
                completion(.failure(.maskGenerationFailed))
            }
            return
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // 人物マスクを読み取り
        var personMask = [Float](repeating: 0, count: maskWidth * maskHeight)

        for y in 0..<maskHeight {
            for x in 0..<maskWidth {
                let offset = y * bytesPerRow + x
                let value = baseAddress.load(fromByteOffset: offset, as: UInt8.self)
                personMask[y * maskWidth + x] = Float(value) / 255.0
            }
        }

        // 顔検出を試みて髪領域の推定精度を向上
        var faceObservation: VNFaceObservation?
        if let cgImage = cgImage {
            let faceRequest = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([faceRequest])
            } catch {
                print("[HairSegmentation] Face detection failed (non-critical): \(error)")
            }
            faceObservation = faceRequest.results?.first
        }

        // 髪領域を抽出（顔検出結果を利用して精度向上）
        let hairMask = extractHairFromPersonMask(personMask: personMask,
                                                  width: maskWidth,
                                                  height: maskHeight,
                                                  faceObservation: faceObservation)

        // 出力サイズにリサンプリング
        let outputMask = resampleMask(hairMask,
                                      fromWidth: maskWidth,
                                      fromHeight: maskHeight,
                                      toWidth: imageWidth,
                                      toHeight: imageHeight)

        // MaskDataに変換
        let maskData = MaskData(width: imageWidth, height: imageHeight)
        for i in 0..<outputMask.count {
            maskData.data[i] = UInt8(min(255, max(0, outputMask[i] * 255)))
        }

        // エッジを滑らかにする
        maskData.applyGaussianBlur(radius: 5)

        let processingTime = CACurrentMediaTime() - startTime

        // 信頼度を計算（マスクの平均値）
        let confidence = outputMask.reduce(0, +) / Float(outputMask.count)

        DispatchQueue.main.async {
            let result = HairSegmentationResult(
                maskData: maskData,
                confidence: confidence,
                processingTime: processingTime
            )
            completion(.success(result))
        }
    }

    /// 人物マスクから髪領域を抽出
    /// faceObservation が提供された場合は顔の位置に基づいて髪領域を特定
    private func extractHairFromPersonMask(personMask: [Float], width: Int, height: Int,
                                            faceObservation: VNFaceObservation? = nil) -> [Float] {
        var hairMask = [Float](repeating: 0, count: width * height)

        // 人物の上部境界を検出
        var topBoundary = height
        for y in 0..<height {
            for x in 0..<width {
                if personMask[y * width + x] > 0.5 {
                    topBoundary = min(topBoundary, y)
                    break
                }
            }
        }

        // 人物の高さを計算
        var bottomBoundary = 0
        for y in (0..<height).reversed() {
            for x in 0..<width {
                if personMask[y * width + x] > 0.5 {
                    bottomBoundary = max(bottomBoundary, y)
                    break
                }
            }
        }

        let personHeight = bottomBoundary - topBoundary
        guard personHeight > 0 else { return hairMask }

        // 髪領域の下端を決定
        let hairRegionEnd: Int
        let faceCenterX: Float
        let faceWidth: Float

        if let face = faceObservation {
            // 顔検出が利用可能な場合、顔の上端を髪の下端とする
            // Vision座標系は左下原点なので変換が必要
            let faceTopY = Int(Float(height) * (1.0 - Float(face.boundingBox.maxY)))
            let faceBottomY = Int(Float(height) * (1.0 - Float(face.boundingBox.minY)))
            // 髪は頭頂部から顔の上端 + 少し余裕
            let faceHeight = faceBottomY - faceTopY
            hairRegionEnd = faceTopY + Int(Float(faceHeight) * 0.3)
            faceCenterX = Float(face.boundingBox.midX) * Float(width)
            faceWidth = Float(face.boundingBox.width) * Float(width)
        } else {
            // フォールバック: 上部25%を髪領域と推定
            hairRegionEnd = topBoundary + Int(Float(personHeight) * 0.25)
            faceCenterX = Float(width) / 2.0
            faceWidth = Float(width) * 0.4
        }

        let halfFaceWidth = faceWidth / 2.0

        for y in 0..<height {
            for x in 0..<width {
                let personValue = personMask[y * width + x]

                if personValue > 0.3 && y >= topBoundary && y <= hairRegionEnd {
                    // 上から下へのグラデーション（上が強く、下が弱い）
                    let hairRegionHeight = max(1, hairRegionEnd - topBoundary)
                    let normalizedY = Float(y - topBoundary) / Float(hairRegionHeight)
                    let gradient = 1.0 - pow(normalizedY, 0.7)

                    // 顔の中心からの距離に基づく横方向ウェイト
                    let distFromFaceCenter = abs(Float(x) - faceCenterX)
                    let normalizedDist = min(distFromFaceCenter / max(halfFaceWidth * 1.5, 1.0), 1.0)
                    let horizontalWeight = 1.0 - pow(normalizedDist, 2.0) * 0.3

                    hairMask[y * width + x] = personValue * gradient * horizontalWeight
                }
            }
        }

        return hairMask
    }

    /// マスクをリサンプリング
    private func resampleMask(_ mask: [Float],
                              fromWidth: Int, fromHeight: Int,
                              toWidth: Int, toHeight: Int) -> [Float] {
        var result = [Float](repeating: 0, count: toWidth * toHeight)

        let scaleX = Float(fromWidth) / Float(toWidth)
        let scaleY = Float(fromHeight) / Float(toHeight)

        for y in 0..<toHeight {
            for x in 0..<toWidth {
                let srcX = Float(x) * scaleX
                let srcY = Float(y) * scaleY

                // バイリニア補間
                let x0 = Int(srcX)
                let y0 = Int(srcY)
                let x1 = min(x0 + 1, fromWidth - 1)
                let y1 = min(y0 + 1, fromHeight - 1)

                let fx = srcX - Float(x0)
                let fy = srcY - Float(y0)

                let v00 = mask[y0 * fromWidth + x0]
                let v10 = mask[y0 * fromWidth + x1]
                let v01 = mask[y1 * fromWidth + x0]
                let v11 = mask[y1 * fromWidth + x1]

                let value = v00 * (1 - fx) * (1 - fy) +
                            v10 * fx * (1 - fy) +
                            v01 * (1 - fx) * fy +
                            v11 * fx * fy

                result[y * toWidth + x] = value
            }
        }

        return result
    }
}
