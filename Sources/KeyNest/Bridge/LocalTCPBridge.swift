import Combine
import Foundation
import Network

/// 本机 HTTP 桥（默认 127.0.0.1:17373），供浏览器扩展通过 `fetch` 查询或写入凭据。
/// 仅在保管库解锁且桥接开启时监听；数据不出本机。
struct BridgeRequest: Codable {
    var url: String
}

struct BridgeCredential: Codable {
    var username: String
    var password: String
    var title: String
}

/// POST /api/save — 扩展在用户同意后写入一条账号密码
struct BridgeSavePayload: Codable {
    var title: String
    var url: String
    var username: String
    var password: String
}

@MainActor
final class LocalTCPBridge: ObservableObject {
    private var listener: NWListener?
    private weak var vault: VaultStore?

    func attach(vault: VaultStore) {
        self.vault = vault
    }

    func start(port: UInt16 = 17373) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: nwPort)
        } catch {
            NSLog("KeyNest bridge: cannot create listener — \(error)")
            return
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: DispatchQueue.main)
            Task { @MainActor in
                self.readHTTP(connection: conn, buffer: Data())
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                NSLog("KeyNest bridge listener failed: \(err)")
            }
        }
        listener.start(queue: DispatchQueue.main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func readHTTP(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                NSLog("KeyNest bridge receive error: \(error)")
                connection.cancel()
                return
            }
            var buf = buffer
            buf.append(data ?? Data())
            guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if buf.count > 512 * 1024 {
                    Task { @MainActor in
                        self.sendHTTP(connection: connection, status: 413, body: Data("payload too large".utf8), json: false)
                    }
                    return
                }
                Task { @MainActor in
                    self.readHTTP(connection: connection, buffer: buf)
                }
                return
            }

            let headerBytes = buf[..<sep.lowerBound]
            let afterHeaders = buf[sep.upperBound...]
            guard let headerText = String(data: Data(headerBytes), encoding: .utf8) else {
                Task { @MainActor in
                    self.sendHTTP(connection: connection, status: 400, body: nil, json: false)
                }
                return
            }

            let firstLine = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let contentLength = LocalTCPBridge.parseContentLength(headerText)

            if firstLine.hasPrefix("POST ") {
                let bodySoFar = Data(afterHeaders)
                if contentLength == 0 {
                    Task { @MainActor in
                        self.dispatchHTTP(connection: connection, headers: headerText, body: Data())
                    }
                    return
                }
                if bodySoFar.count >= contentLength {
                    Task { @MainActor in
                        self.dispatchHTTP(connection: connection, headers: headerText, body: bodySoFar.prefix(contentLength))
                    }
                    return
                }
                Task { @MainActor in
                    self.readHTTPBody(
                        connection: connection,
                        headers: headerText,
                        bodySoFar: bodySoFar,
                        contentLength: contentLength
                    )
                }
                return
            }

            Task { @MainActor in
                self.dispatchHTTP(connection: connection, headers: headerText, body: Data(afterHeaders))
            }
        }
    }

    private func readHTTPBody(connection: NWConnection, headers: String, bodySoFar: Data, contentLength: Int) {
        if bodySoFar.count >= contentLength {
            dispatchHTTP(connection: connection, headers: headers, body: bodySoFar.prefix(contentLength))
            return
        }
        let need = contentLength - bodySoFar.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: need + 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                NSLog("KeyNest bridge body error: \(error)")
                connection.cancel()
                return
            }
            var next = bodySoFar
            next.append(data ?? Data())
            Task { @MainActor in
                self.readHTTPBody(connection: connection, headers: headers, bodySoFar: next, contentLength: contentLength)
            }
        }
    }

    nonisolated private static func parseContentLength(_ headers: String) -> Int {
        for line in headers.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let rest = line.dropFirst("content-length:".count)
                return Int(rest.trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func dispatchHTTP(connection: NWConnection, headers: String, body: Data) {
        let firstLine = headers.split(separator: "\r\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""

        if firstLine.hasPrefix("OPTIONS ") {
            sendHTTP(connection: connection, status: 204, body: nil, json: false, corsOnly: true)
            return
        }

        if firstLine.hasPrefix("GET ") {
            let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else {
                sendHTTP(connection: connection, status: 400, body: nil, json: false)
                return
            }
            let pathAndQuery = String(parts[1])
            guard let u = URL(string: "http://127.0.0.1\(pathAndQuery)"),
                  let components = URLComponents(url: u, resolvingAgainstBaseURL: false),
                  let items = components.queryItems,
                  let pageURL = items.first(where: { $0.name == "url" })?.value
            else {
                sendHTTP(connection: connection, status: 400, body: Data(#"{"error":"missing url query"}"#.utf8), json: true)
                return
            }
            respondWithCredentials(connection: connection, pageURL: pageURL)
            return
        }

        if firstLine.hasPrefix("POST ") {
            let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else {
                sendHTTP(connection: connection, status: 400, body: nil, json: false)
                return
            }
            let rawPath = String(parts[1])
            let pathOnly = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
            if pathOnly == "/api/save" || pathOnly.hasSuffix("/api/save") {
                handleSave(connection: connection, body: body)
                return
            }
            sendHTTP(connection: connection, status: 404, body: Data(#"{"error":"unknown path"}"#.utf8), json: true)
            return
        }

        let trimmed = headers.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = trimmed.data(using: .utf8),
           let req = try? JSONDecoder().decode(BridgeRequest.self, from: d) {
            respondWithCredentials(connection: connection, pageURL: req.url)
            return
        }

        sendHTTP(connection: connection, status: 400, body: nil, json: false)
    }

    private func handleSave(connection: NWConnection, body: Data) {
        guard let vault else {
            sendHTTP(connection: connection, status: 503, body: Data(#"{"error":"vault not attached"}"#.utf8), json: true)
            return
        }
        guard vault.isUnlocked else {
            sendHTTP(connection: connection, status: 503, body: Data(#"{"error":"vault locked"}"#.utf8), json: true)
            return
        }
        guard let payload = try? JSONDecoder().decode(BridgeSavePayload.self, from: body) else {
            sendHTTP(connection: connection, status: 400, body: Data(#"{"error":"invalid json"}"#.utf8), json: true)
            return
        }
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlStr = payload.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = payload.username
        let password = payload.password
        guard !password.isEmpty else {
            sendHTTP(connection: connection, status: 400, body: Data(#"{"error":"empty password"}"#.utf8), json: true)
            return
        }
        let displayTitle = title.isEmpty ? (URL(string: urlStr)?.host ?? "未命名") : title
        if vault.shouldSkipBridgeSave(pageURL: urlStr, username: username, password: password) {
            sendHTTP(connection: connection, status: 200, body: Data(#"{"ok":true,"unchanged":true}"#.utf8), json: true)
            return
        }
        do {
            try vault.add(
                PasswordItem(
                    title: displayTitle,
                    username: username,
                    password: password,
                    url: urlStr
                ),
                pageURL: urlStr
            )
            sendHTTP(connection: connection, status: 200, body: Data(#"{"ok":true}"#.utf8), json: true)
        } catch {
            sendHTTP(connection: connection, status: 500, body: Data(#"{"error":"save failed"}"#.utf8), json: true)
        }
    }

    private func respondWithCredentials(connection: NWConnection, pageURL: String) {
        guard let vault else {
            sendHTTP(connection: connection, status: 503, body: Data(#"{"error":"vault not attached"}"#.utf8), json: true)
            return
        }
        guard vault.isUnlocked else {
            sendHTTP(connection: connection, status: 503, body: Data(#"{"error":"vault locked"}"#.utf8), json: true)
            return
        }
        let matches = vault.matches(forPageURL: pageURL)
        let payload = matches.map {
            BridgeCredential(username: $0.username, password: $0.password, title: $0.title)
        }
        guard let enc = try? JSONEncoder().encode(payload) else {
            sendHTTP(connection: connection, status: 500, body: nil, json: false)
            return
        }
        sendHTTP(connection: connection, status: 200, body: enc, json: true)
    }

    private func sendHTTP(
        connection: NWConnection,
        status: Int,
        body: Data?,
        json: Bool,
        corsOnly: Bool = false
    ) {
        var head = ""
        head += "HTTP/1.1 \(status) \(httpReason(status))\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: *\r\n"
        if corsOnly {
            head += "Content-Length: 0\r\n\r\n"
            connection.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        if let body {
            head += json ? "Content-Type: application/json; charset=utf-8\r\n" : "Content-Type: text/plain; charset=utf-8\r\n"
            head += "Content-Length: \(body.count)\r\n\r\n"
            let packet = head.data(using: .utf8)! + body
            connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
        } else {
            head += "Content-Length: 0\r\n\r\n"
            connection.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func httpReason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}
