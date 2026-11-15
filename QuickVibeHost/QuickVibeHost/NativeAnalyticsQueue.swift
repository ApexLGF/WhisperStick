import Foundation

/// 仅此会话拥有统计网络出口；拒绝所有重定向（包括同域），不使用共享 Cookie、缓存或后台会话。
final class AnalyticsSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class NativeAnalyticsQueue {
    static let endpoint = URL(string: "https://vibeeverything.cc/api/app-analytics/batch")!
    static func allows(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "vibeeverything.cc" && (url.port == nil || url.port == 443)
            && url.path == "/api/app-analytics/batch" && url.query == nil && url.fragment == nil
            && url.user == nil && url.password == nil
    }
    struct Event: Codable {
        let id: String
        let payload: Data
    }
    private struct State: Codable {
        var events: [Event] = []
        var hours: [String: [String: Int]] = [:]
    }
    private let file: URL
    private let condition = NSCondition()
    private let delegate = AnalyticsSessionDelegate()
    private let session: URLSession
    private var state = State()
    private var enabled = false
    private var generation = 0
    private var task: URLSessionDataTask?
    private var retryScheduled = false
    private var failures = 0
    private var acknowledged = Set<String>()
    private let retryBase: TimeInterval

    init(file: URL, configuration: URLSessionConfiguration = .ephemeral, retryBase: TimeInterval = 2) {
        self.file = file
        self.retryBase = retryBase
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        // 不读取、不迁移旧 SDK 磁盘队列。新格式损坏时废弃，不把未知负载发出。
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        }
    }

    private func persist(_ next: State) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            state = next
            return true
        } catch { return false }
    }

    func setEnabled(_ value: Bool) {
        condition.lock(); defer { condition.unlock() }
        generation += 1
        task?.cancel(); task = nil
        retryScheduled = false; failures = 0
        enabled = value
        if !value {
            state = State()
            if !persist(state) { try? FileManager.default.removeItem(at: file) }
            acknowledged.removeAll()
        }
        condition.broadcast()
        if value { startLocked() }
    }

    @discardableResult
    func enqueue(event: String, identity: String, properties: [String: Any], id: String = UUID().uuidString) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard enabled, state.events.count < 10_000,
              let entry = makeEvent(event, identity, properties, id) else { return false }
        var next = state
        if !next.events.contains(where: { $0.id == id }) { next.events.append(entry) }
        guard persist(next) else { return false }
        startLocked()
        return true
    }

    private func makeEvent(_ event: String, _ identity: String, _ properties: [String: Any], _ id: String) -> Event? {
        let body: [String: Any] = ["event": event, "distinct_id": identity, "uuid": id,
                                  "timestamp": ISO8601DateFormatter().string(from: Date()), "properties": properties]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        return Event(id: id, payload: data)
    }

    /// 计数与待发事件共用一次原子文件替换，避免小时计数清零与入队之间丢失或重复。
    func record(bucket: String, counters: [String: Int]) {
        condition.lock(); defer { condition.unlock() }
        guard enabled else { return }
        var next = state
        for (key, delta) in counters where delta > 0 {
            next.hours[bucket, default: [:]][key, default: 0] += delta
        }
        _ = persist(next)
    }

    func flushHours(except current: String? = nil, identity: String, properties: [String: Any]) {
        condition.lock(); defer { condition.unlock() }
        guard enabled else { return }
        var next = state
        for bucket in state.hours.keys.sorted() where bucket != current && next.events.count < 10_000 {
            var props = properties
            props["hour_bucket"] = bucket
            for (key, value) in state.hours[bucket] ?? [:] { props[key] = value }
            guard let event = makeEvent("app_hourly_stats", identity, props, UUID().uuidString) else { continue }
            next.events.append(event)
            next.hours.removeValue(forKey: bucket)
        }
        if persist(next) { startLocked() }
    }

    func waitForDrain(timeout: TimeInterval, acknowledged id: String? = nil) -> Bool {
        condition.lock(); defer { condition.unlock() }
        startLocked()
        let deadline = Date().addingTimeInterval(timeout)
        while enabled && (!state.events.isEmpty || task != nil) && Date() < deadline {
            _ = condition.wait(until: deadline)
        }
        return id.map { acknowledged.contains($0) } ?? state.events.isEmpty
    }

    func stop() {
        condition.lock(); defer { condition.unlock() }
        enabled = false; generation += 1
        task?.cancel(); task = nil
        condition.broadcast()
        session.invalidateAndCancel()
    }

    private func startLocked() {
        guard enabled, task == nil, !retryScheduled, !state.events.isEmpty,
              Self.allows(Self.endpoint) else { return }
        let batch = Array(state.events.prefix(50))
        let values = batch.compactMap { try? JSONSerialization.jsonObject(with: $0.payload) }
        guard values.count == batch.count,
              let body = try? JSONSerialization.data(withJSONObject: ["api_key": AnalyticsConfig.projectToken, "batch": values]) else { return }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let epoch = generation
        task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.condition.lock(); defer { self.condition.unlock() }
            guard self.enabled, epoch == self.generation else { return }
            self.task = nil
            let http = response as? HTTPURLResponse
            let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let success = error == nil && http?.url.map(Self.allows) == true && http?.statusCode == 200
                && (reply?["status"] as? Int) == 1 && (reply?["accepted"] as? Int).map { (0...batch.count).contains($0) } == true
            // 4xx（408/429 除外）是永久拒绝，删除这一批避免毒事件永久堵塞；诊断不会把删除误判为成功。
            let code = http?.statusCode ?? 0
            let permanent = error == nil && (400...499).contains(code) && code != 408 && code != 429
            if success || permanent {
                var next = self.state
                let ids = Set(batch.map(\.id))
                next.events.removeAll { ids.contains($0.id) }
                if self.persist(next) {
                    if success { self.acknowledged = ids }
                    self.failures = 0
                    self.condition.broadcast()
                    self.startLocked()
                    return
                }
            }
            self.failures += 1
            self.retryScheduled = true
            let backoff = min(300, self.retryBase * pow(2, Double(min(self.failures - 1, 8))))
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
            let delay = max(backoff, min(3600, max(0, retryAfter)))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.condition.lock(); defer { self.condition.unlock() }
                guard self.enabled, epoch == self.generation else { return }
                self.retryScheduled = false
                self.startLocked()
            }
            self.condition.broadcast()
        }
        task?.resume()
    }
}
