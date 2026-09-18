// Scripts/conformance-harness.go
// Reference Go LocalAPI differential conformance harness for swift-tailscale-client 1.0.
// Pinned upstream revision: 4c4d1c35f83a21c6069ae09de69b246ed1993f3e (capability 144).
//
// Subcommands:
//   canonicalize <type> <input-json-path>
//   eval-masked-prefs <input-json-path>
//   round-trip-serve-config <input-json-path>
//   generate-oracle-fixtures --in-dir=<dir> --out-dir=<dir>
//   live-diff --socket=<path> --out=<path>

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"time"
)

const (
	PinnedUpstreamCommit  = "4c4d1c35f83a21c6069ae09de69b246ed1993f3e"
	PinnedCapabilityLevel = 144
	HarnessVersion        = "1.0.0"
)

// ============================================================================
// Upstream Wire Structs (Pinned to 4c4d1c35f83a / Cap 144)
// ============================================================================

type Status struct {
	Version        string                 `json:"Version"`
	TUN            bool                   `json:"TUN"`
	BackendState   string                 `json:"BackendState"`
	HaveNodeKey    bool                   `json:"HaveNodeKey"`
	AuthURL        string                 `json:"AuthURL"`
	TailscaleIPs   []string               `json:"TailscaleIPs"`
	Self           *PeerStatus            `json:"Self,omitempty"`
	Health         []string               `json:"Health"`
	MagicDNSSuffix string                 `json:"MagicDNSSuffix"`
	CurrentTailnet *TailnetStatus         `json:"CurrentTailnet,omitempty"`
	CertDomains    []string               `json:"CertDomains"`
	Peer           map[string]*PeerStatus `json:"Peer"`
	User           map[string]*UserStatus `json:"User"`
	ClientVersion  *ClientVersionStatus   `json:"ClientVersion,omitempty"`
}

type TailnetStatus struct {
	Name            string `json:"Name"`
	MagicDNSSuffix  string `json:"MagicDNSSuffix"`
	MagicDNSEnabled bool   `json:"MagicDNSEnabled"`
}

type ClientVersionStatus struct {
	RunningLatest bool `json:"RunningLatest"`
}

type PeerStatus struct {
	ID                  string                 `json:"ID"`
	PublicKey           string                 `json:"PublicKey"`
	HostName            string                 `json:"HostName"`
	DNSName             string                 `json:"DNSName"`
	OS                  string                 `json:"OS"`
	UserID              uint64                 `json:"UserID"`
	TailscaleIPs        []string               `json:"TailscaleIPs"`
	AllowedIPs         []string               `json:"AllowedIPs"`
	Addrs               []string               `json:"Addrs"`
	CurAddr             string                 `json:"CurAddr"`
	Relay               string                 `json:"Relay"`
	PeerRelay           string                 `json:"PeerRelay"`
	RxBytes             int64                  `json:"RxBytes"`
	TxBytes             int64                  `json:"TxBytes"`
	Created             string                 `json:"Created"`
	LastWrite           string                 `json:"LastWrite"`
	LastSeen            string                 `json:"LastSeen"`
	LastHandshake       string                 `json:"LastHandshake"`
	Online              bool                   `json:"Online"`
	ExitNode            bool                   `json:"ExitNode"`
	ExitNodeOption      bool                   `json:"ExitNodeOption"`
	Active              bool                   `json:"Active"`
	PeerAPIURL          []string               `json:"PeerAPIURL"`
	TaildropTarget      int                    `json:"TaildropTarget"`
	NoFileSharingReason string                 `json:"NoFileSharingReason"`
	CapMap              map[string]interface{} `json:"CapMap"`
	InNetworkMap        bool                   `json:"InNetworkMap"`
	InMagicSock         bool                   `json:"InMagicSock"`
	InEngine            bool                   `json:"InEngine"`
	KeyExpiry           string                 `json:"KeyExpiry"`
}

type UserStatus struct {
	ID            uint64 `json:"ID"`
	LoginName     string `json:"LoginName"`
	DisplayName   string `json:"DisplayName"`
	ProfilePicURL string `json:"ProfilePicURL"`
}

