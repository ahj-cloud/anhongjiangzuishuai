import Foundation
import Darwin

// MARK: - 设备模型

struct DLNADevice: Identifiable, Hashable {
    let id: String              // UDN
    var name: String
    var location: URL
    var controlURL: URL?
    var serviceType: String
}

enum CastError: LocalizedError {
    case noDevice
    case badResponse(String)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .noDevice: return "没有找到可投屏的设备"
        case .badResponse(let s): return "设备拒绝：\(s)"
        case .unsupported: return "该设备不支持 AVTransport"
        }
    }
}

// MARK: - SSDP 发现

final class SSDPDiscovery {

    /// 阻塞式搜索，调用方放后台线程
    func search(timeout: TimeInterval = 4) -> [URL] {
        var locations: [URL] = []
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(1900).bigEndian
        target.sin_addr.s_addr = inet_addr("239.255.255.250")

        let messages = [
            "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n",
            "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n"
        ]

        for msg in messages {
            let bytes = Array(msg.utf8)
            _ = withUnsafePointer(to: &target) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 8192)

        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
                }
            }
            guard n > 0 else { continue }
            guard let text = String(bytes: buf[0..<n], encoding: .utf8) else { continue }
            for line in text.split(separator: "\r\n") {
                let l = line.lowercased()
                if l.hasPrefix("location:") {
                    let raw = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                    if let u = URL(string: raw), !locations.contains(u) { locations.append(u) }
                }
            }
        }
        return locations
    }

    // MARK: 设备描述

    func resolve(location: URL) -> DLNADevice? {
        guard let data = fetch(location) else { return nil }
        let parser = DescriptionParser()
        let xp = XMLParser(data: data)
        xp.delegate = parser
        xp.parse()

        let control = parser.services.first { $0.type.contains("AVTransport") }
        guard let ctrl = control ?? parser.services.first else { return nil }
        let ctrlURL = URL(string: ctrl.controlURL, relativeTo: location)?.absoluteURL

        return DLNADevice(
            id: parser.udn ?? location.absoluteString,
            name: parser.friendlyName ?? "未知设备",
            location: location,
            controlURL: ctrlURL,
            serviceType: ctrl.type
        )
    }

    private func fetch(_ url: URL) -> Data? {
        var out: Data?
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("Mozilla/5.0 (iPhone)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            out = data
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        return out
    }
}

private final class DescriptionParser: NSObject, XMLParserDelegate {
    struct Service { var type: String; var controlURL: String }

    var friendlyName: String?
    var udn: String?
    var services: [Service] = []

    private var current = ""
    private var buffer = ""
    private var pendingType = ""
    private var pendingControl = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        current = elementName
        buffer = ""
        if elementName == "service" {
            pendingType = ""
            pendingControl = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "friendlyName":
            if friendlyName == nil { friendlyName = value }
        case "UDN":
            if udn == nil { udn = value }
        case "serviceType":
            pendingType = value
        case "controlURL":
            pendingControl = value
        case "service":
            if !pendingType.isEmpty, !pendingControl.isEmpty {
                services.append(Service(type: pendingType, controlURL: pendingControl))
            }
        default:
            break
        }
        buffer = ""
    }
}

// MARK: - 投屏控制

@MainActor
final class CastService: ObservableObject {

    static let shared = CastService()

    @Published private(set) var devices: [DLNADevice] = []
    @Published private(set) var scanning = false
    @Published private(set) var connected: DLNADevice?
    @Published private(set) var lastError: String?

    private let discovery = SSDPDiscovery()

    func scan() async {
        scanning = true
        lastError = nil
        let locations = await Task.detached(priority: .userInitiated) { [discovery] in
            discovery.search(timeout: 4)
        }.value

        var found: [DLNADevice] = []
        for loc in locations {
            if let d = await Task.detached(priority: .userInitiated, operation: { [discovery] in
                discovery.resolve(location: loc)
            }).value {
                if !found.contains(where: { $0.id == d.id }) { found.append(d) }
            }
        }
        devices = found
        scanning = false
        if found.isEmpty { lastError = CastError.noDevice.errorDescription }
    }

    func cast(url: String, title: String, device: DLNADevice) async {
        guard let control = device.controlURL else {
            lastError = CastError.unsupported.errorDescription
            return
        }
        do {
            try await action(control: control, type: device.serviceType,
                             action: "SetAVTransportURI",
                             args: ["InstanceID": "0",
                                    "CurrentURI": url,
                                    "CurrentURIMetaData": didl(url: url, title: title)])
            try await action(control: control, type: device.serviceType,
                             action: "Play",
                             args: ["InstanceID": "0", "Speed": "1"])
            connected = device
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func stop() async {
        guard let d = connected, let control = d.controlURL else { return }
        _ = try? await action(control: control, type: d.serviceType,
                              action: "Stop", args: ["InstanceID": "0"])
        connected = nil
    }

    // MARK: SOAP

    private func action(control: URL, type: String, action: String,
                        args: [String: String]) async throws {
        let body = soapBody(type: type, action: action, args: args)
        var req = URLRequest(url: control, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(type)#\(action)\"", forHTTPHeaderField: "SOAPACTION")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw CastError.badResponse("HTTP \(code) \(text.prefix(120))")
        }
    }

    private func soapBody(type: String, action: String, args: [String: String]) -> String {
        let inner = args.map { "<\($0.key)>\(escape($0.value))</\($0.key)>" }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action) xmlns:u="\(type)">\(inner)</u:\(action)></s:Body>
        </s:Envelope>
        """
    }

    /// 电视端靠 DIDL 元数据识别标题与编码格式
    private func didl(url: String, title: String) -> String {
        let mime = url.contains(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4"
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
        <item id="1" parentID="0" restricted="1">
        <dc:title>\(escape(title))</dc:title>
        <upnp:class>object.item.videoItem</upnp:class>
        <res protocolInfo="http-get:*:\(mime):*">\(escape(url))</res>
        </item></DIDL-Lite>
        """
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
