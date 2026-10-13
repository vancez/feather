//
//  InstallProgressPoller.swift
//  Feather
//
//  Created by samara on 13.10.2025.
//

import Foundation
import UIKit
import IDeviceSwift
import OSLog

/// Polls the private install-progress API until the system reports an install finished.
///
/// This is a heuristic, not a real completion signal: it treats "progress was above zero at some
/// point, and is now back to zero" as done. Two consequences callers have to live with:
///
/// - `installProgress` is keyed by bundle identifier across the whole device, so two installs
///   sharing an identifier cannot be told apart.
/// - An install that already finished before polling began never flips the start flag, so the
///   loop would spin forever. Anything that must terminate needs its own timeout on top.
enum InstallProgressPoller {
	/// Starts polling `bundleID`, writing into `viewModel`.
	///
	/// The returned task finishes on its own once the install completes, or when cancelled.
	/// - Parameter interval: how long to wait between polls. The single-app install screen wants
	///   the default; a queue installing many apps should back off, since each poll is a
	///   synchronous private-API call that has to hop to the main actor.
	static func start(
		bundleID: String,
		viewModel: InstallerStatusViewModel,
		interval: Duration = .milliseconds(1)
	) -> Task<Void, Never> {
		Task.detached(priority: .background) {
			var hasStarted = false

			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

				if rawProgress > 0 {
					hasStarted = true
				}

				let progress = hasStarted ? normalize(rawProgress) : 0.0

				Logger.misc.info("Install progress for \(bundleID): \(progress)")

				await MainActor.run {
					viewModel.installProgress = progress
				}

				if hasStarted && rawProgress == 0 {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(()))
					}
					break
				}

				try? await Task.sleep(for: interval)
			}
		}
	}

	/// Remaps the raw value, which plateaus around 0.6-0.9 before dropping back to zero.
	static func normalize(_ rawProgress: Double) -> Double {
		min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
	}
}
