# Vertex

Kernel-exploit installer for iOS 27, with **VertexStore** — an App Store catalog
client that browses the entire store through Apple's own API and installs paid
apps for free through the exploit chain.

```
vertex store search "monument valley"      # full catalog, Apple iTunes Search API
vertex store top paid us 25                 # top-paid chart, RSS marketing feed
vertex store info com.hellomono.monument2   # full metadata for one app
vertex get com.hellomono.monument2          # resolve -> download -> trust -> install
vertex get 892028840 --force                # same, by track id
vertex fetch https://host/app.ipa           # direct url install
vertex install ./app.ipa --force            # local ipa
vertex inject com.example.app               # add StoreKit hook (paid IAP unlock)
vertex list                                 # user apps on device
vertex uninstall com.example.app            # remove one
vertex launch com.example.app               # open one
vertex probe                                # boot exploit, dump trust cache
vertex refresh                              # re-trust + re-register everything
```

## How it works

1. **Exploit slot** — `tsx_provider()` in `src/main.m` is a weak symbol.
   Your iOS 27 0-day translation unit overrides it and returns a `tsx_kexp_t`
   (probe / start / kread / kwrite / kallsyms / offsets). Everything downstream
   — root, trust cache, install — is exploit-agnostic.
2. **Trust cache** — `tsx_root_self()` verifies the primitive with a read-back
   before touching anything, then your binary's cdhash is injected so amfi
   grants its entitlements on re-exec.
3. **Install** — IPA is unzipped, every Mach-O cdhash is injected into the
   trust cache, the bundle is registered through `LSApplicationWorkspace`
   (placeholder path first, `MCMAppContainer` fallback).
4. **VertexStore** — `src/appstore.m` talks to
   `itunes.apple.com/search`, `itunes.apple.com/lookup` and
   `rss.applemarketingtools.com` — no auth, no third-party mirror required for
   browsing. `src/acquire.m` resolves the IPA (`VERTEX_MIRROR` templates or a
   direct `ipaHint`), downloads, and runs the same trust + install pipeline.
5. **StoreKit hook** — `dylib/vertexhook.m` is injected into any app with
   `vertex inject`. `addPayment:` resolves instantly to a purchased
   transaction, `canMakePayments` is always YES, restore finishes clean —
   paid IAP unlocks inside the app.

### VERTEX_MIRROR

`vertex get` needs a source for the actual IPA bytes. Set a `;`-separated list
of URL templates with `{id}`, `{bundle}` or `{slug}` placeholders:

```sh
export VERTEX_MIRROR="https://mirror.host/ipa/{id}.ipa;https://cdn.host/{bundle}.ipa"
vertex get com.example.app
```

Items that carry a direct `ipaHint` skip the mirror entirely.

## Build

Local (macOS/Linux with [Theos](https://theos.dev)):

```sh
export THEOS=~/theos
make package FINALPACKAGE=1
```

CI: `.github/workflows/build.yml` builds on every push — ubuntu + Theos +
iOS toolchain + ldid, uploads the `.deb` as an artifact and attaches it to a
GitHub release when a `v*` tag lands.

Target: `iphone:clang:latest:15.0`, `arm64` + `arm64e`.

## Layout

```
include/tsx.h         exploit contract, install API, error codes
include/vstore.h      VertexStore catalog contract (VTSItem / VTSAppStore)
include/tsx_system.h  iOS private class declarations (runtime lookup only)
src/main.m            CLI dispatch, bootstrap re-exec, provider slot
src/kexploit.c        kexp registry + boot sequence
src/trustcache.c      cdhash extract + trust cache injection + bundle walk
src/zip.c             IPA extraction
src/install.m         container install + registration
src/appstore.m        iTunes Search / Lookup / RSS charts client
src/acquire.m         download -> extract -> install pipeline
src/inject.m          LC_LOAD_DYLIB injection into mach-o slack space
dylib/vertexhook.m    StoreKit purchase hook (swizzles, synthetic transactions)
Resources/Icons/      iOS icon set generated from Vertex icon.png
entitlements.plist    com.vertex.tool
```

## Notes

- Trust cache injection is **not** persistent across reboot — run
  `vertex refresh` after a restart to re-trust and re-register.
- `vertex inject` needs slack space after the load commands; if the binary is
  packed tight it reports `no slack space` instead of corrupting the file.
- The patched app's main executable is re-trusted immediately after injection.

Stashed. Every crumb on the bench — no locked cupboards.
