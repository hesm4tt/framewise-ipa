# Framewise

Framewise is a native iPhone camera app inspired by the supplied Framed pages and ad. It recreates the point → scan → capture → film-look → print/share workflow with its own name and interface.

## What it does

- Live rear-camera preview with tap-to-focus, flash, exposure bias, and zoom stops derived from the iPhone's actual rear-camera lenses and sensor resolution. The app uses AVFoundation's virtual camera so the device can switch among its physical lenses.
- Three-screen first-run setup explains the camera flow before asking for permission. A scan request captures one temporary rear-camera still, normalizes its orientation, resizes it to at most 768 px, and JPEG-compresses it. It runs the bundled detector by default; when OpenRouter is enabled, it sends that reduced frame to the configured free vision model and falls back to local detection if the request fails. Tap a subject to make a new one-shot scan centered on that point.
- The selected scan point is held as a motion-anchored target using Core Motion attitude updates; Vision does not continuously analyze preview frames or track the subject visually. The subject marker moves over the live image while the dashed frame target remains fixed at screen center. Direction cues guide physical re-aiming. When the target centers, the camera eases to a device-supported ideal zoom.
- The temporary scan image is discarded after analysis and is never used as the final photo or cropped into one. It stays on device unless the user enables OpenRouter scans; then only the reduced JPEG is sent to OpenRouter and its model provider. The shutter captures a separate full-resolution camera photo at the current lens and zoom.
- A clearly labeled **Take Photo** shutter opens the captured image in the local film and print workflow.
- Full-resolution, quality-prioritized capture uses the largest still dimensions exposed by the active camera, including 48 MP modes when that iPhone camera supports them. **Camera options → RAW + Processed** adds a DNG to the capture, preferring Apple ProRAW when supported and otherwise using Bayer RAW.
- A bounded, local diagnostics log can be exported from **Camera options → Share diagnostics**. It records camera, Vision, and OpenRouter status metadata and errors, not photo/video content, API keys, or model response text.
- The original full-resolution processed image is kept with any film-look or print-rendered copy. RAW DNGs are saved alongside both and can be shared from the review screen or gallery.
- Seven local film looks and five print treatments; the edited image is rendered only when you save or share.
- A private in-app gallery. Photos stay in the app’s Documents folder until you choose to share one.

Framewise has no Framewise-hosted server, subscription, or analytics SDK. Local scanning, motion-based framing guidance, zoom recommendations, film looks, and the gallery run on the phone. The bundled 8.9 MB Apple Core ML YOLOv3 Tiny model recognizes 80 common object classes and remains available as a no-service-cost fallback. Optional OpenRouter scans require the user’s own API key, stored in iOS Keychain, and use only `google/gemma-4-26b-a4b-it:free`; the app does not configure a paid-model fallback. OpenRouter controls the free model’s availability and request limits. The cloud scan sends a reduced JPEG frame, never the full-resolution capture. The only runtime permission requested is camera access; the app does not request access to the system Photos library.

## Sideloading and compatibility

Framewise is a standard iOS app with an iOS 15 deployment target. It uses no app extensions, app groups, push notifications, or special entitlements. Install the IPA with SideStore, AltStore Classic, Sideloadly, Feather, or another trusted installer that supports the device's iOS version and signing setup. Only SideStore uses this project's source feed; the other installers can use the direct IPA from the latest GitHub release.

LiveContainer is also an optional way to run Framewise. After installing LiveContainer with a supported setup method, import the Framewise IPA from its **+** button. LiveContainer's installation guide lists Sideloadly as unsupported for installing LiveContainer itself; that restriction is about LiveContainer's setup, not installing Framewise directly with Sideloadly. LiveContainer applies guest permissions through its host, so confirm camera access is enabled there.

SideInstaller can set up SideStore or LiveContainer directly on supported devices; check its current iOS and pairing requirements and use only the [official SideInstaller site](https://sideinstaller.net/) or [official repository](https://github.com/FrizzleM/SideInstaller).

## Build an IPA

You need a Mac with the full Xcode app and iOS SDK installed. Open `Framewise.xcodeproj` and build the `Framewise` scheme for a device, or run:

```sh
./scripts/package-ipa.sh
```

The script writes an unsigned `build/Framewise.ipa`. LiveContainer can run unsigned guests in its JIT mode and uses its configured signing certificate when signing is required. SideStore can sign the same IPA with its configured Apple account. The package script does not change the Mac’s selected Xcode or signing settings.

The scan still uses the smallest photo dimensions advertised by the active camera format where supported, then is reduced and recompressed to a 768 px JPEG before local inference or optional OpenRouter upload. Final photo capture uses the largest dimensions the active camera exposes at runtime rather than assuming a fixed megapixel count. The zoom controls inspect the physical rear-camera lenses, their fields of view, and sensor sizes: a single-camera 48 MP iPhone gets a 1×/2× pair, a model with an Ultra Wide adds 0.5×, and a telephoto adds its own focal-length stop (with a second optical-quality crop when that sensor supports it). This adapts to newer models without a private model-identifier table and retains the iOS 15 app target.

RAW is optional because DNG files are much larger and standard Bayer RAW skips some of the image-capture pipeline’s computational processing. On supported devices, Framewise enables Apple ProRAW before starting the capture session and prefers it when available. Captures include a normal full-resolution processed image for preview and film looks; the DNG remains available as a separate original.

## Publish a release and SideStore feed update

After changing `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project, run:

```sh
./scripts/publish-ipa.sh
```

The script builds the IPA, publishes the IPA and source JSON to the matching GitHub Release, commits the latest version and exact IPA size to the public feed, then revalidates GitHub’s raw-feed cache and checks the published version, size, and identifiers. The source uses the release `latest/download` URL for future refreshes. It requires an authenticated GitHub CLI (`gh auth login`). Keep the app bundle ID `com.framewise.camera` and the source identifier `com.framewise.source` stable so existing SideStore installs can refresh the same app/source.
