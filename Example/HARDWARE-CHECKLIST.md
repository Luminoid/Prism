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
- [ ] **Cinematic Video on a Pro iPhone.** The Triple camera has no Cinematic Video format, so the drawer row used to stay disabled.
  - [ ] *Cinematic Video* turns on from the Triple camera: the log shows `Cinematic Video: BuiltInTripleCamera has no Cinematic Video format, switching to …`, the lens strip changes to that camera's lenses, and a VIDEO recording has the shallow depth of field;
  - [ ] turning it off returns to the Triple camera (`Cinematic Video off: switching back to BuiltInTripleCamera`);
  - [ ] a flip with it on lands on the front camera Cinematic Video runs on with it still on, and a flip back lands on the back camera it ran on;
  - [ ] no `Slow frame latency` line with it on (the open item in iOS 26 → Cinematic Video).
  - Result 2026-10-08 (iPhone 18 Pro Max, iOS 27.0): it switched to `BuiltInWideAngleCamera` (not the Dual Wide camera), a flip landed on the front `BuiltInUltraWideCamera` without a switch, and VIDEO recorded. On the front camera in PHOTO the preview lagged (`Slow frame latency` avg 105 ms); PHOTO now turns Cinematic Video off, so check the lag in front VIDEO.
- [ ] **Night plan.** The `Night: N frames at …` line shows a real auto shutter (no `n/a`), and a dim scene plans a brighter exposure than auto (the plan is now read before the switch to InputPriority, which restarted auto exposure: on 2026-10-07 it read 1/170 s and planned frames too dark).
- [ ] **Fewer camera switches.** SLO-MO → NIGHT logs one `swapInput` (staying on the wide camera), and a flip back to the rear camera in NIGHT logs one `swapInput` straight to the wide camera.
- [ ] **Filter Chain 48MP format.** The `Started:` line shows `420f` (it was `420v`), and the log has no `no CGColorSpace payload` notice.
- [ ] **Latency log.** After the app comes back from the background, a `Slow frame latency` line, if one appears, spans about 5 s, not the time away.
  - Result 2026-10-07 (iPhone 18 Pro Max, iOS 27.0): steady windows read 30 to 50 ms, so the line now appears only for a slow window (an average of 100 ms or more, or one frame 250 ms behind).

## Log review fixes (2026-10-07, second run)

