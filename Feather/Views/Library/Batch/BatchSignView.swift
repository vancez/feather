//
//  BatchSignView.swift
//  Feather
//
//  Created by samara on 13.10.2025.
//

import SwiftUI
import CoreData
import NimbleViews
import IDeviceSwift

/// Identifiable carrier so a selection snapshot can drive `.sheet(item:)`.
struct BatchSelection: Identifiable {
	let id = UUID()
	let sources: [AppInfoPresentable]
}

// MARK: - View
struct BatchSignView: View {
	@StateObject private var _coordinator = BatchSignCoordinator.shared
	@StateObject private var _optionsManager = OptionsManager.shared

	@State private var _certificate: Int

	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>

	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_certificate) else { return nil }
		return certificates[_certificate]
	}

	/// What the run operates on. Handed to the coordinator only when the user starts.
	private let _sources: [AppInfoPresentable]

	/// One selected app, reduced to the values the setup screen draws.
	///
	/// The names and identifiers are frozen here rather than read off the source on each render,
	/// because a run with "delete after signing" on destroys those rows partway through. Only
	/// `source` stays live, and only the setup screen reaches for it — by the time anything is
	/// deleted the setup screen is long gone.
	struct Entry: Identifiable {
		let id: String
		let name: String
		let identifier: String?
		let source: AppInfoPresentable
	}

	private let _entries: [Entry]

	init(sources: [AppInfoPresentable]) {
		self._sources = sources
		self._entries = sources.compactMap { app in
			guard let uuid = app.uuid else { return nil }
			return Entry(
				id: uuid,
				name: app.name ?? .localized("Unknown"),
				identifier: app.identifier,
				source: app
			)
		}

		let storedCert = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		__certificate = State(initialValue: storedCert)
	}

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Batch Signing"), displayMode: .inline) {
			Group {
				switch _coordinator.stage {
				case .idle: _setup()
				case .signing, .installing: _progress()
				case .finished: _summary()
				}
			}
			.overlay {
				if _coordinator.stage == .idle {
					_startButton()
				}
			}
			.toolbar {
				if !_coordinator.isRunning {
					NBToolbarButton(role: .dismiss)
				}

				if _coordinator.isRunning {
					NBToolbarButton(
						.localized("Stop"),
						style: .text,
						placement: .topBarTrailing
					) {
						_coordinator.cancel()
					}
				}
			}
			.sheet(item: $_coordinator.webview) { webview in
				SafariRepresentableView(url: webview.url).ignoresSafeArea()
			}
		}
		// Nothing resets the coordinator here on purpose — `onDisappear` can fire while the sheet
		// is still up, which would clear the results mid-flow. The presenter resets on dismissal.
		.interactiveDismissDisabled(_coordinator.isRunning)
	}
}

// MARK: - Extension: Setup
extension BatchSignView {
	private var _canStart: Bool {
		_selectedCert() != nil && _optionsManager.options.signingOption != .onlyModify
	}

	/// `.localized` has both a `String` and a `LocalizedStringKey` overload, which makes a bare
	/// ternary of two of them ambiguous. Pinning the return type here picks the `String` one.
	private func _onOff(_ value: Bool) -> String {
		value ? .localized("On") : .localized("Off")
	}

	private var _afterSigningFooter: String {
		_optionsManager.options.installAfterBatchSigning
			? .localized("Installs run one at a time, in the order the apps were selected. Keep the app open — each install waits on a system prompt, and a free developer certificate only allows a few apps at once.")
			: .localized("Both of these are configured under Settings, in Signing Options.")
	}

	@ViewBuilder
	private func _setup() -> some View {
		Form {
			NBSection(.localized("Signing")) {
				if let cert = _selectedCert() {
					NavigationLink {
						CertificatesView(selectedCert: $_certificate)
					} label: {
						CertificatesCellView(cert: cert)
					}
				} else {
					Text(.localized("No Certificate"))
						.font(.footnote)
						.foregroundColor(.disabled())
				}
			} footer: {
				Text(.localized("Batch signing only asks for a certificate. Everything else comes from your signing options in settings, so a globally set name, version or bundle identifier is ignored — otherwise every app in the batch would end up with the same one."))
			}

			NBSection(.localized("After Signing")) {
				LabeledContent(
					.localized("Delete After Signing"),
					value: _onOff(_optionsManager.options.post_deleteAppAfterSigned)
				)
				LabeledContent(
					.localized("Install After Batch Signing"),
					value: _onOff(_optionsManager.options.installAfterBatchSigning)
				)
			} footer: {
				Text(_afterSigningFooter)
			}

			if _optionsManager.options.signingOption == .onlyModify {
				NBSection(.localized("Unavailable")) {
					Label(
						.localized("Signing Type is set to Modify, which produces an unsigned copy. Change it to Default to sign a batch."),
						systemImage: "exclamationmark.triangle"
					)
					.font(.footnote)
					.foregroundColor(.orange)
				}
			}

			NBSection(.localized("Apps"), secondary: _entries.count.description) {
				DisclosureGroup(.localized("Selected Apps")) {
					ForEach(_entries) { entry in
						HStack(spacing: 12) {
							FRAppIconView(app: entry.source, size: 29)

							VStack(alignment: .leading, spacing: 2) {
								Text(entry.name)
								Text(entry.identifier ?? .localized("Unknown"))
									.font(.footnote)
									.foregroundColor(.secondary)
							}
						}
					}
				}
			}
		}
	}

