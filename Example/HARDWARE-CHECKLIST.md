# Hardware checklist

The simulator has no camera, so Prism's unit tests stop at value types, pure helpers and API-surface locks. This checklist covers what only a device can show. Run most of it in the Example app's **Studio** screen; the iOS 26 / 27 controls live in the settings drawer sections after **Format**. A row a device or OS can't support stays visible but disabled, and tapping it says why. The configure-time flags are in the **Configuration Lab** screen (last section).

Record the device, iOS version and date next to each result. Unchecked items have not been verified on hardware yet.

## Baseline (any iOS 18+ device)

- [ ] Studio boots to a live preview; photo, Live Photo, Portrait, video, slo-mo and night captures still save.
  - Result 2026-10-06 (iPhone 18 Pro Max, iOS 27.0): photo, Live Photo, Portrait, burst, video and slo-mo captured. Night crashed on the Triple Camera (see *Night on a Pro iPhone* under iOS 27); re-test after that fix.
- [ ] Camera switch (front / back, virtual / wide hop) keeps the preview live and captures working.

## Audit fixes (any iOS 18+ device)

Behavior changed by the 2026-10-04 audit fix pass. Library changes first, then the Example.

- [ ] **Upright captures.** Shoot a still, a Live Photo, a Night shot and a video with the phone held landscape (both directions) and upside-down portrait: each saves upright. The same in Filter Chain *Snap* and Configuration Lab *Capture*.
- [ ] **Recovery after a media-services reset.** If the log ever shows `Restarting after a media-services reset` (after a `mediaServicesWereReset` runtime error), the preview comes back without leaving the screen.
- [ ] **No rebuild on switch in video.** With Live Photo configured (Studio), switch front / back and hop lenses in VIDEO and SLO-MO: no `Live Photo lost … full session reconfigure` notice and no preview freeze.
- [ ] **Refused while recording.** While recording, the flip button and mode picker are inactive; a flip request toasts "Stop recording to switch cameras". The recording finishes intact.
- [ ] **Portrait first shot.** Fresh launch, switch to PORTRAIT and shoot first: the photo has depth (the Portrait badge in Photos) on a depth-capable camera.
- [ ] **Burst cut short.** Interrupt a 5-shot burst (background the app mid-burst): the shots already taken are saved and the toast says `Burst (saved N of 5) failed`.
- [ ] **Shutter extremes.** Drag the manual shutter slider to both ends, release, capture: no crash; the EXIF shows the clamped value.
- [ ] **Night EXIF.** A Night shot's EXIF shows the planned per-frame shutter and ISO (the `Night:` plan line in the log) and "Night mode: N frames over T s" as its user comment, and its file type follows the Codec row.
- [ ] **Quality ceiling.** Configuration Lab with *Photo quality ceiling → Speed* (or Balanced), Apply, then Studio-style captures through *Capture*: they work (a request above the ceiling used to crash, as did a Night shot).
- [ ] **Unsupported controls.** On the front camera, torch and focus controls that the camera lacks are disabled or toast "unsupported" instead of doing nothing.
- [ ] **48MP round trip.** Max Dimensions on, flip to front and back, Max Dimensions off: the preview and photos return to the original 12MP format (log: `restored baseline format`).
- [ ] **Live Photo and depth at boot (Triple Camera).** With Max Dimensions off, the boot log has no `aux-flags(highRes=true)` lines and `Configured:` reads `livePhoto=true`. Then SLO-MO to PHOTO and to NIGHT: the first capture logs `live=false` (Live Photo stays off outside LIVE).
  - Result 2026-10-06 (iPhone 18 Pro Max, iOS 27.0): before the fix, configure turned Live Photo, depth and the matte off, because the Triple Camera's default format offers 24MP and Prism took any format above 20MP for the 48MP one.
- [ ] **Stabilization across a flip.** Set *Stabilization → Cinematic*, flip twice: the row still reads `cinematic → …` with the same active mode.
- [ ] **Tap-to-focus placement.** In Studio (fit) and Filter Chain / Configuration Lab (now fit as well), tap near each corner on the back and the front (mirrored) camera: focus and the indicator land where tapped.
  - Studio's data connection is unrotated since the front-camera fix, so its taps and detection outlines map straight to the device. Check them again on the back and the front camera.
