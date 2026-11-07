# brandify

[![CI](https://github.com/ryanhz/brandify/actions/workflows/ci.yml/badge.svg)](https://github.com/ryanhz/brandify/actions/workflows/ci.yml)

Store screenshots for Flutter apps, taken from a **real simulator or emulator** and driven by
`integration_test`: capture, frame for each store slot, and export into fastlane's folders, with
one command each.

If your app embeds native views (`PlatformView`: maps, 3D, camera previews, native ads, WebView),
widget-test screenshot tools render them as a black hole and don't tell you. brandify screenshots
the device's own screen, so native views, the real status bar and the real keyboard are in the
picture. See [packages/brandify/README.md](packages/brandify/README.md) for the evidence and usage.

```bash
flutter pub add dev:brandify dev:brandify_flutter
dart run brandify init && dart run brandify doctor
dart run brandify capture && dart run brandify frame && dart run brandify export
```

| Package | |
|---|---|
| [`packages/brandify`](packages/brandify) | The CLI (pure Dart) |
| [`packages/brandify_flutter`](packages/brandify_flutter) | Test helper and framing, a dev dependency of your app |
| [`example`](example) | Example app with `brandify.yaml` and a capture test. Its home screen has a native view (PlatformView). Its UI is English-only by design (see its README). |
| [`tool/e2e.sh`](tool/e2e.sh) | End-to-end check on a real emulator / simulator, run by CI |

## Development

```bash
flutter pub get                                       # the whole workspace
(cd packages/brandify && dart test)
(cd packages/brandify_flutter && flutter test)
tool/e2e.sh fresh android                             # needs an AVD; BRANDIFY_E2E_AVD picks one
```

CI runs the unit tests and the Android end-to-end check on every push. The iOS end-to-end check
runs on a macOS runner when started by hand (Actions → CI → Run workflow → ios).

## License

MIT, see [LICENSE](LICENSE).
