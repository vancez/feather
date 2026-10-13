//
//  InstallRunner.swift
//  Feather
//
//  Created by samara on 13.10.2025.
//

import Foundation
import UIKit
import IDeviceSwift

/// Installs a single app with no UI of its own, for callers that need to sequence installs.
///
/// `InstallPreviewView` is not reusable for this: it is one app, one `@StateObject`, presented by
/// `onAppear`, and it gives up by dismissing its sheet and raising a modal alert — none of which
/// survives being driven in a loop.
///
/// ## How completion is detected
///
/// The two install methods report finishing in completely different ways:
///
/// - **Pairing** (`InstallationProxy`) is `async throws`. Returning means the device took the
///   payload. It cannot be interrupted, so the timeout only stops *waiting*; the upload runs to
///   its own conclusion in the background regardless.
/// - **Server** has no real completion signal. The only thing that ever produces `.completed` is
///   ``InstallProgressPoller``'s "progress went above zero, then back to zero" heuristic, which is
///   keyed by bundle identifier device-wide and misses entirely if the install finished before
///   polling began. The timeout, not the status, is what guarantees this terminates.
@MainActor
final class InstallRunner {
	struct Outcome {
		enum Kind {
			case installed
			case failed
			case skipped
		}

		let kind: Kind
		let message: String?

		static func installed() -> Outcome { .init(kind: .installed, message: nil) }
		static func failed(_ message: String) -> Outcome { .init(kind: .failed, message: message) }
		static func skipped(_ message: String) -> Outcome { .init(kind: .skipped, message: message) }
	}

	private let _app: AppInfoPresentable
	private let _viewModel: InstallerStatusViewModel
	private let _timeout: TimeInterval

	private var _installer: ServerInstaller?
	private var _archiveHandler: ArchiveHandler?
	private var _progressTask: Task<Void, Never>?

	/// The view model driving this install, for progress UI.
	var viewModel: InstallerStatusViewModel { _viewModel }

	init(app: AppInfoPresentable, timeout: TimeInterval = 600) {
		self._app = app
		// Mirrors InstallPreviewView: the idevice method has an upload channel to average in.
		self._viewModel = InstallerStatusViewModel(
			isIdevice: UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1
		)
		self._timeout = timeout
	}

	/// Reasons a queued app cannot be installed at all, checked before any work is done.
	///
	/// The missing name/version case is not cosmetic: the server method's manifest and its
	/// external-plist fallback force-unwrap `identifier`, `name` and `version`.
	static func skipReason(for app: AppInfoPresentable) -> String? {
		guard let identifier = app.identifier, !identifier.isEmpty else {
			return .localized("This app has no bundle identifier.")
		}

		if identifier == Bundle.main.bundleIdentifier {
			return .localized("Installing over ‘%@‘ would close it and abandon the rest of the queue. Use an alternative tool to update it.", arguments: Bundle.main.name)
		}

		guard
			let name = app.name, !name.isEmpty,
			let version = app.version, !version.isEmpty
		else {
			return .localized("This app is missing a name or version.")
		}

		return nil
	}

	/// Packages `_app` and installs it.
	///
	/// - Parameters:
	///   - onWebview: presents or dismisses the Safari redirect page, for the external-plist
	///     server method. Called with `nil` to dismiss.
	///   - shouldSkip: polled between status checks; return `true` to abandon this install.
	func run(
		onWebview: @escaping (URL?) -> Void,
		shouldSkip: @escaping () -> Bool
	) async -> Outcome {
		defer { cleanup() }

		let archiveHandler = ArchiveHandler(app: _app, viewModel: _viewModel)
		_archiveHandler = archiveHandler

		let packageUrl: URL
		do {
			try await archiveHandler.move()
			packageUrl = try await archiveHandler.archive()
		} catch {
			return .failed(error.localizedDescription)
		}

		if shouldSkip() {
			return .skipped(.localized("Skipped."))
		}

		if UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1 {
			return await _installViaPairing(packageUrl: packageUrl)
		}

		return await _installViaServer(packageUrl: packageUrl, onWebview: onWebview, shouldSkip: shouldSkip)
	}

	/// Stops the local install server and reclaims the temporary IPA. Safe to call repeatedly.
	///
	/// The server is shut down before the file is removed, and only ever once the run is over.
	/// The server streams the payload straight off disk, so deleting it while an install is still
	/// pulling would break something that was otherwise going fine.
	func cleanup() {
		_progressTask?.cancel()
		_progressTask = nil

		_installer?.shutdown()
		_installer = nil

		_archiveHandler?.clean()
		_archiveHandler = nil
	}
}

