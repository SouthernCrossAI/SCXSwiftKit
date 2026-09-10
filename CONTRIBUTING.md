# Contributing

This guide is for anyone working on the package: SCX's engineers who maintain it, and
outside contributors sending a fix or an improvement. Both are welcome. Usage is in the
[README](README.md); how the SCX API actually behaves, and why the executor maps things the
way it does, is in [docs/PROVIDER-NOTES.md](docs/PROVIDER-NOTES.md).

## Reporting a problem

Open an issue with the model id, the request shape (a `curl` against `api.scx.ai` is ideal),
what SCX returned, and what the package did with it. Never paste an API key. If the package
mapped an SCX response to the wrong Apple error, say which case you expected and why.

## What you need

- Xcode 27. The provider uses the third-party `LanguageModel` API that arrived in the iOS 27
  SDK, and it compiles out on older toolchains. If Xcode 27 is not your selected toolchain,
  point `DEVELOPER_DIR` at it when you build or test.
- The iOS 27.0 simulator runtime, with at least one iPhone simulator on it.
- An SCX API key with credit, in `~/.config/scx/api_key` or in `SCX_API_KEY`. The live tests
  spend a few cents per run.
- `xcodegen` (Homebrew) if you work on the demo app. `Demo/SCXDemo.xcodeproj` is generated
  and not committed.

## Running the tests

```sh
Scripts/ci.sh                          # uses the selected Xcode; override with DEVELOPER_DIR
swift test --filter SCXRuntimeTests    # parser unit test only, no network
```

`Scripts/ci.sh` is the same script GitHub Actions runs, so a green local run means a green
pull request. It watches the log for the Swift Testing summary line and stops `xcodebuild`
once it appears, because some toolchains hang after the tests finish, and it fails the run if
that summary never appears, so a hung test cannot pass by silence.

The seven live tests skip when no key is present, so the suite still runs without one, but
only the mapping tests then prove anything.

To run the simulator suite by hand without the watchdog:

```sh
xcodebuild test -scheme SCXSwiftKit-Package -only-testing:SCXSwiftKitTests \
  -destination 'platform=iOS Simulator,OS=27.0,name=iPhone 18 Pro Max'
```

## Pull requests

Work on a branch and open a pull request against `main`. CI runs on pull requests only, in two
jobs: `build-and-unit-tests` on stable Xcode 26, which proves the package still builds where the
provider compiles out, and `provider-tests` on GitHub's `xcode-27` image, which runs the full
simulator suite. The live tests on CI need an `SCX_API_KEY` repository secret; without it they
skip and the job stays green, so check the run log if you expect them to have run. GitHub
does not expose secrets to pull requests from forks, so an outside contributor's PR runs the
mapping tests only; a maintainer runs `Scripts/ci.sh` locally before merging it.

Keep pull requests small and self-contained. The package has no dependencies, and that is
deliberate; do not add one for something a few lines can do.

## Where things live

```
Sources/SCXRuntime/     plain OpenAI-compatible client: SCXClient, ChatTypes, ModelInfo, SCXError, JSONValue
Sources/SCXSwiftKit/    the Foundation Models side: SCXLanguageModel (the model), SCXExecutor (streaming and mapping)
Sources/scx-chat/       command line streaming demo
Tests/SCXRuntimeTests/  SSE parser unit test
Tests/SCXSwiftKitTests/ transcript and option mapping (unit) plus the live tests
Demo/                   SwiftUI demo app, iOS 27 simulator
docs/PROVIDER-NOTES.md  how the API behaves and why the executor maps it that way
```

One type per file. `SCXRuntime` must keep building on macOS 26 without Foundation Models;
everything that touches Foundation Models stays inside `SCXSwiftKit` behind its
`canImport(FoundationModels, _version: 2)` guard, and so do its tests.

## When the SCX API changes

The executor's mapping is only as good as PROVIDER-NOTES. When a status code, a finish reason,
a parameter or a model changes on the platform:

1. Probe it against `api.scx.ai` and record the new behaviour in PROVIDER-NOTES.
2. Change the mapping in `SCXExecutor` or `SCXClient`.
3. Add or adjust a test. Mapping changes get a unit test on the request shape; behaviour
   changes get a live test. Check that the test fails without your change before you trust it.

Errors that Apple's `LanguageModelError` cannot express (bad key, no credit, no permission, a
model that does not exist) are meant to reach the app as `SCXError` with SCX's own message. Do
not fold them into an Apple case that does not fit.

## Models

Every text model on the platform works through the package; `SCXLanguageModel.load` reads
capabilities from `/v1/models` at runtime, so adding a model needs no code change. Only text in,
text out models can be loaded; the image, video, speech and moderation entries in the catalogue
are rejected by `load` because they cannot serve chat completions.

## Known toolchain quirks

- `TEST_RUNNER_` environment variables do not reach package test bundles on the simulator.
  The tests read the key from the Mac user's home through `SIMULATOR_HOST_HOME` instead.
- The first boot of an iOS 27 simulator on a fresh runtime can take several minutes.
- The demo app takes `SIMCTL_CHILD_SCX_API_KEY` and `SIMCTL_CHILD_SCX_DEMO_AUTOSEND=1` when
  launched with `simctl`, which is how the README screenshot is recorded:
  `SIMCTL_CHILD_SCX_API_KEY=$SCX_API_KEY SIMCTL_CHILD_SCX_DEMO_AUTOSEND=1 xcrun simctl launch booted ai.scx.demo.SCXDemo`.
