# Framewise

Framewise is a native iPhone camera app inspired by the supplied Framed pages and ad. It recreates the point → scan → capture → film-look → print/share workflow with its own name and interface.

## What it does

- Live rear-camera preview with tap-to-focus, flash, exposure bias, and zoom stops derived from the iPhone's actual rear-camera lenses and sensor resolution. The app uses AVFoundation's virtual camera so the device can switch among its physical lenses.
- Three-screen first-run setup explains the camera flow before asking for permission. The live guide detects and names common objects on device, draws a moving subject box and center connector, and uses Vision tracking to keep the guide attached as the camera moves. Tap a subject to prioritize it; that choice stays locked through detector refreshes and tracking recovery until you tap another subject.
- Direction cues tell you which way to move the phone. Once the subject is centered, a one-tap suggested zoom uses a smooth AVFoundation zoom ramp and can land between the model's optical stops. Core Motion supplies horizon guidance.
- A clearly labeled **Take Photo** shutter opens the captured image in the local film and print workflow.
- Full-resolution, quality-prioritized capture uses the largest still dimensions exposed by the active camera, including 48 MP modes when that iPhone camera supports them. **Camera options → RAW + Processed** adds a DNG to the capture, preferring Apple ProRAW when supported and otherwise using Bayer RAW.
- A bounded, local diagnostics log can be exported from **Camera options → Share diagnostics**. It records camera and Vision metadata and errors, not photo or video content.
- The original full-resolution processed image is kept with any film-look or print-rendered copy. RAW DNGs are saved alongside both and can be shared from the review screen or gallery.
- Seven local film looks and five print treatments; the edited image is rendered only when you save or share.
- A private in-app gallery. Photos stay in the app’s Documents folder until you choose to share one.

There is no server, account, subscription, analytics SDK, or network request in the app. Object detection, tracking, composition advice, film looks, and the gallery run on the phone. The bundled 8.9 MB Apple Core ML YOLOv3 Tiny model recognizes 80 common object classes, so the guide has no per-use service cost. The only runtime permission requested is camera access; the app does not request access to the system Photos library.

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

The photo capture uses the largest dimensions the active camera exposes at runtime rather than assuming a fixed megapixel count. The zoom controls inspect the physical rear-camera lenses, their fields of view, and sensor sizes: a single-camera 48 MP iPhone gets a 1×/2× pair, a model with an Ultra Wide adds 0.5×, and a telephoto adds its own focal-length stop (with a second optical-quality crop when that sensor supports it). Suggested zooms prefer these stops when they fit the framing goal. This adapts to newer models without a private model-identifier table and retains the iOS 15 app target.

RAW is optional because DNG files are much larger and standard Bayer RAW skips some of the image-capture pipeline’s computational processing. On supported devices, Framewise enables Apple ProRAW before starting the capture session and prefers it when available. Captures include a normal full-resolution processed image for preview and film looks; the DNG remains available as a separate original.

## Publish a release and SideStore feed update

After changing `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project, run:

```sh
./scripts/publish-ipa.sh
```

The script builds the IPA, publishes the IPA and source JSON to the matching GitHub Release, commits the latest version and exact IPA size to the public feed, then revalidates GitHub’s raw-feed cache and checks the published version, size, and identifiers. The source uses the release `latest/download` URL for future refreshes. It requires an authenticated GitHub CLI (`gh auth login`). Keep the app bundle ID `com.framewise.camera` and the source identifier `com.framewise.source` stable so existing SideStore installs can refresh the same app/source.
