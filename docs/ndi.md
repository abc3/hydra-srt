# NDI

How to install and enable NDI for HydraSRT.

NDI® is a registered trademark of Vizrt NDI AB.

---

## What HydraSRT ships, and what it does not

HydraSRT integrates NDI through the open-source GStreamer plugin `gst-plugin-ndi`
(from `gst-plugins-rs`, MPL-2.0). That plugin is not the NDI implementation: it loads
the proprietary **NDI runtime** (`libndi`) at run time.

**HydraSRT does not include, bundle, or redistribute the NDI runtime.** You install it
yourself from [ndi.video](https://ndi.video), and it stays subject to Vizrt's licence.
Nothing here changes those terms. This page only explains how to point HydraSRT at a
runtime you have installed.

NDI is **off by default**. With it off, NDI endpoints are rejected, the discovery
coordinator is not started, and the API reports `NDI_DISABLED`.

---

## Requirements

| Component | Notes |
|---|---|
| GStreamer 1.x | Plus `-plugins-base` and `-plugins-good`/`-bad`. |
| `gst-plugin-ndi` | Built from `gst-plugins-rs`. Build with default features; the `advanced-sdk` feature stays **off**. |
| NDI runtime (`libndi.so.6`) | Proprietary. Obtain from [ndi.video](https://ndi.video). |
| Avahi (`avahi-daemon`) | Only for mDNS discovery. `libndi` links `libavahi-client`; without a running daemon, automatic discovery is unavailable and you must use direct addresses or a Discovery Server. |

---

## 1. Install the NDI runtime

Download the NDI SDK for your platform from [ndi.video](https://ndi.video) and run its
installer. Then locate the runtime library for your architecture, for example:

```
NDI SDK for Linux/lib/x86_64-linux-gnu/libndi.so.6.3.2
```

Copy it to a directory of your choosing, and create the soname symlink:

```bash
sudo mkdir -p /opt/ndi
sudo cp "NDI SDK for Linux/lib/x86_64-linux-gnu/libndi.so.6.3.2" /opt/ndi/
sudo ln -sf libndi.so.6.3.2 /opt/ndi/libndi.so.6
sudo ln -sf libndi.so.6 /opt/ndi/libndi.so
```

> The SDK ships one fully-versioned file per architecture (`libndi.so.6.3.2`) and **no
> soname symlink**. The loader looks for `libndi.so.6`, so without that link the runtime
> is not found even though the file is present.

Pick the directory matching the machine's architecture: the SDK also contains i686 and
several ARM builds.

## 2. Verify GStreamer sees the plugin

```bash
gst-inspect-1.0 ndisrc
```

If this fails, the plugin is missing or not on `GST_PLUGIN_PATH`; HydraSRT will report
`NDI_PLUGIN_MISSING`.

## 3. Configure HydraSRT

Two variables, both documented in [envs.md](ENVS.md):

```bash
NDI_FEATURE=true                 # enables NDI (default: false)
HYDRA_NDI_RUNTIME_DIR=/opt/ndi   # directory containing libndi.so.6
```

`HYDRA_NDI_RUNTIME_DIR` is passed to the native pipeline as `NDI_RUNTIME_DIR_V6`.
Restart HydraSRT after setting them. `make dev` sets `NDI_FEATURE=true` already.

---

## Discovery

By default NDI finds sources over **mDNS**, which requires a running `avahi-daemon` and
working multicast on the network.

### When multicast is unavailable

Cloud networks, many container setups and most CI runners do not pass multicast, so
senders are never discovered. NDI's answer is the **Discovery Server**, which replaces
multicast with unicast TCP. `ndi-discovery-server` ships with the SDK.

Run it, then point clients at it with a config file:

```bash
ndi-discovery-server &          # listens on :5959
```

```jsonc
// ~/.ndi/ndi-config.v1.json
{ "ndi": { "networks": { "ips": "", "discovery": "127.0.0.1" } } }
```

Two details that cost real debugging time:

- **The `"ndi"` wrapper is required.** The flat form (`{"networks": …}`) is read without
  error and silently ignored.
- **`libndi` resolves this file from the account's home directory in the passwd
  database, not from `$HOME`.** Overriding `$HOME` for the process has no effect. The
  file must exist for the account that runs HydraSRT, and both the sending and the
  receiving side need their own readable copy.

There is no environment variable for this on Linux; the config file is the only
supported mechanism.

### Referring to a source

A sender is advertised as `MACHINE (Sender Name)`. When selecting a source by name,
use that full advertised name; the bare sender name does not resolve.

---

## Verifying

- **UI** — the NDI health tab shows plugin, runtime, discovery and direct-address status.
- **API** — `GET /api/ndi/capabilities` returns the same document.

## Troubleshooting

| Reported reason | Meaning | Fix |
|---|---|---|
| `NDI_DISABLED` | Feature flag is off. | Set `NDI_FEATURE=true` and restart. |
| `NDI_PLUGIN_MISSING` | `ndisrc`/`ndisink` not registered. | Install `gst-plugin-ndi`; check `GST_PLUGIN_PATH`. |
| `NDI_RUNTIME_MISSING` | `libndi` not loadable. | Check `HYDRA_NDI_RUNTIME_DIR` and the `libndi.so.6` symlink. |
| `NDI_RUNTIME_INCOMPATIBLE` | Runtime major version unsupported. | Install an NDI 6 runtime. |
| `NDI_AVAHI_UNAVAILABLE` | Avahi is not running. | Start `avahi-daemon`, or use direct addresses / a Discovery Server. |
| `NDI_DISCOVERY_UNAVAILABLE` | Discovery is not answering. | Check Avahi or the Discovery Server; direct addresses still work. |
| `NDI_HELPER_PENDING` | The discovery helper is still starting. | Wait a moment. |
| `NDI_HELPER_UNHEALTHY` | HydraSRT could not start its NDI helper. | Usually the runtime is missing or unloadable; verify steps 1-3. |

Configuration with NDI unavailable can still be **saved**; only Test and Start are
blocked until NDI becomes available.
