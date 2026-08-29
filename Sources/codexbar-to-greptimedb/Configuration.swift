import Foundation

struct Configuration: Sendable {
  let greptimeDBURL: URL
  let database: String
  let table: String
  let username: String?
  let password: String?
  let provider: String?
  let excludeProviders: String?
  let source: String?
  let pollInterval: TimeInterval?
  let exportTimeoutSeconds: TimeInterval
  let discordWebhookURL: URL?
  let showHelp: Bool

  static let defaultExportTimeoutSeconds: TimeInterval = 300

  static let usage = """
    Usage: codexbar-to-greptimedb [options]

    Fetches usage through CodexBarCore and appends normalized rows to GreptimeDB.
    The default is one-shot. Use --every-minute, --watch, or --interval-seconds to poll.

    Required:
      --greptime-url URL              GREPTIMEDB_URL

    GreptimeDB options:
      --database NAME                 GREPTIMEDB_DATABASE (default: public)
      --table NAME                    GREPTIMEDB_TABLE (default: llm_usage_snapshots)
      --username NAME                 GREPTIMEDB_USERNAME
      --password VALUE                GREPTIMEDB_PASSWORD

    CodexBarCore options:
      --provider ID                   CODEXBAR_PROVIDER (enabled providers by default)
      --exclude-providers IDS         CODEXBAR_EXCLUDE_PROVIDERS (comma-separated providers to skip)
      --source SOURCE                 CODEXBAR_SOURCE (auto, web, cli, oauth, api)

    Scheduling:
      --once                          Run once even when an interval environment variable is set.
      --watch, --every-minute         Poll every 60 seconds.
      --interval-seconds SECONDS      CODEXBAR_TO_GREPTIMEDB_INTERVAL_SECONDS
      --export-timeout-seconds SECONDS  CODEXBAR_TO_GREPTIMEDB_EXPORT_TIMEOUT_SECONDS (default: 300)

    Notifications (polling mode only):
      DISCORD_WEBHOOK_URL              Notify this Discord webhook when a usage window that was
                                        at 100% drops below 100% on a later poll.

    Other:
      -h, --help                      Show this help.

    Authentication uses HTTP Basic auth when both username and password are supplied.
    """

  static func parse(arguments: [String], environment: [String: String]) throws -> Configuration {
    var values: [String: String] = [:]
    var flagValues: Set<String> = []
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "-h", "--help", "--once", "--watch", "--every-minute":
        flagValues.insert(argument)
        index += 1
      case "--greptime-url", "--database", "--table", "--username", "--password", "--provider",
        "--exclude-providers", "--source", "--interval-seconds", "--export-timeout-seconds":
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
          throw ExportError.invalidConfiguration("\(argument) requires a value")
        }
        values[argument] = arguments[valueIndex]
        index += 2
      default:
        throw ExportError.invalidConfiguration("unknown option: \(argument)")
      }
    }

    let showHelp = flagValues.contains("-h") || flagValues.contains("--help")
    let greptimeURLString = values["--greptime-url"] ?? environment["GREPTIMEDB_URL"]
    let defaultURL = URL(string: "http://localhost:4000")!
    let greptimeDBURL: URL
    if showHelp {
      greptimeDBURL = URL(string: greptimeURLString ?? defaultURL.absoluteString) ?? defaultURL
    } else {
      guard let greptimeURLString, let parsedURL = URL(string: greptimeURLString),
        parsedURL.scheme != nil, parsedURL.host != nil
      else {
        throw ExportError.invalidConfiguration(
          "--greptime-url or GREPTIMEDB_URL must be an absolute HTTP(S) URL")
      }
      guard ["http", "https"].contains(parsedURL.scheme?.lowercased() ?? "") else {
        throw ExportError.invalidConfiguration("GreptimeDB URL must use http or https")
      }
      greptimeDBURL = parsedURL
    }

    let database = values["--database"] ?? environment["GREPTIMEDB_DATABASE"] ?? "public"
    let table = values["--table"] ?? environment["GREPTIMEDB_TABLE"] ?? "llm_usage_snapshots"
    guard isSQLIdentifier(database) else {
      throw ExportError.invalidConfiguration("database must be a simple SQL identifier")
    }
    guard isSQLIdentifier(table) else {
      throw ExportError.invalidConfiguration("table must be a simple SQL identifier")
    }

    let username = values["--username"] ?? environment["GREPTIMEDB_USERNAME"]
    let password = values["--password"] ?? environment["GREPTIMEDB_PASSWORD"]
    if (username == nil) != (password == nil) {
      throw ExportError.invalidConfiguration(
        "provide both GreptimeDB username and password for HTTP Basic authentication")
    }

    let interval: TimeInterval?
    if flagValues.contains("--once") {
      interval = nil
    } else if flagValues.contains("--watch") || flagValues.contains("--every-minute") {
      interval = 60
    } else if let rawInterval = values["--interval-seconds"]
      ?? environment["CODEXBAR_TO_GREPTIMEDB_INTERVAL_SECONDS"]
    {
      guard let seconds = TimeInterval(rawInterval), seconds > 0 else {
        throw ExportError.invalidConfiguration("poll interval must be a positive number of seconds")
      }
      interval = seconds
    } else {
      interval = nil
    }

    let exportTimeoutSeconds: TimeInterval
    if let rawTimeout = values["--export-timeout-seconds"]
      ?? environment["CODEXBAR_TO_GREPTIMEDB_EXPORT_TIMEOUT_SECONDS"]
    {
      guard let seconds = TimeInterval(rawTimeout), seconds > 0 else {
        throw ExportError.invalidConfiguration(
          "export timeout must be a positive number of seconds")
      }
      exportTimeoutSeconds = seconds
    } else {
      exportTimeoutSeconds = defaultExportTimeoutSeconds
    }

    let discordWebhookURL: URL?
    if showHelp {
      discordWebhookURL = nil
    } else if let rawWebhookURL = environment["DISCORD_WEBHOOK_URL"]?.trimmingCharacters(
      in: .whitespacesAndNewlines), !rawWebhookURL.isEmpty
    {
      guard let parsedURL = URL(string: rawWebhookURL), parsedURL.scheme != nil,
        parsedURL.host != nil,
        ["http", "https"].contains(parsedURL.scheme?.lowercased() ?? "")
      else {
        throw ExportError.invalidConfiguration(
          "DISCORD_WEBHOOK_URL must be an absolute HTTP(S) URL")
      }
      discordWebhookURL = parsedURL
    } else {
      discordWebhookURL = nil
    }

    return Configuration(
      greptimeDBURL: greptimeDBURL,
      database: database,
      table: table,
      username: username,
      password: password,
      provider: values["--provider"] ?? environment["CODEXBAR_PROVIDER"],
      excludeProviders: values["--exclude-providers"] ?? environment["CODEXBAR_EXCLUDE_PROVIDERS"],
      source: values["--source"] ?? environment["CODEXBAR_SOURCE"],
      pollInterval: interval,
      exportTimeoutSeconds: exportTimeoutSeconds,
      discordWebhookURL: discordWebhookURL,
      showHelp: showHelp
    )
  }

  private static func isSQLIdentifier(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first,
      CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first)
    else {
      return false
    }

    return value.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
    }
  }
}
