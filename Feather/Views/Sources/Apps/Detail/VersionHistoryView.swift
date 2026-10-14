//
//  VersionHistoryView.swift
//  Feather
//
//  Created by Nagata Asami on 27/7/25.
//

import SwiftUI
import AltSourceKit

// MARK: - VersionHistoryView
struct VersionHistoryView: View {
	let app: ASRepository.App

	var body: some View {
		let versions = app.orderedVersions

		ScrollView {
			LazyVStack(spacing: 12) {
				// Keyed by position rather than `Version.id`: repos reuse version strings,
				// and duplicate ids would break the diff.
				ForEach(versions.indices, id: \.self) { index in
					let version = versions[index]

					HStack(alignment: .top, spacing: 12) {
						AppVersionInfo(
							version: version.version,
							date: version.date?.date,
							description: version.localizedDescription ?? .localized("No release notes available"),
							badge: index == 0 ? String.localized("Latest") : nil,
							size: version.sizeInBytes
						)

						DownloadButtonView(app: app, version: version, style: .icon)
					}
					.padding(.horizontal)
					.background(Color(.systemBackground))
					.contextMenu {
						Button {
							if let downloadURL = version.downloadURL {
								UIPasteboard.general.string = downloadURL.absoluteString
							}
						} label: {
							Label(.localized("Copy Download URL"), systemImage: "doc.on.clipboard")
						}
						.disabled(version.downloadURL == nil)
					}

					Divider().padding(.horizontal)
				}
			}
			.padding(.top, 8)
		}
	}
}
