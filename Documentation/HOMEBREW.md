# Homebrew Distribution

`tailscale-swift` ships as a Homebrew formula in the personal tap
[`dweekly/homebrew-tap`](https://github.com/dweekly/homebrew-tap), building the
executable product from the release tag. homebrew-core is a post-1.0
aspiration once the notability bar is met (see `ROADMAP.md`).

## User installation

```bash
brew tap dweekly/tap
brew install tailscale-swift
```

## Maintainer: setting up the tap (one-time)

1. Create the repository `dweekly/homebrew-tap` (public). Homebrew maps
   `brew tap dweekly/tap` to that repository name automatically.
2. Add `Formula/tailscale-swift.rb` from the template below.

## Maintainer: per-release update

After tagging `vX.Y.Z` (see `RELEASING.md`):

```bash
# Compute the tarball digest for the new tag
curl -sL https://github.com/dweekly/swift-tailscale-client/archive/refs/tags/vX.Y.Z.tar.gz \
  | shasum -a 256
```

Update `url` and `sha256` in the formula, then verify locally:

```bash
brew install --build-from-source dweekly/tap/tailscale-swift
brew test tailscale-swift
brew audit --strict tailscale-swift
```

## Formula template

```ruby
class TailscaleSwift < Formula
  desc "Swift CLI for inspecting a local Tailscale daemon (unofficial)"
  homepage "https://github.com/dweekly/swift-tailscale-client"
  url "https://github.com/dweekly/swift-tailscale-client/archive/refs/tags/v0.6.0.tar.gz"
  sha256 "REPLACE_WITH_TARBALL_SHA256"
  license "MIT"
  head "https://github.com/dweekly/swift-tailscale-client.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :ventura

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release",
           "--product", "tailscale-swift"
    bin.install ".build/release/tailscale-swift"
  end

  test do
    assert_match "SUBCOMMANDS", shell_output("#{bin}/tailscale-swift --help")
  end
end
```

Notes:

- `--disable-sandbox` is required because SwiftPM's own sandbox conflicts with
  Homebrew's build sandbox.
- The formula builds from source; no binary artifacts are attached to GitHub
  Releases yet. If build times become a complaint, prebuilt bottles are the
  next step.
- Man pages can be generated with ArgumentParser's plugin
  (`swift package generate-manual tailscale-swift` from a checkout, or
  `swift package plugin generate-manual` on older toolchains) and installed
  via `man1.install` once we decide to ship them in the formula.
