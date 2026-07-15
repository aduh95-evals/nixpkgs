{
  lib,
  stdenvNoCC,
  fetchurl,
  gcc,
  gfortran,
  bzip2,
  ncurses,
  pcre2,
  perl,
  readline,
  xz,
  zlib,
  pkg-config,
  bison,
  which,
  runCommand,
  blas,
  lapack,
  curl,
  tzdata,
  withRecommendedPackages ? false,
  enableStrictBarrier ? false,
  enableMemoryProfiling ? false,
  # R as of writing does not support outputting both .so and .a files; it outputs:
  #     --enable-R-static-lib conflicts with --enable-R-shlib and will be ignored
  static ? false,
  testers,
}:

assert (!blas.isILP64) && (!lapack.isILP64);

let
  # A stub toolchain. R records absolute paths to the compiler/archiver it was
  # built with in `$out/lib/R/etc/Makeconf`, which would otherwise retain the
  # full GCC (and binutils) in the runtime closure. We build with the real
  # toolchain but rewrite those paths to point at these tiny no-op stubs, so the
  # slim build does not depend on the real GCC at runtime. Compiling R packages
  # from source is intentionally unsupported in this variant.
  dummyToolchain = runCommand "r-slim-dummy-toolchain" { } ''
    mkdir -p "$out/bin"
    msg='This is a slim, toolchain-free R build; compiling code from source is not supported.'
    for prog in cc gcc c++ g++ gfortran g77 ar ranlib ld nm; do
      {
        echo '#!/bin/sh'
        echo "echo \"$msg\" >&2"
        echo 'exit 1'
      } > "$out/bin/$prog"
      chmod +x "$out/bin/$prog"
    done
  '';
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "R";
  version = "4.6.0";

  src =
    let
      inherit (finalAttrs) pname version;
    in
    fetchurl {
      url = "https://cran.r-project.org/src/base/R-${lib.versions.major version}/${pname}-${version}.tar.gz";
      hash = "sha256-uNybRUNmDHtZa4eTjfUyOUNQNgl2Un00QijuDtEuRew=";
    };

  outputs = [
    "out"
  ];

  nativeBuildInputs = [
    bison
    gcc
    gfortran
    perl
    pkg-config
    tzdata
    which
  ];

  buildInputs = [
    bzip2
    ncurses
    pcre2
    readline
    xz
    zlib
    which
    blas
    lapack
    curl
  ];
  strictDeps = true;

  patches = [
    ./no-usr-local-search-paths.patch
  ];

  dontDisableStatic = static;

  preConfigure = ''
    configureFlagsArray=(
      --disable-lto
      --with${lib.optionalString (!withRecommendedPackages) "out"}-recommended-packages
      --with-blas="-L${blas}/lib -lblas"
      --with-lapack="-L${lapack}/lib -llapack"
      --with-readline
      --without-tcltk
      --without-cairo
      --without-libpng
      --without-jpeglib
      --without-libtiff
      --without-ICU
      --without-x
      --disable-java
      ${lib.optionalString enableStrictBarrier "--enable-strict-barrier"}
      ${lib.optionalString enableMemoryProfiling "--enable-memory-profiling"}
      ${if static then "--enable-R-static-lib" else "--enable-R-shlib"}
      AR=$(type -p ar)
      AWK=$(type -p gawk)
      CC=$(type -p gcc)
      CXX=$(type -p g++)
      FC="${gfortran}/bin/gfortran" F77="${gfortran}/bin/gfortran"
      RANLIB=$(type -p ranlib)
      CURL_CONFIG="${lib.getExe' (lib.getDev curl) "curl-config"}"
      r_cv_have_curl728=yes
      R_SHELL="${stdenvNoCC.shell}"
    )
    echo >>etc/Renviron.in "TZDIR=${tzdata}/share/zoneinfo"
  '';

  installTargets = [
    "install"
  ];

  # The store path to "which" is baked into src/library/base/R/unix/system.unix.R,
  # but Nix cannot detect it as a run-time dependency because the installed file
  # is compiled and compressed, which hides the store path.
  postFixup = ''
    echo ${which} > $out/nix-support/undetected-runtime-dependencies

    # Repoint the recorded build toolchain at the stubs so the real GCC/binutils
    # are dropped from the runtime closure (see dummyToolchain above).
    substituteInPlace $out/lib/R/etc/Makeconf \
      --replace-quiet "$(type -p gcc)" "${dummyToolchain}/bin/gcc" \
      --replace-quiet "$(type -p g++)" "${dummyToolchain}/bin/g++" \
      --replace-quiet "$(type -p ar)" "${dummyToolchain}/bin/ar" \
      --replace-quiet "$(type -p ranlib)" "${dummyToolchain}/bin/ranlib" \
      --replace-quiet "${gfortran}/bin/gfortran" "${dummyToolchain}/bin/gfortran"

    ${lib.optionalString stdenvNoCC.hostPlatform.isLinux ''find $out -name "*.so" -exec patchelf {} --add-rpath $out/lib/R/lib \;''}
  '';

  doCheck = true;
  preCheck = "export HOME=$TMPDIR; export TZ=CET; bin/Rscript -e 'sessionInfo()'";

  enableParallelBuilding = true;

  setupHook = ./setup-hook.sh;

  passthru.tests.pkg-config = testers.testMetaPkgConfig finalAttrs.finalPackage;

  meta = {
    homepage = "http://www.r-project.org/";
    description = "Free software environment for statistical computing and graphics (slim, minimal-feature build)";
    mainProgram = "R";
    license = lib.licenses.gpl2Plus;

    longDescription = ''
      GNU R is a language and environment for statistical computing and
      graphics that provides a wide variety of statistical (linear and
      nonlinear modelling, classical statistical tests, time-series
      analysis, classification, clustering, ...) and graphical
      techniques, and is highly extensible.

      This "slim" variant builds R with a minimal set of features: it does
      not build against the X11/Tk GUI stack, Cairo, image libraries, Java
      or the LaTeX documentation toolchain, and (by default) skips the
      recommended packages. It is also built with the compiler-free
      `stdenvNoCC` base, pulling in the C/Fortran toolchain explicitly, so
      it does not depend on the default `stdenv`.
    '';

    pkgConfigModules = [ "libR" ];
    platforms = lib.platforms.all;

    maintainers = with lib.maintainers; [ jbedo ];
    teams = [ lib.teams.sage ];
  };
})
