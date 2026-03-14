import Foundation

final class HTTPServer {
    struct DraftUpdate {
        let text: String
        let remoteAddress: String
        let callbackPort: UInt16?
    }

    private var listenSocket: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "com.autopaste.httpserver", attributes: .concurrent)
    var autoSend = false
    var onPasteRequest: ((String, Bool) -> Void)?
    var onDraftUpdate: ((DraftUpdate) -> Void)?

    func start(port: UInt16) throws {
        listenSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard listenSocket >= 0 else { throw ServerError.socketCreation }

        var yes: Int32 = 1
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(listenSocket)
            throw ServerError.bindFailed(port)
        }

        guard listen(listenSocket, 5) == 0 else {
            close(listenSocket)
            throw ServerError.listenFailed
        }

        running = true

        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        running = false
        if listenSocket >= 0 {
            close(listenSocket)
            listenSocket = -1
        }
    }

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(listenSocket, sockPtr, &addrLen)
                }
            }
            guard clientFd >= 0 else { continue }

            queue.async { [weak self] in
                self?.handleClient(clientFd, clientAddr: clientAddr)
            }
        }
    }

    private func handleClient(_ fd: Int32, clientAddr: sockaddr_in) {
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = recv(fd, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return }

        let rawData = Data(buffer[0..<bytesRead])
        guard let raw = String(data: rawData, encoding: .utf8) else {
            sendResponse(fd: fd, status: 400, body: "{\"error\": \"invalid encoding\"}")
            return
        }

        guard raw.uppercased().hasPrefix("POST") else {
            sendResponse(fd: fd, status: 405, body: "{\"error\": \"method not allowed\"}")
            return
        }

        let requestLines = raw.components(separatedBy: "\r\n")
        guard let requestLine = requestLines.first else {
            sendResponse(fd: fd, status: 400, body: "{\"error\": \"malformed request\"}")
            return
        }

        let requestComponents = requestLine.components(separatedBy: " ")
        guard requestComponents.count >= 2 else {
            sendResponse(fd: fd, status: 400, body: "{\"error\": \"malformed request\"}")
            return
        }

        let path = requestComponents[1]

        guard let headerEnd = raw.range(of: "\r\n\r\n") else {
            sendResponse(fd: fd, status: 400, body: "{\"error\": \"malformed request\"}")
            return
        }

        let headerPart = String(raw[raw.startIndex..<headerEnd.lowerBound])
        var bodyString = String(raw[headerEnd.upperBound...])

        var contentLength = 0
        for line in headerPart.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(val) ?? 0
            }
        }

        let bodyBytes = bodyString.utf8.count
        if bodyBytes < contentLength {
            let remaining = contentLength - bodyBytes
            var extraBuf = [UInt8](repeating: 0, count: remaining)
            var totalExtra = 0
            while totalExtra < remaining {
                let n = extraBuf.withUnsafeMutableBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return 0 }
                    return recv(fd, base + totalExtra, remaining - totalExtra, 0)
                }
                if n <= 0 { break }
                totalExtra += n
            }
            if totalExtra > 0 {
                bodyString += String(data: Data(extraBuf[0..<totalExtra]), encoding: .utf8) ?? ""
            }
        }

        var contentType = ""
        for line in headerPart.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-type:") {
                contentType = line.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces).lowercased()
            }
        }

        var text = ""
        switch path {
        case "/":
            if contentType.contains("application/json") {
                guard let jsonData = bodyString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let t = json["text"] as? String else {
                    sendResponse(fd: fd, status: 400, body: "{\"error\": \"invalid json\"}")
                    return
                }
                text = t
            } else {
                text = bodyString
            }

            guard !text.isEmpty else {
                sendResponse(fd: fd, status: 400, body: "{\"error\": \"empty text\"}")
                return
            }

            let currentAutoSend = autoSend
            onPasteRequest?(text, currentAutoSend)
            sendResponse(fd: fd, status: 200, body: "{\"ok\": true}")

        case "/draft":
            guard contentType.contains("application/json"),
                  let jsonData = bodyString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let t = json["text"] as? String else {
                sendResponse(fd: fd, status: 400, body: "{\"error\": \"invalid json\"}")
                return
            }

            let callbackPort: UInt16?
            if let callbackPortNumber = json["callbackPort"] as? NSNumber {
                let value = callbackPortNumber.uint16Value
                callbackPort = value == 0 ? nil : value
            } else {
                callbackPort = nil
            }

            let update = DraftUpdate(
                text: t,
                remoteAddress: clientIPAddress(from: clientAddr),
                callbackPort: callbackPort
            )
            onDraftUpdate?(update)
            sendResponse(fd: fd, status: 200, body: "{\"ok\": true}")

        default:
            sendResponse(fd: fd, status: 404, body: "{\"error\": \"not found\"}")
        }
    }

    private func sendResponse(fd: Int32, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Error"
        }

        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = response.withCString { ptr in
            send(fd, ptr, strlen(ptr), 0)
        }
    }

    private func clientIPAddress(from addr: sockaddr_in) -> String {
        var addr = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return ""
        }
        return String(cString: buffer)
    }

    enum ServerError: Error, LocalizedError {
        case socketCreation
        case bindFailed(UInt16)
        case listenFailed

        var errorDescription: String? {
            switch self {
            case .socketCreation: return "Failed to create socket"
            case .bindFailed(let port): return "Failed to bind to port \(port)"
            case .listenFailed: return "Failed to listen on socket"
            }
        }
    }
}
