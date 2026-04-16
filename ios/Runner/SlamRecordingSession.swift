import AVFoundation
import CoreImage
import CoreMotion
import CoreVideo
import Darwin
import Foundation
import ImageIO
import QuartzCore
import simd
import UIKit
import UniformTypeIdentifiers

enum SlamRecordingError: LocalizedError {
  case simulatorNotSupported
  case cameraPermissionDenied
  case captureSetupFailed
  case depthModeRequired
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

  var errorDescription: String? {
    switch self {
    case .simulatorNotSupported:
      return "SLAM 采集需要真机（相机与 IMU）。"
    case .cameraPermissionDenied:
      return "未授予相机权限。"
    case .captureSetupFailed:
      return "无法配置相机采集。"
    case .depthModeRequired:
      return "当前设备或配置未进入 LiDAR 深度模式，已阻止录制。"
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

/// Spectacular 风格：`data.mov` + `frames2` + JSONL 双 `frames`；IMU 与 P1 行为保留。
final class SlamRecordingSession: NSObject, AVCaptureDataOutputSynchronizerDelegate,
  AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate
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
  private let metersPerGravity: Double = 9.80665

  private var captureSession: AVCaptureSession?
  private var captureDevice: AVCaptureDevice?
  private var secondCaptureDevice: AVCaptureDevice?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var depthOutput: AVCaptureDepthDataOutput?
  private var secondVideoOutput: AVCaptureVideoDataOutput?
  private var audioOutput: AVCaptureAudioDataOutput?
  private var dataOutputSynchronizer: AVCaptureDataOutputSynchronizer?

  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var assetWriter2: AVAssetWriter?
  private var videoInput2: AVAssetWriterInput?

  private var pendingJsonl: [PendingJsonlLine] = []

  private let motionManager = CMMotionManager()
  private let requestedAudioCapture: Bool

  private var captureMode: DualCaptureMode = .singleWide
  /// Enforce LiDAR depth capture so generated scenes always contain depth stream.
  private let requireDepthAndWideMode = true
  private var shouldExportFrames2PngSequence = false
  private var isSecondaryRecordingEnabled = false

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
  /// MultiCam：待配对的超广角缓冲
  private var ultraBufferQueue: [CMSampleBuffer] = []
  private var pendingWideBuffers: [CMSampleBuffer] = []

  private var isStopping = false
  private var didStartWriter = false
  private var lastPrimaryWrittenPts: CMTime?
  private var lastSecondaryWrittenPts: CMTime?
  private var audioPermissionGranted = false
  private var audioCaptureEnabled = false

  /// 样例与 Spectacular 常用：米/灰度量化（仅作语义对齐；实际深度以 Float 录制为准）
  private let jsonDepthScale: Double = 0.001
  private static let depthVisualizationNearMeters: Float = 0.2
  private static let depthVisualizationFarMeters: Float = 5.0
  private static let targetVideoWidth = 1920
  private static let targetVideoHeight = 1440
  private static let targetCaptureFps: Double = 30
  private static let targetDepthWidth = 256
  private static let targetDepthHeight = 192
  private static let spectacularSecondaryImuTranslationX: Double = 0.1

  private var frames2DirectoryURL: URL {
    outputDirectory.appendingPathComponent("frames2", isDirectory: true)
  }

  init(outputDirectory: URL, enableAudio: Bool) {
    self.outputDirectory = outputDirectory
    self.requestedAudioCapture = enableAudio
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
      self.resolveAudioPermission { [weak self] granted in
        guard let self = self else { return }
        self.syncQueue.async {
          self.audioPermissionGranted = granted
          self.configureCaptureAndRun(completion: completion)
        }
      }
    }
  }

  private func resolveAudioPermission(completion: @escaping (Bool) -> Void) {
    guard requestedAudioCapture else {
      completion(false)
      return
    }
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    switch status {
    case .authorized:
      completion(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        completion(granted)
      }
    default:
      completion(false)
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
    audioInput = nil
    assetWriter2 = nil
    videoInput2 = nil
    pendingJsonl.removeAll(keepingCapacity: true)
    audioCaptureEnabled = requestedAudioCapture && audioPermissionGranted

    if configureDepthAndWideSession() {
      captureMode = .depthAndWide
    } else if requireDepthAndWideMode {
      DispatchQueue.main.async { completion(SlamRecordingError.depthModeRequired) }
      return
    } else if configureMultiCamSession() {
      captureMode = .multiCamRgb
    } else if configureSingleWideSession() {
      captureMode = .singleWide
    } else {
      DispatchQueue.main.async { completion(SlamRecordingError.captureSetupFailed) }
      return
    }

    lastPrimaryWrittenPts = nil
    lastSecondaryWrittenPts = nil
    isSecondaryRecordingEnabled = captureMode != .singleWide
    shouldExportFrames2PngSequence = true
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

  private func prepareFrames2DirectoryIfNeeded() {
    let fm = FileManager.default
    if shouldExportFrames2PngSequence {
      try? fm.removeItem(at: frames2DirectoryURL)
      try? fm.createDirectory(at: frames2DirectoryURL, withIntermediateDirectories: true)
    } else {
      try? fm.removeItem(at: frames2DirectoryURL)
    }
  }

  private func addAudioCaptureIfPossible(to session: AVCaptureSession) {
    audioOutput = nil
    guard audioCaptureEnabled,
          let device = AVCaptureDevice.default(for: .audio),
          let input = try? AVCaptureDeviceInput(device: device),
          session.canAddInput(input)
    else {
      audioCaptureEnabled = false
      return
    }
    session.addInput(input)

    let output = AVCaptureAudioDataOutput()
    output.setSampleBufferDelegate(self, queue: videoQueue)
    guard session.canAddOutput(output) else {
      audioCaptureEnabled = false
      return
    }
    session.addOutput(output)
    audioOutput = output
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
      Self.lockFrameRateIfPossible(device: device)
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

    if let conn = vOut.connection(with: .video) {
      Self.configureVideoConnection(conn)
    }

    addAudioCaptureIfPossible(to: session)

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

  private static func isTargetResolution(_ dimensions: CMVideoDimensions) -> Bool {
    let width = Int(dimensions.width)
    let height = Int(dimensions.height)
    return isTargetResolution(width: width, height: height)
  }

  private static func isTargetResolution(width: Int, height: Int) -> Bool {
    (width == targetVideoWidth && height == targetVideoHeight)
      || (width == targetVideoHeight && height == targetVideoWidth)
  }

  private static func isTargetDepthResolution(_ dimensions: CMVideoDimensions) -> Bool {
    let width = Int(dimensions.width)
    let height = Int(dimensions.height)
    return isTargetDepthResolution(width: width, height: height)
  }

  private static func isTargetDepthResolution(width: Int, height: Int) -> Bool {
    (width == targetDepthWidth && height == targetDepthHeight)
      || (width == targetDepthHeight && height == targetDepthWidth)
  }

  private static func supportsFrameRate(_ format: AVCaptureDevice.Format, fps: Double) -> Bool {
    let ranges = format.videoSupportedFrameRateRanges
    guard !ranges.isEmpty, fps.isFinite else { return false }
    let eps = 0.01
    return ranges.contains { range in
      range.minFrameRate - eps <= fps && fps <= range.maxFrameRate + eps
    }
  }

  private static func colorPreferenceScore(_ subtype: OSType) -> Int64 {
    switch subtype {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      return 3
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
      return 2
    default:
      return 0
    }
  }

  private static func pickPreferredVideoFormat(device: AVCaptureDevice, requireDepth: Bool) -> AVCaptureDevice.Format? {
    func pick(requireFrameRate: Bool) -> AVCaptureDevice.Format? {
      var best: AVCaptureDevice.Format?
      var bestScore = Int64.min

      for format in device.formats {
        if requireDepth && format.supportedDepthDataFormats.isEmpty {
          continue
        }

        let dim = format.formatDescription.dimensions
        guard isTargetResolution(dim) else {
          continue
        }

        if requireFrameRate, !supportsFrameRate(format, fps: targetCaptureFps) {
          continue
        }

        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let colorScore = colorPreferenceScore(subtype)
        let hdrPenalty: Int64 = format.isVideoHDRSupported ? 1 : 0
        let score = colorScore * 10 - hdrPenalty

        if score > bestScore {
          bestScore = score
          best = format
        }
      }

      return best
    }

    if let preferred = pick(requireFrameRate: true) {
      return preferred
    }
    return pick(requireFrameRate: false)
  }

  private static func pickDepthDataFormat(for videoFormat: AVCaptureDevice.Format) -> AVCaptureDevice.Format? {
    let allCandidates = videoFormat.supportedDepthDataFormats
    let targetCandidates = allCandidates.filter { isTargetDepthResolution($0.formatDescription.dimensions) }
    let candidates = targetCandidates.isEmpty ? allCandidates : targetCandidates

    var best: AVCaptureDevice.Format?
    var bestScore = Int64.min

    for depthFormat in candidates {
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
      if let picked = pickDepthVideoFormatAndDepthFormat(device: device, requireFrameRate: true) {
        return (device, picked.videoFormat, picked.depthFormat)
      }
      if let picked = pickDepthVideoFormatAndDepthFormat(device: device, requireFrameRate: false) {
        return (device, picked.videoFormat, picked.depthFormat)
      }
    }

    return nil
  }

  private static func pickDepthVideoFormatAndDepthFormat(
    device: AVCaptureDevice,
    requireFrameRate: Bool
  ) -> (videoFormat: AVCaptureDevice.Format, depthFormat: AVCaptureDevice.Format?)? {
    var candidates: [AVCaptureDevice.Format] = []
    candidates.reserveCapacity(16)

    for format in device.formats {
      guard !format.supportedDepthDataFormats.isEmpty else {
        continue
      }

      let dim = format.formatDescription.dimensions
      guard isTargetResolution(dim) else {
        continue
      }

      if requireFrameRate, !supportsFrameRate(format, fps: targetCaptureFps) {
        continue
      }

      candidates.append(format)
    }

    guard !candidates.isEmpty else {
      return nil
    }

    let candidatesWithTargetDepth = candidates.filter { format in
      format.supportedDepthDataFormats.contains { depthFormat in
        isTargetDepthResolution(depthFormat.formatDescription.dimensions)
      }
    }
    let effectiveCandidates = candidatesWithTargetDepth.isEmpty ? candidates : candidatesWithTargetDepth

    var best: AVCaptureDevice.Format?
    var bestScore = Int64.min
    for format in effectiveCandidates {
      let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
      let colorScore = colorPreferenceScore(subtype)
      let hdrPenalty: Int64 = format.isVideoHDRSupported ? 1 : 0
      let score = colorScore * 10 - hdrPenalty
      if score > bestScore {
        bestScore = score
        best = format
      }
    }

    guard let videoFormat = best else {
      return nil
    }
    let depthFormat = pickDepthDataFormat(for: videoFormat)
    return (videoFormat, depthFormat)
  }

  private static func disableHdrIfPossible(device: AVCaptureDevice) {
    device.automaticallyAdjustsVideoHDREnabled = false
    if device.isVideoHDREnabled {
      device.isVideoHDREnabled = false
    }
  }

  /// Lock to a stable frame rate to reduce capture jitter that can hurt SLAM tracking.
  private static func lockFrameRateIfPossible(device: AVCaptureDevice, preferredFps: Double = targetCaptureFps) {
    let ranges = device.activeFormat.videoSupportedFrameRateRanges
    guard !ranges.isEmpty, preferredFps > 0, preferredFps.isFinite else { return }

    var bestFps: Double?
    var bestDiff = Double.greatestFiniteMagnitude
    for range in ranges {
      let clamped = min(max(preferredFps, range.minFrameRate), range.maxFrameRate)
      let diff = abs(clamped - preferredFps)
      if diff < bestDiff - 0.0001
        || (abs(diff - bestDiff) <= 0.0001 && (bestFps == nil || clamped < bestFps!))
      {
        bestFps = clamped
        bestDiff = diff
      }
    }

    guard let fps = bestFps, fps.isFinite, fps > 0 else { return }
    let timescale = Int32(max(1, Int((fps * 1_000_000).rounded())))
    let frameDuration = CMTime(value: 1_000_000, timescale: timescale)
    device.activeVideoMinFrameDuration = frameDuration
    device.activeVideoMaxFrameDuration = frameDuration
  }

  private static func configureVideoConnection(_ connection: AVCaptureConnection) {
    if connection.isCameraIntrinsicMatrixDeliverySupported {
      connection.isCameraIntrinsicMatrixDeliveryEnabled = true
    }
    if connection.isVideoStabilizationSupported {
      connection.preferredVideoStabilizationMode = .off
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

    guard
      let wideFormat = Self.pickPreferredVideoFormat(device: wide, requireDepth: false),
      let ultraFormat = Self.pickPreferredVideoFormat(device: ultra, requireDepth: false)
    else {
      return false
    }

    do {
      try wide.lockForConfiguration()
      wide.activeFormat = wideFormat
      Self.disableHdrIfPossible(device: wide)
      Self.lockFrameRateIfPossible(device: wide)
      wide.unlockForConfiguration()
    } catch {
      return false
    }

    do {
      try ultra.lockForConfiguration()
      ultra.activeFormat = ultraFormat
      Self.disableHdrIfPossible(device: ultra)
      Self.lockFrameRateIfPossible(device: ultra)
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

    if let conn = outWide.connection(with: .video) {
      Self.configureVideoConnection(conn)
    }
    if let conn = outUltra.connection(with: .video) {
      Self.configureVideoConnection(conn)
    }

    addAudioCaptureIfPossible(to: session)

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

    guard let preferredFormat = Self.pickPreferredVideoFormat(device: device, requireDepth: false) else {
      return false
    }

    do {
      try device.lockForConfiguration()
      device.activeFormat = preferredFormat
      Self.disableHdrIfPossible(device: device)
      Self.lockFrameRateIfPossible(device: device)
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

    if let conn = output.connection(with: .video) {
      Self.configureVideoConnection(conn)
    }

    addAudioCaptureIfPossible(to: session)

    captureSession = session
    captureDevice = device
    videoOutput = output
    secondVideoOutput = nil
    depthOutput = nil
    dataOutputSynchronizer = nil
    return true
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

    guard let depthData = depthDataObj else {
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
    }

    processVideoSampleBuffer(
      sampleBuffer,
      secondSample: nil,
      depthCalibration: depthData.cameraCalibrationData,
      depthData: depthData
    )
  }

  /// 将深度图转为 BGRA8，用于写入 `frames2/*.png`。
  // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate（MultiCam / 单目）

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    syncQueue.async { [weak self] in
      guard let self = self else { return }
      if output === self.audioOutput {
        self.processAudioSampleBuffer(sampleBuffer)
        return
      }
      switch self.captureMode {
      case .singleWide:
        if output === self.videoOutput {
          self.processVideoSampleBuffer(sampleBuffer, secondSample: nil, depthCalibration: nil, depthData: nil)
        }
      case .multiCamRgb:
        self.handleMultiCamOutput(output: output, sampleBuffer: sampleBuffer)
      case .depthAndWide:
        break
      }
    }
  }

  private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard audioCaptureEnabled, !isStopping, didStartWriter else { return }
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
    guard
      let input = audioInput,
      let writer = assetWriter,
      writer.status == .writing,
      input.isReadyForMoreMediaData
    else {
      return
    }
    _ = input.append(sampleBuffer)
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
    processVideoSampleBuffer(wide, secondSample: ultra, depthCalibration: nil, depthData: nil)
  }

  // MARK: - 统一处理

  private func processVideoSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    secondSample: CMSampleBuffer?,
    depthCalibration: AVCameraCalibrationData?,
    depthData: AVDepthData? = nil
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

    let hasSecondSample = isSecondaryRecordingEnabled && secondSample != nil
    let secondSampleForThisFrame = hasSecondSample ? secondSample : nil

    if !didStartWriter {
      writer.startSession(atSourceTime: primaryPts)

      guard input.append(sampleBuffer) else {
        writer.cancelWriting()
        assetWriter2?.cancelWriting()
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        assetWriter2 = nil
        videoInput2 = nil
        firstVideoPts = nil
        didStartWriter = false
        lastPrimaryWrittenPts = nil
        lastSecondaryWrittenPts = nil
        return
      }

      firstVideoPts = primaryPts
      timeOriginMedia = CACurrentMediaTime()
      startMotion()
      didStartWriter = true
      lastPrimaryWrittenPts = primaryPts

      appendFrameJsonl(
        number: frameIndex,
        wideSample: sampleBuffer,
        secondSample: secondSampleForThisFrame,
        isDepthGray: captureMode == .depthAndWide,
        depthCalibration: depthCalibration
      )
      exportFrames2PngIfNeeded(
        wideSample: sampleBuffer,
        secondSample: secondSampleForThisFrame,
        depthData: depthData,
        frameNumber: frameIndex
      )
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
    exportFrames2PngIfNeeded(
      wideSample: sampleBuffer,
      secondSample: secondSampleForThisFrame,
      depthData: depthData,
      frameNumber: frameIndex
    )
    frameIndex += 1
    if input.append(sampleBuffer) {
      lastPrimaryWrittenPts = primaryPts
    }
  }

  private func exportFrames2PngIfNeeded(
    wideSample: CMSampleBuffer,
    secondSample: CMSampleBuffer?,
    depthData: AVDepthData?,
    frameNumber: Int
  ) {
    guard shouldExportFrames2PngSequence else {
      return
    }

    let fileName = String(format: "%08d.png", frameNumber)
    let url = frames2DirectoryURL.appendingPathComponent(fileName)

    if captureMode == .depthAndWide, let depthData {
      if !writeDepthPng16(from: depthData, to: url) {
        print("[SLAM] failed to write depth PNG: \(url.path)")
      }
      return
    }

    let sampleToExport = secondSample ?? wideSample
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleToExport) else {
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

    try? data.write(to: url, options: [.atomic])
  }

  /// Export depth map as 16-bit grayscale PNG in millimeters.
  /// The decoding convention is: depthMeters = pngValue * depthScale, where depthScale = 0.001.
  private func writeDepthPng16(from depthData: AVDepthData, to url: URL) -> Bool {
    let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    let depthMap = converted.depthDataMap
    let width = CVPixelBufferGetWidth(depthMap)
    let height = CVPixelBufferGetHeight(depthMap)
    guard width > 0, height > 0 else { return false }

    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return false }
    let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)

    var depthMillimetersBE = [UInt16](repeating: 0, count: width * height)
    for y in 0..<height {
      let row = baseAddress.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
      for x in 0..<width {
        let meters = row[x]
        let mmValue: UInt16
        if meters.isFinite, meters > 0 {
          let mm = Int(round(Double(meters) / jsonDepthScale))
          mmValue = UInt16(clamping: max(1, min(mm, Int(UInt16.max))))
        } else {
          mmValue = 0
        }
        depthMillimetersBE[y * width + x] = mmValue.bigEndian
      }
    }

    let data = depthMillimetersBE.withUnsafeBufferPointer { Data(buffer: $0) }
    guard let provider = CGDataProvider(data: data as CFData) else { return false }

    let colorSpace = CGColorSpaceCreateDeviceGray()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(.byteOrder16Big)
    guard let cgImage = CGImage(
      width: width,
      height: height,
      bitsPerComponent: 16,
      bitsPerPixel: 16,
      bytesPerRow: width * MemoryLayout<UInt16>.size,
      space: colorSpace,
      bitmapInfo: bitmapInfo,
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ) else {
      return false
    }

    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      return false
    }

    CGImageDestinationAddImage(destination, cgImage, nil)
    return CGImageDestinationFinalize(destination)
  }

  private func startWritersIfNeeded(with sampleBuffer: CMSampleBuffer, second: CMSampleBuffer?) -> Bool {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard Self.isTargetResolution(width: width, height: height) else { return false }
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
          AVVideoExpectedSourceFrameRateKey: Int(Self.targetCaptureFps.rounded()),
          AVVideoMaxKeyFrameIntervalKey: 60,
        ] as [String: Any],
      ]

      let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
      input.expectsMediaDataInRealTime = true

      guard writer.canAdd(input) else {
        return false
      }
      writer.add(input)

      if audioCaptureEnabled {
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        audioInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioInput) {
          writer.add(audioInput)
          self.audioInput = audioInput
        } else {
          self.audioInput = nil
          audioCaptureEnabled = false
        }
      } else {
        self.audioInput = nil
      }
      guard writer.startWriting() else {
        return false
      }