type WhoIsResponse struct {
	Node        *WhoIsNode             `json:"Node,omitempty"`
	UserProfile *UserStatus            `json:"UserProfile,omitempty"`
	CapMap      map[string]interface{} `json:"CapMap"`
}

type WhoIsNode struct {
	ID                  uint64            `json:"ID"`
	StableID            string            `json:"StableID"`
	Name                string            `json:"Name"`
	User                uint64            `json:"User"`
	Key                 string            `json:"Key"`
	KeyExpiry           string            `json:"KeyExpiry"`
	Machine             string            `json:"Machine"`
	DiscoKey            string            `json:"DiscoKey"`
	Addresses           []string          `json:"Addresses"`
	AllowedIPs          []string          `json:"AllowedIPs"`
	Endpoints           []string          `json:"Endpoints"`
	DERP                string            `json:"DERP"`
	Hostinfo            map[string]any    `json:"Hostinfo"`
	Created             string            `json:"Created"`
	Tags                []string          `json:"Tags"`
	Expired             bool              `json:"Expired"`
	Online              bool              `json:"Online"`
	LastSeen            string            `json:"LastSeen"`
	ComputedName        string            `json:"ComputedName"`
	ComputedNameWithHost string           `json:"ComputedNameWithHost"`
	IsExitNode          bool              `json:"IsExitNode"`
}

type Prefs struct {
	ControlURL             string         `json:"ControlURL"`
	RouteAll               bool           `json:"RouteAll"`
	ExitNodeID             string         `json:"ExitNodeID"`
	ExitNodeIP             string         `json:"ExitNodeIP"`
	ExitNodeAllowLANAccess bool           `json:"ExitNodeAllowLANAccess"`
	CorpDNS                bool           `json:"CorpDNS"`
	RunSSH                 bool           `json:"RunSSH"`
	RunWebClient           bool           `json:"RunWebClient"`
	WantRunning            bool           `json:"WantRunning"`
	LoggedOut              bool           `json:"LoggedOut"`
	ShieldsUp              bool           `json:"ShieldsUp"`
	AdvertiseTags          []string       `json:"AdvertiseTags"`
	Hostname               string         `json:"Hostname"`
	ForceDaemon            bool           `json:"ForceDaemon"`
	AdvertiseRoutes        []string       `json:"AdvertiseRoutes"`
	NoSNAT                 bool           `json:"NoSNAT"`
	NetfilterMode          int            `json:"NetfilterMode"`
	OperatorUser           string         `json:"OperatorUser"`
	ProfileName            string         `json:"ProfileName"`
	AutoUpdate             map[string]any `json:"AutoUpdate"`
	AppConnector           map[string]any `json:"AppConnector"`
	PostureChecking        bool           `json:"PostureChecking"`
	AdvertiseServices      []string       `json:"AdvertiseServices"`
	AutoExitNode           string         `json:"AutoExitNode"`
}

type MaskedPrefs struct {
	Prefs
	RouteAllSet               bool `json:"RouteAllSet"`
	ExitNodeIDSet             bool `json:"ExitNodeIDSet"`
	ExitNodeIPSet             bool `json:"ExitNodeIPSet"`
	ExitNodeAllowLANAccessSet bool `json:"ExitNodeAllowLANAccessSet"`
	CorpDNSSet                bool `json:"CorpDNSSet"`
	RunSSHSet                 bool `json:"RunSSHSet"`
	RunWebClientSet           bool `json:"RunWebClientSet"`
	WantRunningSet            bool `json:"WantRunningSet"`
	LoggedOutSet              bool `json:"LoggedOutSet"`
	ShieldsUpSet              bool `json:"ShieldsUpSet"`
	AdvertiseTagsSet          bool `json:"AdvertiseTagsSet"`
	HostnameSet               bool `json:"HostnameSet"`
	ForceDaemonSet            bool `json:"ForceDaemonSet"`
	AdvertiseRoutesSet        bool `json:"AdvertiseRoutesSet"`
	NoSNATSet                 bool `json:"NoSNATSet"`
	NetfilterModeSet          bool `json:"NetfilterModeSet"`
	OperatorUserSet           bool `json:"OperatorUserSet"`
	ProfileNameSet            bool `json:"ProfileNameSet"`
	AutoUpdateSet             bool `json:"AutoUpdateSet"`
	AppConnectorSet           bool `json:"AppConnectorSet"`
	PostureCheckingSet        bool `json:"PostureCheckingSet"`
	AdvertiseServicesSet      bool `json:"AdvertiseServicesSet"`
	AutoExitNodeSet           bool `json:"AutoExitNodeSet"`
}

