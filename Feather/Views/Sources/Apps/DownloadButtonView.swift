//
//  DownloadButtonView.swift
//  Feather
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import Combine
import AltSourceKit
import NimbleViews

struct DownloadButtonView: View {
	enum Style {
		case capsule
		case icon
	}

	let app: ASRepository.App
	/// Explicit version to install. `nil` means the latest one.
	var version: ASRepository.App.Version? = nil
	var style: Style = .capsule
	/// Detail screen only: tapping installs the latest version, long pressing lists them all.
	var allowsVersionSelection: Bool = false

	@ObservedObject private var downloadManager = DownloadManager.shared

	@State private var downloadProgress: Double = 0
	@State private var cancellable: AnyCancellable?

	var body: some View {
		ZStack {
			if let download = _activeDownload {
				_progressRing(for: download)
			} else if allowsVersionSelection && app.orderedVersions.count > 1 {
				_versionPicker()
			} else {
				_getButton()
			}
		}
		.onAppear(perform: setupObserver)
		.onDisappear { cancellable?.cancel() }
		.onChange(of: downloadManager.downloads.description) { _ in
			setupObserver()
		}
		.animation(.easeInOut(duration: 0.3), value: _activeDownload != nil)
	}
}

// MARK: - Extension: DownloadButtonView (Resolution)
extension DownloadButtonView {
	/// A version picked explicitly never falls back to the app's top level URL, which
	/// belongs to the latest version — installing that instead would be a silent downgrade
	/// of intent, so a version with no URL is simply not installable.
	private var _targetURL: URL? {
		if let version {
			return version.downloadURL
		}

		return app.currentDownloadUrl
	}

	private var _downloadId: String {
		version.map { app.downloadId(for: $0) } ?? app.currentUniqueId
	}

	private var _activeDownload: Download? {
		if let download = downloadManager.getDownload(by: _downloadId) {
			return download
		}

		// `startDownload` dedupes by URL, so a download started under another id can be
		// the one this button is about to resume.
		if let url = _targetURL, let download = downloadManager.getDownload(byURL: url) {
			return download
		}

		// The capsule also reflects a download started for one of the older versions, so
		// it stays visible and cancellable after leaving the version history screen.
		guard allowsVersionSelection, version == nil else { return nil }

		return app.orderedVersions
			.compactMap { downloadManager.getDownload(by: app.downloadId(for: $0)) }
			.first
	}
}

// MARK: - Extension: DownloadButtonView (Builders)
extension DownloadButtonView {
	@ViewBuilder
	private func _progressRing(for download: Download) -> some View {
		ZStack {
			Circle()
				.trim(from: 0, to: downloadProgress)
				.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
				.rotationEffect(.degrees(-90))
				.frame(width: 31, height: 31)
				.animation(.smooth, value: downloadProgress)

			Image(systemName: downloadProgress >= 0.75 ? "archivebox" : "square.fill")
				.foregroundStyle(.tint)
				.font(.footnote).bold()
		}
		.onTapGesture {
			if downloadProgress <= 0.75 {
				downloadManager.cancelDownload(download)
			}
		}
		.compatTransition()
	}

	@ViewBuilder
	private func _getButton() -> some View {
		Button {
			if let url = _targetURL {
				_ = downloadManager.startDownload(from: url, id: _downloadId)
			}
		} label: {
			_label()
		}
		.disabled(_targetURL == nil)
		.buttonStyle(.borderless)
		.compatTransition()
	}

	@ViewBuilder
	private func _versionPicker() -> some View {
		let versions = app.orderedVersions

		Menu {
			ForEach(versions.indices, id: \.self) { index in
				let entry = versions[index]

				Button {
					if let url = entry.downloadURL {
						_ = downloadManager.startDownload(from: url, id: app.downloadId(for: entry))
					}
				} label: {
					Text(verbatim: _menuTitle(for: entry, isLatest: index == 0))
				}
				.disabled(entry.downloadURL == nil)
			}
		} label: {
			_label()
		} primaryAction: {
			if let url = app.currentDownloadUrl {
				_ = downloadManager.startDownload(from: url, id: app.currentUniqueId)
			}
		}
		.buttonStyle(.borderless)
		.compatTransition()
	}

	@ViewBuilder
	private func _label() -> some View {
		switch style {
		case .capsule:
			Text(.localized("Get"))
				.lineLimit(0)
				.font(.headline.bold())
				.foregroundStyle(Color.accentColor)
				.padding(.horizontal, 24)
				.padding(.vertical, 6)
				.background(Color(uiColor: .quaternarySystemFill))
				.clipShape(Capsule())
		case .icon:
			Image(systemName: "arrow.down.circle")
				.font(.title2)
				.foregroundStyle(Color.accentColor)
				.frame(width: 31, height: 31)
				.accessibilityLabel(Text(.localized("Install")))
		}
	}

	/// Interpolating into `Text` would make a `LocalizedStringKey` out of the whole line
	/// and look for a format key, so the menu entries are built as plain strings.
	private func _menuTitle(for version: ASRepository.App.Version, isLatest: Bool) -> String {
		var parts: [String] = [
			isLatest ? version.version + " (\(String.localized("Latest")))" : version.version
		]

		if let date = version.date?.date {
			parts.append(date.formatted(.relative(presentation: .named)))
		}

		if let size = version.sizeInBytes {
			parts.append(size.formattedByteCount)
		}

		return parts.joined(separator: " · ")
	}

	private func setupObserver() {
		cancellable?.cancel()
		guard let download = _activeDownload else {
			downloadProgress = 0
			return
		}
		downloadProgress = download.overallProgress

		let publisher = Publishers.CombineLatest(
			download.$progress,
			download.$unpackageProgress
		)

		cancellable = publisher.sink { _, _ in
			downloadProgress = download.overallProgress
		}
	}
}
