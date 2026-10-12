//
//  SourcesViewModel.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import Foundation
import AltSourceKit
import SwiftUI
import NimbleJSON

// MARK: - Class
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	private let _dataService = NBFetchService()
	
	@Published var isFinished = true
	@Published var sources: [AltSource: ASRepository] = [:]
	/// sources that are queued or currently being fetched
	@Published var loadingSources: Set<AltSource> = []
	
	/// fraction of `sources` that are done loading, `nil` when none of them are being fetched
	func progress(for sources: some Collection<AltSource>) -> Double? {
		guard !sources.isEmpty else { return nil }

		let pending = sources.reduce(into: 0) { count, source in
			if loadingSources.contains(source) { count += 1 }
		}

		guard pending > 0 else { return nil }
		return Double(sources.count - pending) / Double(sources.count)
	}

	@MainActor
	func fetchSources(_ sources: some Collection<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		guard isFinished else { return }
		
		// check if sources to be fetched are the same as before, if yes, return
		// also skip check if refresh is true
		if !refresh, sources.allSatisfy({ self.sources[$0] != nil }) { return }
		
		// isfinished is used to prevent multiple fetches at the same time
		isFinished = false
		
		let sourcesArray = Array(sources)
		loadingSources.formUnion(sourcesArray)
		
		for startIndex in stride(from: 0, to: sourcesArray.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, sourcesArray.count)
			let batch = sourcesArray[startIndex..<endIndex]
			
			await withTaskGroup(of: (AltSource, ASRepository?).self) { group in
				for source in batch {
					group.addTask {
						guard let url = source.sourceURL else {
							return (source, nil)
						}
						
						return await withCheckedContinuation { continuation in
							self._dataService.fetch(from: url) { (result: RepositoryDataHandler) in
								switch result {
								case .success(let repo):
									continuation.resume(returning: (source, repo))
								case .failure(_):
									continuation.resume(returning: (source, nil))
								}
							}
						}
					}
				}
				
				// merge in each result as it arrives, so sources that are already
				// loaded can be displayed without waiting on the rest of them
				for await (source, repo) in group {
					await MainActor.run {
						if let repo {
							self.sources[source] = repo
						}
						self.loadingSources.remove(source)
					}
				}
			}
		}
		
		loadingSources.removeAll()
		isFinished = true
	}
}
