import Foundation
import Network

/// Minimal HTTP/1.1 server on 127.0.0.1 — no dependencies (Network.framework).
/// Endpoints:
///   GET  /health  -> {"ok":true,...}
///   POST /events  -> AgentEvent JSON (object or array)
/// All mutable state is confined to `queue`.
final class EventServer: @unchecked Sendable {
    static let port: UInt16 = 47836

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agentdeck.eventserver")

    func start() {
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    NSLog("AgentDeck EventServer failed: \(error)")
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            NSLog("AgentDeck EventServer listening on 127.0.0.1:\(Self.port)")
        } catch {
            NSLog("AgentDeck EventServer start error: \(error)")
            MainActor.assumeIsolated {
                ErrorCenter.shared.post("EventServer の起動に失敗しました", detail: "\(error)")
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil {
                connection.cancel()
                return
            }
            if let request = ParsedRequest(from: buf) {
                self.respond(to: request, on: connection)
            } else {
                self.receive(connection, buffer: buf)
            }
        }
    }

    private func respond(to request: ParsedRequest, on connection: NWConnection) {
        // Async main hop: never block the server queue on the main thread
        // (hooks fire per agent turn; a slow main turn used to stall the
        // whole server and hang every client).
        let connection = connection
        routeAsync(request) { [connection] status, body in
            var head = "HTTP/1.1 \(status)\r\n"
            head += "Content-Type: application/json; charset=utf-8\r\n"
            head += "Content-Length: \(body.utf8.count)\r\n"
            head += "Access-Control-Allow-Origin: *\r\n"
            head += "Connection: close\r\n\r\n"
            var out = Data(head.utf8)
            out.append(Data(body.utf8))
            connection.send(content: out, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    @MainActor
    private func routeOnMain(_ request: ParsedRequest) -> (String, String) {
        let store = SessionStore.shared
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return ("200 OK", "{\"ok\":true,\"events\":\(store.eventCount),\"sessions\":\(store.sessions.count)}")
        case ("GET", "/debug/sessions"):
            struct DebugRow: Encodable {
                let key: String
                let agent: String
                let project: String
                let state: String
                let lastActivity: Date
                let title: String
            }
            let rows = store.sessions.map {
                DebugRow(
                    key: $0.key, agent: $0.agent, project: $0.project,
                    state: $0.state.rawValue, lastActivity: $0.lastActivity, title: $0.title)
            }
            let body = (try? JSONEncoder().encode(rows)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return ("200 OK", body)
        case ("POST", "/events"):
            let decoder = JSONDecoder()
            var applied = 0
            if let single = try? decoder.decode(AgentEvent.self, from: request.body) {
                store.apply(single)
                applied = 1
            } else if let many = try? decoder.decode([AgentEvent].self, from: request.body) {
                for e in many { store.apply(e) }
                applied = many.count
            } else {
                return ("400 Bad Request", "{\"ok\":false,\"error\":\"bad json\"}")
            }
            return ("200 OK", "{\"ok\":true,\"applied\":\(applied)}")
        default:
            return ("404 Not Found", "{\"ok\":false}")
        }
    }

    private func routeAsync(_ request: ParsedRequest, completion: @escaping @Sendable (String, String) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let (status, body) = self.routeOnMain(request)
                completion(status, body)
            }
        }
    }
}

private struct ParsedRequest {
    let method: String
    let path: String
    let body: Data

    init?(from data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let header = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 && kv[0].lowercased() == "content-length" {
                contentLength = Int(kv[1]) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        let available = data.count - data.distance(from: data.startIndex, to: bodyStart)
        guard available >= contentLength else { return nil }
        body = data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)]
    }
}