	@ViewBuilder
	private func _startButton() -> some View {
		VStack(spacing: 0) {
			Spacer()
			NBVariableBlurView()
				.frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 60 : 80)
				.rotationEffect(.degrees(180))
				.overlay {
					Button {
						_start()
					} label: {
						NBSheetButton(
							title: .localized("Start Signing"),
							style: .prominent
						)
						.padding()
					}
					.buttonStyle(.plain)
					.disabled(!_canStart)
					.offset(y: UIDevice.current.userInterfaceIdiom == .pad ? -20 : -40)
				}
		}
		.ignoresSafeArea(edges: .bottom)
	}

	private func _start() {
		let generator = UIImpactFeedbackGenerator(style: .light)
		generator.impactOccurred()

		_coordinator.start(
			apps: _sources,
			certificate: _selectedCert(),
			installAfterSigning: _optionsManager.options.installAfterBatchSigning
		)
	}
}

// MARK: - Extension: Progress & Summary
extension BatchSignView {
	@ViewBuilder
	private func _progress() -> some View {
		Form {
			NBSection(.localized("Progress")) {
				ProgressView(
					value: Double(_coordinator.completedCount),
					total: Double(max(1, _coordinator.items.count))
				)
				.progressViewStyle(.linear)
				.tint(Color.accentColor)

				// Signing reports no progress of its own — Zsign is a single opaque call — so the
				// count is the only honest thing to show for that half of the run.
				LabeledContent(
					.localized("Signed"),
					value: "\(_coordinator.completedCount) / \(_coordinator.items.count)"
				)
			} footer: {
				Text(.localized("Stopping takes effect between apps. Signing and the system installer cannot be interrupted once they have started."))
			}

			if let current = _coordinator.currentInstall {
				NBSection(.localized("Installing")) {
					HStack(spacing: 16) {
						InstallProgressView(app: current.app, viewModel: current.viewModel)

						VStack(alignment: .leading, spacing: 2) {
							Text(current.app.name ?? .localized("Unknown"))
							Text(current.viewModel.statusLabel)
								.font(.footnote)
								.foregroundColor(.secondary)
						}
					}
				}
			}

			NBSection(.localized("Apps")) {
				ForEach(_coordinator.items) { item in
					_itemRow(item)
				}
			}
		}
	}

	@ViewBuilder
	private func _summary() -> some View {
		Form {
			NBSection(.localized("Results")) {
				LabeledContent(.localized("Signed"), value: _coordinator.completedCount.description)
				LabeledContent(.localized("Failed"), value: _coordinator.failureCount.description)
				LabeledContent(.localized("Skipped"), value: _coordinator.skippedCount.description)
			}

			NBSection(.localized("Apps")) {
				ForEach(_coordinator.items) { item in
					_itemRow(item)
				}
			}

			Section {
				Button(.localized("Copy Results"), systemImage: "doc.on.doc") {
					UIPasteboard.general.string = _resultsText()
				}
			}
		}
	}

	@ViewBuilder
	private func _itemRow(_ item: BatchSignCoordinator.Item) -> some View {
		// Once "delete after signing" has run the source row is gone and its icon no longer
		// resolves, so the produced copy is used wherever there is one.
		HStack(spacing: 12) {
			FRAppIconView(app: item.produced, size: 29)

			VStack(alignment: .leading, spacing: 2) {
				Text(item.name)

				if let message = item.message {
					Text(message)
						.font(.footnote)
						.foregroundColor(item.phase == .failed ? Color.red : Color.secondary)
				}
			}

			Spacer()

			Image(systemName: _icon(for: item.phase))
				.foregroundColor(_color(for: item.phase))
		}
	}

	private func _icon(for phase: BatchSignCoordinator.Item.Phase) -> String {
		switch phase {
		case .pending: "circle.dashed"
		case .signing, .installing: "arrow.triangle.2.circlepath"
		case .signed: "signature"
		case .installed: "checkmark.circle.fill"
		case .failed: "exclamationmark.triangle.fill"
		case .skipped: "minus.circle"
		}
	}

	private func _color(for phase: BatchSignCoordinator.Item.Phase) -> Color {
		switch phase {
		case .installed: .green
		case .failed: .red
		case .pending, .skipped: .secondary
		case .signing, .signed, .installing: .accentColor
		}
	}

	private func _resultsText() -> String {
		_coordinator.items.map { item in
			let outcome = item.message.map { " — \($0)" } ?? ""
			return "[\(item.phase)] \(item.name)\(outcome)"
		}
		.joined(separator: "\n")
	}
}
