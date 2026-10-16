//
//  Storage+Superseded.swift
//  Feather
//

import CoreData
import AltSourceKit

// MARK: - Class extension: Superseded Versions
extension Storage {
	/// Removes the imported copies of an app that `uuid` replaces.
	///
	/// Downloads stack up rather than replace: pulling a new version of something already in
	/// the library left the copy it supersedes behind as a second row. Everything at or below
	/// `version` goes, so re-downloading the same build collapses to a single entry, while a
	/// *newer* copy already in the library is left alone and so is `uuid` itself.
	///
	/// Signed copies are deliberately out of reach here, and are cleaned up by
	/// ``removeSupersededSigned`` instead.
	func removeSupersededImports(
		identifier: String?,
		version: String?,
		keeping uuid: String
	) {
		_removeSuperseded(
			Imported.self,
			identifier: identifier,
			version: version,
			sparing: [uuid]
		)
	}

	/// Removes the signed copies of an app that `uuid` replaces.
	///
	/// Called once a signing run has written `uuid`'s row, never when the download that
	/// preceded it landed: the library would otherwise be left with the old signed copy gone
	/// and its replacement not signed yet, which is a gap nothing can be installed from.
	///
	/// Same version counts as superseded here. Signing a build that is already in the library
	/// leaves the earlier signature of that exact build behind as a duplicate of what was just
	/// produced, and a duplicate is what this is for.
	///
	/// What must survive is anything the run is still using: `uuid` itself, the app it was
	/// built from — whose fate "Delete After Signing" decides, and not this — and the sources
	/// of a batch run's remaining queue, which would otherwise have their directory pulled out
	/// from under them before the run got to them.
	func removeSupersededSigned(
		identifier: String?,
		version: String?,
		keeping uuid: String,
		sparing spared: [String] = []
	) {
		_removeSuperseded(
			Signed.self,
			identifier: identifier,
			version: version,
			sparing: [uuid] + spared
		)
	}

	/// The lookup both of the above share.
	///
	/// Everything at or below `version` is superseded; only a *newer* copy escapes on its
	/// version, and `spared` escapes on its uuid.
	///
	/// With no version on either side there is no telling which of the two is the older one,
	/// so nothing is removed — a bundle version missing from one of the IPAs must not read as
	/// "older than everything" and take the library with it.
	///
	/// - Parameter spared: uuids left alone whatever their version.
	private func _removeSuperseded<T: NSManagedObject & AppInfoPresentable>(
		_ type: T.Type,
		identifier: String?,
		version: String?,
		sparing spared: [String]
	) {
		guard
			let identifier, !identifier.isEmpty,
			let version, !version.isEmpty
		else {
			return
		}

		let request = NSFetchRequest<T>(entityName: String(describing: T.self))
		request.predicate = NSPredicate(
			format: "identifier == %@ AND NOT (uuid IN %@)",
			identifier,
			spared
		)

		guard let existing = try? context.fetch(request) else { return }

		for app in existing {
			guard let other = app.version, !other.isEmpty else { continue }
			guard VersionOrder.compare(other, version) != .orderedDescending else { continue }

			deleteApp(for: app)
		}
	}
}
