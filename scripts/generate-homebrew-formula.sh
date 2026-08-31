#!/usr/bin/env bash
set -euo pipefail

: "${VERSION:?VERSION must be set to the release tag, for example v0.1.0}"
: "${REPOSITORY:?REPOSITORY must be set to the GitHub owner/repository}"
: "${MACOS_ARM64_SHA256:?MACOS_ARM64_SHA256 must be set}"
: "${MACOS_X86_64_SHA256:?MACOS_X86_64_SHA256 must be set}"
: "${OUTPUT:?OUTPUT must be set to the target Formula path}"

if [[ ! "$VERSION" =~ ^v[0-9][0-9A-Za-z.+-]*$ ]]; then
  printf 'error: VERSION must be a v-prefixed release version, got %q\n' "$VERSION" >&2
  exit 1
fi

if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  printf 'error: REPOSITORY must be a GitHub owner/repository, got %q\n' "$REPOSITORY" >&2
  exit 1
fi

for checksum_name in MACOS_ARM64_SHA256 MACOS_X86_64_SHA256; do
  checksum="${!checksum_name}"
  if [[ ! "$checksum" =~ ^[[:xdigit:]]{64}$ ]]; then
    printf 'error: %s must be a SHA-256 checksum, got %q\n' "$checksum_name" "$checksum" >&2
    exit 1
  fi
done

version="${VERSION#v}"
binary="codexbar-to-greptimedb"
app_name="CodexBarToGreptimeDB.app"
release_url="https://github.com/${REPOSITORY}/releases/download/${VERSION}"

mkdir -p "$(dirname "$OUTPUT")"
cat >"$OUTPUT" <<RUBY
class CodexbarToGreptimedb < Formula
  desc "Export CodexBar usage snapshots to GreptimeDB"
  homepage "https://github.com/${REPOSITORY}"
  version "${version}"
  license "Apache-2.0"
  depends_on :macos

  on_macos do
    depends_on macos: :sonoma
  end

  if Hardware::CPU.arm?
    url "${release_url}/${binary}-${version}-macos-arm64.tar.gz"
    sha256 "${MACOS_ARM64_SHA256}"
  elsif Hardware::CPU.intel?
    url "${release_url}/${binary}-${version}-macos-x86_64.tar.gz"
    sha256 "${MACOS_X86_64_SHA256}"
  end

  def install
    prefix.install "${app_name}"
    bin.write_exec_script prefix/"${app_name}/Contents/MacOS/${binary}"

    config = etc/"${binary}.env"
    unless config.exist?
      etc.mkpath
      config.write <<~EOS
        # Shell assignments exported to the Homebrew service.
        GREPTIMEDB_URL=http://localhost:4000
      EOS
    end
    config.chmod 0o600

    libexec.mkpath
    service_script = libexec/"${binary}-service"
    service_script.write <<~SH
      #!/bin/sh
      set -a
      . "#{config}"
      exec "#{opt_prefix}/${app_name}/Contents/MacOS/${binary}" --every-minute
    SH
    service_script.chmod 0755
  end

  service do
    run opt_libexec/"${binary}-service"
    environment_variables PATH: std_service_path_env
    log_path var/"log/${binary}.log"
    error_log_path var/"log/${binary}.log"
  end

  test do
    assert_match "--every-minute", shell_output("#{bin}/${binary} --help")
  end
end
RUBY