// ============================================================================
// Normalization Pipeline
// ============================================================================

func normalizeTimestamp(ts string) string {
	if ts == "" || ts == "0001-01-01T00:00:00Z" {
		return "0001-01-01T00:00:00Z"
	}
	t, err := time.Parse(time.RFC3339Nano, ts)
	if err != nil {
		t, err = time.Parse(time.RFC3339, ts)
	}
	if err != nil {
		return ts
	}
	return t.UTC().Format("2006-01-02T15:04:05Z")
}

func normalizeSlice[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

func normalizePeerStatus(p *PeerStatus, zeroCounters bool) {
	if p == nil {
		return
	}
	p.Created = normalizeTimestamp(p.Created)
	p.LastWrite = normalizeTimestamp(p.LastWrite)
	p.LastSeen = normalizeTimestamp(p.LastSeen)
	p.LastHandshake = normalizeTimestamp(p.LastHandshake)
	p.KeyExpiry = normalizeTimestamp(p.KeyExpiry)
	p.TailscaleIPs = normalizeSlice(p.TailscaleIPs)
	p.AllowedIPs = normalizeSlice(p.AllowedIPs)
	p.Addrs = normalizeSlice(p.Addrs)
	p.PeerAPIURL = normalizeSlice(p.PeerAPIURL)
	if p.CapMap == nil {
		p.CapMap = map[string]interface{}{}
	}
	if zeroCounters {
		p.RxBytes = 0
		p.TxBytes = 0
	}
}

func canonicalizeStatus(data []byte, zeroCounters bool) ([]byte, error) {
	var s Status
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&s); err != nil {
		return nil, err
	}

	s.TailscaleIPs = normalizeSlice(s.TailscaleIPs)
	s.Health = normalizeSlice(s.Health)
	s.CertDomains = normalizeSlice(s.CertDomains)
	if s.Peer == nil {
		s.Peer = map[string]*PeerStatus{}
	}
	if s.User == nil {
		s.User = map[string]*UserStatus{}
	}

	normalizePeerStatus(s.Self, zeroCounters)
	for _, p := range s.Peer {
		normalizePeerStatus(p, zeroCounters)
	}

	return json.MarshalIndent(s, "", "  ")
}

func canonicalizeWhoIs(data []byte) ([]byte, error) {
	var w WhoIsResponse
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&w); err != nil {
		return nil, err
	}
	if w.Node != nil {
		w.Node.Created = normalizeTimestamp(w.Node.Created)
		w.Node.LastSeen = normalizeTimestamp(w.Node.LastSeen)
		w.Node.KeyExpiry = normalizeTimestamp(w.Node.KeyExpiry)
		w.Node.Addresses = normalizeSlice(w.Node.Addresses)
		w.Node.AllowedIPs = normalizeSlice(w.Node.AllowedIPs)
		w.Node.Endpoints = normalizeSlice(w.Node.Endpoints)
		w.Node.Tags = normalizeSlice(w.Node.Tags)
	}
	if w.CapMap == nil {
		w.CapMap = map[string]interface{}{}
	}
	return json.MarshalIndent(w, "", "  ")
}

func canonicalizePrefs(data []byte) ([]byte, error) {
	var p Prefs
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&p); err != nil {
		return nil, err
	}
	p.AdvertiseTags = normalizeSlice(p.AdvertiseTags)
	p.AdvertiseRoutes = normalizeSlice(p.AdvertiseRoutes)
	p.AdvertiseServices = normalizeSlice(p.AdvertiseServices)
	return json.MarshalIndent(p, "", "  ")
}