      assetWriter = writer
      videoInput = input
    } catch {
      return false
    }

    if isSecondaryRecordingEnabled, captureMode != .singleWide, let sec = second, let pb2 = CMSampleBufferGetImageBuffer(sec) {
      let w2 = CVPixelBufferGetWidth(pb2)
      let h2 = CVPixelBufferGetHeight(pb2)
      videoWidth2 = w2
      videoHeight2 = h2
      let movie2URL = outputDirectory.appendingPathComponent("data2.mov")
      try? FileManager.default.removeItem(at: movie2URL)
      assetWriter2 = nil
      videoInput2 = nil
    } else {
      videoWidth2 = 0
      videoHeight2 = 0
      let movie2URL = outputDirectory.appendingPathComponent("data2.mov")
      try? FileManager.default.removeItem(at: movie2URL)
      assetWriter2 = nil
      videoInput2 = nil
    }

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
  /// 针对旋转+平移的刚体变换求逆。
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
    var frame0Calibration: [String: Any]?
    if let cal = Self.intrinsicCalibration(from: wideSample) {
      lastFocalLengthX = cal.fx
      lastFocalLengthY = cal.fy
      lastPrincipalPointX = cal.cx
      lastPrincipalPointY = cal.cy
      didUpdateIntrinsicsFromSample = true
      let c0: [String: Any] = [
        "focalLengthX": cal.fx,
        "focalLengthY": cal.fy,
        "principalPointX": cal.cx,
        "principalPointY": cal.cy,
      ]
      frame0Calibration = c0
      frame0["calibration"] = c0
    }
    frame0["exposureTimeSeconds"] = lockedExposureDurationSeconds

    var framesArray: [[String: Any]] = [frame0]

    if isDepthGray || secondSample != nil {
      var frame1: [String: Any] = [
        "cameraInd": 1,
        "aligned": true,
      ]

      let secondaryOffsetSeconds: Double = {
        guard let sb2 = secondSample else { return 0 }
        let widePts = CMSampleBufferGetPresentationTimeStamp(wideSample)
        let secondPts = CMSampleBufferGetPresentationTimeStamp(sb2)
        let delta = CMTimeGetSeconds(CMTimeSubtract(secondPts, widePts))
        if delta.isFinite {
          return max(0, delta)
        }
        return 0
      }()
      frame1["time"] = secondaryOffsetSeconds

      if isDepthGray {
        frame1["colorFormat"] = "gray"
        frame1["depthScale"] = jsonDepthScale
        if let c0 = frame0Calibration {
          frame1["calibration"] = c0
        }
      } else {
        guard let sb2 = secondSample else { return }
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

  private static func videoResolution(from url: URL) -> CGSize? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else { return nil }
    let transformed = track.naturalSize.applying(track.preferredTransform)
    let width = abs(transformed.width)
    let height = abs(transformed.height)
    guard width > 0, height > 0 else { return nil }
    return CGSize(width: width, height: height)
  }

  private func prunePendingSecondaryFrameMetadata() {
    guard !pendingJsonl.isEmpty else { return }
    for i in pendingJsonl.indices {
      let line = pendingJsonl[i]
      guard line.kind == .frame else { continue }
      guard var frames = line.object["frames"] as? [[String: Any]] else { continue }
      if frames.count <= 1 { continue }
      frames = frames.filter { frame in
        (frame["cameraInd"] as? Int) != 1
      }
      var newObject = line.object
      newObject["frames"] = frames
      pendingJsonl[i] = PendingJsonlLine(time: line.time, kind: line.kind, object: newObject)
    }
  }

  private func discardSecondaryVideoOutput() {
    if let w2 = assetWriter2, w2.status == .writing || w2.status == .unknown {
      w2.cancelWriting()
    }
    isSecondaryRecordingEnabled = false
    assetWriter2 = nil
    videoInput2 = nil
    videoWidth2 = 0
    videoHeight2 = 0
    lastSecondaryWrittenPts = nil
    prunePendingSecondaryFrameMetadata()
    let movie2URL = outputDirectory.appendingPathComponent("data2.mov")
    try? FileManager.default.removeItem(at: movie2URL)
  }

  private func hasValidRecordedVideos() -> Bool {
    let movieURL = outputDirectory.appendingPathComponent("data.mov")
    guard Self.videoResolution(from: movieURL) != nil else { return false }

    if lastSecondaryWrittenPts != nil {
      let movie2URL = outputDirectory.appendingPathComponent("data2.mov")
      guard Self.videoResolution(from: movie2URL) != nil else { return false }
    }

    return true
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
    audioOutput?.setSampleBufferDelegate(nil, queue: nil)
    captureSession?.stopRunning()
    captureSession = nil
    videoOutput = nil
    secondVideoOutput = nil
    audioOutput = nil
    depthOutput = nil
    captureDevice = nil
    secondCaptureDevice = nil
    pendingWideBuffers.removeAll()
    ultraBufferQueue.removeAll()

    let finalizeFailure: (Error) -> Void = { [weak self] error in
      guard let self = self else { return }
      self.assetWriter = nil
      self.videoInput = nil
      self.audioInput = nil
      self.assetWriter2 = nil
      self.videoInput2 = nil

      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = false
        completion(.failure(error))
      }
    }

    let finalizeSuccess: () -> Void = { [weak self] in
      guard let self = self else { return }
      self.assetWriter = nil
      self.videoInput = nil
      self.audioInput = nil
      self.assetWriter2 = nil
      self.videoInput2 = nil

      guard self.hasValidRecordedVideos() else {
        finalizeFailure(SlamRecordingError.writerSetupFailed("invalid_video_resolution_metadata"))
        return
      }

      self.writeSortedJsonlToDisk()
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
        guard self.lastSecondaryWrittenPts != nil else {
          self.discardSecondaryVideoOutput()
          finalizeSuccess()
          return
        }

        if w2.status == .failed {
          self.discardSecondaryVideoOutput()
          finalizeSuccess()
          return
        }

        input2.markAsFinished()
        w2.finishWriting { [weak self] in
          guard let self = self else { return }
          self.syncQueue.async {
            guard w2.status == .completed else {
              self.discardSecondaryVideoOutput()
              finalizeSuccess()
              return
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
        finalizeFailure(SlamRecordingError.writerSetupFailed("no_video_samples_captured"))
        return
      }

      if writer.status == .failed {
        finalizeFailure(SlamRecordingError.wrapWriterError(writer.error))
        return
      }

      input.markAsFinished()
      audioInput?.markAsFinished()
      writer.finishWriting { [weak self] in
        guard let self = self else { return }
        self.syncQueue.async {
          guard writer.status == .completed else {
            if self.hasValidRecordedVideos() {
              finishOne()
              return
            }
            finalizeFailure(SlamRecordingError.wrapWriterError(writer.error))
            return
          }
          finishOne()
        }
      }
    } else {
      assetWriter = nil
      videoInput = nil
      audioInput = nil
      assetWriter2 = nil
      videoInput2 = nil
      finalizeFailure(SlamRecordingError.writerSetupFailed("no_video_writer_started"))
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
      motionManager.magnetometerUpdateInterval = 1.0 / 100.0
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
    let t = motion.timestamp
    let gx = motion.rotationRate.x
    let gy = motion.rotationRate.y
    let gz = motion.rotationRate.z
    let ax = (motion.gravity.x + motion.userAcceleration.x) * metersPerGravity
    let ay = (motion.gravity.y + motion.userAcceleration.y) * metersPerGravity
    let az = (motion.gravity.z + motion.userAcceleration.z) * metersPerGravity

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
    let t = data.timestamp
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

    let shouldWriteSecondCamera = (captureMode == .depthAndWide)
      || (captureMode != .singleWide && videoWidth2 > 0 && videoHeight2 > 0)

    if shouldWriteSecondCamera {
      let w2: Int
      let h2: Int
      if captureMode == .depthAndWide {
        // In depth mode there is no secondary video writer, but we still need
        // camera #1 intrinsics/extrinsics for downstream depth-aware tooling.
        w2 = w
        h2 = h
      } else {
        w2 = videoWidth2
        h2 = videoHeight2
      }
      let fx2: Double
      let fy2: Double
      let cx2: Double
      let cy2: Double
      if captureMode == .depthAndWide {
        fx2 = fx1
        fy2 = fy1
        cx2 = cx1
        cy2 = cy1
      } else {
        fx2 = didUpdateSecondIntrinsics && lastSecondFocalLengthX > 1 ? lastSecondFocalLengthX : fx1
        fy2 = didUpdateSecondIntrinsics && lastSecondFocalLengthY > 1 ? lastSecondFocalLengthY : fy1
        cx2 = didUpdateSecondIntrinsics ? lastSecondPrincipalPointX : Double(w2) / 2.0
        cy2 = didUpdateSecondIntrinsics ? lastSecondPrincipalPointY : Double(h2) / 2.0
      }
      var imu2 = imuI
      if captureMode == .depthAndWide {
        imu2[0][3] = Self.spectacularSecondaryImuTranslationX
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

    writeJsonFile(name: "calibration.json", object: ["cameras": cameras])
  }

  private func writeMetadataJson() {
    let model = SlamRecordingSession.machineModelName()
    let root: [String: Any] = [
      "device_model": model,
      "platform": "ios",
    ]
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
