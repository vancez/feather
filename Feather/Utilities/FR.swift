//
//  FR.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation.NSURL
import UIKit.UIImage
import Zsign
import NimbleJSON
import AltSourceKit
import IDeviceSwift

enum FR {
	static func handlePackageFile(
		_ ipa: URL,
		download: Download? = nil,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = AppFileHandler(file: ipa, download: download)
			
			do {
				try await handler.copy()
				try await handler.extract()
				try await handler.move()
				try await handler.addToDatabase()
				try? await handler.clean()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	/// Signs `app`, yielding the uuid the signed copy was written under on success.
	static func signPackageFile(
		_ app: AppInfoPresentable,
		using options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		Task.detached {
			let handler = SigningHandler(app: app, options: options)
			handler.appCertificate = certificate
			handler.appIcon = icon

			do {
				try await handler.copy()
				try await handler.modify()
				try? await handler.clean()
				let uuid = handler.uuid
				await MainActor.run {
					completion(.success(uuid))
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(.failure(error))
				}
			}
		}
	}

	/// Wraps up a signing run that produced `producedUUID`.
	///
	/// The option reads as "delete your application after signing", so it applies to re-signs too:
	/// the previous copy is removed rather than left behind as a duplicate entry. The source is
	/// only ever deleted after the produced `Signed` row is visible, so a sign that threw on the
	/// way out leaves everything untouched.
	///
	/// Retiring the signed versions this one replaces happens here rather than on the download
	/// that came first — see ``Storage/removeSupersededSigned(identifier:version:keeping:sparing:)``.
	///
	/// - Parameter sparing: uuids belonging to apps the caller is still working with, which the
	///   cleanup must leave alone. A batch run passes its whole queue: it snapshots its sources
	///   up front, so a later item whose superseded copy was just removed would be signing a
	///   directory that no longer exists.
	static func finalizePostSigning(
		source: AppInfoPresentable,
		producedUUID: String,
		options: Options,
		sparing: [String] = []
	) {
		// The produced row is the only place that knows what was actually built: the
		// identifier may have been rewritten (PPQ protection, identifier rules) and the
		// version overridden, so both are read back off the artifact rather than assumed
		// from the source it was built out of.
		guard let produced = Storage.shared.getSignedApp(uuid: producedUUID) else { return }

		if
			options.post_deleteAppAfterSigned,
			producedUUID != source.uuid
		{
			Storage.shared.deleteApp(for: source)
		}

		if options.deleteOldVersions {
			// The source is spared explicitly rather than by version: re-signing an app
			// produces another copy of the version it already had, and whether that one is
			// kept is "Delete After Signing"'s call, not this option's.
			Storage.shared.removeSupersededSigned(
				identifier: produced.identifier,
				version: produced.version,
				keeping: producedUUID,
				sparing: [source.uuid].compactMap { $0 } + sparing
			)
		}
	}
	
	static func handleCertificateFiles(
		p12URL: URL,
		provisionURL: URL,
		p12Password: String,
		certificateName: String = "",
		isDefault: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = CertificateFileHandler(
				key: p12URL,
				provision: provisionURL,
				password: p12Password,
				nickname: certificateName.isEmpty ? nil : certificateName,
				isDefault: isDefault
			)
			
			do {
				try await handler.copy()
				try await handler.addToDatabase()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func checkPasswordForCertificate(
		for key: URL,
		with password: String,
		using provision: URL
	) -> Bool {
		defer {
			password_check_fix_WHAT_THE_FUCK_free(provision.path)
		}
		
		password_check_fix_WHAT_THE_FUCK(provision.path)
		
		if (!p12_password_check(key.path, password)) {
			return false
		}
		
		return true
	}
	
	static func movePairing(_ url: URL) {
		let fileManager = FileManager.default
		let dest = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")
		
		try? fileManager.removeFileIfNeeded(at: dest)
		
		try? fileManager.copyItem(at: url, to: dest)
		
		HeartbeatManager.shared.start(true)
	}
	
	static func downloadSSLCertificates(
		from urlString: String,
		completion: @escaping (Bool) -> Void
	) {
		let generator = UINotificationFeedbackGenerator()
		generator.prepare()
		
		NBFetchService().fetch(from: urlString) { (result: Result<ServerView.ServerPackModel, Error>) in
			switch result {
			case .success(let pack):
				do {
					try FileManager.forceWrite(content: pack.key, to: "server.pem")
					try FileManager.forceWrite(content: pack.cert, to: "server.crt")
					try FileManager.forceWrite(content: pack.info.domains.commonName, to: "commonName.txt")
					generator.notificationOccurred(.success)
					completion(true)
				} catch {
					completion(false)
				}
			case .failure(_):
				completion(false)
			}
		}
	}
	
	static func handleSource(
		_ urlString: String,
		competion: @escaping () -> Void
	) {
		guard let url = URL(string: urlString) else { return }
		
		NBFetchService().fetch<ASRepository>(from: url) { (result: Result<ASRepository, Error>) in
			switch result {
			case .success(let data):
				let id = data.id ?? url.absoluteString
				
				if !Storage.shared.sourceExists(id) {
					Storage.shared.addSource(url, repository: data, id: id) { _ in
						competion()
					}
				} else {
					DispatchQueue.main.async {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Repository already added."))
					}
				}
			case .failure(let error):
				DispatchQueue.main.async {
					UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
				}
			}
		}
	}
	
	static func exportCertificateAndOpenUrl(using template: String) {
		// Helper that performs the export for a given certificate
		func performExport(for certificate: CertificatePair) {
			guard
				let certificateKeyFile = Storage.shared.getFile(.certificate, from: certificate),
				let certificateKeyFileData = try? Data(contentsOf: certificateKeyFile)
			else {
				return
			}
			
			let base64encodedCert = certificateKeyFileData.base64EncodedString()
			
			var allowedQueryParamAndKey = NSCharacterSet.urlQueryAllowed
			allowedQueryParamAndKey.remove(charactersIn: ";/?:@&=+$, ")
			
			guard let encodedCert = base64encodedCert.addingPercentEncoding(withAllowedCharacters: allowedQueryParamAndKey) else {
				return
			}
			
			let urlStr = template
				.replacingOccurrences(of: "$(BASE64_CERT)", with: encodedCert)
				.replacingOccurrences(of: "$(PASSWORD)", with: certificate.password ?? "")
			
			guard let callbackUrl = URL(string: urlStr) else {
				return
			}
			
			UIApplication.shared.open(callbackUrl)
		}
		
		let certificates = Storage.shared.getAllCertificates()
		guard !certificates.isEmpty else { return }
		
		DispatchQueue.main.async {
			var selectionActions: [UIAlertAction] = []
			
			for cert in certificates {
				var title: String
				let decoded = Storage.shared.getProvisionFileDecoded(for: cert)
				
				title = cert.nickname ?? decoded?.Name ?? .localized("Unknown")
				
				if let getTaskAllow = decoded?.Entitlements?["get-task-allow"]?.value as? Bool, getTaskAllow == true {
					title = "🐞 \(title)"
				}
				
				let selectAction = UIAlertAction(title: title, style: .default) { _ in
					performExport(for: cert)
				}
				selectionActions.append(selectAction)
			}
			
			UIAlertController.showAlertWithCancel(
				title: .localized("Export Certificate"),
				message: .localized("Do you want to export your certificate to an external app? That app will be able to sign apps using your certificate."),
				style: .alert,
				actions: selectionActions
			)
		}
	}
}