- [ ] **Depth Inspector.** On a Pro iPhone the status line reports the depth format switch and the depth tile fills in (it stayed empty before).
- [ ] **Blur filters.** Gaussian / Motion / Zoom blur in Filter Chain show no dark border at the frame edges.
- [ ] **Level indicator.** With Reduce Motion on, the level line still tilts with the phone; a haptic tick plays when it levels.
- [ ] **VoiceOver.** The settings drawer is modal while open (the camera UI behind it isn't reachable) and a two-finger scrub closes it; rows read `title, value, Expanded/Collapsed`; the shutter reads Capture / Start recording / Stop recording, and its actions rotor offers *Start / Stop video recording*; toasts are announced.
- [ ] **Example lifecycle.** Leave each camera screen during boot, and cancel a back-swipe halfway: no camera indicator stays on after leaving, and a cancelled swipe returns to a live preview. Leaving Studio mid-recording saves the video.
- [ ] **Overlapping taps.** In Studio, tap the shutter repeatedly during a Night capture or a Live Photo: extra taps are ignored and the camera returns to its prior exposure afterwards; a tap during the self-timer cancels it.

## Hardware run fixes (2026-10-06)

- [ ] **Front preview orientation.** Use the front camera on the iPhone 18 Pro Max (iOS 27) and the iPhone 17 Pro (iOS 26) in Studio and Configuration Lab (*Front*): the preview is upright and mirrored like a mirror. The back camera stays upright everywhere, the Depth Inspector's two tiles included. The log's `Preview orientation:` line names the angle per camera: send it if a camera still comes out sideways (on iOS 26 the preview always uses 90°).
  - Result 2026-10-06 (iPhone 18 Pro Max, iOS 27.0): the front preview was rotated. Studio rotated the frames by 90°, and the iOS 27 portrait angle for the front camera (likely 0°) was thrown away.
  - Result 2026-10-07 (iPhone 18 Pro Max, iOS 27.0): still 90° off. The log showed the front camera upright at 0° (static, preview and capture angles alike), and the preview drew the frames at 0°. But the Center Stage front camera's sensor is mounted in portrait, and its video-data connection defaults to 270° so frames look like older front cameras', which leaves 90° to draw. Fixed in the next section.
- [ ] **Portrait readiness.** In PORTRAIT on a depth-capable camera:
  - [ ] a subject 0.5 to 2.5 m away shows a yellow **NATURAL LIGHT** pill above the lens chips;
  - [ ] closer than the lens allows shows "Move farther away."; farther than 2.5 m shows "Place subject within 2.5 m."; a dark room shows "More light required.";
  - [ ] the pill doesn't flicker between states, follows *Detect → Faces / People* when on (the largest face or body), and goes away in other modes;
  - [ ] Portrait photos still capture with depth while the pill runs, and the preview doesn't drop frames noticeably.
- [ ] **Night mode.** In a dark room, handheld, NIGHT (AUTO):
  - [ ] the AUTO label shows 1 to 3 s, and the pill counts down with "HOLD STILL", then shows PROCESSING;
  - [ ] the photo is clearly brighter and cleaner than a PHOTO shot of the same scene, without blown street lights or lamps;
  - [ ] it's sharp handheld (blurred frames are dropped; the log's `Night photo: N of M frames` shows how many went in);
  - [ ] someone walking through the frame doesn't leave a ghost;
  - [ ] on a tripod (or braced), AUTO shows a longer time (3 to 10 s) and the photo is cleaner still;
  - [ ] focus, zoom, lens chips, the drawer, the mode picker and the flip button wait until it's done, and the preview, exposure and white balance are back to normal afterwards;
  - [ ] the log's `Night: frames W×H` line shows the frame size: 4032×3024 on the photo format. A smaller size triggers a switch to InputPriority (`switching to InputPriority for the capture`); report either way.

## Hardware run fixes (2026-10-07)

