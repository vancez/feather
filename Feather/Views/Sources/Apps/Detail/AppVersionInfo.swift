//
//  AppVersionInfo.swift
//  Feather
//
//  Created by Nagata Asami on 27/7/25.
//

import SwiftUI

struct AppVersionInfo: View {
	let version: String
	let date: Date?
	let description: String
	/// Already localized, rendered as written.
	let badge: String?
	let size: Int64?

	init(
		version: String,
		date: Date? = nil,
		description: String,
		badge: String? = nil,
		size: Int64? = nil
	) {
		self.version = version
		self.date = date
		self.description = description
		self.badge = badge
		self.size = size
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				Text("Version \(version)")
					.font(.subheadline)
					.foregroundStyle(.secondary)

				if let badge {
					Text(verbatim: badge)
						.font(.caption2.weight(.semibold))
						.foregroundStyle(Color.accentColor)
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.background(Color.accentColor.opacity(0.15))
						.clipShape(Capsule())
				}

				Spacer()

				if let size {
					Text(size.formattedByteCount)
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}

				if let date {
					Text(date.formatted(.relative(presentation: .named)))
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}
			}
			.padding(.vertical, 4)

			ExpandableText(text: description, lineLimit: 3)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
