//
//  BackgroundAudioManager.swift
//  Feather
//
//  Created by Nagata Asami on 12/10/25.
//

#if !targetEnvironment(macCatalyst)

import AVFoundation

class BackgroundAudioManager {
	static let shared = BackgroundAudioManager()
	private let _engine = AVAudioEngine()
	private var _isRunning = false
	private var _isPrepared = false

	private let _silence = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
		let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
		for buffer in ablPointer {
			memset(buffer.mData, 0, Int(buffer.mDataByteSize))
		}
		return noErr
	}

	private init() {}

	/// Attaches the silent source node exactly once. `AVAudioEngine` accumulates nodes on every
	/// `attach`, and callers start this repeatedly (downloads start it on every array mutation),
	/// so neither repeated starts nor stop/start cycles may create new ones.
	private func _prepare() {
		guard !_isPrepared else { return }
		_isPrepared = true

		_engine.attach(_silence)
		_engine.connect(_silence, to: _engine.mainMixerNode, format: nil)
	}

	func start() {
		guard !_isRunning else { return }

		do {
			let session = AVAudioSession.sharedInstance()

			try session.setCategory(.playback, options: [.mixWithOthers])
			try session.setActive(true)
			_prepare()
			try _engine.start()
			_isRunning = true
		} catch {
			print("failed to start engine:", error)
		}
	}

	func stop() {
		guard _isRunning else { return }
		_isRunning = false

		_engine.stop()
		try? AVAudioSession.sharedInstance().setActive(false)
	}
}

#endif
