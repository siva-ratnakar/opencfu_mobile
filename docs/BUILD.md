# Building the Android APK

The app **builds and launches fine without any extra flags**, but the native
OpenCFU counting engine (`libopencfu_mobile.so`) is only compiled if Gradle
is told where the OpenCV Android SDK lives. Without it you'll see:

```
Native OpenCFU library not linked: Invalid argument(s): Failed to load
dynamic library 'libopencfu_mobile.so': dlopen failed: library
"libopencfu_mobile.so" not found
```

This is silent by design (see `android/app/build.gradle.kts` and
`native/opencfu_core/README.md`) — a plain `flutter build apk` "succeeds"
but ships an app that can't actually count colonies.

## Correct build command

```
flutter build apk --release \
  -POpenCV_DIR=/home/siva_ratnakar/dev/opencv/OpenCV-android-sdk/sdk/native/jni
```

`OpenCV_DIR` must point at `<OpenCV-android-sdk>/sdk/native/jni` (the
directory containing `OpenCVConfig.cmake`). On this machine the SDK is
already downloaded at `/home/siva_ratnakar/dev/opencv/OpenCV-android-sdk`.

As a convenience, `OpenCV_DIR` has also been added to
`~/.gradle/gradle.properties` (not part of this repo) on this machine, so a
plain `flutter build apk --release` now picks it up automatically. The
explicit `-POpenCV_DIR=...` flag above still works and is what to use on any
other machine/CI where that global property isn't set.

## Sanity check

Confirm the native lib actually made it into the APK before handing it off:

```
python3 -c "
import zipfile
z = zipfile.ZipFile('build/app/outputs/flutter-apk/app-release.apk')
print([n for n in z.namelist() if 'libopencfu_mobile' in n])
"
```

Should list `lib/arm64-v8a/libopencfu_mobile.so`,
`lib/armeabi-v7a/libopencfu_mobile.so`, and
`lib/x86_64/libopencfu_mobile.so`. A release APK with the native engine
linked is ~120 MB; one without it is ~59 MB — a quick way to eyeball whether
`OpenCV_DIR` was picked up.

## `flutter clean` caveat

`flutter clean` wipes the CMake build cache (`android/app/.cxx`) along with
everything else. The next build after a clean must pass `OpenCV_DIR` again
(or rely on the global gradle.properties above) — it does not persist
anywhere else.

# Building the web app

```
flutter build web --release --base-href /<repo-name>/
```

`--base-href` must match the URL path the app is served from, with leading
and trailing slashes:

- **GitHub Pages project site** (`https://<user>.github.io/<repo-name>/`):
  `--base-href /<repo-name>/` -- for this repo, `/opencfu_mobile/`.
- **Custom domain at the root** (`https://yourdomain.com/`): `--base-href /`
  (the default — the flag can be omitted).

## Deploying to GitHub Pages

`.github/workflows/deploy-web.yml` builds and publishes `build/web` to
GitHub Pages automatically on every push to `main`. One-time setup:

1. Push this repo to GitHub (already done if `git remote -v` shows an
   `origin`).
2. On GitHub: repo **Settings > Pages > Source**, select **"GitHub
   Actions"**.
3. Push to `main` (or run the workflow manually from the **Actions** tab —
   it's also listed there under "Deploy web to GitHub Pages", with a **Run
   workflow** button). The first run takes a few minutes; the deployed URL
   shows up in the workflow's summary and under Settings > Pages once it
   finishes, at `https://<your-github-username>.github.io/opencfu_mobile/`.

No local build or manual file copying needed after that — every push to
`main` redeploys automatically. If you'd rather deploy by hand instead of
using the workflow, see the sanity checklist and troubleshooting notes below.

### Custom domain instead of GitHub Pages' default subpath

1. Add a `web/CNAME` file containing just your domain (e.g.
   `count.example.com`) -- `flutter build web` copies everything in `web/`
   into `build/web/` verbatim, so this carries through automatically, and
   `actions/deploy-pages` picks it up the same way a manual deploy would.
2. Change the workflow's `--base-href` to `/` (the app is now served from
   the domain's root, not a `/opencfu_mobile/` subpath).
3. Point your domain's DNS at GitHub Pages (a `CNAME` record to
   `<your-github-username>.github.io` for a subdomain, or the GitHub Pages
   `A`/`AAAA` records for an apex domain -- see GitHub's "Managing a custom
   domain for your GitHub Pages site" docs for the current IPs).

### Deploying by hand (no GitHub Actions)

```
flutter build web --release --base-href /opencfu_mobile/
```

Then either push `build/web`'s contents to a `gh-pages` branch (with Pages'
source set to "Deploy from a branch" instead of "GitHub Actions"), or copy
them anywhere else that serves static files -- GitHub Pages needs nothing
beyond plain static hosting, no server-side config.

### Sanity-checking a build before publishing

```
cd build/web && python3 -m http.server 8000
```

then open `http://localhost:8000` (note: this serves at the root, not the
`/opencfu_mobile/` subpath baked into a `--base-href /opencfu_mobile/`
build -- rebuild with `--base-href /` first if you want to sanity-check
locally at the root, or mimic the real path with e.g. `mkdir -p
/tmp/site/opencfu_mobile && cp -r build/web/* /tmp/site/opencfu_mobile/ &&
cd /tmp/site && python3 -m http.server 8000`, then visit
`http://localhost:8000/opencfu_mobile/`).

### If it doesn't work

- **Blank white page**: almost always a `--base-href` mismatch -- open
  the browser console (F12), a wall of 404s for `main.dart.js`/`assets/...`
  means the base href doesn't match where it's actually being served from.
- **Old version keeps showing after a redeploy**: Flutter web ships a
  service worker (`flutter_service_worker.js`) that aggressively caches the
  build. A hard refresh (Ctrl/Cmd+Shift+R) or a private/incognito window
  usually clears it; it should resolve on its own within a page load or two
  otherwise.
- **Camera doesn't prompt for permission**: browsers only allow camera
  access on `https://` or `localhost` -- GitHub Pages is always `https://`,
  so this only bites during local `http://` testing (gallery import still
  works there instead).

## Known limitation: no automatic colony counting on web

The native OpenCFU engine (`native/opencfu_core`) is C++/OpenCV compiled via
`dart:ffi`, which the web target doesn't support — there's no WebAssembly
build of it. `lib/services/opencfu_engine_stub.dart` is used automatically on
web (see the conditional export in `opencfu_engine.dart`) and always reports
the engine as unavailable, same as a native build without `libopencfu_mobile`
linked.

The rest of the app still works: capture/import a photo, count manually
(tap-to-add markers in Advanced mode, or just type a number via the count
edit dialog in Basic mode), and save/export PDF/CSV/PNG results — all of
that runs entirely in Dart/the browser. Porting the counting engine itself to
WebAssembly (via Emscripten) is a separate, much larger undertaking not done
here.

## Web-specific implementation notes

Two things `dart:io` can't do on web needed browser-native replacements
(both live behind `kIsWeb` checks, so native builds are unaffected):

- **Showing the captured/imported photo**: `Image.file` is unsupported on
  Flutter web. `_xFileImage()` in `lib/main.dart` uses `Image.network` with
  the `XFile`'s `blob:` URL instead (that's what `image_picker`/`camera_web`
  hand back on web).
- **Saving/exporting files**: there's no filesystem to write into.
  `lib/services/web_download_web.dart` (loaded via the same
  stub/native-style conditional export pattern as `opencfu_engine.dart`,
  see `lib/services/web_download.dart`) triggers a normal browser download
  (a `Blob` + object URL + a clicked, invisible `<a download>`) instead.
