//
//  FRAppIconView.swift
//  Feather
//
//  Created by samara on 18.04.2025.
//

import SwiftUI

enum FRIconAppearance: Int {
	case light = 0
	case dark = 1
}

final class FRIconCache {
	static let shared = FRIconCache()
	private init() {}

	private let cache = NSCache<NSString, UIImage>()

	private func key(url: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool) -> NSString {
		"\(url.path)#\(appearance.rawValue)#\(tint)#\(isTinted)#\(dynamic)" as NSString
	}

	func image(for url: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool) -> UIImage? {
		cache.object(forKey: key(url: url, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic))
	}

	func insert(_ image: UIImage, for url: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool) {
		cache.setObject(image, forKey: key(url: url, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic))
	}

	func invalidateAll() {
		cache.removeAllObjects()
	}
}

@MainActor
final class FRAppIconLoader: ObservableObject {
	@Published var image: UIImage?
	private var task: Task<Void, Never>?
	/// The bundle `image` was generated for. The view uses this to avoid showing an icon that
	/// belongs to a different app while the next one is loading.
	private(set) var loadedBundleURL: URL?

	func load(bundleURL: URL, appearance: FRIconAppearance, tint: String, isTinted: Bool, dynamic: Bool) {
		// Cancel before the cache check: a generation for a previous bundle may still be in
		// flight, and returning early on a cache hit used to leave it running. It could then
		// finish later and overwrite the image for this bundle with the previous app's icon.
		task?.cancel()

		if loadedBundleURL != bundleURL {
			loadedBundleURL = bundleURL
			// The previous icon belongs to a different app; showing it while the new one
			// generates is worse than showing the placeholder.
			self.image = nil
		}

		if let cached = FRIconCache.shared.image(for: bundleURL, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic) {
			self.image = cached
			return
		}

		task = Task {
			let generated = await Task.detached(priority: .userInitiated) {
				return iconTest(bundleURL)
			}.value

			guard !Task.isCancelled else { return }

			if let generated {
				FRIconCache.shared.insert(generated, for: bundleURL, appearance: appearance, tint: tint, isTinted: isTinted, dynamic: dynamic)
				self.image = generated
			}
		}
	}

	func cancel() {
		task?.cancel()
	}

	/// Generates and caches `app`'s icon ahead of when it is needed.
	///
	/// The batch installer knows which signed copy it will install well before that row takes
	/// over the progress view. On-demand generation there can miss the cache — the row may
	/// never have been on screen, so its icon was never generated — and the view shows the
	/// placeholder until `iconTest` finishes, right in the middle of the install pulse.
	/// Warming it during signing leaves the first frame with the real icon.
	static func prefetch(app: AppInfoPresentable) async {
		guard let bundleURL = Storage.shared.getAppDirectory(for: app) else { return }

		// Match the keys `FRAppIconView` looks up with. The window's style override decides
		// the environment's color scheme, so the screen's own style is not enough.
		let defaults = UserDefaults.standard
		let tint = defaults.string(forKey: "Feather.userTintColor") ?? "#848ef9"
		let isTinted = defaults.bool(forKey: "Feather.shouldTintIcons")
		let dynamic = defaults.bool(forKey: "Feather.shouldChangeIconsBasedOffStyle")

		let storedStyle = UIUserInterfaceStyle(
			rawValue: defaults.integer(forKey: "Feather.userInterfaceStyle")
		)
		let windowStyle = UIApplication.shared.connectedScenes
			.compactMap { $0 as? UIWindowScene }
			.flatMap(\.windows)
			.first(where: \.isKeyWindow)?
			.traitCollection.userInterfaceStyle
		let style: UIUserInterfaceStyle
		if let storedStyle, storedStyle != .unspecified {
			style = storedStyle
		} else {
			style = windowStyle ?? UIScreen.main.traitCollection.userInterfaceStyle
		}
		let appearance: FRIconAppearance = style == .dark ? .dark : .light

		guard
			FRIconCache.shared.image(
				for: bundleURL,
				appearance: appearance,
				tint: tint,
				isTinted: isTinted,
				dynamic: dynamic
			) == nil
		else {
			return
		}

		let generated = await Task.detached(priority: .utility) {
			iconTest(bundleURL)
		}.value

		guard let generated else { return }

		FRIconCache.shared.insert(
			generated,
			for: bundleURL,
			appearance: appearance,
			tint: tint,
			isTinted: isTinted,
			dynamic: dynamic
		)
	}
}

