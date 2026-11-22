// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import PeerDiagnosticsCore
import SwiftUI

/// The whole window: peers on the left, the selected peer's ping result on the right, and
/// the data source and connection status above it.
///
/// The view only reads ``PeerDiagnosticsModel`` and calls its actions. Starting and
/// stopping the model belongs to whoever owns it (the app scene, or the snapshot), so this
/// view can be drawn from any state.
public struct PeerDiagnosticsView: View {
  @ObservedObject var model: PeerDiagnosticsModel
  /// The mode for which a first peer was already chosen, so the suggestion is made once
  /// per mode and never overrides what the user picked.
  @State private var suggestedForMode: DiagnosticsMode?

  public init(model: PeerDiagnosticsModel) {
    self.model = model
  }

  public var body: some View {
    NavigationSplitView {
      PeerListView(model: model)
        .navigationSplitViewColumnWidth(
          min: Layout.sidebarWidth.minimum, ideal: Layout.sidebarWidth.ideal,
          max: Layout.sidebarWidth.maximum)
    } detail: {
      VStack(alignment: .leading, spacing: 0) {
        SourceHeader(model: model)
        Divider()
        PeerDetailView(model: model)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .onAppear(perform: suggestPeerIfNeeded)
    .onChange(of: model.peers) { _ in suggestPeerIfNeeded() }
  }

  private func suggestPeerIfNeeded() {
    guard suggestedForMode != model.mode, model.selectedPeerID == nil else {
      if model.selectedPeerID != nil { suggestedForMode = model.mode }
      return
    }
    guard let id = model.suggestedPeerID() else { return }
    suggestedForMode = model.mode
    model.select(peerID: id)
  }
}

// MARK: - Sidebar

struct PeerListView: View {
  @ObservedObject var model: PeerDiagnosticsModel
  @Environment(\.timeZone) private var timeZone

  var body: some View {
    let selection = Binding<String?>(
      get: { model.selectedPeerID },
      set: { model.select(peerID: $0) })
    List(selection: selection) {
      Section("Peers") {
        ForEach(model.peers) { peer in
          PeerRow(peer: peer).tag(peer.id)
        }
      }
    }
    .listStyle(.sidebar)
    .overlay {
      if model.peers.isEmpty {
        Text(model.emptySelectionText.title)
          .foregroundStyle(.secondary)
      }
    }
    .safeAreaInset(edge: .bottom) {
      FreshnessLabel(subject: "Peer list", freshness: model.peerListFreshness)
        .font(.caption)
        .padding(.horizontal, Layout.boxPadding)
        .padding(.vertical, Layout.gridRowSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct PeerRow: View {
  let peer: PeerSummary

  var body: some View {
    HStack(spacing: Layout.gridRowSpacing) {
      // Filled for online, dashed outline for offline: the shape carries the meaning, the
      // color only reinforces it.
      Image(systemName: peer.isOnline ? "circle.fill" : "circle.dashed")
        .imageScale(.small)
        .foregroundStyle(peer.isOnline ? Color.green : Color.secondary)
        .accessibilityLabel(peer.isOnline ? "Online" : "Offline")
      VStack(alignment: .leading, spacing: Layout.lineSpacing) {
        Text(peer.name)
          .lineLimit(1)
        Text(peer.isOnline ? peer.operatingSystem ?? "" : "offline · \(peer.operatingSystem ?? "")")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Data source and connection

struct SourceHeader: View {
  @ObservedObject var model: PeerDiagnosticsModel

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.gridRowSpacing * 2) {
      HStack(alignment: .firstTextBaseline) {
        Picker("Data source", selection: modeBinding) {
          ForEach([DiagnosticsMode.fixture, .live], id: \.self) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        Spacer()
        ConnectionBadge(state: model.connection)
      }
      Text(model.mode.explanation)
        .font(.callout)
        .foregroundStyle(.secondary)
      if let summary = model.connectionSummary {
        Text("Source: \(summary)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      if case .unavailable(let reason) = model.connection {
        HStack(alignment: .firstTextBaseline) {
          Text(reason)
            .font(.callout)
          Spacer()
          Button("Retry", action: model.restart)
        }
      }
      VStack(alignment: .leading, spacing: Layout.lineSpacing) {
        Toggle("Also look for the Mac App Store edition of Tailscale", isOn: appStoreBinding)
          .toggleStyle(.checkbox)
        Text(
          "macOS may ask for permission to access another app’s data. "
            + "Applies the next time Live starts."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, Layout.detailPadding)
      }
    }
    .padding(Layout.detailPadding)
  }

  private var modeBinding: Binding<DiagnosticsMode> {
    Binding(get: { model.mode }, set: { model.switchMode(to: $0) })
  }

  private var appStoreBinding: Binding<Bool> {
    Binding(
      get: { model.allowMacOSAppStoreDiscovery },
      set: { model.allowMacOSAppStoreDiscovery = $0 })
  }
}

struct ConnectionBadge: View {
  let state: ConnectionState

  var body: some View {
    Label {
      Text(state.title)
    } icon: {
      Image(systemName: symbol).foregroundStyle(tint)
    }
    .font(.callout)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Connection: \(state.title)")
  }

  private var symbol: String {
    switch state {
    case .connected: return "checkmark.circle.fill"
    case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
    case .stopped: return "pause.circle"
    case .disconnected: return "bolt.horizontal.circle"
    case .unavailable: return "exclamationmark.triangle.fill"
    }
  }

  private var tint: Color {
    switch state {
    case .connected: return .green
    case .unavailable, .disconnected: return .orange
    default: return .secondary
    }
  }
}

/// "Peer list current as of 17:30:00", with a warning symbol when stale.
struct FreshnessLabel: View {
  let subject: String
  let freshness: Freshness
  @Environment(\.timeZone) private var timeZone

  var body: some View {
    Label {
      Text("\(subject) \(freshness.text(timeZone: timeZone))")
        .monospacedDigit()
    } icon: {
      Image(systemName: freshness.isStale ? "exclamationmark.triangle.fill" : "clock")
        .foregroundStyle(freshness.isStale ? Color.orange : Color.secondary)
    }
    .foregroundStyle(freshness.isStale ? Color.primary : Color.secondary)
    .fontWeight(freshness.isStale ? .semibold : .regular)
    .accessibilityElement(children: .combine)
  }
}
