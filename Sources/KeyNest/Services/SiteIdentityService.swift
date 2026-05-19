import Darwin
import Foundation

/// 站点身份：域名 + 系统 DNS/hosts 解析到的 IP，用于区分同一域名指向不同测试环境。
enum SiteIdentityService {
    /// 与保管库、扩展一致：仅用主机名（域名或 IP，小写），不含路径、查询、端口。
    static func normalizedHost(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var s = t
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    static func resolveEndpointForUrl(_ raw: String) -> String? {
        guard let host = normalizedHost(raw) else { return nil }
        return resolveEndpointForHost(host)
    }

    static func resolveEndpointForHost(_ host: String) -> String? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(h, nil, &hints, &res)
        defer { if res != nil { freeaddrinfo(res) } }
        guard code == 0, let res else { return nil }
        var ptr: UnsafeMutablePointer<addrinfo>? = res
        while let node = ptr {
            if node.pointee.ai_family == AF_INET, let sa = node.pointee.ai_addr {
                var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    return String(cString: buf).lowercased()
                }
            }
            ptr = node.pointee.ai_next
        }
        return nil
    }

    private static func hostWithPort(_ raw: String) -> String? {
        guard let host = normalizedHost(raw) else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let h = url.host, !h.isEmpty else { return host }
        if let port = url.port, port != 443 && port != 80 {
            return "\(h.lowercased()):\(port)"
        }
        return host
    }

    static func getIdentityKey(url: String, siteEndpoint: String?, distinguishByIp: Bool) -> String? {
        guard let hostPart = hostWithPort(url) else { return nil }
        if !distinguishByIp { return hostPart }
        var ep = normalizeEndpoint(siteEndpoint)
        if ep == nil { ep = resolveEndpointForUrl(url) }
        if let ep, !ep.isEmpty { return "\(hostPart)@\(ep)" }
        return hostPart
    }

    static func normalizeEndpoint(_ endpoint: String?) -> String? {
        let t = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let t, !t.isEmpty else { return nil }
        return t
    }

    static func formatGroupTitle(_ identityKey: String?) -> String {
        guard let identityKey, !identityKey.isEmpty else { return "无网站" }
        guard let at = identityKey.lastIndex(of: "@"), at > identityKey.startIndex else {
            return identityKey
        }
        let next = identityKey.index(after: at)
        guard next < identityKey.endIndex else { return identityKey }
        let host = identityKey[..<at]
        let ep = identityKey[next...]
        return "\(host) · \(ep)"
    }

    static func formatSiteDisplay(url: String, siteEndpoint: String?, distinguishByIp: Bool) -> String {
        guard let hostPart = hostWithPort(url) else { return "" }
        if !distinguishByIp { return hostPart }
        if let ep = normalizeEndpoint(siteEndpoint), !ep.isEmpty {
            return "\(hostPart) (\(ep))"
        }
        return hostPart
    }

    static func contextsMatch(
        pageUrl: String,
        itemUrl: String,
        itemSiteEndpoint: String?,
        distinguishByIp: Bool,
        hostsMatch: (String, String) -> Bool
    ) -> Bool {
        guard let pageHost = normalizedHost(pageUrl),
              let itemHost = normalizedHost(itemUrl)
        else { return false }
        if !hostsMatch(pageHost, itemHost) { return false }
        if !distinguishByIp { return true }

        let pageEp = resolveEndpointForUrl(pageUrl)
        let itemEp = normalizeEndpoint(itemSiteEndpoint)
        if itemEp == nil { return true }
        guard let pageEp else { return false }
        return pageEp == itemEp
    }
}