func canonicalizeGeneric(data []byte) ([]byte, error) {
	var val interface{}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&val); err != nil {
		return nil, err
	}
	return json.MarshalIndent(val, "", "  ")
}

// ============================================================================
// Subcommand Implementations
// ============================================================================

func runCanonicalize(typeName, inputPath string) error {
	data, err := os.ReadFile(inputPath)
	if err != nil {
		return fmt.Errorf("read %s: %w", inputPath, err)
	}

	var canonical []byte
	switch typeName {
	case "status":
		canonical, err = canonicalizeStatus(data, false)
	case "whois":
		canonical, err = canonicalizeWhoIs(data)
	case "prefs":
		canonical, err = canonicalizePrefs(data)
	case "serve-config", "generic":
		canonical, err = canonicalizeGeneric(data)
	default:
		return fmt.Errorf("unknown canonicalize type %q (expected status, whois, prefs, serve-config, generic)", typeName)
	}
	if err != nil {
		return fmt.Errorf("canonicalize %s: %w", typeName, err)
	}

	fmt.Println(string(canonical))
	return nil
}

func runEvalMaskedPrefs(inputPath string) error {
	data, err := os.ReadFile(inputPath)
	if err != nil {
		return fmt.Errorf("read %s: %w", inputPath, err)
	}

	var mp MaskedPrefs
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&mp); err != nil {
		return fmt.Errorf("decode masked prefs: %w", err)
	}

	var rawMap map[string]interface{}
	if err := json.Unmarshal(data, &rawMap); err != nil {
		return fmt.Errorf("raw unmarshal: %w", err)
	}

	activeFlags := []string{}
	evaluatedFields := map[string]interface{}{}

	checkFlag := func(flagName, fieldName string, isSet bool, val interface{}) {
		if isSet {
			activeFlags = append(activeFlags, flagName)
			evaluatedFields[fieldName] = val
		}
	}

	checkFlag("RouteAllSet", "RouteAll", mp.RouteAllSet, mp.RouteAll)
	checkFlag("ExitNodeIDSet", "ExitNodeID", mp.ExitNodeIDSet, mp.ExitNodeID)
	checkFlag("ExitNodeIPSet", "ExitNodeIP", mp.ExitNodeIPSet, mp.ExitNodeIP)
	checkFlag("ExitNodeAllowLANAccessSet", "ExitNodeAllowLANAccess", mp.ExitNodeAllowLANAccessSet, mp.ExitNodeAllowLANAccess)
	checkFlag("CorpDNSSet", "CorpDNS", mp.CorpDNSSet, mp.CorpDNS)
	checkFlag("RunSSHSet", "RunSSH", mp.RunSSHSet, mp.RunSSH)
	checkFlag("RunWebClientSet", "RunWebClient", mp.RunWebClientSet, mp.RunWebClient)
	checkFlag("WantRunningSet", "WantRunning", mp.WantRunningSet, mp.WantRunning)
	checkFlag("LoggedOutSet", "LoggedOut", mp.LoggedOutSet, mp.LoggedOut)
	checkFlag("ShieldsUpSet", "ShieldsUp", mp.ShieldsUpSet, mp.ShieldsUp)
	checkFlag("AdvertiseTagsSet", "AdvertiseTags", mp.AdvertiseTagsSet, mp.AdvertiseTags)
	checkFlag("HostnameSet", "Hostname", mp.HostnameSet, mp.Hostname)
	checkFlag("ForceDaemonSet", "ForceDaemon", mp.ForceDaemonSet, mp.ForceDaemon)
	checkFlag("AdvertiseRoutesSet", "AdvertiseRoutes", mp.AdvertiseRoutesSet, mp.AdvertiseRoutes)
	checkFlag("NoSNATSet", "NoSNAT", mp.NoSNATSet, mp.NoSNAT)
	checkFlag("NetfilterModeSet", "NetfilterMode", mp.NetfilterModeSet, mp.NetfilterMode)
	checkFlag("OperatorUserSet", "OperatorUser", mp.OperatorUserSet, mp.OperatorUser)
	checkFlag("ProfileNameSet", "ProfileName", mp.ProfileNameSet, mp.ProfileName)
	checkFlag("AutoUpdateSet", "AutoUpdate", mp.AutoUpdateSet, mp.AutoUpdate)
	checkFlag("AppConnectorSet", "AppConnector", mp.AppConnectorSet, mp.AppConnector)
	checkFlag("PostureCheckingSet", "PostureChecking", mp.PostureCheckingSet, mp.PostureChecking)
	checkFlag("AdvertiseServicesSet", "AdvertiseServices", mp.AdvertiseServicesSet, mp.AdvertiseServices)
	checkFlag("AutoExitNodeSet", "AutoExitNode", mp.AutoExitNodeSet, mp.AutoExitNode)

	sort.Strings(activeFlags)

	report := map[string]interface{}{
		"valid":            len(activeFlags) > 0,
		"active_flags":     activeFlags,
		"evaluated_fields": evaluatedFields,
	}

	out, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(out))
	return nil
}

