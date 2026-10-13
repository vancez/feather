//
//  Server.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import Vapor
import NIOSSL
import NIOTLS
import SwiftUI
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	let port = Int.random(in: 4000...8000)
	private var _needsShutdown = false
	
	var packageUrl: URL?
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?

	/// Set when the local server never came up.
	///
	/// Initialization deliberately does not throw. Callers build one of these per queued app and
	/// have to report a failure and move on rather than crash, and a healthy-looking installer
	/// that silently serves nothing is worse than an explicit error. Non-nil means this instance
	/// is unusable.
	private(set) var startupError: Error?

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
		self.app = app
		self.viewModel = viewModel

		do {
			try _setup()
			try _configureRoutes()
			try _server?.server.start()
			_needsShutdown = true
		} catch {
			// A partially built Application still holds an event loop group, and `_needsShutdown`
			// is never set on this path, so nothing else would ever release it.
			_server?.shutdown()
			_server = nil
			startupError = error
		}
	}

	deinit {
		_shutdownServer()
	}

	/// Stops the local server and releases its event loop group.
	///
	/// Idempotent, and safe to call before `deinit` — `_needsShutdown` makes sure the shutdown
	/// is only ever performed once. Callers that build a server per app need this so the previous
	/// one lets go of its port before the next one is created.
	func shutdown() {
		_shutdownServer()
	}

	private func _setup() throws {
		// Deliberately not `try?`: swallowing this leaves `_server` nil, so the routes are never
		// bound and the installer reports `.ready` while serving nothing at all.
		self._server = try setupApp(port: port)
	}
		
	private func _configureRoutes() throws {
		_server?.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			switch req.url.path {
			case plistEndpoint.path:
				self._updateStatus(.sendingManifest)
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: installManifestData))
			case displayImageSmallEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageSmallData))
			case displayImageLargeEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageLargeData))
			case payloadEndpoint.path:
				guard let packageUrl = packageUrl else {
					return Response(status: .notFound)
				}
				
				self._updateStatus(.sendingPayload)
				
				return req.fileio.streamFile(
					at: packageUrl.path
				) { result in
					switch result {
					case .success:
						self._updateStatus(.installing)
					case .failure(let error):
						self._updateStatus(.broken(error))
					}

				}
			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			default:
				return Response(status: .notFound)
			}
		}
	}
	
	private func _shutdownServer() {
		guard _needsShutdown else { return }
		
		_needsShutdown = false
		_server?.server.shutdown()
		_server?.shutdown()
	}
	
	private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			self.viewModel.status = newStatus
		}
	}
		
	func getServerMethod() -> Int {
		UserDefaults.standard.integer(forKey: "Feather.serverMethod")
	}

	func getIPFix() -> Bool {
		UserDefaults.standard.bool(forKey: "Feather.ipFix")
	}
}

// MARK: - Extension: Creation
extension ServerInstaller {
	/// Builds a server, retrying with a fresh random port when a bind loses the race.
	///
	/// Ports are drawn at random from a shared range with nothing reserving them, so collisions
	/// are possible. A single install would only ever hit this by bad luck, but a queue builds
	/// one of these per app, which makes it worth handling rather than giving up on.
	static func make(
		app: AppInfoPresentable,
		viewModel: InstallerStatusViewModel,
		attempts: Int = 3
	) throws -> ServerInstaller {
		var lastError: Error?

		for _ in 0..<max(1, attempts) {
			let installer = ServerInstaller(app: app, viewModel: viewModel)

			if let error = installer.startupError {
				lastError = error
				continue
			}

			return installer
		}

		throw lastError ?? ServerInstallerError.portUnavailable
	}
}

enum ServerInstallerError: Error, LocalizedError {
	case portUnavailable

	var errorDescription: String? {
		switch self {
		case .portUnavailable: .localized("Unable to start the local install server.")
		}
	}
}
