import CodexBarCore
import Foundation

struct CodexBarCoreFetcher: Sendable {
  let providerSelector: String?
  let excludeSelector: String?
  let sourceOverride: String?

  func fetchSnapshots() async throws -> [ExportSnapshot] {
    let config = try CodexBarConfigLoader.load()
    let providers = try selectedProviders(config: config)
    let browserDetection = BrowserDetection()
    let usageFetcher = UsageFetcher()
    let claudeFetcher = ClaudeUsageFetcher(browserDetection: browserDetection)
    let environment = ProcessInfo.processInfo.environment

    var snapshots: [ExportSnapshot] = []
    snapshots.reserveCapacity(providers.count)

    for provider in providers {
      let providerConfig = config.providerConfig(for: provider)
      let selectedAccount = activeAccount(in: providerConfig)
      let sourceMode = try resolvedSourceMode(for: providerConfig)
      let fetchEnvironment = ProviderEnvironmentResolver.resolve(
        base: environment,
        provider: provider,
        config: providerConfig,
        selectedAccount: selectedAccount
      )
      let context = ProviderFetchContext(
        runtime: .cli,
        sourceMode: sourceMode,
        includeCredits: true,
        webTimeout: 60,
        webDebugDumpHTML: false,
        verbose: false,
        env: fetchEnvironment,
        settings: CoreSettingsFactory.make(
          provider: provider,
          config: providerConfig,
          account: selectedAccount
        ),
        fetcher: provider == .codex ? UsageFetcher(environment: fetchEnvironment) : usageFetcher,
        claudeFetcher: claudeFetcher,
        browserDetection: browserDetection,
        selectedTokenAccountID: selectedAccount?.id
      )

      do {
        let result = try await ProviderDescriptorRegistry.descriptor(for: provider).fetch(
          context: context)
        snapshots.append(
          ExportSnapshot(
            provider: provider,
            result: result,
            capturedAt: Date(),
            accountLabel: selectedAccount?.label
          ))
      } catch {
        throw ExportError.providerFetchFailed(
          provider: provider.rawValue,
          message: error.localizedDescription
        )
      }
    }

    return snapshots
  }

  private func selectedProviders(config: CodexBarConfig) throws -> [UsageProvider] {
    let excluded = try Self.excludedProviders(from: excludeSelector)

    guard let rawSelector = providerSelector?.trimmingCharacters(in: .whitespacesAndNewlines),
      !rawSelector.isEmpty
    else {
      return config.enabledProviders().filter { !excluded.contains($0) }
    }

    switch rawSelector.lowercased() {
    case "all":
      return UsageProvider.allCases.filter { !excluded.contains($0) }
    case "both":
      return [.codex, .claude].filter { !excluded.contains($0) }
    default:
      let provider = try Self.resolveProvider(rawSelector)
      return excluded.contains(provider) ? [] : [provider]
    }
  }

  static func excludedProviders(from selector: String?) throws -> Set<UsageProvider> {
    guard let selector else { return [] }
    var providers: Set<UsageProvider> = []
    for token in selector.split(separator: ",") {
      let name = token.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { continue }
      providers.insert(try Self.resolveProvider(name))
    }
    return providers
  }

  private static func resolveProvider(_ name: String) throws -> UsageProvider {
    if let provider = UsageProvider(rawValue: name) {
      return provider
    }
    if let provider = ProviderDescriptorRegistry.cliNameMap[name.lowercased()] {
      return provider
    }
    throw ExportError.invalidConfiguration("unknown CodexBar provider: \(name)")
  }

  private func resolvedSourceMode(for config: ProviderConfig?) throws -> ProviderSourceMode {
    let rawSource = sourceOverride ?? config?.source?.rawValue ?? ProviderSourceMode.auto.rawValue
    guard let source = ProviderSourceMode(rawValue: rawSource.lowercased()) else {
      throw ExportError.invalidConfiguration("source must be auto, web, cli, oauth, or api")
    }
    return source
  }

  private func activeAccount(in config: ProviderConfig?) -> ProviderTokenAccount? {
    guard let accounts = config?.tokenAccounts, !accounts.accounts.isEmpty else {
      return nil
    }
    return accounts.accounts[accounts.clampedActiveIndex()]
  }
}

