import AVFoundation
import CoreImage
import CoreMotion
import CoreVideo
import Darwin
import Foundation
import QuartzCore
import simd
import UIKit

enum SlamRecordingError: LocalizedError {
  case simulatorNotSupported
  case cameraPermissionDenied
  case captureSetupFailed
  case writerSetupFailed(String)
  case alreadyRecording

  static func wrapWriterError(_ error: Error?) -> SlamRecordingError {
    guard let nsError = error as NSError? else {
      return .writerSetupFailed("unknown")
    }
    var details: [String] = [
      "domain=\(nsError.domain)",
      "code=\(nsError.code)",
      "desc=\(nsError.localizedDescription)",
    ]
    if let reason = nsError.localizedFailureReason, !reason.isEmpty {
      details.append("reason=\(reason)")
    }
    if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
      details.append("suggestion=\(suggestion)")
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
      details.append("underlyingDomain=\(underlying.domain)")
      details.append("underlyingCode=\(underlying.code)")
      details.append("underlyingDesc=\(underlying.localizedDescription)")
    }
    return .writerSetupFailed(details.joined(separator: " "))
  }

  static func isTransientFinalizeError(_ error: Error?) -> Bool {
    guard let nsError = error as NSError? else { return false }
    guard nsError.domain == AVFoundationErrorDomain, nsError.code == -11800 else {
      return false
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
      return underlying.domain == NSOSStatusErrorDomain && underlying.code == -12780
    }
    return false
  }

  var errorDescription: String? {
    switch self {
    case .simulatorNotSupported:
      return "SLAM 采集需要真机（相机与 IMU）。"
    case .cameraPermissionDenied:
      return "未授予相机权限。"
    case .captureSetupFailed:
      return "无法配置相机采集。"
    case .writerSetupFailed(let message):
      return "视频写入失败: \(message)"
    case .alreadyRecording:
      return "已在录制中。"
    }
  }
}

// MARK: - JSONL

private enum JsonlLineKind: Int {
  case gyroscope = 0
  case accelerometer = 1
  case magnetometer = 2
  case imuTemperature = 3
  case frame = 4
}

private struct PendingJsonlLine {
  let time: Double
  let kind: JsonlLineKind
  let object: [String: Any]
}

/// 采集模式：LiDAR 深度 + 广角 RGB（样例风格第二路 gray+depthScale）、或 MultiCam 广角+超广角双 RGB、或单广角。
private enum DualCaptureMode {
  /// `data.mov` 广角 RGB + `frames2/*.png` 深度图转灰度（`colorFormat: gray`、`depthScale`）
  case depthAndWide
  /// `data.mov` 广角 + `frames2/*.png` 超广角 RGB（无 LiDAR 时回退）
  case multiCamRgb
  /// 仅广角（配置失败时）
  case singleWide
}

