import AppKit
import UniformTypeIdentifiers
import KongFetchCore

/// One thing that can be shown in the results list.
struct SearchResult: Equatable {
    var url: URL
    var displayName: String
    var fileName: String
    var contentType: String?
    var modified: Date?
    var size: Int?
    var score: Int

    var path: String { url.path }
    var isApplication: Bool { url.pathExtension.lowercased() == "app" || contentType == "com.apple.application-bundle" }
}

/// Runs Spotlight (NSMetadataQuery) name searches.
final class SpotlightSearch: NSObject {
    struct Hit {
        var path: String
        var displayName: String
        var fileName: String
        var contentType: String?
        var modified: Date?
        var size: Int?
        /// Spotlight's content relevance (0…1), only for content searches.
        var relevance: Double?
    }

    /// Spotlight can match hundreds of thousands of items for short queries; only this many are ranked.
    var maximumHits = 4000

    private var query: NSMetadataQuery?
    private var completion: (([Hit], Bool) -> Void)?

    /// Calls `completion` with partial results while gathering, then once with `finished == true`.
    func search(_ input: SearchQuery, content: Bool = false, completion: @escaping ([Hit], Bool) -> Void) {
        stop()
        guard let predicate = content ? Self.contentPredicate(for: input) : Self.predicate(for: input) else {
            completion([], true)
            return
        }
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.notificationBatchingInterval = 0.15
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(progress(_:)), name: .NSMetadataQueryGatheringProgress, object: query)
        center.addObserver(self, selector: #selector(finished(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        self.query = query
        self.completion = completion
        if !query.start() {
            stop()
            completion([], true)
        }
    }

    func stop() {
        if let query {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
        }
        query = nil
        completion = nil
    }

    @objc private func progress(_ note: Notification) {
        guard let query = note.object as? NSMetadataQuery, query === self.query else { return }
        completion?(collect(query), false)
    }

    @objc private func finished(_ note: Notification) {
        guard let query = note.object as? NSMetadataQuery, query === self.query else { return }
        let hits = collect(query)
        let completion = self.completion
        stop() // a one-shot search: no live updates needed
        completion?(hits, true)
    }

