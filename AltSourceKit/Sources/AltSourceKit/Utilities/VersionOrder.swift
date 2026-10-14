//
//  VersionOrder.swift
//  AltSourceKit
//

import Foundation

/// Ordering for repo supplied version strings.
///
/// Repos are only loosely semver: "1.2", "1.2.0", "v1.10", "2.0-beta", "1.0b10" and
/// outright junk all show up in the wild, so this is a best effort total order that
/// never traps on input it does not understand.
public enum VersionOrder {
	/// Loose semver precedence. "1.2" and "1.2.0" are the same version, "1.10" is newer
	/// than "1.9", and a prerelease sorts below the release it leads up to.
	static public func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
		let (lhsCore, lhsPre) = _split(lhs)
		let (rhsCore, rhsPre) = _split(rhs)

		let core = _compare(lhsCore, rhsCore)
		guard core == .orderedSame else { return core }

		switch (lhsPre, rhsPre) {
		case (nil, nil): return .orderedSame
		case (.some, nil): return .orderedAscending
		case (nil, .some): return .orderedDescending
		case let (.some(l), .some(r)): return _compare(l, r)
		}
	}

	/// The repo's versions ordered newest first.
	///
	/// The `date` field is optional per entry, so the mode is chosen for the list as a
	/// whole rather than entry by entry. Deciding per pair is not transitive: an undated
	/// newer release sinks below an older dated one, which aims "latest" at the wrong
	/// package. `sorted(by:)` needs a strict weak ordering, and both modes below are
	/// plain lexicographic keys, so either one is safe.
	static public func sortedNewestFirst(_ versions: [ASRepository.App.Version]) -> [ASRepository.App.Version] {
		let datesAreUsable = !versions.isEmpty && versions.allSatisfy { $0.date != nil }

		return versions.sorted { lhs, rhs in
			if datesAreUsable, let l = lhs.date?.date, let r = rhs.date?.date, l != r {
				return l > r
			}

			let version = compare(lhs.version, rhs.version)
			if version != .orderedSame { return version == .orderedDescending }

			let build = compare(lhs.build ?? "", rhs.build ?? "")
			if build != .orderedSame { return build == .orderedDescending }

			switch (lhs.date?.date, rhs.date?.date) {
			case let (.some(l), .some(r)) where l != r: return l > r
			case (.some, .none): return true
			case (.none, .some): return false
			default: break
			}

			return lhs.id > rhs.id
		}
	}

	private static let _locale = Locale(identifier: "en_US_POSIX")

	/// "v1.2.3-beta+build7" -> (["1", "2", "3"], ["beta"])
	private static func _split(_ raw: String) -> (core: [String], pre: [String]?) {
		var string = raw.trimmingCharacters(in: .whitespacesAndNewlines)

		if string.hasPrefix("v") || string.hasPrefix("V") {
			string.removeFirst()
		}
		if let plus = string.firstIndex(of: "+") {
			string = String(string[string.startIndex..<plus])
		}

		let halves = string.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
		let core = halves.first.map(String.init) ?? ""
		let pre = halves.count > 1 ? String(halves[1]) : nil

		return (_components(core), pre.map { _components($0) })
	}

	/// Drops trailing zero components so "1.2", "1.2.0" and "1.2.0.0" compare equal.
	private static func _components(_ string: String) -> [String] {
		var items = string.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

		while let last = items.last, last.isEmpty || last == "0" {
			items.removeLast()
		}

		return items
	}

	/// Compares component by component. `.numeric` compares digit runs by value, which
	/// covers "1.10" > "1.9" and "b10" > "b2" without parsing anything into an Int.
	private static func _compare(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
		for index in 0..<max(lhs.count, rhs.count) {
			let l = index < lhs.count ? lhs[index] : ""
			let r = index < rhs.count ? rhs[index] : ""

			let result = l.compare(r, options: [.numeric, .caseInsensitive], locale: _locale)
			if result != .orderedSame { return result }
		}

		return .orderedSame
	}
}