// MARK: - Extension: Install methods
extension InstallRunner {
	/// Installs over the pairing file.
	///
	/// `install(at:suspend:)` is one blocking chunked upload that ignores cancellation, so the
	/// timeout is built from **unstructured** tasks on purpose. A `withTaskGroup` race would not
	/// work here: the group does not return until every child has finished, so a hung upload would
	/// hold the queue open no matter what the timer said.
	///
	/// Giving up does not stop the upload — it keeps running until the tunnel drops it. What this
	/// buys is that `run` always returns, so the queue always advances and the sheet it is driven
	/// from can always be dismissed. A queue that can never finish is a worse failure than an
	/// upload that finishes unobserved.
	private func _installViaPairing(packageUrl: URL) async -> Outcome {
		let viewModel = _viewModel
		let timeout = _timeout
		let once = _Once()

		return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
			Task.detached {
				let outcome: Outcome
				do {
					let handler = await InstallationProxy(viewModel: viewModel)
					try await handler.install(at: packageUrl, suspend: false)
					outcome = .installed()
				} catch {
					outcome = .failed(error.localizedDescription)
				}

				if once.claim() { continuation.resume(returning: outcome) }
			}

			Task.detached {
				try? await Task.sleep(for: .seconds(timeout))

				if once.claim() {
					continuation.resume(
						returning: .failed(.localized("Timed out waiting for the install to finish."))
					)
				}
			}
		}
	}

	private func _installViaServer(
		packageUrl: URL,
		onWebview: @escaping (URL?) -> Void,
		shouldSkip: @escaping () -> Bool
	) async -> Outcome {
		let serverMethod = UserDefaults.standard.integer(forKey: "Feather.serverMethod")

		let installer: ServerInstaller
		do {
			installer = try ServerInstaller.make(app: _app, viewModel: _viewModel)
		} catch {
			return .failed(error.localizedDescription)
		}

		_installer = installer
		installer.packageUrl = packageUrl

		// Nothing else moves the view model off `.none`, and the hand-off below only ever fires on
		// `.ready` — ServerInstaller itself only ever reports manifest/payload/installing/broken.
		// Without this the device is never told the manifest exists and every app times out.
		_viewModel.status = .ready

		let bundleID = _app.identifier ?? ""
		let deadline = Date().addingTimeInterval(_timeout)

		var hasOpenedInstall = false
		var hasDismissedWebview = false
		var hasStartedPolling = false

		while Date() < deadline {
			if shouldSkip() {
				onWebview(nil)
				return .skipped(.localized("Skipped."))
			}

			switch _viewModel.status {
			case .ready:
				// Handing off to the system installer more than once would stack install
				// prompts, so this only ever fires on the first sighting.
				if !hasOpenedInstall {
					hasOpenedInstall = true

					if serverMethod == 1 {
						onWebview(installer.pageEndpoint)
					} else if let url = URL(string: installer.iTunesLink) {
						// In an async context this resolves to the async overload, unlike the
						// fire-and-forget call the single-app sheet makes from a sync closure.
						_ = await UIApplication.shared.open(url)
					}
				}

			case .sendingPayload:
				// The device is pulling the payload now; the redirect page has done its job.
				if serverMethod == 1, !hasDismissedWebview {
					hasDismissedWebview = true
					onWebview(nil)
				}

			case .installing:
				if !hasStartedPolling, !bundleID.isEmpty {
					hasStartedPolling = true
					_progressTask = InstallProgressPoller.start(
						bundleID: bundleID,
						viewModel: _viewModel,
						interval: .milliseconds(250)
					)
				}

			case .completed:
				onWebview(nil)
				return .installed()

			case .broken(let error):
				onWebview(nil)
				return .failed(error.localizedDescription)

			case .none, .sendingManifest:
				break
			}

			try? await Task.sleep(for: .milliseconds(250))
		}

		onWebview(nil)
		return .failed(.localized("Timed out waiting for the install to finish."))
	}
}

/// Lets exactly one of two racing tasks resume a continuation.
///
/// `CheckedContinuation` traps if it is resumed twice, and both the install task and the timeout
/// task reach the resume eventually — the loser has to be told to drop its outcome.
private final class _Once: @unchecked Sendable {
	private let _lock = NSLock()
	private var _isClaimed = false

	func claim() -> Bool {
		_lock.lock()
		defer { _lock.unlock() }

		if _isClaimed { return false }
		_isClaimed = true
		return true
	}
}
