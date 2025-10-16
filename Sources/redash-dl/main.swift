import ArgumentParser
import Foundation
import RedashClient

@main
struct RedashDL: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Redash downloader CLI (Swift)",
        subcommands: [Query.self, Safe.self, Period.self, Config.self],
        defaultSubcommand: Query.self
    )
}

struct Credentials: Codable {
    let endpoint: String
    let apikey: String
}

struct CredentialCache {
    private static let key = "lastCredentialsPath"

    static func store(_ path: String) {
        UserDefaults.standard.set(path, forKey: key)
    }

    static func load() -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

struct CommonOptions: ParsableArguments {
    @Option(name: [.short, .long], help: "Redash endpoint, e.g., https://redash.example.com")
    var endpoint: String?

    @Option(name: [.short, .long], help: "API key for Redash")
    var apikey: String?

    @Option(name: [.short, .long], help: "Path to credentials JSON {\"endpoint\":..., \"apikey\":...}")
    var credentials: String?

    @Option(name: [.short, .long], help: "Output file path. Default: ./redash_<id>.csv")
    var output: String?

    func loadCredentials() throws -> Credentials {
        if let credentialsPath = credentials {
            let url = URL(fileURLWithPath: credentialsPath)
            let data = try Data(contentsOf: url)
            let creds = try JSONDecoder().decode(Credentials.self, from: data)
            return creds
        }
        if let endpoint, let apikey {
            return Credentials(endpoint: endpoint, apikey: apikey)
        }
        if let cachedPath = CredentialCache.load(), FileManager.default.fileExists(atPath: cachedPath) {
            let url = URL(fileURLWithPath: cachedPath)
            let data = try Data(contentsOf: url)
            let creds = try JSONDecoder().decode(Credentials.self, from: data)
            return creds
        }
        throw ValidationError("Missing credentials. Provide --credentials or both --endpoint and --apikey")
    }
}

struct Query: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Run a Redash query and download result")

    @Option(name: [.customShort("i"), .long], help: "Query ID")
    var id: Int

    @Option(name: [.customShort("p"), .long], parsing: .unconditional, help: "Params JSON string")
    var params: String?

    @OptionGroup var common: CommonOptions

    func run() throws {
        let creds = try common.loadCredentials()
        let client = RedashClient.Client(endpoint: creds.endpoint, apiKey: creds.apikey)
        let parameters: [String:String] = {
            if let params = params {
                let data = Data(params.utf8)
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return dict.reduce(into: [:]) { acc, kv in acc[kv.key] = String(describing: kv.value) }
                }
            }
            return [:]
        }()
        let df = try client.query(queryId: id, params: parameters)
        let outPath = common.output ?? "redash_\(id).csv"
        try CSVWriter.write(rows: df.rows, headers: df.headers, to: URL(fileURLWithPath: outPath))
        FileHandle.standardError.write(Data("Wrote \(df.rows.count) rows to \(outPath)\n".utf8))
        if let path = common.credentials {
            CredentialCache.store(path)
        }
    }
}

struct Safe: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Run a paginated query (offset/limit)")

    @Option(name: [.customShort("i"), .long], help: "Query ID") var id: Int
    @Option(name: [.customShort("l"), .long], help: "Limit per page") var limit: Int = 10000
    @Option(name: [.customShort("n"), .long], help: "Max iterations") var maxiter: Int = 100
    @Option(name: [.customShort("p"), .long], parsing: .unconditional, help: "Params JSON string") var params: String?
    @Flag(name: [.long], help: "禁用进度显示")
    var noProgress: Bool = false
    @OptionGroup var common: CommonOptions

    func run() throws {
        let creds = try common.loadCredentials()
        let client = RedashClient.Client(endpoint: creds.endpoint, apiKey: creds.apikey)
        let baseParams: [String:String] = {
            if let params = params {
                let data = Data(params.utf8)
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return dict.reduce(into: [:]) { acc, kv in acc[kv.key] = String(describing: kv.value) }
                }
            }
            return [:]
        }()
        let df = try client.safeQuery(queryId: id, baseParams: baseParams, maxAge: 0, limit: limit, maxIter: maxiter, showProgress: !noProgress)
        let outPath = common.output ?? "redash_\(id)_safe.csv"
        try CSVWriter.write(rows: df.rows, headers: df.headers, to: URL(fileURLWithPath: outPath))
        FileHandle.standardError.write(Data("Wrote \(df.rows.count) rows to \(outPath)\n".utf8))
        if let path = common.credentials { CredentialCache.store(path) }
    }
}

struct Period: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Run a period-limited query")

    @Option(name: [.customShort("i"), .long], help: "Query ID") var id: Int
    @Option(name: [.customShort("s"), .long], help: "Start date yyyy-MM-dd") var start: String
    @Option(name: [.customShort("e"), .long], help: "End date yyyy-MM-dd") var end: String
    @Option(name: [.customShort("t"), .long], help: "Interval: d/w/m/q/y") var interval: String
    @Option(name: [.customShort("m"), .long], help: "Interval multiple") var mult: Int = 1
    @Option(name: [.customShort("p"), .long], parsing: .unconditional, help: "Params JSON string") var params: String?
    @Flag(name: [.long], help: "禁用进度显示")
    var noProgress: Bool = false
    @OptionGroup var common: CommonOptions

    func run() throws {
        let creds = try common.loadCredentials()
        let client = RedashClient.Client(endpoint: creds.endpoint, apiKey: creds.apikey)
        let baseParams: [String:String] = {
            if let params = params {
                let data = Data(params.utf8)
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return dict.reduce(into: [:]) { acc, kv in acc[kv.key] = String(describing: kv.value) }
                }
            }
            return [:]
        }()
        let df = try client.periodLimitedQuery(queryId: id, startDate: start, endDate: end, interval: interval, intervalMultiple: mult, baseParams: baseParams, maxAge: 0, showProgress: !noProgress)
        let outPath = common.output ?? "redash_\(id)_period.csv"
        try CSVWriter.write(rows: df.rows, headers: df.headers, to: URL(fileURLWithPath: outPath))
        FileHandle.standardError.write(Data("Wrote \(df.rows.count) rows to \(outPath)\n".utf8))
        if let path = common.credentials { CredentialCache.store(path) }
    }
}

struct Config: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Manage cached credentials",
        subcommands: [Show.self, Clear.self]
    )

    struct Show: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Show cached credentials path")
        func run() throws {
            if let p = CredentialCache.load() {
                print(p)
            } else {
                print("No cached credentials")
            }
        }
    }

    struct Clear: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Clear cached credentials")
        func run() throws {
            CredentialCache.clear()
            FileHandle.standardError.write(Data("Cached credentials cleared\n".utf8))
        }
    }
}
