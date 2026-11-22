// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import PeerDiagnosticsCore
import SwiftUI

/// The selected peer and its latest ping result, or an empty state.
struct PeerDetailView: View {
  @ObservedObject var model: PeerDiagnosticsModel

  var body: some View {
    if let peer = model.selectedPeer {
      ScrollView {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
          PeerHeader(model: model, peer: peer)
          PingResultBox(model: model)
        }
        .padding(Layout.detailPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      let text = model.emptySelectionText
      EmptyState(
        symbol: model.peers.isEmpty ? "person.2.slash" : "sidebar.left",
        title: text.title, message: text.message)
    }
  }
}

struct PeerHeader: View {
  @ObservedObject var model: PeerDiagnosticsModel
  let peer: PeerSummary

  var body: some View {
    HStack(alignment: .center, spacing: Layout.sectionSpacing) {
      VStack(alignment: .leading, spacing: Layout.lineSpacing) {
        Text(peer.name)
          .font(.title2.weight(.semibold))
          .textSelection(.enabled)
        Text(peer.detailText)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .textSelection(.enabled)
        if !peer.isOnline {
          Label(
            "Reported offline, so a ping will probably go unanswered.", systemImage: "info.circle"
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button {
        model.pingSelectedPeer()
      } label: {
        Label("Ping", systemImage: "dot.radiowaves.left.and.right")
      }
      .controlSize(.large)
      .keyboardShortcut(.defaultAction)
      .disabled(!model.canPing)
      .accessibilityHint("Sends up to \(PingBurstPolicy.maximumPings) pings to \(peer.name)")
    }
  }
}

/// The last ping: how it travelled, how fast, when, after how many pings, and whether the
/// answer is still current.
struct PingResultBox: View {
  @ObservedObject var model: PeerDiagnosticsModel
  @Environment(\.timeZone) private var timeZone

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: Layout.boxPadding) {
        if let outcome = model.pingResult {
          resultView(outcome)
        } else if model.isPinging {
          progress(sent: 0)
        } else {
          Text(
            "Not pinged yet. Ping sends up to \(PingBurstPolicy.maximumPings) pings, one "
              + "second apart, and stops at the first direct reply."
          )
          .foregroundStyle(.secondary)
        }
      }
      .padding(Layout.boxPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Text("Last ping").font(.headline)
    }
  }

  @ViewBuilder
  private func resultView(_ outcome: PingOutcome) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Layout.gridColumnSpacing) {
      Label {
        Text(outcome.pathTitle)
      } icon: {
        Image(systemName: PathStyle.symbol(for: outcome))
          .foregroundStyle(PathStyle.tint(for: outcome))
      }
      .font(.title.weight(.semibold))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Path: \(outcome.pathTitle)")
      ConclusionBadge(outcome: outcome)
      Spacer()
    }

    Grid(
      alignment: .leadingFirstTextBaseline, horizontalSpacing: Layout.gridColumnSpacing,
      verticalSpacing: Layout.gridRowSpacing
    ) {
      if let latency = outcome.latencyText {
        row("Latency", latency)
      }
      if let endpoint = outcome.endpoint {
        row(endpoint.label, endpoint.value)
      }
      row("Measured at", DisplayTime.text(outcome.measuredAt, timeZone: timeZone))
      row("Pings sent", outcome.pingsSentText)
    }

    Text(outcome.summary)
      .textSelection(.enabled)

    if model.isPinging {
      progress(sent: outcome.pingsSent)
    } else {
      FreshnessLabel(subject: "This result is", freshness: model.pingFreshness)
        .font(.callout)
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      Text(value)
        .monospacedDigit()
        .textSelection(.enabled)
    }
    .accessibilityElement(children: .combine)
  }

  private func progress(sent: Int) -> some View {
    HStack(spacing: Layout.gridRowSpacing) {
      ProgressView().controlSize(.small)
      Text("Pinging… \(sent) of up to \(PingBurstPolicy.maximumPings) sent")
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

/// A capsule with the result's verdict: settled, one measurement, still pinging, or failed.
struct ConclusionBadge: View {
  let outcome: PingOutcome

  var body: some View {
    Text(outcome.conclusionTitle)
      .font(.callout.weight(.medium))
      .padding(.horizontal, Layout.badgePadding.horizontal)
      .padding(.vertical, Layout.badgePadding.vertical)
      .background(Capsule().fill(PathStyle.tint(for: outcome).opacity(Layout.badgeFillOpacity)))
      .overlay(
        Capsule().strokeBorder(PathStyle.tint(for: outcome).opacity(Layout.badgeStrokeOpacity))
      )
      .accessibilityLabel("Verdict: \(outcome.conclusionTitle)")
  }
}

/// Symbol and tint for each kind of result. The symbol and the title carry the meaning;
/// the tint only reinforces it.
enum PathStyle {
  static func symbol(for outcome: PingOutcome) -> String {
    switch outcome.reply {
    case .failure: return "xmark.octagon.fill"
    case .reply(.direct, _): return "arrow.left.and.right.circle.fill"
    case .reply(.peerRelay, _): return "point.3.connected.trianglepath.dotted"
    case .reply(.derp, _): return "server.rack"
    case .reply(.unknown, _): return "questionmark.circle.fill"
    }
  }

  static func tint(for outcome: PingOutcome) -> Color {
    if outcome.isSettledPath { return .green }
    switch outcome.reply {
    case .failure: return .red
    case .reply(.direct, _): return .green
    case .reply(.peerRelay, _), .reply(.derp, _): return .orange
    case .reply(.unknown, _): return .gray
    }
  }
}

struct EmptyState: View {
  let symbol: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: Layout.gridRowSpacing * 2) {
      Image(systemName: symbol)
        .font(.largeTitle)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(title).font(.title3.weight(.semibold))
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(Layout.detailPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