    private func collect(_ query: NSMetadataQuery) -> [Hit] {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let count = min(query.resultCount, maximumHits)
        var hits: [Hit] = []
        hits.reserveCapacity(count)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let fileName = item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent
            hits.append(Hit(path: path,
                            displayName: item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String ?? fileName,
                            fileName: fileName,
                            contentType: item.value(forAttribute: NSMetadataItemContentTypeKey) as? String,
                            modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                            size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.intValue,
                            relevance: (item.value(forAttribute: NSMetadataQueryResultContentRelevanceAttribute) as? NSNumber)?.doubleValue))
        }
        return hits
    }

    // MARK: Predicate

    static func predicate(for input: SearchQuery) -> NSPredicate? {
        var parts: [NSPredicate] = []
        let needles = input.nameNeedles
        // A single character matches far too much as a substring; use it as a prefix instead.
        let prefixOnly = needles.count == 1 && needles[0].count == 1 && input.extensions.isEmpty && input.kind == nil
        for needle in needles {
            let pattern = prefixOnly ? escape(needle) + "*" : "*" + escape(needle) + "*"
            parts.append(NSPredicate(format: "(%K LIKE[cd] %@) OR (%K LIKE[cd] %@)",
                                     NSMetadataItemFSNameKey, pattern, NSMetadataItemDisplayNameKey, pattern))
        }
        if !input.extensions.isEmpty {
            let options = input.extensions.map { NSPredicate(format: "%K LIKE[c] %@", NSMetadataItemFSNameKey, "*." + escape($0)) }
            parts.append(NSCompoundPredicate(orPredicateWithSubpredicates: options))
        }
        if let kind = input.kind {
            parts.append(kindPredicate(kind))
        }
        if let days = input.modifiedWithinDays {
            let since = Date().addingTimeInterval(-Double(days) * 86_400)
            parts.append(NSPredicate(format: "%K >= %@", NSMetadataItemFSContentChangeDateKey, since as NSDate))
        }
        // Exclusions are applied locally after the query.
        guard !parts.isEmpty else { return nil }
        return parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    /// Matches words in the file's text (or its name), like Finder's "contents" search.
    static func contentPredicate(for input: SearchQuery) -> NSPredicate? {
        let needles = input.nameNeedles.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return nil }
        var parts: [String] = []
        for needle in needles {
            let value = mdEscape(needle)
            parts.append("(kMDItemTextContent == \"\(value)*\"cdw || kMDItemDisplayName == \"*\(value)*\"cd)")
        }
        if !input.extensions.isEmpty {
            parts.append("(" + input.extensions.map { "kMDItemFSName == \"*.\(mdEscape($0))\"c" }.joined(separator: " || ") + ")")
        }
        if let kind = input.kind {
            parts.append(kindQuery(kind))
        }
        if let days = input.modifiedWithinDays {
            parts.append("kMDItemFSContentChangeDate >= $time.today(-\(days))")
        }
        return NSPredicate(fromMetadataQueryString: parts.joined(separator: " && "))
    }

    private static func kindQuery(_ kind: SearchQuery.Kind) -> String {
        switch kind {
        case .application: return "kMDItemContentType == \"com.apple.application-bundle\""
        case .folder: return "kMDItemContentType == \"public.folder\""
        case .pdf: return "kMDItemContentType == \"com.adobe.pdf\""
        case .image: return "kMDItemContentTypeTree == \"public.image\""
        case .video: return "kMDItemContentTypeTree == \"public.movie\""
        case .audio: return "kMDItemContentTypeTree == \"public.audio\""
        case .archive: return "kMDItemContentTypeTree == \"public.archive\""
        case .document:
            return "(kMDItemContentTypeTree == \"public.composite-content\" || kMDItemContentTypeTree == \"public.text\" || " +
                "kMDItemContentTypeTree == \"public.presentation\" || kMDItemContentTypeTree == \"public.spreadsheet\")"
        }
    }

    /// Escapes a value for a Spotlight query string literal.
    static func mdEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
    }

    private static func kindPredicate(_ kind: SearchQuery.Kind) -> NSPredicate {
        func type(_ uti: String) -> NSPredicate { NSPredicate(format: "%K == %@", NSMetadataItemContentTypeKey, uti) }
        func tree(_ uti: String) -> NSPredicate { NSPredicate(format: "%K == %@", NSMetadataItemContentTypeTreeKey, uti) }
        switch kind {
        case .application: return type("com.apple.application-bundle")
        case .folder: return type("public.folder")
        case .pdf: return type("com.adobe.pdf")
        case .image: return tree("public.image")
        case .video: return tree("public.movie")
        case .audio: return tree("public.audio")
        case .archive: return tree("public.archive")
        case .document:
            return NSCompoundPredicate(orPredicateWithSubpredicates: [tree("public.composite-content"), tree("public.text"),
                                                                      tree("public.presentation"), tree("public.spreadsheet")])
        }
    }

    /// Escapes the LIKE wildcards so names containing * or ? are matched literally.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
    }
}

/// Installed applications with their localized names and pinyin, for instant app launching.
final class ApplicationIndex {
    struct App {
        let url: URL
        let displayName: String
        let fileName: String
        let pinyin: PinyinForms?
    }

    private(set) var apps: [App] = []
    private var isRefreshing = false

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async {
            let found = Self.scan()
            DispatchQueue.main.async {
                self.apps = found
                self.isRefreshing = false
            }
        }
    }

    func matches(_ query: SearchQuery) -> [(App, Int)] {
        guard query.kind == nil || query.kind == .application, query.extensions.isEmpty, query.modifiedWithinDays == nil,
              !query.nameNeedles.isEmpty else { return [] }
        var result: [(App, Int)] = []
        for app in apps {
            guard query.passesExclusionsAndExtensions(app.fileName, alternateName: app.displayName) else { continue }
            let byName = [Ranker.nameScore(name: app.displayName, needles: query.nameNeedles),
                          Ranker.nameScore(name: app.fileName, needles: query.nameNeedles)].compactMap { $0 }.max()
            var score = byName
            if score == nil, let word = query.pinyinCandidate, let forms = app.pinyin {
                score = Ranker.pinyinScore(forms: forms, query: word)
            }
            if let score { result.append((app, score)) }
        }
        return result
    }

    private static func scan() -> [App] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     home + "/Applications", "/System/Library/CoreServices/Applications"]
        var seen = Set<String>()
        var apps: [App] = []
        func add(_ path: String) {
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard !seen.contains(resolved) else { return }
            seen.insert(resolved)
            let fileName = (path as NSString).lastPathComponent
            let display = (fm.displayName(atPath: path) as NSString).deletingPathExtension
            apps.append(App(url: URL(fileURLWithPath: path), displayName: display, fileName: fileName,
                            pinyin: Pinyin.forms(for: display)))
        }
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names where !name.hasPrefix(".") {
                let path = root + "/" + name
                if name.hasSuffix(".app") {
                    add(path)
                } else if root == "/Applications" || root == home + "/Applications" {
                    // One level of grouping folders, e.g. "/Applications/Microsoft Office".
                    var isDirectory: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                       let inner = try? fm.contentsOfDirectory(atPath: path) {
                        for innerName in inner where innerName.hasSuffix(".app") { add(path + "/" + innerName) }
                    }
                }
            }
        }
        return apps
    }
}

