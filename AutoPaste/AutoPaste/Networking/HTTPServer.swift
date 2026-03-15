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

        let separator = Data("\r\n\r\n".utf8)
        var requestData = Data()
        var headerRange: Range<Data.Index>?
        var contentLength = 0
        var headerPart = ""

        while true {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = recv(fd, &buffer, buffer.count, 0)
            guard bytesRead > 0 else { break }

            requestData.append(buffer, count: bytesRead)

            if headerRange == nil, let range = requestData.range(of: separator) {
                headerRange = range

                let headerData = requestData.subdata(in: 0..<range.lowerBound)
                guard let parsedHeader = String(data: headerData, encoding: .utf8) else {
                    sendResponse(fd: fd, status: 400, body: "{\"error\": \"invalid encoding\", \"hint\": \"Body must be valid UTF-8\"}")
                    return
                }
                headerPart = parsedHeader

                for line in headerPart.components(separatedBy: "\r\n") {
                    if line.lowercased().hasPrefix("content-length:") {
                        let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                        contentLength = Int(val) ?? 0
                    }
                }
            }

            if let headerRange {
                let bodyStart = headerRange.upperBound
                if requestData.count - bodyStart >= contentLength {
                    break
                }
            }
        }

        guard let headerRange else {
            sendResponse(fd: fd, status: 400, body: "{\"error\": \"malformed HTTP request\"}")
            return
        }

        let requestLines = headerPart.components(separatedBy: "\r\n")
        guard let requestLine = requestLines.first else {
            sendResponse(fd: fd, status: 400, body: "{\"error\": \"malformed HTTP request\"}")
            return
        }

        let requestComponents = requestLine.components(separatedBy: " ")
        guard requestComponents.count >= 2 else {
            sendResponse(fd: fd, status: 400, body: "{\"error\": \"malformed HTTP request\"}")
            return
        }

        let method = requestComponents[0].uppercased()
        let path = requestComponents[1]

        guard method == "POST" else {
            sendResponse(fd: fd, status: 405, body: "{\"error\": \"method not allowed\", \"hint\": \"Use POST\"}")
            return
        }

        let bodyStart = headerRange.upperBound
        guard requestData.count >= bodyStart + contentLength else {
            sendResponse(fd: fd, status: 400, body: "{\"error\": \"malformed HTTP request\"}")
            return
        }

        let bodyData = requestData.subdata(in: bodyStart..<(bodyStart + contentLength))

        var contentType = ""
        for line in headerPart.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-type:") {
                contentType = line.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces).lowercased()
            }
        }

        switch path {
        case "/":
            let text: String
            if contentType.contains("application/json") {
                guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                      let t = json["text"] as? String else {
                    sendResponse(fd: fd, status: 400, body: "{\"error\": \"invalid JSON body\", \"hint\": \"Send valid JSON with Content-Type: application/json\"}")
                    return
                }
                text = t
            } else {
                guard let plainText = String(data: bodyData, encoding: .utf8) else {
                    sendResponse(fd: fd, status: 400, body: "{\"error\": \"invalid encoding\", \"hint\": \"Body must be valid UTF-8\"}")
                    return
                }
                text = plainText
            }

            guard !text.isEmpty else {
                sendResponse(fd: fd, status: 400, body: "{\"error\": \"text is empty\", \"hint\": \"POST a non-empty text field\"}")
                return
            }

            let currentAutoSend = autoSend
            onPasteRequest?(text, currentAutoSend)
            sendResponse(fd: fd, status: 200, body: "{\"ok\": true}")

        case "/draft":
            guard contentType.contains("application/json"),
                  let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let t = json["text"] as? String else {
                sendResponse(fd: fd, status: 400, body: "{\"error\": \"invalid JSON body\", \"hint\": \"Send valid JSON with Content-Type: application/json\"}")
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
            sendResponse(fd: fd, status: 404, body: "{\"error\": \"not found\", \"hint\": \"POST to / or /draft\"}")
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
