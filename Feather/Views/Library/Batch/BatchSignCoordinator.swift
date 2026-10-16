//
//  BatchSignCoordinator.swift
//  Feather
//
//  Created by samara on 13.10.2025.
//

import Foundation
import UIKit
import Combine
import IDeviceSwift

/// Drives a batch signing run, and optionally the queue of installs that follows it.
///
/// A singleton so the orchestration task outlives the sheet that started it — the same reasoning
/// behind `DownloadManager.shared` and `SourcesViewModel.shared`. The view renders whatever this
/// publishes and never owns the work.
@MainActor
final class BatchSignCoordinator: ObservableObject {
	static let shared = BatchSignCoordinator()

	// MARK: - Types

	/// One selected app, held as value snapshots.
	///
	/// Deliberately not the `AppInfoPresentable` itself: with "delete after signing" on, the source
	/// row is destroyed partway through the run, and reading it afterwards is undefined. The live
	/// object only ever lives inside the run's local `sources` array.
	struct Item: Identifiable {
		enum Phase {
			case pending
			case signing
			case signed
			case installing
			case installed
			case failed
			case skipped
		}

		let id: String
		let uuid: String
		let name: String
		let identifier: String?
		let version: String?
		let wasSigned: Bool

		/// The signed copy, resolved once when signing succeeds.
		///
		/// Safe to hold, unlike the source: nothing deletes a produced row during a run, and the
		/// run's install phase needs it anyway. Resolving it lazily per row instead would mean a
		/// CoreData fetch on every progress tick.
		var produced: AppInfoPresentable?
		var phase: Phase = .pending
		var message: String?
	}

	/// What the whole run is doing, which decides what the sheet shows.
	enum Stage {
		case idle
		case signing
		case installing
		case finished
	}

	struct Webview: Identifiable {
		let id = UUID()
		let url: URL
	}

	/// The install currently in flight. Kept as one value because the app and its view model are
	/// only ever meaningful together.
	struct CurrentInstall {
		let app: AppInfoPresentable
		let viewModel: InstallerStatusViewModel
	}

	// MARK: - Published state

	@Published private(set) var items: [Item] = []
	@Published private(set) var stage: Stage = .idle
	@Published private(set) var currentInstall: CurrentInstall?

	/// Set while the external-plist server method needs its Safari redirect page on screen.
	@Published var webview: Webview?

	// MARK: - Private state

	private var _task: Task<Void, Never>?
	private var _isCancelled = false

	private init() {}

	// MARK: - Derived

	var isRunning: Bool { stage == .signing || stage == .installing }

	var completedCount: Int {
		items.filter { $0.phase == .installed || $0.phase == .signed }.count
	}

	var currentIndex: Int? {
		items.firstIndex { $0.phase == .signing || $0.phase == .installing }
	}

	var failureCount: Int {
		items.filter { $0.phase == .failed }.count
	}

	var skippedCount: Int {
		items.filter { $0.phase == .skipped }.count
	}

	// MARK: - Control

	func start(
		apps: [AppInfoPresentable],
		certificate: CertificatePair?,
		installAfterSigning: Bool
	) {
		guard !isRunning else { return }

		let sources = apps.filter { $0.uuid != nil }
		guard !sources.isEmpty else { return }

		_isCancelled = false
		items = sources.map { app in
			Item(
				id: app.uuid ?? UUID().uuidString,
				uuid: app.uuid ?? "",
				name: app.name ?? .localized("Unknown"),
				identifier: app.identifier,
				version: app.version,
				wasSigned: app.isSigned
			)
		}
		stage = .signing

		_task = Task { [weak self] in
			guard let self else { return }

			await self._run(
				sources: sources,
				certificate: certificate,
				installAfterSigning: installAfterSigning
			)
		}
	}

	/// Stops the run. Takes effect between items — Zsign and the system installer cannot be
	/// interrupted, and a pairing install cannot be called off at all.
	func cancel() {
		_isCancelled = true
	}

	func reset() {
		guard !isRunning else { return }

		_task = nil
		_isCancelled = false
		items = []
		stage = .idle
		currentInstall = nil
		webview = nil
	}
}