/// Spectacular 风格：`data.mov` + 必需 `frames2/*.png`，JSONL 双 `frames`；IMU 与 P1 行为保留。
final class SlamRecordingSession: NSObject, AVCaptureDataOutputSynchronizerDelegate,
  AVCaptureVideoDataOutputSampleBufferDelegate
{
  let outputDirectory: URL

  var currentCaptureSession: AVCaptureSession? {
    captureSession
  }

  private let syncQueue = DispatchQueue(label: "com.binwu.reconstruction.spatial_data_recorder.recording")
  private let videoQueue = DispatchQueue(label: "com.binwu.reconstruction.spatial_data_recorder.video")
  private let motionQueue = OperationQueue()
  private let magnetometerQueue = OperationQueue()
  private let ciContext = CIContext(options: nil)

  private var captureSession: AVCaptureSession?
  private var captureDevice: AVCaptureDevice?
  private var secondCaptureDevice: AVCaptureDevice?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var depthOutput: AVCaptureDepthDataOutput?
  private var secondVideoOutput: AVCaptureVideoDataOutput?
  private var dataOutputSynchronizer: AVCaptureDataOutputSynchronizer?

  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var assetWriter2: AVAssetWriter?
  private var videoInput2: AVAssetWriterInput?

  private var pendingJsonl: [PendingJsonlLine] = []

  private let motionManager = CMMotionManager()

  private var captureMode: DualCaptureMode = .singleWide
  private var shouldExportFrames2PngSequence = false

  private var timeOriginMedia: CFTimeInterval = 0
  private var firstVideoPts: CMTime?
  private var frameIndex: Int = 0
  private var videoWidth: Int = 0
  private var videoHeight: Int = 0
  private var videoWidth2: Int = 0
  private var videoHeight2: Int = 0

  private var lockedExposureDurationSeconds: Double = 0.01

  private var lastFocalLengthX: Double = 0
  private var lastFocalLengthY: Double = 0
  private var lastPrincipalPointX: Double = 0
  private var lastPrincipalPointY: Double = 0
  private var didUpdateIntrinsicsFromSample = false

  private var lastSecondFocalLengthX: Double = 0
  private var lastSecondFocalLengthY: Double = 0
  private var lastSecondPrincipalPointX: Double = 0
  private var lastSecondPrincipalPointY: Double = 0
  private var didUpdateSecondIntrinsics = false
  private var lastDepthToWideExtrinsic: [[Double]]?

  private var lastPrimaryImuToCameraSource = "capture_convention_back_camera_axes"
  private var lastSecondaryImuToCameraSource = "not_applicable_single_camera"

  /// MultiCam：待配对的超广角缓冲
  private var ultraBufferQueue: [CMSampleBuffer] = []
  private var pendingWideBuffers: [CMSampleBuffer] = []

  private var isStopping = false
  private var didStartWriter = false
  private var lastPrimaryWrittenPts: CMTime?
  private var lastSecondaryWrittenPts: CMTime?

  /// 样例与 Spectacular 常用：米/灰度量化（仅作语义对齐；实际深度以 Float 录制为准）
  private let jsonDepthScale: Double = 0.001
  private static let depthVisualizationNearMeters: Float = 0.2
  private static let depthVisualizationFarMeters: Float = 5.0

  private var frames2DirectoryURL: URL {
    outputDirectory.appendingPathComponent("frames2", isDirectory: true)
  }

  init(outputDirectory: URL) {
    self.outputDirectory = outputDirectory
    motionQueue.name = "com.binwu.reconstruction.spatial_data_recorder.motion"
    motionQueue.maxConcurrentOperationCount = 1
    magnetometerQueue.name = "com.binwu.reconstruction.spatial_data_recorder.magnetometer"
    magnetometerQueue.maxConcurrentOperationCount = 1
  }

  func start(completion: @escaping (Error?) -> Void) {
    #if targetEnvironment(simulator)
    completion(SlamRecordingError.simulatorNotSupported)
    return
    #endif

    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      guard let self = self else { return }
      if !granted {
        DispatchQueue.main.async {
          completion(SlamRecordingError.cameraPermissionDenied)
        }
        return
      }
      self.syncQueue.async {
        self.configureCaptureAndRun(completion: completion)
      }
    }
  }

  // MARK: - Session setup

  private func configureCaptureAndRun(completion: @escaping (Error?) -> Void) {
    isStopping = false
    didStartWriter = false
    firstVideoPts = nil
    frameIndex = 0
    timeOriginMedia = 0
    assetWriter = nil
    videoInput = nil
    assetWriter2 = nil
    videoInput2 = nil
    pendingJsonl.removeAll(keepingCapacity: true)

    if configureDepthAndWideSession() {
      captureMode = .depthAndWide
    } else if configureMultiCamSession() {
      captureMode = .multiCamRgb
    } else if configureSingleWideSession() {
      captureMode = .singleWide
    } else {
      DispatchQueue.main.async { completion(SlamRecordingError.captureSetupFailed) }
      return
    }

    // Keep frames2/*.png in all dual-stream modes so uploaded session layout
    // stays aligned with the sample structure.
    shouldExportFrames2PngSequence = captureMode != .singleWide
    lastDepthToWideExtrinsic = nil
    lastPrimaryImuToCameraSource = "capture_convention_back_camera_axes"
    lastSecondaryImuToCameraSource = "not_applicable_single_camera"
    lastPrimaryWrittenPts = nil
    lastSecondaryWrittenPts = nil
    prepareFrames2DirectoryIfNeeded()

    captureSession?.startRunning()

    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        completion(nil)
        return
      }
      UIApplication.shared.isIdleTimerDisabled = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.applyFocusExposureLockIfPossible()
      }
      completion(nil)
    }
  }

  /// LiDAR：同步广角 RGB + 深度图（优先，与样例第二路 gray + depthScale 一致）
  private func configureDepthAndWideSession() -> Bool {
    guard let selected = Self.pickDepthDeviceAndFormats() else { return false }
    let device = selected.device
    let format = selected.videoFormat
    let depthFormat = selected.depthFormat

    let session = AVCaptureSession()
    session.beginConfiguration()
    session.sessionPreset = .inputPriority

    do {
      try device.lockForConfiguration()
      device.activeFormat = format
      if let depthFormat {
        device.activeDepthDataFormat = depthFormat
      }
      Self.disableHdrIfPossible(device: device)
      device.unlockForConfiguration()
    } catch {
      session.commitConfiguration()
      return false
    }

    guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
      session.commitConfiguration()
      return false
    }
    session.addInput(input)

    let vOut = AVCaptureVideoDataOutput()
    vOut.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]
    vOut.alwaysDiscardsLateVideoFrames = true

    let dOut = AVCaptureDepthDataOutput()
    dOut.isFilteringEnabled = false
    dOut.alwaysDiscardsLateDepthData = true

    guard session.canAddOutput(vOut), session.canAddOutput(dOut) else {
      session.commitConfiguration()
      return false
    }
    session.addOutput(vOut)
    session.addOutput(dOut)

    if let conn = vOut.connection(with: .video), conn.isCameraIntrinsicMatrixDeliverySupported {
      conn.isCameraIntrinsicMatrixDeliveryEnabled = true
    }

    session.commitConfiguration()

    let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [vOut, dOut])
    sync.setDelegate(self, queue: videoQueue)

    captureSession = session
    captureDevice = device
    videoOutput = vOut
    depthOutput = dOut
    secondCaptureDevice = nil
    secondVideoOutput = nil
    dataOutputSynchronizer = sync
    return true
  }

  private static func pickFormatWithDepth(device: AVCaptureDevice) -> AVCaptureDevice.Format? {
    var best: AVCaptureDevice.Format?
    var bestScore = Int64.min

    for format in device.formats {
      if format.supportedDepthDataFormats.isEmpty { continue }

      let dim = format.formatDescription.dimensions
      let area = Int64(dim.width) * Int64(dim.height)
      let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)

      // Prefer standard 8-bit YUV (SDR-friendly) to avoid washed-looking video.
      let colorScore: Int64
      switch subtype {
      case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        colorScore = 3
      case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        colorScore = 2
      default:
        colorScore = 0
      }

      let hdrPenalty: Int64 = format.isVideoHDRSupported ? -1 : 0
      let score = colorScore * 1_000_000_000 + area * 1_000 + hdrPenalty

      if score > bestScore {
        bestScore = score
        best = format
      }
    }
    return best
  }

  private static func pickDepthDataFormat(for videoFormat: AVCaptureDevice.Format) -> AVCaptureDevice.Format? {
    var best: AVCaptureDevice.Format?
    var bestScore = Int64.min

    for depthFormat in videoFormat.supportedDepthDataFormats {
      let depthDesc = depthFormat.formatDescription
      let dim = depthDesc.dimensions
      let area = Int64(dim.width) * Int64(dim.height)
      let subtype = CMFormatDescriptionGetMediaSubType(depthDesc)

      let precisionScore: Int64
      switch subtype {
      case kCVPixelFormatType_DepthFloat32:
        precisionScore = 4
      case kCVPixelFormatType_DepthFloat16:
        precisionScore = 3
      case kCVPixelFormatType_DisparityFloat32:
        precisionScore = 2
      case kCVPixelFormatType_DisparityFloat16:
        precisionScore = 1
      default:
        precisionScore = 0
      }

      let score = precisionScore * 1_000_000 + area
      if score > bestScore {
        bestScore = score
        best = depthFormat
      }
    }

    return best
  }

  private static func pickDepthDeviceAndFormats() -> (
    device: AVCaptureDevice,
    videoFormat: AVCaptureDevice.Format,
    depthFormat: AVCaptureDevice.Format?
  )? {
    var preferredTypes: [AVCaptureDevice.DeviceType] = []
    if #available(iOS 15.4, *) {
      preferredTypes.append(.builtInLiDARDepthCamera)
    }
    preferredTypes.append(contentsOf: [
      .builtInTripleCamera,
      .builtInDualWideCamera,
      .builtInDualCamera,
      .builtInWideAngleCamera,
    ])

    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: preferredTypes,
      mediaType: .video,
      position: .back
    )

    for type in preferredTypes {
      guard let device = discovery.devices.first(where: { $0.deviceType == type }) else {
        continue
      }
      guard let videoFormat = pickFormatWithDepth(device: device) else {
        continue
      }
      let depthFormat = pickDepthDataFormat(for: videoFormat)
      return (device, videoFormat, depthFormat)
    }

    return nil
  }

  private static func disableHdrIfPossible(device: AVCaptureDevice) {
    device.automaticallyAdjustsVideoHDREnabled = false
    if device.isVideoHDREnabled {
      device.isVideoHDREnabled = false
    }
  }

  /// 双路 RGB：广角 + 超广角（无 LiDAR 深度时）
  private func configureMultiCamSession() -> Bool {
    guard
      let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
      let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
    else {
      return false
    }
    guard AVCaptureMultiCamSession.isMultiCamSupported else { return false }

    do {
      try wide.lockForConfiguration()
      Self.disableHdrIfPossible(device: wide)
      wide.unlockForConfiguration()
    } catch {
      return false
    }

    do {
      try ultra.lockForConfiguration()
      Self.disableHdrIfPossible(device: ultra)
      ultra.unlockForConfiguration()
    } catch {
      return false
    }

    let session = AVCaptureMultiCamSession()
    session.beginConfiguration()

    guard
      let inWide = try? AVCaptureDeviceInput(device: wide),
      let inUltra = try? AVCaptureDeviceInput(device: ultra),
      session.canAddInput(inWide),
      session.canAddInput(inUltra)
    else {
      session.commitConfiguration()
      return false
    }
    session.addInput(inWide)
    session.addInput(inUltra)

    let outWide = AVCaptureVideoDataOutput()
    outWide.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]
    outWide.alwaysDiscardsLateVideoFrames = true
    outWide.setSampleBufferDelegate(self, queue: videoQueue)

    let outUltra = AVCaptureVideoDataOutput()
    outUltra.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]
    outUltra.alwaysDiscardsLateVideoFrames = true
    outUltra.setSampleBufferDelegate(self, queue: videoQueue)

    guard session.canAddOutput(outWide), session.canAddOutput(outUltra) else {
      session.commitConfiguration()
      return false
    }
    session.addOutput(outWide)
    session.addOutput(outUltra)

    if let conn = outWide.connection(with: .video), conn.isCameraIntrinsicMatrixDeliverySupported {
      conn.isCameraIntrinsicMatrixDeliveryEnabled = true
    }
    if let conn = outUltra.connection(with: .video), conn.isCameraIntrinsicMatrixDeliverySupported {
      conn.isCameraIntrinsicMatrixDeliveryEnabled = true
    }

    session.commitConfiguration()

    captureSession = session
    captureDevice = wide
    secondCaptureDevice = ultra
    videoOutput = outWide
    secondVideoOutput = outUltra
    depthOutput = nil
    dataOutputSynchronizer = nil
    return true
  }

  private func configureSingleWideSession() -> Bool {
    let session = AVCaptureSession()
    session.sessionPreset = .high

    guard
      let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    else {
      return false
    }

    do {
      try device.lockForConfiguration()
      Self.disableHdrIfPossible(device: device)
      device.unlockForConfiguration()
    } catch {
      return false
    }

    guard
      let input = try? AVCaptureDeviceInput(device: device),
      session.canAddInput(input)
    else {
      return false
    }
    session.addInput(input)

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: videoQueue)

    guard session.canAddOutput(output) else { return false }
    session.addOutput(output)

    if let conn = output.connection(with: .video), conn.isCameraIntrinsicMatrixDeliverySupported {
      conn.isCameraIntrinsicMatrixDeliveryEnabled = true
    }

    captureSession = session
    captureDevice = device
    videoOutput = output
    secondVideoOutput = nil
    depthOutput = nil
    dataOutputSynchronizer = nil
    return true
  }

  private func prepareFrames2DirectoryIfNeeded() {
    let fm = FileManager.default
    if shouldExportFrames2PngSequence {
      try? fm.removeItem(at: frames2DirectoryURL)
      try? fm.createDirectory(at: frames2DirectoryURL, withIntermediateDirectories: true)
    } else {
      try? fm.removeItem(at: frames2DirectoryURL)
    }
  }

  // MARK: - AVCaptureDataOutputSynchronizerDelegate（深度 + 广角）

  func dataOutputSynchronizer(
    _ synchronizer: AVCaptureDataOutputSynchronizer,
    didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
  ) {
    syncQueue.async { [weak self] in
      self?.processSynchronizedDepthWide(synchronizedDataCollection)
    }
  }

  private func processSynchronizedDepthWide(_ collection: AVCaptureSynchronizedDataCollection) {
    guard !isStopping, let vOut = videoOutput, let dOut = depthOutput else { return }

    guard
      let vidSync = collection.synchronizedData(for: vOut) as? AVCaptureSynchronizedSampleBufferData
    else {
      return
    }
    let sampleBuffer = vidSync.sampleBuffer

    var depthDataObj: AVDepthData?
    if let depSync = collection.synchronizedData(for: dOut) as? AVCaptureSynchronizedDepthData,
       !depSync.depthDataWasDropped
    {
      depthDataObj = depSync.depthData
    }

    guard let depthData = depthDataObj,
          let grayBuffer = Self.depthFloat32ToGrayBGRA(depthData: depthData)
    else {
      return
    }

    if let cal = depthData.cameraCalibrationData {
      let m = cal.intrinsicMatrix
      let fx = Double(m.columns.0.x)
      let fy = Double(m.columns.1.y)
      let cx = Double(m.columns.2.x)
      let cy = Double(m.columns.2.y)
      lastSecondFocalLengthX = fx
      lastSecondFocalLengthY = fy
      lastSecondPrincipalPointX = cx
      lastSecondPrincipalPointY = cy
      didUpdateSecondIntrinsics = fx > 1 && fy > 1
      lastDepthToWideExtrinsic = Self.depthToWideExtrinsicRows(cal)
    }

    guard let sb2 = Self.makeSampleBuffer(from: grayBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    else {
      return
    }
    processVideoSampleBuffer(sampleBuffer, secondSample: sb2, depthCalibration: depthData.cameraCalibrationData)
  }

  /// 将深度图转为 BGRA8，用于导出 `frames2/*.png`
  private static func depthFloat32ToGrayBGRA(depthData: AVDepthData) -> CVPixelBuffer? {
    let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    let depthMap = converted.depthDataMap

    let w = CVPixelBufferGetWidth(depthMap)
    let h = CVPixelBufferGetHeight(depthMap)
    let pf = CVPixelBufferGetPixelFormatType(depthMap)
    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

    guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
    let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
    let nearMeters = Self.depthVisualizationNearMeters
    let farMeters = max(nearMeters + 0.001, Self.depthVisualizationFarMeters)
    let invRange: Float = 1.0 / (farMeters - nearMeters)

    func readDepth(x: Int, y: Int) -> Float {
      let o = y * rowBytes + x * MemoryLayout<Float>.size
      guard pf == kCVPixelFormatType_DepthFloat32 else { return .nan }
      return base.load(fromByteOffset: o, as: Float.self)
    }

    var outBuf: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    CVPixelBufferCreate(
      kCFAllocatorDefault,
      w,
      h,
      kCVPixelFormatType_32BGRA,
      attrs as CFDictionary,
      &outBuf
    )
    guard let out = outBuf else { return nil }

    CVPixelBufferLockBaseAddress(out, [])
    defer { CVPixelBufferUnlockBaseAddress(out, []) }
    guard let outBase = CVPixelBufferGetBaseAddress(out) else { return nil }
    let outRowBytes = CVPixelBufferGetBytesPerRow(out)
    for y in 0..<h {
      var outRow = outBase.advanced(by: y * outRowBytes).assumingMemoryBound(to: UInt8.self)
      for x in 0..<w {
        let v = readDepth(x: x, y: y)
        let g: UInt8
        if v.isFinite, v > 0 {
          let clamped = min(max(v, nearMeters), farMeters)
          let normalized = ((farMeters - clamped) * invRange).clamped(to: 0...1)
          let emphasized = normalized.squareRoot()
          g = UInt8(min(255, max(0, emphasized * 255)))
        } else {
          g = 0
        }
        outRow[0] = g
        outRow[1] = g
        outRow[2] = g
        outRow[3] = 255
        outRow = outRow.advanced(by: 4)
      }
    }
    return out
  }

  private static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
    var timing = CMSampleTimingInfo(
      duration: CMTime.invalid,
      presentationTimeStamp: pts,
      decodeTimeStamp: CMTime.invalid
    )
    var formatDesc: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
    guard let fmt = formatDesc else { return nil }

    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: fmt,
      sampleTiming: &timing,
      sampleBufferOut: &sb
    )
    return sb
  }

  // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate（MultiCam / 单目）

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    syncQueue.async { [weak self] in
      guard let self = self else { return }
      switch self.captureMode {
      case .singleWide:
        if output === self.videoOutput {
          self.processVideoSampleBuffer(sampleBuffer, secondSample: nil, depthCalibration: nil)
        }
      case .multiCamRgb:
        self.handleMultiCamOutput(output: output, sampleBuffer: sampleBuffer)
      case .depthAndWide:
        break
      }
    }
  }

  private func handleMultiCamOutput(output: AVCaptureOutput, sampleBuffer: CMSampleBuffer) {
    guard captureMode == .multiCamRgb else { return }
    if output === videoOutput {
      pendingWideBuffers.append(sampleBuffer)
      while pendingWideBuffers.count > 30 {
        pendingWideBuffers.removeFirst()
      }
      tryPairWideUltra()
    } else if output === secondVideoOutput {
      ultraBufferQueue.append(sampleBuffer)
      while ultraBufferQueue.count > 30 {
        ultraBufferQueue.removeFirst()
      }
      tryPairWideUltra()
    }
  }

  private func tryPairWideUltra() {
    guard !pendingWideBuffers.isEmpty, !ultraBufferQueue.isEmpty else { return }
    let wide = pendingWideBuffers.first!
    let wPts = CMSampleBufferGetPresentationTimeStamp(wide)

    var bestIdx: Int?
    var bestDiff = CMTime(seconds: 1, preferredTimescale: 600)
    for (i, u) in ultraBufferQueue.enumerated() {
      let uPts = CMSampleBufferGetPresentationTimeStamp(u)
      let d = CMTimeAbsoluteValue(CMTimeSubtract(wPts, uPts))
      if CMTimeCompare(d, bestDiff) < 0 {
        bestDiff = d
        bestIdx = i
      }
    }
    guard let idx = bestIdx, CMTimeGetSeconds(bestDiff) < 0.05 else { return }

    let ultra = ultraBufferQueue.remove(at: idx)
    pendingWideBuffers.removeFirst()
    processVideoSampleBuffer(wide, secondSample: ultra, depthCalibration: nil)
  }

  // MARK: - 统一处理

  private func processVideoSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    secondSample: CMSampleBuffer?,
    depthCalibration: AVCameraCalibrationData?
  ) {
    guard !isStopping else { return }

    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
    let primaryPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if let lastPts = lastPrimaryWrittenPts, CMTimeCompare(primaryPts, lastPts) <= 0 {
      return
    }

    if assetWriter == nil {
      guard startWritersIfNeeded(with: sampleBuffer, second: secondSample) else { return }
    }

    guard
      let input = videoInput,
      let writer = assetWriter,
      writer.status == .writing,
      input.isReadyForMoreMediaData
    else {
      return
    }

    let hasSecondWriter =
      captureMode != .singleWide && secondSample != nil && assetWriter2 != nil && videoInput2 != nil
    let canAppendSecond = hasSecondWriter && (videoInput2?.isReadyForMoreMediaData ?? false)
    let secondSampleForThisFrame = secondSample

    if !didStartWriter {
      writer.startSession(atSourceTime: primaryPts)
      if hasSecondWriter, let w2 = assetWriter2 {
        w2.startSession(atSourceTime: primaryPts)
      }

      guard input.append(sampleBuffer) else {
        writer.cancelWriting()
        assetWriter2?.cancelWriting()
        assetWriter = nil
        videoInput = nil
        assetWriter2 = nil
        videoInput2 = nil
        firstVideoPts = nil
        didStartWriter = false
        lastPrimaryWrittenPts = nil
        lastSecondaryWrittenPts = nil
        return
      }

      var appendedSecond = false
      if canAppendSecond, let i2 = videoInput2, let sb2 = secondSampleForThisFrame {
        let sb2ToAppend = Self.retimeSampleBufferIfNeeded(sb2, to: primaryPts) ?? sb2
        appendedSecond = i2.append(sb2ToAppend)
      }

      firstVideoPts = primaryPts
      timeOriginMedia = CACurrentMediaTime()
      startMotion()
      didStartWriter = true
      lastPrimaryWrittenPts = primaryPts
      if appendedSecond {
        lastSecondaryWrittenPts = primaryPts
      }

      appendFrameJsonl(
        number: frameIndex,
        wideSample: sampleBuffer,
        secondSample: secondSampleForThisFrame,
        isDepthGray: captureMode == .depthAndWide,
        depthCalibration: depthCalibration
      )
      exportFrames2PngIfNeeded(secondSample: secondSampleForThisFrame, frameNumber: frameIndex)
      frameIndex += 1
      return
    }

    appendFrameJsonl(
      number: frameIndex,
      wideSample: sampleBuffer,
      secondSample: secondSampleForThisFrame,
      isDepthGray: captureMode == .depthAndWide,
      depthCalibration: depthCalibration
    )
    exportFrames2PngIfNeeded(secondSample: secondSampleForThisFrame, frameNumber: frameIndex)
    frameIndex += 1
    if input.append(sampleBuffer) {
      lastPrimaryWrittenPts = primaryPts
    }
    if canAppendSecond, let i2 = videoInput2, let sb2 = secondSampleForThisFrame {
      let sb2ToAppend = Self.retimeSampleBufferIfNeeded(sb2, to: primaryPts) ?? sb2
      if i2.append(sb2ToAppend) {
        lastSecondaryWrittenPts = primaryPts
      }
    }
  }

  private static func retimeSampleBufferIfNeeded(_ sampleBuffer: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
    let currentPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if CMTimeCompare(currentPts, pts) == 0 {
      return sampleBuffer
    }

    var timingCount = 0
    guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount) == noErr,
          timingCount > 0
    else {
      return nil
    }

    var timings = Array(
      repeating: CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: .invalid,
        decodeTimeStamp: .invalid
      ),
      count: timingCount
    )

    guard CMSampleBufferGetSampleTimingInfoArray(
      sampleBuffer,
      entryCount: timingCount,
      arrayToFill: &timings,
      entriesNeededOut: &timingCount
    ) == noErr
    else {
      return nil
    }

    for i in 0..<timings.count {
      timings[i].presentationTimeStamp = pts
      timings[i].decodeTimeStamp = .invalid
    }

    var retimed: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault,
      sampleBuffer: sampleBuffer,
      sampleTimingEntryCount: timings.count,
      sampleTimingArray: &timings,
      sampleBufferOut: &retimed
    )

    guard status == noErr else { return nil }
    return retimed
  }

  private func exportFrames2PngIfNeeded(secondSample: CMSampleBuffer?, frameNumber: Int) {
    guard shouldExportFrames2PngSequence,
          let sb2 = secondSample,
          let pixelBuffer = CMSampleBufferGetImageBuffer(sb2)
    else {
      return
    }

    let pngImage = CIImage(cvPixelBuffer: pixelBuffer)

    guard let cgImage = ciContext.createCGImage(pngImage, from: pngImage.extent) else {
      return
    }

    let image = UIImage(cgImage: cgImage)
    guard let data = image.pngData() else {
      return
    }

    let fileName = String(format: "%08d.png", frameNumber)
    let url = frames2DirectoryURL.appendingPathComponent(fileName)
    try? data.write(to: url, options: [.atomic])
  }

  private func startWritersIfNeeded(with sampleBuffer: CMSampleBuffer, second: CMSampleBuffer?) -> Bool {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    videoWidth = width
    videoHeight = height

    let movieURL = outputDirectory.appendingPathComponent("data.mov")
    try? FileManager.default.removeItem(at: movieURL)

    do {
      let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
      let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: width * height * 4,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
          AVVideoMaxKeyFrameIntervalKey: 60,
        ] as [String: Any],
      ]

      let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
      input.expectsMediaDataInRealTime = true

      guard writer.canAdd(input) else {
        return false
      }
      writer.add(input)
      guard writer.startWriting() else {
        return false
      }

      assetWriter = writer
      videoInput = input
    } catch {
      return false
    }

    if captureMode != .singleWide, let sec = second, let pb2 = CMSampleBufferGetImageBuffer(sec) {
      let w2 = CVPixelBufferGetWidth(pb2)
      let h2 = CVPixelBufferGetHeight(pb2)
      videoWidth2 = w2
      videoHeight2 = h2
    } else {
      videoWidth2 = 0
      videoHeight2 = 0
    }

    // data2.mov is no longer recorded. Keep only frames2 sequence for the second stream.
    let movie2URL = outputDirectory.appendingPathComponent("data2.mov")
    try? FileManager.default.removeItem(at: movie2URL)
    assetWriter2 = nil
    videoInput2 = nil

    return true
  }

  private static func intrinsicCalibration(from sampleBuffer: CMSampleBuffer) -> (
    fx: Double, fy: Double, cx: Double, cy: Double
  )? {
    guard
      let att = CMGetAttachment(
        sampleBuffer,
        key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
        attachmentModeOut: nil
      ),
      CFGetTypeID(att) == CFDataGetTypeID(),
      let data = att as? Data
    else {
      return nil
    }
    guard data.count >= MemoryLayout<matrix_float3x3>.size else { return nil }
    let m = data.withUnsafeBytes { raw -> matrix_float3x3 in
      raw.load(as: matrix_float3x3.self)
    }
    let fx = Double(m.columns.0.x)
    let fy = Double(m.columns.1.y)
    let cx = Double(m.columns.2.x)
    let cy = Double(m.columns.2.y)
    guard fx > 1, fy > 1 else { return nil }
    return (fx, fy, cx, cy)
  }

  /// 对齐 Spectacular 常见输出：将 iOS 设备运动坐标轴映射到相机坐标轴。
  private static func captureConventionImuToCameraMatrix() -> [[Double]] {
    [
      [0, -1, 0, 0],
      [-1, 0, 0, 0],
      [0, 0, -1, 0],
      [0, 0, 0, 1],
    ]
  }

  /// AVCameraCalibrationData.extrinsicMatrix（3x4）扩展为 4x4 齐次矩阵。
  private static func depthToWideExtrinsicRows(_ calibration: AVCameraCalibrationData) -> [[Double]] {
    let e = calibration.extrinsicMatrix
    return [
      [Double(e.columns.0.x), Double(e.columns.1.x), Double(e.columns.2.x), Double(e.columns.3.x)],
      [Double(e.columns.0.y), Double(e.columns.1.y), Double(e.columns.2.y), Double(e.columns.3.y)],
      [Double(e.columns.0.z), Double(e.columns.1.z), Double(e.columns.2.z), Double(e.columns.3.z)],
      [0, 0, 0, 1],
    ]
  }

  private static func multiply4x4(_ left: [[Double]], _ right: [[Double]]) -> [[Double]] {
    var out = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
    for r in 0..<4 {
      for c in 0..<4 {
        var v = 0.0
        for k in 0..<4 {
          v += left[r][k] * right[k][c]
        }
        out[r][c] = v
      }
    }
    return out
  }

  /// 针对旋转+平移的刚体变换求逆。
  private static func invertRigid4x4(_ matrix: [[Double]]) -> [[Double]]? {
    guard matrix.count == 4, matrix.allSatisfy({ $0.count == 4 }) else {
      return nil
    }

    let r00 = matrix[0][0], r01 = matrix[0][1], r02 = matrix[0][2]
    let r10 = matrix[1][0], r11 = matrix[1][1], r12 = matrix[1][2]
    let r20 = matrix[2][0], r21 = matrix[2][1], r22 = matrix[2][2]
    let tx = matrix[0][3], ty = matrix[1][3], tz = matrix[2][3]

    let rt00 = r00, rt01 = r10, rt02 = r20
    let rt10 = r01, rt11 = r11, rt12 = r21
    let rt20 = r02, rt21 = r12, rt22 = r22

    let itx = -(rt00 * tx + rt01 * ty + rt02 * tz)
    let ity = -(rt10 * tx + rt11 * ty + rt12 * tz)
    let itz = -(rt20 * tx + rt21 * ty + rt22 * tz)

    return [
      [rt00, rt01, rt02, itx],
      [rt10, rt11, rt12, ity],
      [rt20, rt21, rt22, itz],
      [0, 0, 0, 1],
    ]
  }

  private func appendFrameJsonl(
    number: Int,
    wideSample: CMSampleBuffer,
    secondSample: CMSampleBuffer?,
    isDepthGray: Bool,
    depthCalibration: AVCameraCalibrationData?
  ) {
    guard let first = firstVideoPts else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(wideSample)
    let rel = CMTimeSubtract(pts, first)
    let t = timeOriginMedia + CMTimeGetSeconds(rel)

    var frame0: [String: Any] = [
      "cameraInd": 0,
      "colorFormat": "rgb",
    ]
    if let cal = Self.intrinsicCalibration(from: wideSample) {
      lastFocalLengthX = cal.fx
      lastFocalLengthY = cal.fy
      lastPrincipalPointX = cal.cx
      lastPrincipalPointY = cal.cy
      didUpdateIntrinsicsFromSample = true
      frame0["calibration"] = [
        "focalLengthX": cal.fx,
        "focalLengthY": cal.fy,
        "principalPointX": cal.cx,
        "principalPointY": cal.cy,
      ]
    }
    frame0["exposureTimeSeconds"] = lockedExposureDurationSeconds

    var framesArray: [[String: Any]] = [frame0]

    if let sb2 = secondSample {
      var frame1: [String: Any] = [
        "cameraInd": 1,
        "time": 0,
        "aligned": true,
      ]
      if isDepthGray {
        frame1["colorFormat"] = "gray"
        frame1["depthScale"] = jsonDepthScale
        if didUpdateSecondIntrinsics {
          frame1["calibration"] = [
            "focalLengthX": lastSecondFocalLengthX,
            "focalLengthY": lastSecondFocalLengthY,
            "principalPointX": lastSecondPrincipalPointX,
            "principalPointY": lastSecondPrincipalPointY,
          ]
        } else if let cal = Self.intrinsicCalibration(from: wideSample) {
          frame1["calibration"] = [
            "focalLengthX": cal.fx,
            "focalLengthY": cal.fy,
            "principalPointX": cal.cx,
            "principalPointY": cal.cy,
          ]
        }
      } else {
        frame1["colorFormat"] = "rgb"
        if let c2 = Self.intrinsicCalibration(from: sb2) {
          lastSecondFocalLengthX = c2.fx
          lastSecondFocalLengthY = c2.fy
          lastSecondPrincipalPointX = c2.cx
          lastSecondPrincipalPointY = c2.cy
          didUpdateSecondIntrinsics = true
          frame1["calibration"] = [
            "focalLengthX": c2.fx,
            "focalLengthY": c2.fy,
            "principalPointX": c2.cx,
            "principalPointY": c2.cy,
          ]
        }
        frame1["exposureTimeSeconds"] = lockedExposureDurationSeconds
      }
      framesArray.append(frame1)
    }

    enqueueJsonl(
      time: t,
      kind: .frame,
      object: [
        "number": number,
        "time": t,
        "frames": framesArray,
      ]
    )
  }

  private func enqueueJsonl(time: Double, kind: JsonlLineKind, object: [String: Any]) {
    pendingJsonl.append(PendingJsonlLine(time: time, kind: kind, object: object))
  }

  private func writeSortedJsonlToDisk() {
    guard !pendingJsonl.isEmpty else { return }
    let sorted = pendingJsonl.sorted { a, b in
      if a.time != b.time { return a.time < b.time }
      return a.kind.rawValue < b.kind.rawValue
    }
    let url = outputDirectory.appendingPathComponent("data.jsonl")
    try? FileManager.default.removeItem(at: url)
    var blob = Data()
    for line in sorted {
      guard JSONSerialization.isValidJSONObject(line.object),
            let data = try? JSONSerialization.data(withJSONObject: line.object, options: [.sortedKeys]),
            let s = String(data: data, encoding: .utf8)
      else {
        continue
      }
      if let nl = (s + "\n").data(using: .utf8) {
        blob.append(nl)
      }
    }
    try? blob.write(to: url, options: [.atomic])
    pendingJsonl.removeAll()
  }

  private func hasNonEmptyPrimaryMovie() -> Bool {
    let movieURL = outputDirectory.appendingPathComponent("data.mov")
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: movieURL.path),
          let size = attrs[.size] as? NSNumber
    else {
      return false
    }
    return size.int64Value > 0
  }

  func stop(completion: @escaping (Result<URL, Error>) -> Void) {
    syncQueue.async { [weak self] in
      self?.performStop(completion: completion)
    }
  }

  private func performStop(completion: @escaping (Result<URL, Error>) -> Void) {
    isStopping = true
    motionManager.stopDeviceMotionUpdates()
    motionManager.stopMagnetometerUpdates()

    dataOutputSynchronizer?.setDelegate(nil, queue: nil)
    dataOutputSynchronizer = nil

    videoOutput?.setSampleBufferDelegate(nil, queue: nil)
    secondVideoOutput?.setSampleBufferDelegate(nil, queue: nil)
    captureSession?.stopRunning()
    captureSession = nil
    videoOutput = nil
    secondVideoOutput = nil
    depthOutput = nil
    captureDevice = nil
    secondCaptureDevice = nil
    pendingWideBuffers.removeAll()
    ultraBufferQueue.removeAll()

    writeSortedJsonlToDisk()

    let finalizeSuccess: () -> Void = { [weak self] in
      guard let self = self else { return }
      self.assetWriter = nil
      self.videoInput = nil
      self.assetWriter2 = nil
      self.videoInput2 = nil

      self.writeCalibrationJson()
      self.writeMetadataJson()

      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = false
        completion(.success(self.outputDirectory))
      }
    }

    let finishOne: () -> Void = { [weak self] in
      guard let self = self else { return }
      if let input2 = self.videoInput2, let w2 = self.assetWriter2, self.didStartWriter {
        input2.markAsFinished()
        w2.finishWriting { [weak self] in
          guard let self = self else { return }
          self.syncQueue.async {
            if w2.status == .failed {
              self.assetWriter2 = nil
              self.videoInput2 = nil
            }
            finalizeSuccess()
          }
        }
      } else {
        finalizeSuccess()
      }
    }

    if let input = videoInput, let writer = assetWriter, didStartWriter {
      guard let lastPts = lastPrimaryWrittenPts else {
        writer.cancelWriting()
        assetWriter2?.cancelWriting()
        assetWriter = nil
        videoInput = nil
        assetWriter2 = nil
        videoInput2 = nil
        didStartWriter = false
        firstVideoPts = nil
        lastSecondaryWrittenPts = nil
        finalizeSuccess()
        return
      }

      if writer.status == .failed {
        if hasNonEmptyPrimaryMovie() {
          finishOne()
          return
        }

        if SlamRecordingError.isTransientFinalizeError(writer.error) {
          syncQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            if self.hasNonEmptyPrimaryMovie() {
              finishOne()
              return
            }
            let err = SlamRecordingError.wrapWriterError(writer.error)
            DispatchQueue.main.async {
              UIApplication.shared.isIdleTimerDisabled = false
              completion(.failure(err))
            }
          }
          return
        }

        let err = SlamRecordingError.wrapWriterError(writer.error)
        DispatchQueue.main.async {
          UIApplication.shared.isIdleTimerDisabled = false
          completion(.failure(err))
        }
        return
      }

      input.markAsFinished()
      writer.finishWriting { [weak self] in
        guard let self = self else { return }
        self.syncQueue.async {
          if writer.status == .failed {
            if self.hasNonEmptyPrimaryMovie() {
              finishOne()
              return
            }

            if SlamRecordingError.isTransientFinalizeError(writer.error) {
              self.syncQueue.asyncAfter(deadline: .now() + 0.2) {
                if self.hasNonEmptyPrimaryMovie() {
                  finishOne()
                  return
                }
                self.assetWriter = nil
                self.videoInput = nil
                self.assetWriter2 = nil
                self.videoInput2 = nil
                let err = SlamRecordingError.wrapWriterError(writer.error)
                DispatchQueue.main.async {
                  UIApplication.shared.isIdleTimerDisabled = false
                  completion(.failure(err))
                }
              }
              return
            }

            self.assetWriter = nil
            self.videoInput = nil
            self.assetWriter2 = nil
            self.videoInput2 = nil
            let err = SlamRecordingError.wrapWriterError(writer.error)
            DispatchQueue.main.async {
              UIApplication.shared.isIdleTimerDisabled = false
              completion(.failure(err))
            }
            return
          }
          finishOne()
        }
      }
    } else {
      assetWriter = nil
      videoInput = nil
      assetWriter2 = nil
      videoInput2 = nil
      finalizeSuccess()
    }
  }

  private func applyFocusExposureLockIfPossible() {
    guard let device = captureDevice else { return }
    let lensPosition = min(max(device.lensPosition, 0), 1)

    do {
      try device.lockForConfiguration()
      if device.isFocusPointOfInterestSupported {
        device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
      }
      if device.isExposurePointOfInterestSupported {
        device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
      }
      guard device.isFocusModeSupported(.locked) else {
        device.unlockForConfiguration()
        return
      }

      device.setFocusModeLocked(lensPosition: lensPosition) { [weak self] _ in
        guard let device = self?.captureDevice else { return }
        do {
          try device.lockForConfiguration()
          guard device.isExposureModeSupported(.custom) else {
            device.unlockForConfiguration()
            return
          }
          let duration = device.exposureDuration
          let iso = min(max(device.iso, device.activeFormat.minISO), device.activeFormat.maxISO)
          self?.syncQueue.async {
            self?.lockedExposureDurationSeconds = CMTimeGetSeconds(duration)
          }
          device.setExposureModeCustom(duration: duration, iso: iso) { [weak self] _ in
            guard let device = self?.captureDevice else { return }
            self?.syncQueue.async {
              self?.lockedExposureDurationSeconds = CMTimeGetSeconds(device.exposureDuration)
            }
            do {
              try device.lockForConfiguration()
              if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
              }
              device.unlockForConfiguration()
            } catch {
              try? device.unlockForConfiguration()
            }
          }
        } catch {
          try? device.unlockForConfiguration()
        }
      }
      device.unlockForConfiguration()
    } catch {
      try? device.unlockForConfiguration()
    }
  }

  private func startMotion() {
    guard motionManager.isDeviceMotionAvailable else { return }
    motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
    motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, _ in
      guard let self = self, let m = motion else { return }
      self.syncQueue.async {
        self.appendImuLines(from: m)
      }
    }

    if motionManager.isMagnetometerAvailable {
      motionManager.magnetometerUpdateInterval = 1.0 / 60.0
      motionManager.startMagnetometerUpdates(to: magnetometerQueue) { [weak self] data, _ in
        guard let self = self, let d = data else { return }
        self.syncQueue.async {
          self.appendMagnetometerLine(d)
        }
      }
    }
  }

  private func appendImuLines(from motion: CMDeviceMotion) {
    guard !isStopping, didStartWriter else { return }
    let t = CACurrentMediaTime()
    let gx = motion.rotationRate.x
    let gy = motion.rotationRate.y
    let gz = motion.rotationRate.z
    let ax = motion.gravity.x + motion.userAcceleration.x
    let ay = motion.gravity.y + motion.userAcceleration.y
    let az = motion.gravity.z + motion.userAcceleration.z

    enqueueJsonl(
      time: t,
      kind: .gyroscope,
      object: [
        "time": t,
        "sensor": [
          "type": "gyroscope",
          "values": [gx, gy, gz],
        ],
      ]
    )
    enqueueJsonl(
      time: t,
      kind: .accelerometer,
      object: [
        "time": t,
        "sensor": [
          "type": "accelerometer",
          "values": [ax, ay, az],
        ],
      ]
    )
  }

  private func appendMagnetometerLine(_ data: CMMagnetometerData) {
    guard !isStopping, didStartWriter else { return }
    let t = CACurrentMediaTime()
    let f = data.magneticField
    enqueueJsonl(
      time: t,
      kind: .magnetometer,
      object: [
        "time": t,
        "sensor": [
          "type": "magnetometer",
          "values": [f.x, f.y, f.z],
        ],
      ]
    )
  }

  private func writeCalibrationJson() {
    let w = videoWidth > 0 ? videoWidth : 1920
    let h = videoHeight > 0 ? videoHeight : 1080

    let fx1: Double
    let fy1: Double
    let cx1: Double
    let cy1: Double
    if didUpdateIntrinsicsFromSample, lastFocalLengthX > 1, lastFocalLengthY > 1 {
      fx1 = lastFocalLengthX
      fy1 = lastFocalLengthY
      cx1 = lastPrincipalPointX
      cy1 = lastPrincipalPointY
    } else {
      fx1 = Double(w) * 0.72
      fy1 = fx1
      cx1 = Double(w) / 2.0
      cy1 = Double(h) / 2.0
    }

    let imuI = Self.captureConventionImuToCameraMatrix()
    let primaryImuSource = "capture_convention_back_camera_axes"
    var secondaryImuSource = "not_applicable_single_camera"

    var cam1: [String: Any] = [
      "model": "pinhole",
      "focalLengthX": fx1,
      "focalLengthY": fy1,
      "principalPointX": cx1,
      "principalPointY": cy1,
      "imageWidth": w,
      "imageHeight": h,
      "imuToCamera": imuI,
    ]

    var cameras: [[String: Any]] = [cam1]

    if captureMode != .singleWide, videoWidth2 > 0, videoHeight2 > 0 {
      let w2 = videoWidth2
      let h2 = videoHeight2
      let fx2 = didUpdateSecondIntrinsics && lastSecondFocalLengthX > 1 ? lastSecondFocalLengthX : fx1
      let fy2 = didUpdateSecondIntrinsics && lastSecondFocalLengthY > 1 ? lastSecondFocalLengthY : fy1
      let cx2 = didUpdateSecondIntrinsics ? lastSecondPrincipalPointX : Double(w2) / 2.0
      let cy2 = didUpdateSecondIntrinsics ? lastSecondPrincipalPointY : Double(h2) / 2.0
      var imu2 = imuI
      if captureMode == .depthAndWide,
         let depthToWide = lastDepthToWideExtrinsic,
         let wideToDepth = Self.invertRigid4x4(depthToWide)
      {
        imu2 = Self.multiply4x4(wideToDepth, imuI)
        secondaryImuSource = "depth_calibration_extrinsic_composed"
      } else {
        secondaryImuSource = "capture_convention_copy_primary"
      }
      let cam2: [String: Any] = [
        "model": "pinhole",
        "focalLengthX": fx2,
        "focalLengthY": fy2,
        "principalPointX": cx2,
        "principalPointY": cy2,
        "imageWidth": w2,
        "imageHeight": h2,
        "imuToCamera": imu2,
      ]
      cameras.append(cam2)
    }

    lastPrimaryImuToCameraSource = primaryImuSource
    lastSecondaryImuToCameraSource = secondaryImuSource

    writeJsonFile(name: "calibration.json", object: ["cameras": cameras])
  }

  private func writeMetadataJson() {
    let model = SlamRecordingSession.machineModelName()
    var root: [String: Any] = [
      "device_model": model,
      "platform": "ios",
      "imu_temperature_status": "unavailable_no_public_api_ios",
      "intrinsics_source": didUpdateIntrinsicsFromSample ? "cmsamplebuffer_attachment" : "heuristic_fallback",
      "dual_capture_mode": captureMode == .depthAndWide ? "depth_gray_frames2"
        : captureMode == .multiCamRgb ? "wide_ultrawide_rgb_frames2" : "single_wide",
    ]
    root["p1"] = [
      "jsonl_sorted_by_time": true,
      "focus_exposure_locked_after_delay_s": 0.2,
    ] as [String: Any]
    root["spectacular_sample_alignment"] = [
      "magnetometer_jsonl": true,
      "per_frame_calibration_rgb": true,
      "dual_camera_data2": false,
      "data2_mov_recorded": false,
      "frames2_png_sequence": shouldExportFrames2PngSequence,
      "imu_temperature_jsonl": false,
    ] as [String: Any]
    root["calibration_capture_sources"] = [
      "imu_to_camera_primary": lastPrimaryImuToCameraSource,
      "imu_to_camera_secondary": lastSecondaryImuToCameraSource,
      "depth_to_wide_extrinsic_available": lastDepthToWideExtrinsic != nil,
    ] as [String: Any]
    writeJsonFile(name: "metadata.json", object: root)
  }

  private func writeJsonFile(name: String, object: [String: Any]) {
    let url = outputDirectory.appendingPathComponent(name)
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    else {
      return
    }
    try? data.write(to: url, options: [.atomic])
  }

  private static func machineModelName() -> String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    guard size > 0 else {
      return UIDevice.current.model
    }
    var buf = [CChar](repeating: 0, count: size)
    let err = sysctlbyname("hw.machine", &buf, &size, nil, 0)
    guard err == 0 else {
      return UIDevice.current.model
    }
    return String(cString: buf)
  }
}

private extension Comparable {
  func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}
