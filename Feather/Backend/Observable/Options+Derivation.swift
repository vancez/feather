//
//  Options+Derivation.swift
//  Feather
//
//  Created by samara on 13.10.2025.
//

import Foundation

// MARK: - Extension: Per-app derivation
extension Options {
	/// Returns a copy of the receiver with the per-app rules applied for `app`.
	///
	/// The order mirrors what the single-app signing flow has always done: PPQ protection first,
	/// then the dictionaries, so an explicit `identifiers` entry wins over the generated one.
	func derivedForApp(_ app: AppInfoPresentable, certificate: CertificatePair?) -> Options {
		var options = self

		// ppq protection
		if
			options.ppqProtection,
			let identifier = app.identifier,
			let certificate,
			certificate.ppQCheck
		{
			options.appIdentifier = "\(identifier).\(options.ppqString)"
		}

		if
			let currentBundleId = app.identifier,
			let newBundleId = options.identifiers[currentBundleId]
		{
			options.appIdentifier = newBundleId
		}

		if
			let currentName = app.name,
			let newName = options.displayNames[currentName]
		{
			options.appName = newName
		}

		return options
	}

	/// Returns a copy with the single-app overrides cleared.
	///
	/// Batch signing uses this as its base. A globally pinned name, version or bundle identifier
	/// would otherwise be stamped onto every selected app, collapsing them onto one identifier
	/// and one display name. The `identifiers` / `displayNames` dictionaries are keyed by each
	/// app's own values, so they are left intact and keep resolving per app.
	var withoutExplicitAppOverrides: Options {
		var options = self
		options.appName = nil
		options.appVersion = nil
		options.appIdentifier = nil
		return options
	}
}
