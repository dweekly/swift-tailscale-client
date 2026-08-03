Security: never log LocalAPI authentication-token material

Why

LocalAPIDiscovery currently logs the first eight characters of the macOS sameuserproof token when debug logging is enabled.

That token authenticates loopback LocalAPI requests. An official-quality client should treat the complete value—and every substring—as secret.

Current code:

https://github.com/dweekly/swift-tailscale-client/blob/main/Sources/TailscaleClient/Configuration/LocalAPIDiscovery.swift

Upstream credential handling:

https://github.com/tailscale/tailscale/blob/main/safesocket/safesocket_darwin.go

Scope

* Remove the token preview from discovery logging.
* Log only non-secret provenance such as installation flavor, transport kind, and loopback port.
* Audit logs, errors, debug descriptions, test diagnostics, and CLI output for:
    * authToken
    * Authorization
    * ID tokens
    * certificate private keys
    * audit/request reasons
    * other credential-bearing response fields
* Introduce a small centralized redaction helper if multiple call sites need the same protection.
* Ensure public model descriptions do not accidentally dump secret-bearing fields.
* Add regression tests that inject recognizable secrets and capture every supported diagnostic surface.

Acceptance criteria

* No authentication-token bytes are emitted by debug or normal logging.
* Logs do not contain meaningful substrings of authentication tokens.
* The implementing PR documents a repository-wide audit of secret-bearing fields.
* Tests fail if an injected token, authorization value, ID token, or private-key fixture appears in logs, errors, or debug descriptions.
* Discovery remains diagnosable through non-secret transport and provenance information.
* Documentation tells integrators which returned values they must themselves treat as secrets.
