# Muse Glimmer managed runtime

Standalone llama.cpp runs Muse Glimmer behind this Python standard-library service.
The service provides the Ollama-compatible HTTP endpoints QChat uses, plus bounded
conversation caches and renewable five-minute leases. Ollama is not a runtime dependency.

- [Install and configure](../docs/setup-runtime.md)
- [HTTP API and cache behavior](../docs/runtime-api.md)
- [Local resource and lease dashboard](../docs/runtime-dashboard.md)
- [Troubleshooting](../docs/troubleshooting.md)

From this directory, after setup:

```sh
./scripts/start.sh
./scripts/status.sh
./scripts/stop.sh
```

On macOS, `start.sh` generates a machine-specific launchd registration under ignored
`state/`; it does not need a hard-coded workspace or Python path. The registered job survives
the terminal, but automatic startup after logout/reboot is not installed by this script.

Run tests without starting or changing the service:

```sh
PYTHONPATH=. python3 -m unittest discover -s tests -v
```
