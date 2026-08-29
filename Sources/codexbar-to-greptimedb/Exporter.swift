import Foundation

struct Exporter: Sendable {
  let configuration: Configuration

  @discardableResult
  func runOnce() async throws -> [ExportSnapshot] {
    let snapshots = try await CodexBarCoreFetcher(
      providerSelector: configuration.provider,
      excludeSelector: configuration.excludeProviders,
      sourceOverride: configuration.source
    ).fetchSnapshots()
    let writer = GreptimeDBWriter(configuration: configuration)
    try await writer.ensureTableExists()
    let rowCount = try await writer.insert(snapshots)

    let providers = Set(snapshots.map(\.provider)).sorted().joined(separator: ", ")
    print("saved \(rowCount) rows for \(snapshots.count) provider snapshot(s): \(providers)")
    return snapshots
  }
}