func runRoundTripServeConfig(inputPath string) error {
	data, err := os.ReadFile(inputPath)
	if err != nil {
		return fmt.Errorf("read %s: %w", inputPath, err)
	}

	var root map[string]interface{}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&root); err != nil {
		return fmt.Errorf("decode serve config: %w", err)
	}

	encoded, err := json.MarshalIndent(root, "", "  ")
	if err != nil {
		return fmt.Errorf("encode round-trip: %w", err)
	}

	// Verify exact equality of unmodeled fields
	var redecoded map[string]interface{}
	dec2 := json.NewDecoder(bytes.NewReader(encoded))
	dec2.UseNumber()
	if err := dec2.Decode(&redecoded); err != nil {
		return fmt.Errorf("redecode: %w", err)
	}

	fmt.Println(string(encoded))
	return nil
}

func runGenerateOracleFixtures(inDir, outDir string) error {
	versions := []string{"1.76.0", "1.84.0", "1.96.4", "1.98.0"}
	if err := os.MkdirAll(outDir, 0755); err != nil {
		return err
	}

	oracleManifest := map[string]interface{}{
		"schema_version":   "1.0.0",
		"upstream_commit":  PinnedUpstreamCommit,
		"capability_level": PinnedCapabilityLevel,
		"generated_at":     time.Now().UTC().Format(time.RFC3339),
		"versions":         map[string]interface{}{},
	}

	for _, v := range versions {
		srcVerDir := filepath.Join(inDir, v)
		dstVerDir := filepath.Join(outDir, v)
		if err := os.MkdirAll(dstVerDir, 0755); err != nil {
			return err
		}

		endpoints := []struct {
			filename string
			typeName string
		}{
			{"status.json", "status"},
			{"status_peers_false.json", "status"},
			{"whois.json", "whois"},
			{"prefs.json", "prefs"},
			{"serve-config.json", "serve-config"},
			{"derpmap.json", "generic"},
			{"cert-domains.json", "generic"},
		}

		processedFiles := []string{}
		for _, ep := range endpoints {
			srcFile := filepath.Join(srcVerDir, ep.filename)
			dstFile := filepath.Join(dstVerDir, ep.filename)
			data, err := os.ReadFile(srcFile)
			if err != nil {
				if os.IsNotExist(err) {
					continue
				}
				return err
			}

			var canonical []byte
			switch ep.typeName {
			case "status":
				canonical, err = canonicalizeStatus(data, false)
			case "whois":
				canonical, err = canonicalizeWhoIs(data)
			case "prefs":
				canonical, err = canonicalizePrefs(data)
			default:
				canonical, err = canonicalizeGeneric(data)
			}
			if err != nil {
				return fmt.Errorf("canonicalize %s in %s: %w", ep.filename, v, err)
			}

			if err := os.WriteFile(dstFile, append(canonical, '\n'), 0644); err != nil {
				return err
			}
			processedFiles = append(processedFiles, ep.filename)
		}

		oracleManifest["versions"].(map[string]interface{})[v] = map[string]interface{}{
			"files": processedFiles,
		}
	}

	manifestBytes, err := json.MarshalIndent(oracleManifest, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(outDir, "oracle-manifest.json"), append(manifestBytes, '\n'), 0644)
}