/// Combines Spotlight hits, installed apps and recently opened items into one ranked list.
final class FileSearchCoordinator {
    let spotlight = SpotlightSearch()
    let applications = ApplicationIndex()
    let recents: RecentItems
    let preferences: Preferences
    let pinyinIndex: NameIndex?
    let ocrStore: OCRStore?
    private var generation = 0

    init(recents: RecentItems, preferences: Preferences, pinyinIndex: NameIndex? = nil, ocrStore: OCRStore? = nil) {
        self.recents = recents
        self.preferences = preferences
        self.pinyinIndex = pinyinIndex
        self.ocrStore = ocrStore
        applications.refresh()
    }

    /// `update` is called on the main thread with the ranked list, possibly several times.
    /// `content` searches inside files (and their names) instead of names only.
    func search(_ text: String, content: Bool = false, update: @escaping ([SearchResult], _ finished: Bool) -> Void) {
        generation += 1
        let current = generation
        let query = SearchQuery.parse(text)
        guard !query.isEmpty, !content || !query.nameNeedles.isEmpty else {
            spotlight.stop()
            update([], true)
            return
        }
        let instant = content ? ocrCandidates(for: query) : localCandidates(for: query)
        update(rank(instant, spotlight: [], query: query, content: content), false)
        spotlight.search(query, content: content) { [weak self] hits, finished in
            guard let self, current == self.generation else { return }
            update(self.rank(instant, spotlight: hits, query: query, content: content), finished)
        }
    }

    func cancel() {
        generation += 1
        spotlight.stop()
    }

    /// Recently opened items, newest first, that still exist.
    func recentResults(limit: Int = 30) -> [SearchResult] {
        let fm = FileManager.default
        return recents.entries.prefix(limit * 2).compactMap { entry -> SearchResult? in
            guard fm.fileExists(atPath: entry.path) else { return nil }
            return makeResult(path: entry.path, score: 0)
        }.prefix(limit).map { $0 }
    }

    private func localCandidates(for query: SearchQuery) -> [SearchResult] {
        var results: [SearchResult] = []
        for (app, score) in applications.matches(query) {
            results.append(SearchResult(url: app.url, displayName: app.displayName, fileName: app.fileName,
                                        contentType: "com.apple.application-bundle", modified: nil, size: nil, score: score + 150))
        }
        // Pinyin: Spotlight cannot do it, so use KongFetch's own name index plus recently opened files.
        if let word = query.pinyinCandidate {
            var seen = Set<String>()
            let wantsFolders = query.kind == .folder
            let fileKinds: Set<SearchQuery.Kind?> = [nil, .folder, .application]
            if fileKinds.contains(query.kind), let index = pinyinIndex {
                let matches = index.matches(pinyin: word, limit: 200) { entry in
                    (!wantsFolders || entry.isDirectory) && query.passesExclusionsAndExtensions(entry.name)
                }
                for (entry, score) in matches where FileManager.default.fileExists(atPath: entry.path) {
                    if let result = makeResult(path: entry.path, score: score) {
                        results.append(result)
                        seen.insert(entry.path)
                    }
                }
            }
            for entry in recents.entries.prefix(200) where !seen.contains(entry.path) {
                let name = (entry.path as NSString).lastPathComponent
                guard query.passesExclusionsAndExtensions(name),
                      let forms = Pinyin.forms(for: Ranker.displayStem(name)),
                      let score = Ranker.pinyinScore(forms: forms, query: word),
                      FileManager.default.fileExists(atPath: entry.path) else { continue }
                if let result = makeResult(path: entry.path, score: score) { results.append(result) }
            }
        }
        return results
    }