struct FRAppIconView: View {
	private let app: AppInfoPresentable?
	private let size: CGFloat

	@Environment(\.colorScheme) private var colorScheme
	@StateObject private var loader = FRAppIconLoader()
	
	@AppStorage("Feather.userTintColor") private var selectedColorHex: String = "#848ef9"
	@AppStorage("Feather.shouldTintIcons") private var shouldTintIcons: Bool = false
	@AppStorage("Feather.shouldChangeIconsBasedOffStyle") private var shouldChangeIconsBasedOffStyle: Bool = false
	
	init(app: AppInfoPresentable? = nil, size: CGFloat = 87) {
		self.app = app
		self.size = size
	}

	private var appearance: FRIconAppearance {
		colorScheme == .dark ? .dark : .light
	}

	/// Everything that changes the image the loader should produce, including which app it
	/// belongs to.
	///
	/// SwiftUI reuses a view for as long as its structural identity holds, even when its
	/// `app` changes — a queued batch install swaps the app under the same progress row, and
	/// the run's results replace `nil` with the signed copy. Without the app in here, the
	/// task would not restart and the row would keep the icon it loaded first, which is the
	/// previous app's.
	private var _taskID: String {
		let bundleID = app.map { "\($0.isSigned)-\($0.uuid ?? "")" } ?? "main"
		return "\(bundleID)#\(appearance.rawValue)#\(selectedColorHex)#\(shouldTintIcons)#\(shouldChangeIconsBasedOffStyle)"
	}

	/// The bundle whose icon this view should show.
	private var _bundleURL: URL? {
		guard let app else { return Bundle.main.bundleURL }
		return Storage.shared.getAppDirectory(for: app)
	}

	/// An icon already generated for the current bundle and appearance.
	///
	/// Read synchronously while the body is built, so a view that has just been created or
	/// moved to another app in a batch draws the real icon on its first frame. Waiting for
	/// `.task` to hit the same cache left a placeholder frame in between, which showed up
	/// as the blank icon flashing during the install animation. `loader.image` alone cannot
	/// cover this — it is empty until that task runs.
	private var _cachedImage: UIImage? {
		guard let bundleURL = _bundleURL else { return nil }
		return FRIconCache.shared.image(
			for: bundleURL,
			appearance: appearance,
			tint: selectedColorHex,
			isTinted: shouldTintIcons,
			dynamic: shouldChangeIconsBasedOffStyle
		)
	}

	private var _image: UIImage? {
		if let cached = _cachedImage { return cached }
		// A pending or previous generation may belong to another app. Showing it here is
		// what used to leave the previous app's icon on screen; show the placeholder until
		// the right one is ready instead.
		return loader.loadedBundleURL == _bundleURL ? loader.image : nil
	}

	var body: some View {
		Group {
			if let image = _image {
				Image(uiImage: image)
					.appIconStyle(size: size)
			} else {
				Image("App_Unknown")
					.appIconStyle(size: size)
			}
		}
		.task(id: _taskID) {
			_load()
		}
		.onDisappear {
			loader.cancel()
		}
	}

	private func _load() {
		guard let bundleURL = _bundleURL else { return }

		loader.load(
			bundleURL: bundleURL,
			appearance: appearance,
			tint: selectedColorHex,
			isTinted: shouldTintIcons,
			dynamic: shouldChangeIconsBasedOffStyle
		)
	}

}