// MARK: - Extension: Run
extension BatchSignCoordinator {
	private func _run(
		sources: [AppInfoPresentable],
		certificate: CertificatePair?,
		installAfterSigning: Bool
	) async {
		// Base options for the whole run, with the single-app overrides stripped: a globally
		// pinned name, version or bundle identifier would otherwise land on every selected app
		// and collapse them all onto one identifier. The per-app dictionaries and PPQ protection
		// are applied per item below, so they keep working.
		let baseOptions = OptionsManager.shared.options.withoutExplicitAppOverrides

		for index in sources.indices {
			if _isCancelled { break }

			let source = sources[index]
			let options = baseOptions.derivedForApp(source, certificate: certificate)

			items[index].phase = .signing

			let result = await withCheckedContinuation { continuation in
				FR.signPackageFile(
					source,
					using: options,
					icon: nil,
					certificate: certificate
				) { result in
					continuation.resume(returning: result)
				}
			}

			switch result {
			case .failure(let error):
				items[index].phase = .failed
				items[index].message = error.localizedDescription

			case .success(let producedUUID):
				FR.finalizePostSigning(
					source: source,
					producedUUID: producedUUID,
					options: options,
					// The queue was snapshotted up front, so every source in it is off
					// limits: signing one app can supersede another app that is still
					// waiting its turn, and removing that one would leave the run signing
					// a directory that is no longer there.
					sparing: sources.compactMap { $0.uuid }
				)

				items[index].produced = Storage.shared.getSignedApp(uuid: producedUUID)
				items[index].phase = .signed

				if !options.post_deleteAppAfterSigned {
					items[index].message = items[index].wasSigned
						? .localized("Kept the previous copy.")
						: .localized("Kept the original.")
				}
			}
		}

		if installAfterSigning, !_isCancelled, items.contains(where: { $0.produced != nil }) {
			stage = .installing
			await _runInstalls()
		}

		if _isCancelled {
			_markUnfinishedAsCancelled(wasInstalling: installAfterSigning)
		}

		currentInstall = nil
		webview = nil
		stage = .finished
	}

	private func _runInstalls() async {
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.start()
		defer { BackgroundAudioManager.shared.stop() }
		#endif

		// `installProgress` is keyed by bundle identifier across the whole device, so two queued
		// apps sharing one would read each other's progress — the first one wins, the rest skip.
		var seenIdentifiers: Set<String> = []

		for index in items.indices {
			if _isCancelled { break }

			// Only what actually signed. Signing failures already carry their own phase and
			// reason, and overwriting them here would replace a real error with a wrong one.
			guard items[index].phase == .signed else { continue }

			guard let signed = items[index].produced else {
				items[index].phase = .skipped
				items[index].message = .localized("The signed app could not be found.")
				continue
			}

			if let reason = InstallRunner.skipReason(for: signed) {
				items[index].phase = .skipped
				items[index].message = reason
				continue
			}

			if let identifier = signed.identifier, !seenIdentifiers.insert(identifier).inserted {
				items[index].phase = .skipped
				items[index].message = .localized("Another app in this batch uses the same bundle identifier.")
				continue
			}

			items[index].phase = .installing

			let runner = InstallRunner(app: signed)
			currentInstall = CurrentInstall(app: signed, viewModel: runner.viewModel)

			let outcome = await runner.run(
				onWebview: { [weak self] url in
					self?.webview = url.map { Webview(url: $0) }
				},
				shouldSkip: { [weak self] in
					self?._isCancelled ?? true
				}
			)

			currentInstall = nil
			webview = nil

			switch outcome.kind {
			case .installed:
				items[index].phase = .installed
			case .failed:
				items[index].phase = .failed
				items[index].message = outcome.message
			case .skipped:
				items[index].phase = .skipped
				items[index].message = outcome.message
			}
		}
	}

	/// Resolves anything the run never got to, so the summary never shows a stuck spinner.
	///
	/// Items that got as far as a successful sign keep that phase — it is still true — and only
	/// pick up a note saying the install never happened.
	private func _markUnfinishedAsCancelled(wasInstalling: Bool) {
		for index in items.indices {
			switch items[index].phase {
			case .installed, .failed, .skipped:
				continue
			case .signed:
				if wasInstalling {
					items[index].message = .localized("Signed, but not installed.")
				}
			case .pending, .signing, .installing:
				items[index].phase = .skipped
				items[index].message = .localized("Cancelled.")
			}
		}
	}
}
