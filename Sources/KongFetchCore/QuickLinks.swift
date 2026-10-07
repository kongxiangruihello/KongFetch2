import Foundation

/// A web search reached by typing its keyword and a space in the search window, e.g. "hd 仁".
public struct QuickLink: Codable, Equatable, Identifiable {
    public var id: UUID
    /// Short prefix typed before the query.
    public var keyword: String
    public var name: String
    /// URL with {query} where the search words go.
    public var template: String
    /// Offered when a file search finds nothing.
    public var fallback: Bool

    public init(id: UUID = UUID(), keyword: String, name: String, template: String, fallback: Bool = false) {
        self.id = id
        self.keyword = keyword
        self.name = name
        self.template = template
        self.fallback = fallback
    }

    /// The address for a query, or nil if the template is not a usable web address.
    public func url(for query: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = query.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let address = template.contains("{query}") ? template.replacingOccurrences(of: "{query}", with: encoded) : template + encoded
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            return nil
        }
        return url
    }
}

public enum QuickLinks {
    public static let defaults: [QuickLink] = [
        QuickLink(keyword: "g", name: "Google", template: "https://www.google.com/search?q={query}", fallback: true),
        QuickLink(keyword: "bd", name: "百度", template: "https://www.baidu.com/s?wd={query}", fallback: true),
        QuickLink(keyword: "hd", name: "汉典", template: "https://www.zdic.net/hans/{query}"),
        QuickLink(keyword: "ct", name: "中国哲学书电子化计划", template: "https://ctext.org/searchbooks.pl?if=gb&searchu={query}"),
        QuickLink(keyword: "zw", name: "知网", template: "https://kns.cnki.net/kns8s/defaultresult/index?korder=SU&kw={query}"),
        QuickLink(keyword: "db", name: "豆瓣读书", template: "https://search.douban.com/book/subject_search?search_text={query}"),
        QuickLink(keyword: "gs", name: "Google 学术", template: "https://scholar.google.com/scholar?q={query}"),
        QuickLink(keyword: "wk", name: "维基百科", template: "https://zh.wikipedia.org/w/index.php?search={query}"),
        QuickLink(keyword: "bk", name: "百度百科", template: "https://baike.baidu.com/item/{query}")
    ]

    /// Splits "hd 仁" into the link whose keyword is "hd" and the query "仁". Keywords ignore case.
    public static func match(_ text: String, in links: [QuickLink]) -> (link: QuickLink, query: String)? {
        let trimmed = text.drop { $0 == " " }
        guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\u{3000}" }) else { return nil }
        let keyword = trimmed[..<space].lowercased()
        let query = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty, !query.isEmpty,
              let link = links.first(where: { $0.keyword.lowercased() == keyword && !$0.keyword.isEmpty }) else { return nil }
        return (link, query)
    }
}