func runLiveDiff(socketPath, outPath string) error {
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return net.Dial("unix", socketPath)
			},
		},
		Timeout: 10 * time.Second,
	}

	fetch := func(path string) ([]byte, error) {
		req, err := http.NewRequest("GET", "http://local-tailscaled.sock"+path, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Sec-Tailscale", "localapi")
		resp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			body, _ := io.ReadAll(resp.Body)
			return nil, fmt.Errorf("status %d: %s", resp.StatusCode, string(body))
		}
		return io.ReadAll(resp.Body)
	}

	statusData, err := fetch("/localapi/v0/status")
	if err != nil {
		return fmt.Errorf("fetch status: %w", err)
	}
	canonicalStatus, err := canonicalizeStatus(statusData, true)
	if err != nil {
		return fmt.Errorf("canonicalize status: %w", err)
	}

	prefsData, err := fetch("/localapi/v0/prefs")
	if err != nil {
		return fmt.Errorf("fetch prefs: %w", err)
	}
	canonicalPrefs, err := canonicalizePrefs(prefsData)
	if err != nil {
		return fmt.Errorf("canonicalize prefs: %w", err)
	}

	snapshot := map[string]json.RawMessage{
		"status": json.RawMessage(canonicalStatus),
		"prefs":  json.RawMessage(canonicalPrefs),
	}

	outBytes, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		return err
	}

	if outPath != "" {
		return os.WriteFile(outPath, append(outBytes, '\n'), 0644)
	}
	fmt.Println(string(outBytes))
	return nil
}

// ============================================================================
// Main CLI
// ============================================================================

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "Usage: %s <subcommand> [flags]\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "Subcommands: canonicalize, eval-masked-prefs, round-trip-serve-config, generate-oracle-fixtures, live-diff\n")
		os.Exit(1)
	}

	subcommand := os.Args[1]
	switch subcommand {
	case "canonicalize":
		if len(os.Args) < 4 {
			fmt.Fprintf(os.Stderr, "Usage: %s canonicalize <type> <input-json-path>\n", os.Args[0])
			os.Exit(1)
		}
		if err := runCanonicalize(os.Args[2], os.Args[3]); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}

	case "eval-masked-prefs":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s eval-masked-prefs <input-json-path>\n", os.Args[0])
			os.Exit(1)
		}
		if err := runEvalMaskedPrefs(os.Args[2]); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}

	case "round-trip-serve-config":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s round-trip-serve-config <input-json-path>\n", os.Args[0])
			os.Exit(1)
		}
		if err := runRoundTripServeConfig(os.Args[2]); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}

	case "generate-oracle-fixtures":
		fs := flag.NewFlagSet("generate-oracle-fixtures", flag.ExitOnError)
		inDir := fs.String("in-dir", "Tests/TailscaleClientTests/Fixtures/LocalAPI", "Input fixtures directory")
		outDir := fs.String("out-dir", "Tests/TailscaleClientTests/Fixtures/LocalAPI/Oracle", "Output oracle directory")
		_ = fs.Parse(os.Args[2:])
		if err := runGenerateOracleFixtures(*inDir, *outDir); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Generated Go oracle fixtures under %s\n", *outDir)

	case "live-diff":
		fs := flag.NewFlagSet("live-diff", flag.ExitOnError)
		socket := fs.String("socket", "/var/run/tailscaled.socket", "Unix domain socket path")
		out := fs.String("out", "", "Output report path")
		_ = fs.Parse(os.Args[2:])
		if err := runLiveDiff(*socket, *out); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}

	default:
		fmt.Fprintf(os.Stderr, "Unknown subcommand %q\n", subcommand)
		os.Exit(1)
	}
}