- [ ] **Front preview, again.** The preview now rotates by the upright angle minus the data connection's own rotation. On the iPhone 18 Pro Max and the iPhone 17 Pro, in Studio and Configuration Lab (*Front*):
  - [ ] the front preview is upright and mirrored like a mirror; the `Preview orientation:` line reads `→ 90°` with `data connection 270°` (send it if not);
  - [ ] tap-to-focus on the front camera lands where you tap, and *Detect → Faces* outlines sit on the faces (the 270° connection's frames are assumed to be in the same space as the focus point);
  - [ ] a front photo and a front recording save upright.
- [ ] **Cinematic Video on a Pro iPhone.** The Triple camera has no Cinematic Video format (Apple supports it on the Dual Wide and TrueDepth cameras), so the drawer row used to stay disabled.
  - [ ] *Cinematic Video* turns on from the Triple camera: the log shows `Cinematic Video: BuiltInTripleCamera has no Cinematic Video format, switching to BuiltInDualWideCamera`, the lens strip changes to the Dual Wide camera's lenses, and a VIDEO recording has the shallow depth of field;
  - [ ] turning it off returns to the Triple camera (`Cinematic Video off: switching back to BuiltInTripleCamera`);
  - [ ] a flip with it on lands on the front camera Cinematic Video runs on (TrueDepth) with it still on, and a flip back lands on the Dual Wide camera;
  - [ ] the `Frame latency` lines with it on (the open item in iOS 26 → Cinematic Video).
- [ ] **Night plan.** The `Night: N frames at …` line shows a real auto shutter (no `n/a`), and a dim scene plans a brighter exposure than auto (the plan is now read before the switch to InputPriority, which restarted auto exposure: on 2026-10-07 it read 1/170 s and planned frames too dark).
- [ ] **Fewer camera switches.** SLO-MO → NIGHT logs one `swapInput` (staying on the wide camera), and a flip back to the rear camera in NIGHT logs one `swapInput` straight to the wide camera.
- [ ] **Filter Chain 48MP format.** The `Started:` line shows `420f` (it was `420v`), and the log has no `no CGColorSpace payload` notice.
- [ ] **Latency log.** After the app comes back from the background, the next `Frame latency` line spans about 5 s (it spanned the time away).

## iOS 26

- [ ] **Deferred start.** Apps linked on iOS 26 defer the photo and movie outputs by default (Prism also defers its metadata output). Cold boot, then capture immediately: no `awaitPhotoOutputReady: timeout` warning in the log. Repeat right after a camera switch, and once with *Subject Tracking* on before boot.
  - Result 2026-10-06 (iPhone 18 Pro Max, iOS 27.0): with the system default, every wait logged `ready after 0 ms`: after boot, before each capture, and after the Triple / Wide switches for SLO-MO. The *Subject Tracking* run is still open.
- [ ] **Rect focus.** Turn on *Rect Focus*, tap a small subject: focus and exposure follow a region twice the system default.
- [ ] **White balance presets.** The Tung / Fluor / Day / Cloud / Shade chips lock to Apple's calibrated values; the readout shows the calibrated Kelvin (it may differ from the old nominal 3200 / 4000 / 5500 / 6500 / 7500).
- [ ] **Nominal focal lengths.** Lens chips read Apple's nominal values (for example 13 / 24 / 48 / 120 mm on an iPhone 17 Pro).
- [ ] **Lens smudge detection.** Turn on *Smudge Detection*, smear the lens: `SMUDGE` appears in the telemetry strip within one detection run (30 s), and clears after cleaning.
- [ ] **Interruption reason.** Trigger an interruption (Control Center camera, a call): the toast and the telemetry strip name the reason (`INT:camera-busy`, `INT:background`, …) while interrupted.
- [ ] **Object detection.** *Detect → Faces / People / Pets* outlines each detection in white; the outlines track the subjects (front camera too, where the preview is mirrored) and clear when set back to *Off*.
- [ ] **Low-latency stabilization.** *Stabilization → LowLat* is accepted; the row reads `low latency → low latency` (choice → what the connection runs).
- [ ] **Cinematic Video.** On a supporting camera, turn on *Cinematic Video*, switch to VIDEO and record:
  - [ ] the clip has a shallow depth of field; tapping a subject racks focus to it (yellow box follows it), and every face and body Cinematic Video sees is outlined;
  - [ ] *Cine Tap → Strong*: a tap on an outlined face tracks that person (not just the point); *Weak* shows a faded box and a gentler focus pull; *Fixed* holds focus at the tapped distance and shows an orange box;
  - [ ] *Depth Aperture* changes the blur before recording and is refused while recording;
  - [ ] `CINE·DARK` appears in a dim room;
  - [ ] photo capture still works with Cinematic Video on, or AVError -11872 appears (if so, enable with `targetPhotoOutputAttached: false`);
  - [ ] the preview never freezes after enabling (a frozen preview means the Cinematic format doesn't offer BGRA);
  - [ ] the preview keeps up with motion: the debug line `Frame latency over 5.0s: avg … ms` stays under about 100 ms, and the *Stabilization* row reads `→ off` or `→ low latency` in the preview (the movie gets the chosen mode while recording);
    - Result 2026-10-06 (iPhone 18 Pro Max, iOS 27.0): the preview lagged far behind. The data connection fed the preview with the requested stabilization (`.auto`, which is cinematic on video formats). If the lag remains with low latency, it's Cinematic Video's own rendering, and the next step is a system preview layer for that mode.
  - [ ] a camera switch keeps Cinematic Video on, and no readiness timeout is logged;
  - [ ] enabling on a format that needs a switch logs both commits without a readiness timeout between them;
  - [ ] *Focus Mode* and the lens-position slider are refused with a toast (no crash), and leaving VIDEO for PHOTO keeps Cinematic Video on;
  - [ ] turning Cinematic Video off brings back photo depth (Portrait) and stops the face / body detection feed.
- [ ] **Dynamic aspect ratio (iPhone 17 front camera).** *Sensor Aspect* switches between the offered ratios while the phone stays upright; the preview resizes without freezing. Note whether a format change (48MP, slo-mo) resets the ratio and whether 1:1 changes saved photo dimensions.
- [ ] **Smart Framing (iPhone 17 front camera).** Turn on *Smart Framing* with several people in frame; *Apply* changes the ratio and zoom to the suggestion.
- [ ] **AirPods Camera Control.** With AirPods connected, a stem click takes a photo. With *AirPods Sounds* on, the shutter sound plays through the AirPods for stills, and in VIDEO the begin / end recording sounds play on start and stop. Not available in the EU.
- [ ] **AirPods high-quality mic.** Studio enables it at configure: with AirPods connected, record a clip in VIDEO and confirm the AirPods microphone is offered and the audio is clean (not the narrowband call mic).

## iOS 27

- [ ] **Priority modes.** On a single-lens device (the Studio switches to the wide camera for manual exposure):
  - [ ] *Priority → Tv* holds the shutter while ISO (and aperture, where variable) keep metering as the scene brightness changes;
  - [ ] *Sv* holds ISO the same way; `Tv` / `Sv` show in the telemetry strip;
  - [ ] the slider under the priority picker sets the locked value (shutter in Tv, ISO in Sv) while the other axes keep metering;
  - [ ] still captures in a priority mode honor the locked axis.
- [ ] **Priority modes on a virtual device.** Open question: are priority modes honored on `.builtInTripleCamera`, with and without *Lens Lock*? Prism refuses them there today (`prm_setExposure` throws `virtualDeviceManualControlUnsupported` when any axis is locked), and Studio hops to the wide camera first, so testing this needs a temporary build with that guard removed. If they hold, the guard can be relaxed for priority modes.
- [ ] **Variable aperture (where the hardware has it).** *Aperture* moves the 𝑓-number; `Av` holds it while shutter and ISO meter. *Aperture Pace → Smooth* slows the aperture's moves in auto exposure (pan between bright and dark), *Fast* speeds them up.
- [ ] **Exposure signals.** *AE Signals* lists the supported signals; picking *Document* or *Starburst* changes the aperture choice in matching scenes, and the row's value names the signals auto exposure is acting on.
- [ ] **Lens lock.** *Lens Lock → T* keeps the telephoto in low light instead of falling back to the wide crop; `LOCK` shows in the telemetry strip.
- [ ] **Subject tracking.** Turn on *Subject Tracking*, tap a moving subject:
  - [ ] focus follows it and `TRACK` appears; the yellow box follows the subject;
  - [ ] *Tracking Bias* shifts focus toward the near / far edge of the subject;
  - [ ] tracking survives (or is cleanly re-applied after) a 48MP toggle, a depth (Portrait) switch and a lens switch-over.
- [ ] **Low-light video noise reduction.** *Low-light NR → On* shows `NR` (and *active* on the row) while recording in a dark scene.
- [ ] **Cinematic metadata capture.** *Cine Metadata → On* records clips whose focus can be edited in Photos afterwards; the row shows `→ on` while Cinematic Video is on. *Off* records clips without it.
- [ ] **System pressure.** Under sustained recording heat, `WARM` appears at `.fair` and `HOT` from `.serious`, with the contributing factors (`HOT(cam,batt)`).
- [ ] **Night on a Pro iPhone.** On a phone whose back camera is a Triple or Dual Camera, NIGHT switches to the wide camera (log: `switchDevice(type=BuiltInWideAngleCamera`), the night shot saves, and leaving NIGHT for PHOTO switches back. Also SLO-MO to NIGHT (one switch, none back to the Triple Camera in between) and NIGHT to SLO-MO.
  - Result 2026-10-06 (iPhone 18 Pro Max, iOS 27.0): before the fix, a Night shot on the Triple Camera crashed with `NSInvalidArgumentException` ("The active format of the source device does not support manual exposure bracketed capture"). iOS 27 checks the format before a manual-exposure bracket, and virtual cameras' formats refuse it.
- [ ] **Portrait rotation baseline.** After a camera switch the preview is upright from the first frame, with no sideways flash before motion data arrives.

## Configuration Lab (iOS 26 / 27 group)

Pick the options, tap *Apply Configuration*, and read the status lines: *iOS 26/27 support* lists what the camera reports, *iOS 26/27 landed* what the session ended up with.

- [ ] **Support line.** Lists aperture range, AE signals, lens lock, focus / exposure rects, AF tracking, smudge detection, low-light NR, Cinematic Video (frame rate, zoom and depth ranges), aspect ratios and Smart Framing as the device and OS allow; the lens line says `nominal` on iOS 26.
- [ ] **Deferred start.** *Off*, *System* and *Photo+Movie* all reach a live preview, and *Capture* right after Apply works without a readiness timeout in the log.
- [ ] **Lens smudge detection.** *Once*, *Always* and *30 s* report `smudge clean` (or `smudged` with a smeared lens) on the landed line after a few seconds; re-Apply to refresh.
- [ ] **Sensor orientation compensation.** *On* and *Off* both save correctly oriented photos from *Capture*.
- [ ] **Detect objects.** *Faces / People / Pets* show a count badge over the preview (`2 face · 1 body`); the landed line reports the metadata output and its type count. *Attach metadata output at configure* reports the output even with *Detect* off.
- [ ] **Cinematic Video at configure.** Turning it on switches off Live Photo, depth and the matte; after Apply the landed line says `Cinematic Video on`, the badge counts faces and bodies, and the outputs list a movie output.
- [ ] **AirPods high-quality mic.** Turning it on also turns audio on; turning audio off turns it off.

## Logging (any iOS 18+ device)

Run with the device's log open in Console.app, filtered to `subsystem:dev.luminoid.prism` with Info and Debug messages on (the Example sets `PRMLog.minimumLevel = .debug`). For the "kept on device" checks, collect a sysdiagnose afterwards, or set the threshold back to `.info` and confirm the lines still appear.

- [ ] **Session summaries.** Boot Studio, then switch front / back and hop virtual / wide: one `Configured:`, `Started:` and `Switched device:` notice each, naming the device type, position, preset, format, frame rates, outputs and hardware cost. Leaving Studio logs `Stopped`, and `AVCaptureSession isRunning changed to …` follows each start and stop.
  - Result 2026-10-06 (iPhone 18 Pro Max, iOS 27.0): `Configured:`, `Started:`, `isRunning changed to true` and both `Switched device:` notices (virtual / wide hop) appear with every field. Front / back and leaving Studio not yet checked.
- [ ] **Runtime error.** Enter SLO-MO at 240 fps with the photo output still attached (or another configuration that raises AVError -11872): one `Sent to errorStream` error line with `AVFoundationErrorDomain -11872`, matching the error the app receives.
- [ ] **Interruption.** Pull down Control Center's camera or take a call: `AVCaptureSession interrupted: <reason>` at notice, then `interruption ended`.
- [ ] **Thermal state and system pressure.** Record until the device warms: `Thermal state changed to fair / serious` and `System pressure changed to …` lines appear, at warning from serious up, with the contributing factors.
- [ ] **Photo outcomes.** Each still and Live Photo logs `Photo captured:` / `Live Photo captured:` with dimensions, container type and byte count. Cancel a capture mid-flight (leave the screen during a night capture) and get `capture cancelled` instead of an error.
  - Result 2026-10-06 (iPhone 18 Pro Max, iOS 27.0): every still, burst shot and Live Photo logged its outcome line. The cancel case is still open.
- [ ] **Photo failure.** Capture right after toggling Live Photo on a Triple Camera until the readiness wait times out (or detach the photo output and capture): an error line names the stuck signal or the missing output.
- [ ] **Recording outcomes.** Record and stop: `Recording started`, then `Recording finished: <seconds> s, <bytes> bytes`. Fill the disk or hit the maximum duration while recording: one `Recording failed` or `ended with an error while no stop() was pending` error line with the AVError code and `successfullyFinished`.
  - Result 2026-10-06 (iPhone 18 Pro Max, iOS 27.0): VIDEO and SLO-MO logged `Recording started` and `Recording finished` with duration and size. The failure cases are still open.
- [ ] **Recorder start-hang fix.** Make recording fail before it starts (start recording while the session is interrupted, or right after a format change that drops the movie connection): `start()` throws `videoRecordingFailed` and the UI recovers, instead of the record button never responding; the log shows `Recording failed before it started`. Cancelling the task that awaits `start()` before recording begins throws `cancelled`.
- [ ] **No floods.** Force a non-BGRA format under a filter (Portrait depth format on a device whose depth format lacks BGRA): one `Buffer pool needs BGRA input` and one renderer line, not one per frame; they return once after the format recovers and fails again.
