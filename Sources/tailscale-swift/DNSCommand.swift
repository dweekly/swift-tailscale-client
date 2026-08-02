// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct DNSCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "dns",
    abstract: "DNS diagnostics: OS configuration and forwarder queries",
    subcommands: [DNSStatusCommand.self, DNSQueryCommand.self]
  )
}

struct DNSStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show the DNS configuration Tailscale has installed"
  )

  @Flag(name: [.short, .long], help: "Output raw JSON.")
  var json = false

  func run() async throws {
    let client = TailscaleClient()
    let config = try await client.dnsOSConfig()

    if json {
      try printJSON(config)
      return
    }

    let nameservers =
      config.nameservers.isEmpty ? "none" : config.nameservers.joined(separator: ", ")
    print("Nameservers: \(nameservers)")
    if !config.searchDomains.isEmpty {
      print("Search domains: \(config.searchDomains.joined(separator: ", "))")
    }
    if !config.matchDomains.isEmpty {
      print("Split-DNS match domains: \(config.matchDomains.joined(separator: ", "))")
    }
  }
}

struct DNSQueryCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "query",
    abstract: "Resolve a name through tailscaled's DNS forwarder"
  )

  @Argument(help: "DNS name to resolve (e.g., peer.tailnet.ts.net)")
  var name: String

  @Option(name: .shortAndLong, help: "Record type: A, AAAA, TXT, CNAME, SRV, NS, PTR, MX")
  var type: String = "A"

  @Flag(name: [.short, .long], help: "Output raw JSON (answer bytes are base64).")
  var json = false

  func run() async throws {
    let client = TailscaleClient()
    let response = try await client.dnsQuery(name: name, type: type)

    if json {
      try printJSON(response)
      return
    }

    print("Answer: \(response.bytes.count) bytes (RFC 1035 wire format)")
    if !response.resolvers.isEmpty {
      print("Resolvers:")
      for resolver in response.resolvers {
        var details = [resolver.address ?? "?"]
        if !resolver.bootstrapResolution.isEmpty {
          details.append("bootstrap: \(resolver.bootstrapResolution.joined(separator: ", "))")
        }
        if resolver.useWithExitNode { details.append("kept with exit node") }
        print("  \(details.joined(separator: "  "))")
      }
    }
  }
}