    /// Scanned documents and images whose recognized text matches (content mode).
    private func ocrCandidates(for query: SearchQuery) -> [SearchResult] {
        guard let store = ocrStore else { return [] }
        let hits = store.search(query.nameNeedles, limit: 300) { path in
            let name = (path as NSString).lastPathComponent
            guard query.passesExclusionsAndExtensions(name) else { return false }
            let ext = (path as NSString).pathExtension.lowercased()
            switch query.kind {
            case nil: return true
            case .pdf?, .document?: return ext == "pdf"
            case .image?: return OCRService.imageExtensions.contains(ext)
            default: return false
            }
        }
        return hits.compactMap { hit in
            guard FileManager.default.fileExists(atPath: hit.path) else { return nil }
            let name = (hit.path as NSString).lastPathComponent
            let nameBonus = Ranker.nameScore(name: name, needles: query.nameNeedles).map { $0 / 3 } ?? 0
            return makeResult(path: hit.path, score: 450 + nameBonus)
        }
    }

    private func rank(_ local: [SearchResult], spotlight hits: [SpotlightSearch.Hit], query: SearchQuery, content: Bool) -> [SearchResult] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let excludedPrefixes = preferences.excludedPathPrefixes.map { ($0 as NSString).expandingTildeInPath }.filter { !$0.isEmpty }
        let hideLibrary = !preferences.includeLibraryFolders
        var byPath: [String: SearchResult] = [:]

        func allowed(_ path: String) -> Bool {
            if hideLibrary && Ranker.isSystemLocation(path, home: home) { return false }
            return !excludedPrefixes.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }

        for hit in hits where allowed(hit.path) {
            guard query.passesExclusionsAndExtensions(hit.fileName, alternateName: hit.displayName) else { continue }
            let nameMatch = [Ranker.nameScore(name: hit.displayName, needles: query.nameNeedles),
                             Ranker.nameScore(name: hit.fileName, needles: query.nameNeedles)].compactMap { $0 }.max()
            var score: Int
            if content {
                // Content matches: Spotlight's relevance, a bonus when the name matches too, and recent edits first.
                score = Int((hit.relevance ?? 0.5) * 600) + (nameMatch.map { $0 / 3 } ?? 0)
                if let modified = hit.modified {
                    let age = Date().timeIntervalSince(modified)
                    score += age < 30 * 86_400 ? 60 : (age < 365 * 86_400 ? 20 : 0)
                }
            } else {
                score = nameMatch ?? 0
            }
            score += recents.boost(for: hit.path) - Ranker.locationPenalty(path: hit.path, home: home)
            if !content && hit.contentType == "com.apple.application-bundle" && query.kind == nil {
                // Installed apps first; copies inside build folders and disk images barely count.
                let installed = ["/Applications/", "/System/Applications/", home + "/Applications/"].contains { hit.path.hasPrefix($0) }
                score += installed ? 200 : 20
            }
            byPath[hit.path] = SearchResult(url: URL(fileURLWithPath: hit.path), displayName: hit.displayName, fileName: hit.fileName,
                                            contentType: hit.contentType, modified: hit.modified, size: hit.size, score: score)
        }
        for var result in local where allowed(result.path) {
            result.score += recents.boost(for: result.path) - Ranker.locationPenalty(path: result.path, home: home)
            if let existing = byPath[result.path], existing.score >= result.score { continue }
            byPath[result.path] = result
        }
        return byPath.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }.prefix(300).map { $0 }
    }

    private func makeResult(path: String, score: Int) -> SearchResult? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .contentTypeKey, .localizedNameKey])
        let fileName = url.lastPathComponent
        let display = values?.localizedName.map { url.pathExtension == "app" ? ($0 as NSString).deletingPathExtension : $0 } ?? fileName
        return SearchResult(url: url, displayName: display, fileName: fileName, contentType: values?.contentType?.identifier,
                            modified: values?.contentModificationDate, size: values?.fileSize, score: score)
    }
}

extension Ranker {
    /// The visible part of a file name used for pinyin: no extension.
    static func displayStem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }
}
