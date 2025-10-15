import Foundation

public enum JobStatus: Int {
    case pending = 1
    case started = 2
    case success = 3
    case failure = 4
    case cancelled = 5
}

public struct DataFrame {
    public let headers: [String]
    public let rows: [[String]]
}

public enum RedashError: Error, LocalizedError {
    case httpError(Int, String)
    case apiMessage(String)
    case jobFailed(String)
    case timeout(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .httpError(let code, let body): return "HTTP error (\(code)): \(body)"
        case .apiMessage(let message): return message
        case .jobFailed(let message): return message
        case .timeout(let message): return message
        case .invalidResponse: return "Invalid response"
        }
    }
}

public final class Client {
    let endpoint: String
    let apiKey: String
    let urlSession: URLSession
    let defaultTimeout: TimeInterval
    let defaultQueryTimeout: TimeInterval

    public init(endpoint: String, apiKey: String, defaultTimeout: TimeInterval = 60, defaultQueryTimeout: TimeInterval = 300) {
        self.endpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        self.defaultTimeout = defaultTimeout
        self.defaultQueryTimeout = defaultQueryTimeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = defaultTimeout
        config.timeoutIntervalForResource = defaultQueryTimeout
        self.urlSession = URLSession(configuration: config)
    }

    public func query(queryId: Int, params: [String:String] = [:], maxAge: Int = 0) throws -> DataFrame {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<DataFrame, Error>!
        self.queryAsync(queryId: queryId, params: params, maxAge: maxAge) { res in
            result = res
            sem.signal()
        }
        sem.wait()
        switch result! {
        case .success(let df): return df
        case .failure(let err): throw err
        }
    }

