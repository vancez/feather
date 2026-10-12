//
//  SourceAppsView.swift
//  Feather
//
//  Created by samara on 1.05.2025.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import UIKit

// MARK: - Extension: View (Enil)
extension SourceAppsView {
	enum SortOption: String, CaseIterable {
		case `default` = "default"
		case name
		case date
		
		var displayName: String {
			switch self {
			case .default:  .localized("Default")
			case .name: 	.localized("Name")
			case .date: 	.localized("Date")
			}
		}
	}
}

// MARK: - View
struct SourceAppsView: View {
	@AppStorage("Feather.sortOptionRawValue") private var _sortOptionRawValue: String = SortOption.default.rawValue
	@AppStorage("Feather.sortAscending") private var _sortAscending: Bool = true
	
	@State private var _sortOption: SortOption = .default
	@State private var _selectedRoute: SourceAppRoute?
	@State private var _searchText = ""

	private var _navigationTitle: String {
		if object.count == 1 {
			object[0].name ?? .localized("Unknown")
		} else {
			.localized("%lld Sources", arguments: object.count)
		}
	}
	
	/// nil when none of the sources being displayed are still being fetched
	private var _progress: Double? {
		viewModel.progress(for: object)
	}
	
	var object: [AltSource]
	@ObservedObject var viewModel: SourcesViewModel
	@State private var _sources: [ASRepository]?
	
	// MARK: Body
	var body: some View {
		ZStack {
			if
				let _sources,
				!_sources.isEmpty
			{
				SourceAppsTableRepresentableView(
					sources: _sources,
					searchText: $_searchText,
					sortOption: $_sortOption,
					sortAscending: $_sortAscending,
					onSelect: {self._selectedRoute = $0},
					onRefresh: { await viewModel.fetchSources(object, refresh: true) }
				)
				.ignoresSafeArea()
			} else if _progress != nil || !viewModel.isFinished || _sources == nil {
				ProgressView()
			} else {
				VStack(spacing: 6) {
					Image(systemName: "exclamationmark.triangle")
						.font(.title2)
					Text(.localized("Unable to load repositories"))
						.font(.subheadline)
						.multilineTextAlignment(.center)
				}
				.foregroundStyle(.secondary)
				.padding()
			}
		}
		.overlay(alignment: .top) {
			if let _progress {
				ProgressView(value: _progress)
					.progressViewStyle(.linear)
					.tint(Color.accentColor)
			}
		}
		.animation(.easeInOut(duration: 0.25), value: _progress)
		.navigationTitle(_navigationTitle)
		.searchable(text: $_searchText, placement: .platform())
		.toolbarTitleMenu {
			if
				let _sources,
				_sources.count == 1
			{
				if let url = _sources[0].website {
					Button(.localized("Visit Website"), systemImage: "globe") {
						UIApplication.open(url)
					}
				}
				
				if let url = _sources[0].patreonURL {
					Button(.localized("Visit Patreon"), systemImage: "dollarsign.circle") {
						UIApplication.open(url)
					}
				}
			}
			
			Divider()
			
			Button(.localized("Copy"), systemImage: "doc.on.doc") {
				guard !object.isEmpty else {
					UIAlertController.showAlertWithOk(
						title: .localized("Error"),
						message: .localized("No sources to copy")
					)
					return
				}
				UIPasteboard.general.string = object.map {
					$0.sourceURL!.absoluteString
				}.joined(separator: "\n")
				UIAlertController.showAlertWithOk(
					title: .localized("Success"),
					message: .localized("Sources copied to clipboard")
				)
			}
		}
		.toolbar {
			NBToolbarMenu(
				systemImage: "line.3.horizontal.decrease",
				style: .icon,
				placement: .topBarTrailing
			) {
				_sortActions()
			}
		}
		.onAppear {
			_load(from: viewModel.sources)
			_sortOption = SortOption(rawValue: _sortOptionRawValue) ?? .default
			Task { await viewModel.fetchSources(object) }
		}
		.onReceive(viewModel.$sources) { _load(from: $0) }
		.onChange(of: _sortOption) { newValue in
			_sortOptionRawValue = newValue.rawValue
		}
		.navigationDestinationIfAvailable(item: $_selectedRoute) { route in
			SourceAppsDetailView(source: route.source, app: route.app)
		}
	}
	
	private func _load(from sources: [AltSource: ASRepository]) {
		_sources = object.compactMap { sources[$0] }
	}
	
	struct SourceAppRoute: Identifiable, Hashable {
		let source: ASRepository
		let app: ASRepository.App
		let id: String = UUID().uuidString
	}
}

// MARK: - Extension: View (Sort)
extension SourceAppsView {
	@ViewBuilder
	private func _sortActions() -> some View {
		Section(.localized("Filter by")) {
			ForEach(SortOption.allCases, id: \.displayName) { opt in
				_sortButton(for: opt)
			}
		}
	}
	
	private func _sortButton(for option: SortOption) -> some View {
		Button {
			if _sortOption == option {
				_sortAscending.toggle()
			} else {
				_sortOption = option
				_sortAscending = true
			}
		} label: {
			HStack {
				Text(option.displayName)
				Spacer()
				if _sortOption == option {
					Image(systemName: _sortAscending ? "chevron.up" : "chevron.down")
				}
			}
		}
	}
}

import SwiftUI

extension View {
	@ViewBuilder
	func navigationDestinationIfAvailable<Item: Identifiable & Hashable, Destination: View>(
		item: Binding<Item?>,
		@ViewBuilder destination: @escaping (Item) -> Destination
	) -> some View {
		if #available(iOS 17, *) {
			self.navigationDestination(item: item, destination: destination)
		} else {
			self
		}
	}
}
