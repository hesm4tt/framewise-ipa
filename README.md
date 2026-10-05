<p align="center">
  <img src="framewise-icon.png" width="112" height="112" alt="Framewise app icon">
</p>

<h1 align="center">Framewise</h1>

<p align="center"><strong>Compose the shot you have in mind.</strong><br>
An on-device camera guide that helps you find your subject, refine the frame, and take the shot.</p>

<p align="center"><a href="https://hesm4tt.github.io/framewise-ipa/">Project website</a> &nbsp;·&nbsp; <a href="https://github.com/hesm4tt/framewise-ipa/tree/main">Browse the source</a></p>

<p align="center">
  <a href="https://github.com/hesm4tt/framewise-ipa/releases/latest"><img src="https://img.shields.io/github/v/release/hesm4tt/framewise-ipa?style=flat-square&color=ff8b58" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/iOS-15%2B-5961f6?style=flat-square" alt="iOS 15 and later">
  <img src="https://img.shields.io/badge/AI-local%20%2B%20optional%20cloud-202124?style=flat-square" alt="Local AI with optional cloud scans">
</p>

<p align="center">
  <a href="https://docs.sidestore.io/docs/advanced/app-sources"><strong>Install with SideStore</strong></a>
  &nbsp; · &nbsp;
  <a href="https://github.com/hesm4tt/framewise-ipa/releases/latest/download/Framewise.ipa"><strong>Download the latest IPA</strong></a>
</p>

## A little more intention in every frame

Framewise scans one temporary camera still, then guides you to re-aim, centers the chosen subject with motion sensors, and eases to an ideal zoom before the full-resolution shutter photo.

- One-shot subject detection on device by default. Optionally enable OpenRouter vision scans for stronger subject and group selection; tap a subject to retarget. Analysis does not run on every preview frame.
- A motion-anchored subject marker moves over the live scene while a dashed frame target stays fixed at screen center. Clear move-the-phone cues guide the marker into the frame; the camera eases to the scan’s ideal zoom when centered.
- The scan image is orientation-corrected, reduced to 768 px, and JPEG-compressed. It is processed locally unless you enable OpenRouter; it is never used as the final photo.
- Zoom controls adapt to the iPhone’s physical lenses and sensor resolution, so each model gets its own optical and optical-quality stops.
- Full-resolution processed capture, optional RAW + processed DNG capture, local film looks, and a private in-app gallery.
- Bundled Core ML and Apple Vision processing with local fallback. Optional OpenRouter mode uses your own key and a free vision model; cloud scans are opt-in.

## Install with the method you already use

Framewise is a standard iOS IPA, not a LiveContainer-only app. Use any trusted installer that accepts a standard IPA and supports your iOS version and signing setup. The current build requires iOS 15 or later.

### SideStore

SideStore is the quickest route if you already use it. First, open the [SideStore app-source guide](https://docs.sidestore.io/docs/advanced/app-sources), then add this source URL in SideStore:

```text
https://github.com/hesm4tt/framewise-ipa/releases/latest/download/framewise.json
```

The source follows the latest release, so you can install and update Framewise from SideStore.

### Other sideloading options

| Method | Get started | Install Framewise |
| --- | --- | --- |
| **SideInstaller** | [Official setup](https://sideinstaller.net/) · [official repo](https://github.com/FrizzleM/SideInstaller) | SideInstaller can set up SideStore or LiveContainer on supported devices. Then add the Framewise SideStore source above or import the IPA. Check the current iOS and pairing requirements first. |
| **AltStore Classic** | [AltStore](https://altstore.io/) · [official guide](https://faq.altstore.io/) | Download the IPA below and import it in AltStore Classic. The SideStore source link above is for SideStore. |
| **Sideloadly** | [Official download and guide](https://sideloadly.io/) | Download the IPA below and install it from Sideloadly on macOS or Windows. |
| **Feather** | [Official project and releases](https://github.com/iProdb/Feather) | Import the IPA below and use your own compatible signing setup. |
| **LiveContainer** | [Official project and install guide](https://github.com/LiveContainer/LiveContainer) | LiveContainer is optional. After setting it up with a supported installer, open LiveContainer, tap **+**, and import the Framewise IPA. |

> **LiveContainer note:** its installation guide lists Sideloadly as unsupported for installing LiveContainer itself. That does not make Framewise LiveContainer-only; install Framewise directly with Sideloadly, or set up LiveContainer using its [supported installation guide](https://livecontainer.github.io/docs/installation/).
>
> **SideInstaller note:** SideInstaller is an independent project, not affiliated with SideStore. Use only [sideinstaller.net](https://sideinstaller.net/) or its [official GitHub repository](https://github.com/FrizzleM/SideInstaller), and review its current device requirements.

### Direct IPA

[Download Framewise.ipa](https://github.com/hesm4tt/framewise-ipa/releases/latest/download/Framewise.ipa) and import it with your preferred IPA installer. You can also browse the [release history](https://github.com/hesm4tt/framewise-ipa/releases).

## Privacy and cost

By default, camera analysis, composition guidance, and photo treatments run on your iPhone. If you enable OpenRouter in **Camera options → OpenRouter AI scan settings** and add your own API key, each scan sends only its reduced 768 px JPEG frame to OpenRouter and the model provider. Framewise is pinned to a free vision model and does not select paid models; OpenRouter controls free availability and request limits. If cloud scanning fails, the bundled on-device detector takes over. Full-resolution photos are never sent for analysis and stay in Framewise’s private app library unless you choose to share them.

## Build from source

The `main` branch includes the complete Xcode project, Swift source, and bundled Core ML model. Open [`Framewise.xcodeproj`](https://github.com/hesm4tt/framewise-ipa/tree/main/Framewise.xcodeproj) in Xcode, or build an unsigned IPA on a Mac with full Xcode installed:

```sh
./scripts/package-ipa.sh
```

The scan flow uses one temporary still and a single analysis: local Vision inference by default, or an opt-in OpenRouter free vision request when configured. OpenRouter receives the 768 px scan JPEG; if that request fails, local inference runs. A motion-anchored target point guides physical re-aiming using gyroscope samples at about 32 ms. The fixed frame target stays at screen center; the subject reticle follows phone movement without repeated visual detection. Lock requires the target to remain within a 0.06-radius center zone for more than 600 ms. Framewise then snaps the reticle to center, eases to the ideal camera zoom, and shows ready about 900 ms after lock. The shutter captures the camera’s full-resolution output at its current zoom. There is no final-photo crop. Zoom choices derive from the device’s physical lenses and sensor sizes. RAW is optional because DNG files are larger and may omit some computational processing. Framewise keeps the original full-resolution processed image with the edited version, and saves a DNG sidecar when RAW is enabled. ProRAW is used where the current camera configuration supports it; otherwise, Framewise uses Bayer RAW.

To publish a new IPA and refresh the SideStore feed, set the version/build in `Framewise.xcodeproj/project.pbxproj` and run `./scripts/publish-ipa.sh` with an authenticated GitHub CLI.

See [`DEVELOPMENT.md`](https://github.com/hesm4tt/framewise-ipa/blob/main/DEVELOPMENT.md) for more project and packaging details.

## About

Framewise is an independent project. It is not affiliated with Apple, Framed, SideStore, SideInstaller, AltStore, Sideloadly, Feather, or LiveContainer.
