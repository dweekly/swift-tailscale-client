// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import Foundation

/// What the `PeerDiagnostics` command was asked to do, parsed from its arguments.
///
/// With no arguments the command opens the window in fixture mode. `--print` and
/// `--snapshot` run without a window and exit.
public struct LaunchOptions: Sendable, Equatable {
  /// What to do after parsing.
  public enum Action: Sendable, Equatable {
    /// Open the window.
    case window
    /// Print the peers and one ping interpretation, then exit.
    case print
    /// Render the window's content in fixture mode to a PNG at `path`, then exit.
    case snapshot(path: String)
  }

  /// Light or dark rendering for `--snapshot`.
  public enum Appearance: String, Sendable, Equatable, CaseIterable {
    case light
    case dark
  }

  /// Why the arguments could not be used. Each description is one line for the terminal.
  public enum ParseError: Error, Equatable, CustomStringConvertible {
    case unknownArgument(String)
    case missingValue(String)
    case badAppearance(String)
    case conflictingModes
    case snapshotNeedsFixture
    case conflictingActions

    public var description: String {
      switch self {
      case .unknownArgument(let argument): return "unknown argument \(argument)"
      case .missingValue(let flag): return "\(flag) needs a value"
      case .badAppearance(let value): return "--appearance must be light or dark, not \(value)"
      case .conflictingModes: return "choose one of --fixture and --live"
      case .snapshotNeedsFixture: return "--snapshot renders fixture data only; drop --live"
      case .conflictingActions: return "choose one of --print and --snapshot"
      }
    }
  }

  /// The one-screen help text, also printed after a parse error.
  public static let usage = """
    usage: PeerDiagnostics [--fixture | --live] [--allow-app-store-discovery]
           PeerDiagnostics [--fixture | --live] --print [--allow-app-store-discovery]
           PeerDiagnostics --fixture --snapshot <file.png> [--appearance light|dark]

      (no action)   open the window; starts in fixture mode unless --live is given
      --print       print the peers and one ping result without a window, then exit
      --snapshot    render the window's content with fixture data to a PNG, then exit
    """

  /// What to do.
  public var action: Action
  /// Which data source to start with.
  public var mode: DiagnosticsMode
  /// Whether live discovery may look for the Mac App Store edition of Tailscale.
  public var allowMacOSAppStoreDiscovery: Bool
  /// Rendering appearance for ``Action/snapshot(path:)``; ignored otherwise.
  public var appearance: Appearance

  public init(
    action: Action = .window, mode: DiagnosticsMode = .fixture,
    allowMacOSAppStoreDiscovery: Bool = false, appearance: Appearance = .light
  ) {
    self.action = action
    self.mode = mode
    self.allowMacOSAppStoreDiscovery = allowMacOSAppStoreDiscovery
    self.appearance = appearance
  }

  /// Parses the arguments that follow the program name.
  ///
  /// Arguments that start with a single dash (such as `-NSDocumentRevisionsDebugMode YES`,
  /// which Xcode passes to apps it launches) are AppKit settings, not ours, and are skipped
  /// together with their value.
  public static func parse(_ arguments: [String]) throws -> LaunchOptions {
    var options = LaunchOptions()
    var sawFixture = false
    var sawLive = false
    var sawPrint = false
    var snapshotPath: String?
    var index = arguments.startIndex
    func value(after flag: String) throws -> String {
      let next = arguments.index(after: index)
      guard next < arguments.endIndex, !arguments[next].hasPrefix("--") else {
        throw ParseError.missingValue(flag)
      }
      index = next
      return arguments[next]
    }
    while index < arguments.endIndex {
      let argument = arguments[index]
      switch argument {
      case "--fixture": sawFixture = true
      case "--live": sawLive = true
      case "--print": sawPrint = true
      case "--allow-app-store-discovery": options.allowMacOSAppStoreDiscovery = true
      case "--snapshot": snapshotPath = try value(after: argument)
      case "--appearance":
        let raw = try value(after: argument)
        guard let appearance = Appearance(rawValue: raw) else {
          throw ParseError.badAppearance(raw)
        }
        options.appearance = appearance
      default:
        if argument.hasPrefix("-"), !argument.hasPrefix("--") {
          // An AppKit setting and, if present, its value.
          let next = arguments.index(after: index)
          if next < arguments.endIndex, !arguments[next].hasPrefix("-") { index = next }
        } else {
          throw ParseError.unknownArgument(argument)
        }
      }
      index = arguments.index(after: index)
    }
    if sawFixture && sawLive { throw ParseError.conflictingModes }
    if sawPrint && snapshotPath != nil { throw ParseError.conflictingActions }
    options.mode = sawLive ? .live : .fixture
    if let snapshotPath {
      if sawLive { throw ParseError.snapshotNeedsFixture }
      options.action = .snapshot(path: snapshotPath)
    } else if sawPrint {
      options.action = .print
    }
    return options
  }
}
