// Loaded via a <script defer> tag from web/index.html. Wraps the
// Embind-based opencfu_mobile.wasm module (built from
// native/opencfu_core/wasm/, see its README.md) behind one plain async
// function taking/returning only simple JS values (numbers, strings,
// Uint8Arrays, plain objects/arrays) -- lib/services/opencfu_engine_web.dart
// calls this one function over dart:js_interop instead of constructing
// Embind's vector/value_object types itself, which interop can do but is
// far more error-prone to get right blind (no browser available while this
// was written -- see docs/BUILD.md's web WASM section).
(function () {
  // document.currentScript is only valid synchronously, during this
  // script's own top-level execution -- capture it now. Reading it again
  // later inside loadModule() (called asynchronously, whenever the operator
  // first triggers an analysis) would return null, since by then this
  // script has long finished running and is no longer "the current script".
  // That was silently resolving opencfu_mobile.js against the page's own
  // URL instead of this script's folder, 404ing on any base-href other than
  // "/" (e.g. a GitHub Pages project site).
  const thisScriptUrl = document.currentScript ? document.currentScript.src : '';
  const base = thisScriptUrl ? thisScriptUrl.replace(/[^/]+$/, '') : '';

  let modulePromise = null;
  let classifierReady = false;

  function loadModule() {
    if (modulePromise) return modulePromise;
    modulePromise = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = base + 'opencfu_mobile.js';
      script.onload = () => {
        // opencfu_mobile.js was built with -sMODULARIZE=1 -sEXPORT_NAME=OpenCfuModule,
        // so loading it as a classic script attaches the factory function to
        // the global scope under that name.
        globalThis.OpenCfuModule({
          // Emscripten's default locateFile resolves the .wasm relative to
          // the page, not to this script -- override so it still finds it
          // when the app is served from a subpath (e.g. GitHub Pages).
          locateFile: (path) => base + path,
        }).then(resolve).catch(reject);
      };
      script.onerror = () => reject(new Error('Failed to load opencfu_mobile.js'));
      document.head.appendChild(script);
    });
    return modulePromise;
  }

  function ensureClassifier(Module, classifierBytes) {
    if (classifierReady) return;
    // Same file copied to both names -- mirrors what
    // opencfu_engine_native.dart does on Android/iOS (see its doc comment).
    Module.FS.mkdirTree('/classifiers/data');
    Module.FS.writeFile('/classifiers/data/trainedClassifier.xml', classifierBytes);
    Module.FS.writeFile('/classifiers/data/trainedClassifierPS.xml', classifierBytes);
    classifierReady = true;
  }

  window.opencfuAnalyze = async function (imageBytes, classifierBytes, opts) {
    const Module = await loadModule();
    ensureClassifier(Module, classifierBytes);
    Module.FS.writeFile('/input', imageBytes);

    const maskX = new Module.VectorFloat();
    const maskY = new Module.VectorFloat();
    for (const v of opts.maskPointsX) maskX.push_back(v);
    for (const v of opts.maskPointsY) maskY.push_back(v);

    let result;
    try {
      result = Module.analyze(
        '/input',
        '/classifiers',
        opts.thresholdMode,
        opts.autoThreshold,
        opts.threshold,
        opts.minRadius,
        opts.maxRadius,
        opts.hasMaxRadius,
        opts.hueFilter,
        opts.outlierFilter,
        opts.outlierThreshold,
        opts.similarColours,
        opts.clusterDistance,
        opts.maskType,
        opts.maskTool,
        maskX,
        maskY
      );
    } finally {
      maskX.delete();
      maskY.delete();
    }

    // Flatten Embind's vector-typed fields (colonies, maskPointsX/Y -- see
    // wasm_bridge.cpp's EMSCRIPTEN_BINDINGS block) into plain JS
    // arrays/objects, and free their WASM-heap-backed wrappers once copied
    // out. Individual colony entries are plain value_objects already (no
    // nested vectors), so they need no separate cleanup.
    const colonies = [];
    const colonyCount = result.colonies.size();
    for (let i = 0; i < colonyCount; i++) {
      const c = result.colonies.get(i);
      colonies.push({
        cx: c.cx,
        cy: c.cy,
        cornerX: [c.cornerX0, c.cornerX1, c.cornerX2, c.cornerX3],
        cornerY: [c.cornerY0, c.cornerY1, c.cornerY2, c.cornerY3],
        radius: c.radius,
        valid: c.valid,
      });
    }
    result.colonies.delete();

    const maskPointsX = [];
    const maskPointsY = [];
    const maskPointCount = result.maskPointsX.size();
    for (let i = 0; i < maskPointCount; i++) {
      maskPointsX.push(result.maskPointsX.get(i));
      maskPointsY.push(result.maskPointsY.get(i));
    }
    result.maskPointsX.delete();
    result.maskPointsY.delete();

    return {
      ok: result.ok,
      errorMessage: result.errorMessage,
      colonyCount: result.colonyCount,
      totalCount: result.totalCount,
      imageWidth: result.imageWidth,
      imageHeight: result.imageHeight,
      maskApplied: result.maskApplied,
      maskPointsX,
      maskPointsY,
      colonies,
    };
  };
})();