    public func queryAsync(queryId: Int, params: [String:String] = [:], maxAge: Int = 0, completion: @escaping (Result<DataFrame, Error>) -> Void) {
        let uri = "\(endpoint)/api/queries/\(queryId)/results?api_key=\(apiKey)"
        let parameters = ["parameters": params, "max_age": maxAge] as [String : Any]
        guard let body = try? JSONSerialization.data(withJSONObject: parameters) else {
            return completion(.failure(RedashError.invalidResponse))
        }
        var req = URLRequest(url: URL(string: uri)!)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let task = urlSession.dataTask(with: req) { data, resp, err in
            if let err = err { return completion(.failure(err)) }
            guard let http = resp as? HTTPURLResponse, let data = data else {
                return completion(.failure(RedashError.invalidResponse))
            }
            if http.statusCode >= 400 {
                return completion(.failure(RedashError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return completion(.failure(RedashError.invalidResponse))
            }
            if let message = json["message"] as? String {
                return completion(.failure(RedashError.apiMessage(message)))
            }
            guard let job = json["job"] as? [String: Any] else {
                return completion(.failure(RedashError.invalidResponse))
            }
            let jobIdStr: String
            if let s = job["id"] as? String {
                jobIdStr = s
            } else if let n = job["id"] as? Int {
                jobIdStr = String(n)
            } else {
                return completion(.failure(RedashError.invalidResponse))
            }
            self.pollJob(jobId: jobIdStr, queryId: queryId, completion: completion)
        }
        task.resume()
    }

    private func pollJob(jobId: String, queryId: Int, completion: @escaping (Result<DataFrame, Error>) -> Void) {
        let start = Date()
        func check() {
            if Date().timeIntervalSince(start) > self.defaultQueryTimeout {
                return completion(.failure(RedashError.timeout("Query wait time exceeded \(Int(self.defaultQueryTimeout)) seconds")))
            }
            let url = URL(string: "\(endpoint)/api/jobs/\(jobId)?api_key=\(apiKey)")!
            let task = urlSession.dataTask(with: url) { data, resp, err in
                if let err = err { return completion(.failure(err)) }
                guard let http = resp as? HTTPURLResponse, let data = data else {
                    return completion(.failure(RedashError.invalidResponse))
                }
                if http.statusCode == 502 {
                    // 502 -> return empty
                    return completion(.success(DataFrame(headers: [], rows: [])))
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let job = (json["job"] as? [String: Any]),
                      let statusRaw = job["status"] as? Int,
                      let status = JobStatus(rawValue: statusRaw) else {
                    return completion(.failure(RedashError.invalidResponse))
                }
                switch status {
                case .pending, .started:
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { check() }
                case .failure:
                    let err = (job["error"] as? String) ?? "Query failed"
                    return completion(.failure(RedashError.jobFailed(err)))
                case .cancelled:
                    let err = (job["error"] as? String) ?? "Query cancelled"
                    return completion(.failure(RedashError.jobFailed(err)))
                case .success:
                    self.fetchResult(queryId: queryId, job: job, completion: completion)
                }
            }
            task.resume()
        }
        check()
    }

    private func fetchResult(queryId: Int, job: [String: Any], completion: @escaping (Result<DataFrame, Error>) -> Void) {
        let resultIdStr: String
        if let n = job["query_result_id"] as? Int { resultIdStr = String(n) }
        else if let s = job["query_result_id"] as? String { resultIdStr = s }
        else { return completion(.failure(RedashError.invalidResponse)) }
        let url = URL(string: "\(endpoint)/api/query_results/\(resultIdStr)?api_key=\(apiKey)")!
        let task = urlSession.dataTask(with: url) { data, resp, err in
            if let err = err { return completion(.failure(err)) }
            guard let http = resp as? HTTPURLResponse, let data = data else {
                return completion(.failure(RedashError.invalidResponse))
            }
            if http.statusCode == 502 {
                return completion(.failure(RedashError.httpError(http.statusCode, "Gateway error (502)")))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let queryResult = (json["query_result"] as? [String: Any]),
                  let dataObj = (queryResult["data"] as? [String: Any]),
                  let columns = dataObj["columns"] as? [[String: Any]],
                  let rowsAny = dataObj["rows"] as? [[String: Any]] else {
                return completion(.failure(RedashError.invalidResponse))
            }
            let headers = columns.compactMap { $0["name"] as? String }
            let rows = rowsAny.map { row -> [String] in
                headers.map { h in
                    if let v = row[h] { return String(describing: v) } else { return "" }
                }
            }
            completion(.success(DataFrame(headers: headers, rows: rows)))
        }
        task.resume()
    }

    // MARK: - Safe Query (offset/limit pagination)
    public func safeQuery(
        queryId: Int,
        baseParams: [String: String] = [:],
        maxAge: Int = 0,
        limit: Int = 10000,
        maxIter: Int = 100
    ) throws -> DataFrame {
        var headers: [String] = []
        var allRows: [[String]] = []
        if limit <= 0 {
            return try self.query(queryId: queryId, params: baseParams, maxAge: maxAge)
        }
        for batchIndex in 0..<maxIter {
            let startIndex = batchIndex * limit
            var params = baseParams
            params["offset_rows"] = String(startIndex)
            params["limit_rows"] = String(limit)
            let df = try self.query(queryId: queryId, params: params, maxAge: maxAge)
            if df.rows.isEmpty { break }
            if headers.isEmpty { headers = df.headers }
            allRows.append(contentsOf: df.rows)
            if df.rows.count < limit { break }
        }
        return DataFrame(headers: headers, rows: allRows)
    }

    // MARK: - Period limited query
    public func periodLimitedQuery(
        queryId: Int,
        startDate: String,
        endDate: String,
        interval: String,
        intervalMultiple: Int = 1,
        baseParams: [String: String] = [:],
        maxAge: Int = 0
    ) throws -> DataFrame {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: startDate), let end = formatter.date(from: endDate) else {
            throw RedashError.apiMessage("Invalid date format. Use yyyy-MM-dd")
        }
        let cal = Calendar(identifier: .gregorian)
        func add(_ d: Date) -> Date? {
            switch interval.lowercased() {
            case "day", "d":
                return cal.date(byAdding: .day, value: intervalMultiple, to: d)
            case "week", "w":
                return cal.date(byAdding: .weekOfYear, value: intervalMultiple, to: d)
            case "month", "m":
                return cal.date(byAdding: .month, value: intervalMultiple, to: d)
            case "quarter", "q":
                return cal.date(byAdding: .month, value: 3 * intervalMultiple, to: d)
            case "year", "y":
                return cal.date(byAdding: .year, value: intervalMultiple, to: d)
            default:
                return nil
            }
        }
        var current = start
        var headers: [String] = []
        var allRows: [[String]] = []
        while current <= end {
            guard let next = add(current) else { break }
            let nextMinusOne = cal.date(byAdding: .day, value: -1, to: next) ?? next
            let segmentEnd = min(nextMinusOne, end)
            var params = baseParams
            params["start_date"] = formatter.string(from: current)
            params["end_date"] = formatter.string(from: segmentEnd)
            let df = try self.query(queryId: queryId, params: params, maxAge: maxAge)
            if headers.isEmpty { headers = df.headers }
            if !df.rows.isEmpty { allRows.append(contentsOf: df.rows) }
            if next <= current { break }
            current = next
        }
        return DataFrame(headers: headers, rows: allRows)
    }
}

public enum CSVWriter {
    public static func write(rows: [[String]], headers: [String], to url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        defer { try? handle.close() }
        let headerLine = escape(headers).joined(separator: ",") + "\n"
        try handle.write(contentsOf: headerLine.data(using: .utf8)!)
        for row in rows {
            let line = escape(row).joined(separator: ",") + "\n"
            try handle.write(contentsOf: line.data(using: .utf8)!)
        }
    }

    private static func escape(_ fields: [String]) -> [String] {
        return fields.map { field in
            if field.contains(",") || field.contains("\n") || field.contains("\"") {
                let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            return field
        }
    }
}
