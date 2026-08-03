// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct ServeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "serve",
    abstract: "Inspect the daemon's serve/Funnel configuration",
    subcommands: [ServeStatusCommand.self]
  )
}

struct ServeStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show what this node is serving (and what Funnel exposes)"
  )

  @Flag(name: [.short, .long], help: "Output raw JSON.")
  var json = false

  func run() async throws {
    let client = TailscaleClient()
    let config = try await client.serveConfig()

    if json {
      try printJSON(config)
      return
    }

    if config.isEmpty {
      print("No serve configuration.")
      return
    }
    if let etag = config.etag, !etag.isEmpty {
      print("ETag: \(etag)")
    }
    for (port, handler) in config.tcp.sorted(by: { $0.key < $1.key }) {
      var details: [String] = []
      if handler.https { details.append("HTTPS termination") }
      if handler.http { details.append("HTTP") }
      if let forward = handler.tcpForward { details.append("forward → \(forward)") }
      if let sni = handler.terminateTLS { details.append("TLS terminated for \(sni)") }
      print("TCP :\(port)  \(details.joined(separator: ", "))")
    }
    for (hostPort, web) in config.web.sorted(by: { $0.key < $1.key }) {
      print("Web \(hostPort)")
      for (mount, handler) in web.handlers.sorted(by: { $0.key < $1.key }) {
        let target: String
        if let proxy = handler.proxy {
          target = "proxy \(proxy)"
        } else if let path = handler.path {
          target = "serve \(path)"
        } else if let redirect = handler.redirect {
          target = "redirect \(redirect)"
        } else if handler.text != nil {
          target = "static text"
        } else {
          target = "?"
        }
        print("  \(mount) → \(target)")
      }
    }
    for (hostPort, allowed) in config.allowFunnel.sorted(by: { $0.key < $1.key }) where allowed {
      print("Funnel ON for \(hostPort) (exposed to the public internet)")
    }
    if !config.foreground.isEmpty {
      print("Foreground sessions: \(config.foreground.count)")
    }
  }
}

struct CertCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cert",
    abstract: "TLS certificates for this node's tailnet domains",
    subcommands: [CertDomainsCommand.self]
  )
}

struct CertDomainsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "domains",
    abstract: "List DNS names this node can obtain TLS certificates for"
  )

  @Flag(name: [.short, .long], help: "Output raw JSON.")
  var json = false

  func run() async throws {
    let client = TailscaleClient()
    let domains = try await client.certDomains()

    if json {
      try printJSON(domains)
      return
    }

    if domains.isEmpty {
      print("No cert domains (is HTTPS enabled for this tailnet?)")
      return
    }
    for domain in domains {
      print(domain)
    }
  }
}