- [ ] **Unsupported modes.** In Studio's drawer, *WB Mode → Auto* on an iPhone toasts "Back Camera has no auto (one-shot) white balance. It offers locked and continuous auto." and snaps back to the current mode; the camera stays where it was (on 2026-10-07 the refusal left Studio thinking white balance was automatic, so it hopped back to the Triple camera while the wide camera's white balance stayed locked).
- [ ] **Photo size.** Each `capturePhoto:` debug line shows the size asked for (`up to 8064×6048`) and the quality; a `Photo captured:` line smaller than that ends with the reason, such as `(asked for up to 8064x6048: manual exposure and locked white balance capture at 12 MP)`. With Max Dimensions on, automatic exposure and continuous white balance, a photo in daylight comes back 8064x6048 (send the line if it doesn't).
- [ ] **SLO-MO → NIGHT.** No `Live Photo requested but not supported: a movie output is attached` line: slow motion's exit now drops the movie output and its frame rate before the photo output comes back.
- [ ] **Slider logs.** A shutter, ISO, white balance or aperture drag logs two lines (the first value and `… (settled after N more)`), not one per tick, and the aperture slider sends each stop once per drag.

## Setting conflicts (newest wins)

Each change below should land, move the other controls to match, toast the text shown, and log a `Conflict:` line (`Refused:` for the refusals). Send the line for any row that doesn't.

- [ ] **Max Dimensions on** in LIVE (or PORTRAIT, BURST): Studio moves to PHOTO first. "Max Dimensions turned off LIVE: the 48 MP format has no Live Photo movie or depth."
- [ ] **Max Dimensions on** with WB locked (or an ISO, shutter, aperture or priority set): "Max Dimensions turned off locked white balance: manual photos are 12 MP." Exposure and white balance read auto afterwards, and a daylight photo comes back 8064x6048.
- [ ] **ISO drag** with Max Dimensions on: "ISO turned off Max Dimensions: manual photos are 12 MP."
- [ ] **ISO drag** in LIVE: "ISO turned off LIVE: Live Photo keeps exposure automatic." In PORTRAIT: "… turned off PORTRAIT: a manual capture carries no depth."
- [ ] **LIVE** with Max Dimensions on, ISO set or WB locked: "LIVE turned off Max Dimensions and manual exposure: …"; **PORTRAIT** turns off manual exposure the same way; **BURST** turns off Max Dimensions.
- [ ] **Cinematic Video on** in PHOTO or PORTRAIT with Subject Tracking on: Studio moves to VIDEO. "Cinematic Video turned off Subject Tracking and PORTRAIT: …". With Max Dimensions on, it's turned off too.
- [ ] With **Cinematic Video on**: PHOTO, PORTRAIT, LIVE, NIGHT or SLO-MO turns it off ("PHOTO turned off Cinematic Video: photos would come from Cinematic Video's 16:9 video format."), as do Focus Mode, the Focus slider and Subject Tracking ("… turned off Cinematic Video: Cinematic Video controls focus."), and ISO / WB ("… Cinematic Video keeps exposure and white balance automatic."). The camera goes back to the Triple camera in each case.
- [ ] **Lens Lock** on a Triple-camera lens, then an ISO drag: "ISO turned off Lens Lock: manual controls run on the wide camera.", and the Lens Lock segment reads Auto.
- [ ] **Flip to the front camera** with Max Dimensions on: "Front Camera turned off Max Dimensions: it caps at 12 MP." (the camera's own name).
- [ ] **Configuration Lab**: turning on *Live Photo capture* with *Movie file output* on toasts "Live Photo capture turned off Movie file output: Live Photo can't run beside a movie output."; *Portrait-effects matte* on with depth off toasts "… turned on Depth-data delivery …".
- [ ] **Refused**:
  - [ ] In VIDEO, SLO-MO and NIGHT the Max Dimensions row is dimmed ("Max Dimensions is for photos"); it keeps its setting, and back in PHOTO the 48MP format comes back (`applyPhotoFormat(max-dimensions)` in the log; it used to stay at 12MP after a frame-rate change).
  - [ ] While recording on the Triple camera, ISO and Shutter are dimmed ("Stop recording to change ISO: manual exposure needs the wide camera."), and so are Cinematic Video, Lens Lock and Sensor Aspect.
  - [ ] Tracking Bias is dimmed until Subject Tracking is on.
  - [ ] Low-light boost and HDR are dimmed on a camera or format without them.
  - [ ] A vertical EV drag under a custom exposure toasts "EV does nothing under manual exposure. Set exposure to Auto first." and leaves the exposure alone.
  - [ ] A camera refusal toasts "Not available: <reason>" instead of "Camera failed: Unsupported in the current configuration: …".
- [ ] **Tap to focus** under a custom exposure focuses and keeps the ISO and shutter (it used to reset them to auto).

## Log review fixes (2026-10-08)

The 2026-10-08 log (iPhone 18 Pro Max, iOS 27.0) confirmed the WB *Auto* refusal, the photo-size lines and an 8064x6048 Max Dimensions photo, the slider bursts, SLO-MO → NIGHT on one camera, the Filter Chain `420f` format, a real auto reading in the Night plan, and the Max Dimensions → LIVE, LIVE → manual exposure and Cinematic Video → manual exposure conflicts. Fixes from it to check:

- [ ] **Shutter during a mode change.** Pick SLO-MO from VIDEO and tap the shutter at once: the recording starts once the switch to the wide camera lands (`Record waited for the camera setup in flight`). It used to start on the old camera and fail with "Cannot Record" (AVError -11805) when the setup switched cameras under it.
- [x] **Night, 1 s handheld.** Most frames merge. On 2026-10-08, 14 of 17 were rejected as blurred against a first frame that measured twice as sharp as the rest; each frame is now compared with the median of the frames before it. Rejections read `blurred (sharpness N vs typical M)`.
  - Result 2026-10-09 (lit room): 29 of 39 frames at *1s*, 53 of 64 at *3s*. The 39 was more than a 30 fps format delivers in a second; see the 2026-10-09 section.
- [x] **Cinematic Video and PHOTO.** With Cinematic Video on, PHOTO turns it off (toast above), and turning it on in PHOTO moves to VIDEO. With it on, front photos had come back 2160x3840 JPEG from its 16:9 format.
  - Result 2026-10-09: both directions logged their `Conflict:` line.
- [x] **Cinematic Video from a manual exposure.** With an aperture or ISO set (so Studio is on the wide camera), turning Cinematic Video on logs no `swapInput` on an iPhone 18 Pro Max, whose wide camera runs it (it used to go to the Triple camera and straight back). Turning it off goes back to the Triple camera (`Studio: back to BuiltInTripleCamera, …`).
  - Result 2026-10-09: from 𝑓/4.0, no switch; PHOTO turned it off and went back to the Triple camera.
- [ ] **A locked focus keeps the wide camera.** Drag *Focus*, set ISO, then set exposure and WB back to auto: Studio stays on the wide camera and the focus stays put. *Focus Mode → Cont* then goes back to the Triple camera.
- [x] **Hops say why.** Each manual hop's `swapInput` follows a `Studio: to the wide camera for <control>` line, and each return a `Studio: back to …` line. A focus drag logs `PRMCamera.setLensPosition(…)` like the other sliders.
  - Result 2026-10-09: NIGHT, ISO, White balance, Manual focus and Max Dimensions each named.
- [x] **Codec.** With HEIC selected, the 48MP photos, the aperture photos and the front Cinematic Video photos came back JPEG on 2026-10-08. A JPEG photo now logs `Photo codec hvc1 isn't offered by the output now (it offers …)` when that's why; send that line, or the `Photo captured:` line if there's none (the capture then ignored the codec).
  - Result 2026-10-09: every photo was HEIC until one right after the focus rows; from then on all were JPEG with no codec notice. The *Codec* row sits just below them and logged nothing, so it was most likely set to JPEG. It logs now (2026-10-09 section).
  - Result 2026-10-09, second log: `Studio Codec → jpeg`, then JPEG photos. Not a camera fault.
- [ ] **Error lines.** A failed capture logs the error case and codes (`Record failed: … <- AVFoundationErrorDomain -11805 <- NSOSStatusErrorDomain -16418`), not the whole Swift description. A capture with no size set reads `capturePhoto: default size`, not `up to 0×0`.

## Log review fixes (2026-10-09)

The 2026-10-09 log (iPhone 18 Pro Max, iOS 27.0) confirmed HEIC from PHOTO, LIVE, PORTRAIT, BURST and NIGHT, the hop reasons, the focus-slider line, `capturePhoto: default size`, the PHOTO and Cinematic Video conflicts in both directions, and Cinematic Video turned on from an aperture without a camera switch. Fixes from it to check:

- [x] **Drawer choices are logged.** Changing *Codec*, *HDR*, *Low-Light Boost*, *Stabilization* or *Auto Red-Eye* logs `Studio <row> → <value>`. A JPEG photo now follows a `Studio Codec → jpeg` line or the codec notice; one with neither is a camera that ignored the codec.
  - Result 2026-10-09, second log: `Studio Codec → jpeg`, then a JPEG photo.
- [x] **Night frame counts.** In a lit room, *1s* plans about 30 frames on a 30 fps format. It planned 39 from a 1/38 s shutter, more than the format delivers in a second, so "29 of 39" looked like ten rejections. The photo line now reads `Night photo: N of M frames (R rejected, S skipped while merging)`: skipped frames arrived while the previous one was still merging; rejected ones were blurred or couldn't be aligned.
  - Result 2026-10-09, second log: *AUTO* planned 30 frames at 1/40 s and merged 27 (0 rejected, 3 skipped). *3s* merged 64 of 64 twice (2 and 19 skipped).
- [ ] **A manual control in VIDEO keeps VIDEO's frame rate.** In VIDEO, set the aperture or ISO: after `Studio: to the wide camera for …` the log shows `PRMCamera.setFrameRate(30.0, …)` and `switching sessionPreset Photo → InputPriority`, and the return to auto does the same after `Studio: back to …`. A clip recorded after the switch has the same dimensions as one recorded before it. The switch used to leave VIDEO on the Photo preset (`preset=Photo` in the `Switched device` line, and no `resetFrameRate: restoring` line on the way to PHOTO).
- [ ] **VIDEO → PHOTO from the wide camera.** With Cinematic Video on (or a manual hop) in VIDEO, picking PHOTO logs `Movie output detached, Live Photo off` before `Studio: back to BuiltInTripleCamera`; the `swapInput post:` line reads `live(supported=true, …)` and the outputs list has no `movie`. It used to swap with the movie output attached (`live(supported=false, …)`, `hardwareCost=0.50`).
- [ ] **Max Dimensions in VIDEO.** Tapping the dimmed row toasts "Max Dimensions is for photos. Switch to PHOTO to use it." when it's off, and "… It stays on for when you go back to PHOTO." when it's on. It used to say it was kept even when off.
- [ ] **Focus Mode is traced.** A *Focus Mode* change logs `PRMCamera.setFocusMode(…)` at debug, before any `Studio: back to …` it causes.

## iPhone 14 Pro on iOS 18 (2026-10-09)

The 2026-10-09 log (iPhone 14 Pro, iOS 18) confirmed PHOTO, LIVE, VIDEO at 30 fps, NIGHT's hop to the wide camera and back, a locked white balance and lens position on the wide camera, an 8064x6048 JPEG with *Max Dimensions* on, and the ISO refusal in NIGHT. Fixes from it to check:

- [ ] **PORTRAIT gets depth.** The 14 Pro's Triple camera lists no depth format on iOS 18: the log said `Portrait: no depth-capable format on this camera`, the pill read unavailable, and the photo had no depth. PORTRAIT now logs `Studio: to BuiltInDualWideCamera for PORTRAIT, BuiltInTripleCamera has no depth format`, the pill tracks the subject, and the photo opens as Portrait in Photos. Leaving PORTRAIT logs `Studio: back to BuiltInTripleCamera after PORTRAIT` before the next mode's setup. A camera that has a depth format doesn't switch.
  - Result 2026-10-09, second 14 Pro log: the switch and return lines as above, the pill went `moveCloser` → `ready (2.29 m)` and tracked distance, and the capture asked for `depth=true, portrait=true`. Still to check: the photo opens as Portrait in Photos.
  - Result 2026-10-09 (iPhone 18 Pro Max, iOS 27.0): its Triple camera has a depth format, so PORTRAIT stayed on it (no switch line), the pill read `ready`, and the capture asked for depth.
- [ ] **Depth Inspector.** It opens on the Dual Wide camera (`Configured: device=BuiltInDualWideCamera`, no `Depth data delivery requested but not supported` line) and the depth tile fills in. It used to say the phone had no dual camera.
- [ ] **WB and Focus rows on the Triple camera.** That camera can't lock white balance to a temperature or focus at a lens position, so both rows were disabled (`Refused: WB (This camera can't lock white balance to a temperature)`) while *WB Mode → Locked* moved to the wide camera fine. The Kelvin slider, a WB preset and the Focus slider now log `Studio: to the wide camera for …` and apply.
  - Result 2026-10-09, second 14 Pro log: the Kelvin slider logged `Studio: to the wide camera for White balance` and locked. The Focus slider and the presets weren't tried.
- [ ] **WB or focus in PORTRAIT.** On the back camera, locking white balance or dragging *Focus* in PORTRAIT toasts "… turned off PORTRAIT: manual controls run on the wide camera, which has no depth." and lands in PHOTO on the wide camera. On the front TrueDepth camera PORTRAIT stays on.
  - Result 2026-10-09 (iPhone 18 Pro Max, iOS 27.0): the Kelvin slider in PORTRAIT logged `Conflict: White balance turned off PORTRAIT (…)`, moved to PHOTO and then to the wide camera. The front camera wasn't tried. The picker line it wrote read like a tap (`Studio picker: PHOTO / STANDARD`, before the `Conflict:` line); see the next item.
- [ ] **A conflict's mode change names its cause.** The same drag now logs `Studio picker: PHOTO / STANDARD (for White balance)`; a tap on the picker logs no `(for …)`.
- [ ] **Mode segments offer only what the camera runs.** *WB Mode → Auto* is greyed out on every iPhone camera (none has one-shot auto white balance). The 2026-10-09 iOS 27 log shows it refused twice in a row (`Refused: auto (one-shot) white balance (…)`). *Exposure Mode* and *Focus Mode* segments stay enabled where the camera has the mode; after a switch to the wide camera and back the greyed segments still match.
- [x] **Opaque HEIC.** A Night photo (or a filtered HEIC) logs no `writeImageAtIndex … opaque image … 'AlphaLast'` error, and the file is smaller than before for the same scene.
  - Result 2026-10-09, second 14 Pro log: no AlphaLast line after the Night HEIC.
- Night on the 14 Pro merged 14 of 30 frames at 1/48 s (17 skipped while merging), then 10 of 22 at 1/22 s (13 skipped): an A16 takes two frame intervals or more per 12 MP frame, so a bright 1 s scene keeps about half its frames.
- [ ] **Night stage timing.** The Night photo line now ends its counts with `N ms a frame: P prepare, A align, M merge` (the BGRA frame, quarter-size copy and sharpness; Vision's alignment and the identity check; the GPU merge). Send the line from a 14 Pro run in a dim room and a bright one: it says which stage to speed up.

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
  - [ ] the preview keeps up with motion: no debug line `Slow frame latency over 5.0s: …` (it appears when a window averages 100 ms or more, or one frame lags 250 ms), and the *Stabilization* row reads `→ off` or `→ low latency` in the preview (the movie gets the chosen mode while recording);
    - Result 2026-10-06 (iPhone 18 Pro Max, iOS 27.0): the preview lagged far behind. The data connection fed the preview with the requested stabilization (`.auto`, which is cinematic on video formats). If the lag remains with low latency, it's Cinematic Video's own rendering, and the next step is a system preview layer for that mode.
  - [ ] a camera switch keeps Cinematic Video on, and no readiness timeout is logged;
  - [ ] enabling on a format that needs a switch logs both commits without a readiness timeout between them;
  - [ ] *Focus Mode* and the lens-position slider turn Cinematic Video off with a toast (no crash), and leaving VIDEO for PHOTO turns it off too (`Conflict: PHOTO turned off Cinematic Video …`);
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
