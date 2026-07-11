/*
 * config.h for the OpenCFU mobile native core.
 *
 * The desktop build generates this file with autotools. The mobile build does
 * not use autotools, so we provide a hand-written equivalent that only defines
 * the macros the vendored processor layer actually consumes (see
 * `grep -r PACKAGE_VERSION|INSTALLDIR|TRAINED_CLASSIF` in src/).
 *
 * The classifier files are resolved relative to the current working directory:
 * the bridge chdir()s into the directory that contains `data/` before it
 * constructs a Processor, so `./data/trainedClassifier.xml` resolves against
 * the app's private storage where the Dart layer copies the bundled assets.
 */
#ifndef OPENCFU_MOBILE_CONFIG_H
#define OPENCFU_MOBILE_CONFIG_H

#define PACKAGE_VERSION "3.9.0-mobile"
#define VERSION "3.9.0-mobile"

/* Processor::Processor() falls back to INSTALLDIR when the classifier is not
 * found next to the working directory. On mobile the working directory is
 * already the asset directory, so keep the fallback pointing at "." too. */
#define INSTALLDIR "."

#define TRAINED_CLASSIF_XML_FILE "data/trainedClassifier.xml"
#define TRAINED_CLASSIF_PS_XML_FILE "data/trainedClassifierPS.xml"

#endif /* OPENCFU_MOBILE_CONFIG_H */