private enum CoreSettingsFactory {
  static func make(
    provider: UsageProvider,
    config: ProviderConfig?,
    account: ProviderTokenAccount?
  ) -> ProviderSettingsSnapshot? {
    let cookieSettings = cookieSettings(provider: provider, config: config, account: account)

    switch provider {
    case .codex:
      return .make(
        codex: .init(
          usageDataSource: codexUsageDataSource(for: config?.source),
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader
        ))
    case .claude:
      return .make(
        claude: .init(
          usageDataSource: claudeUsageDataSource(for: config?.source),
          webExtrasEnabled: false,
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader,
          organizationID: account?.sanitizedOrganizationID
        ))
    case .cursor:
      return .make(
        cursor: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .opencode:
      return .make(
        opencode: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader,
          workspaceID: config?.sanitizedWorkspaceID))
    case .opencodego:
      return .make(
        opencodego: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader,
          workspaceID: config?.sanitizedWorkspaceID))
    case .alibaba:
      return .make(
        alibaba: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader,
          apiRegion: AlibabaCodingPlanAPIRegion(rawValue: config?.sanitizedRegion ?? "")
            ?? .international
        ))
    case .alibabatokenplan:
      return .make(
        alibabaTokenPlan: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader,
          apiRegion: AlibabaTokenPlanAPIRegion(rawValue: config?.sanitizedRegion ?? "")
            ?? .chinaMainland
        ))
    case .factory:
      return .make(
        factory: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .minimax:
      return .make(
        minimax: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader,
          apiRegion: MiniMaxAPIRegion(rawValue: config?.sanitizedRegion ?? "") ?? .global
        ))
    case .manus:
      return .make(
        manus: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .zai:
      return .make(
        zai: .init(
          apiRegion: ZaiAPIRegion(rawValue: config?.sanitizedRegion ?? "") ?? .global,
          usageScope: .personal, teamContext: nil))
    case .copilot:
      return .make(
        copilot: .init(
          apiToken: config?.sanitizedAPIKey,
          enterpriseHost: config?.sanitizedEnterpriseHost,
          budgetExtrasEnabled: config?.extrasEnabled ?? false,
          budgetCookieSource: cookieSettings.cookieSource,
          manualBudgetCookieHeader: cookieSettings.manualCookieHeader
        ))
    case .kilo:
      return .make(
        kilo: .init(
          usageDataSource: kiloUsageDataSource(for: config?.source),
          extrasEnabled: config?.extrasEnabled ?? false
        ))
    case .kimi:
      return .make(
        kimi: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .augment:
      return .make(
        augment: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .moonshot:
      return .make(
        moonshot: .init(
          region: MoonshotRegion(rawValue: config?.sanitizedRegion ?? "") ?? .international))
    case .amp:
      return .make(
        amp: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .t3chat:
      return .make(
        t3chat: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .devin:
      return .make(
        devin: .init(
          cookieSource: cookieSettings.cookieSource,
          manualBearerToken: cookieSettings.manualCookieHeader,
          organization: config?.sanitizedWorkspaceID
        ))
    case .commandcode:
      return .make(
        commandcode: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .ollama:
      return .make(
        ollama: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .jetbrains:
      return .make(jetbrains: .init(ideBasePath: nil))
    case .windsurf:
      return .make(
        windsurf: .init(
          usageDataSource: windsurfUsageDataSource(for: config?.source),
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader
        ))
    case .perplexity:
      return .make(
        perplexity: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .mimo:
      return .make(
        mimo: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .abacus:
      return .make(
        abacus: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .mistral:
      return .make(
        mistral: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .qoder:
      return .make(
        qoder: .init(
          cookieSource: cookieSettings.cookieSource,
          manualCookieHeader: cookieSettings.manualCookieHeader))
    case .stepfun:
      return .make(
        stepfun: .init(
          cookieSource: cookieSettings.cookieSource,
          manualToken: config?.sanitizedRegion ?? cookieSettings.manualCookieHeader ?? "",
          username: config?.sanitizedAPIKey ?? "",
          password: config?.sanitizedSecretKey ?? ""
        ))
    default:
      return nil
    }
  }

  private static func cookieSettings(
    provider: UsageProvider,
    config: ProviderConfig?,
    account: ProviderTokenAccount?
  ) -> ProviderSettingsSnapshot.CookieProviderSettings {
    let configuredSource: ProviderCookieSource =
      config?.cookieSource
      ?? (config?.sanitizedCookieHeader == nil ? .auto : .manual)
    return ProviderCookieSettingsResolver.resolve(
      provider: provider,
      configuredSource: configuredSource,
      configuredHeader: config?.sanitizedCookieHeader,
      selectedAccount: account
    )
  }

  private static func codexUsageDataSource(for source: ProviderSourceMode?) -> CodexUsageDataSource
  {
    switch source {
    case .oauth: .oauth
    case .cli: .cli
    default: .auto
    }
  }

  private static func claudeUsageDataSource(for source: ProviderSourceMode?)
    -> ClaudeUsageDataSource
  {
    switch source {
    case .api: .api
    case .oauth: .oauth
    default: .auto
    }
  }

  private static func kiloUsageDataSource(for source: ProviderSourceMode?) -> KiloUsageDataSource {
    switch source {
    case .api: .api
    case .cli: .cli
    default: .auto
    }
  }

  private static func windsurfUsageDataSource(for source: ProviderSourceMode?)
    -> WindsurfUsageDataSource
  {
    switch source {
    case .web: .web
    case .cli: .cli
    default: .auto
    }
  }
}
