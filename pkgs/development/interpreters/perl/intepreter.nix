{ stdenv
, fetchurl
, fetchFromGitHub
, buildPackages
, lib
, self
, version
, sha256
, pkgsBuildBuild
, pkgsBuildHost
, pkgsBuildTarget
, pkgsHostHost
, pkgsTargetTarget
, zlib
, config
, passthruFun
, perlAttr ? "perl${lib.versions.major version}${lib.versions.minor version}"
, enableThreading ? true, coreutils, makeWrapper
, enableCrypt ? true, libxcrypt ? null
, overrides ? config.perlPackageOverrides or (p: {}) # TODO: (self: super: {}) like in python
} @ inputs:

# Note: this package is used for bootstrapping fetchurl, and thus
# cannot use fetchpatch! All mutable patches (generated by GitHub or
# cgit) that are needed here should be included directly in Nixpkgs as
# files.

assert (enableCrypt -> (libxcrypt != null));

let
  crossCompiling = stdenv.buildPlatform != stdenv.hostPlatform;
  libc = if stdenv.cc.libc or null != null then stdenv.cc.libc else "/usr";
  libcInc = lib.getDev libc;
  libcLib = lib.getLib libc;
in

stdenv.mkDerivation (rec {
  inherit version;
  pname = "perl";

  src = fetchurl {
    url = "mirror://cpan/src/5.0/perl-${version}.tar.gz";
    inherit sha256;
  };

  strictDeps = true;
  # TODO: Add a "dev" output containing the header files.
  outputs = [ "out" "man" "devdoc" ] ++
    lib.optional crossCompiling "mini";
  setOutputFlags = false;

  # On FreeBSD, if Perl is built with threads support, having
  # libxcrypt available will result in a build failure, because
  # perl.h will get conflicting definitions of struct crypt_data
  # from libc's unistd.h and libxcrypt's crypt.h.
  #
  # FreeBSD Ports has the same issue building the perl port if
  # the libxcrypt port has been installed.
  #
  # Without libxcrypt, Perl will still find FreeBSD's crypt functions.
  propagatedBuildInputs = lib.optional (enableCrypt && !stdenv.isFreeBSD) libxcrypt;

  disallowedReferences = [ stdenv.cc ];

  patches =
    # Enable TLS/SSL verification in HTTP::Tiny by default
    lib.optional (lib.versionOlder version "5.38.0") ./http-tiny-verify-ssl-by-default.patch

    # Do not look in /usr etc. for dependencies.
    ++ lib.optional (lib.versionOlder version "5.38.0") ./no-sys-dirs-5.31.patch
    ++ lib.optional (lib.versionAtLeast version "5.38.0") ./no-sys-dirs-5.38.0.patch

    ++ lib.optional stdenv.isSunOS ./ld-shared.patch
    ++ lib.optionals stdenv.isDarwin [ ./cpp-precomp.patch ./sw_vers.patch ]
    ++ lib.optional crossCompiling ./cross.patch;

  # This is not done for native builds because pwd may need to come from
  # bootstrap tools when building bootstrap perl.
  postPatch = (if crossCompiling then ''
    substituteInPlace dist/PathTools/Cwd.pm \
      --replace "/bin/pwd" '${coreutils}/bin/pwd'
    substituteInPlace cnf/configure_tool.sh --replace "cc -E -P" "cc -E"
  '' else ''
    substituteInPlace dist/PathTools/Cwd.pm \
      --replace "/bin/pwd" "$(type -P pwd)"
  '') +
  # Perl's build system uses the src variable, and its value may end up in
  # the output in some cases (when cross-compiling)
  ''
    unset src
  '';

  # Build a thread-safe Perl with a dynamic libperl.so.  We need the
  # "installstyle" option to ensure that modules are put under
  # $out/lib/perl5 - this is the general default, but because $out
  # contains the string "perl", Configure would select $out/lib.
  # Miniperl needs -lm. perl needs -lrt.
  configureFlags =
    (if crossCompiling
    then [ "-Dlibpth=\"\"" "-Dglibpth=\"\"" "-Ddefault_inc_excludes_dot" ]
    else [ "-de" "-Dcc=cc" ])
    ++ [
      "-Uinstallusrbinperl"
      "-Dinstallstyle=lib/perl5"
    ] ++ lib.optional (!crossCompiling) "-Duseshrplib" ++ [
      "-Dlocincpth=${libcInc}/include"
      "-Dloclibpth=${libcLib}/lib"
    ]
    ++ lib.optionals ((builtins.match ''5\.[0-9]*[13579]\..+'' version) != null) [ "-Dusedevel" "-Uversiononly" ]
    ++ lib.optional stdenv.isSunOS "-Dcc=gcc"
    ++ lib.optional enableThreading "-Dusethreads"
    ++ lib.optional (!enableCrypt) "-A clear:d_crypt_r"
    ++ lib.optional stdenv.hostPlatform.isStatic "--all-static"
    ++ lib.optionals (!crossCompiling) [
      "-Dprefix=${placeholder "out"}"
      "-Dman1dir=${placeholder "out"}/share/man/man1"
      "-Dman3dir=${placeholder "out"}/share/man/man3"
    ];

  configureScript = lib.optionalString (!crossCompiling) "${stdenv.shell} ./Configure";

  dontAddStaticConfigureFlags = true;

  dontAddPrefix = !crossCompiling;

  enableParallelBuilding = false;

  # perl includes the build date, the uname of the build system and the
  # username of the build user in some files.
  # We override these to make it build deterministically.
  # other distro solutions
  # https://github.com/bmwiedemann/openSUSE/blob/master/packages/p/perl/perl-reproducible.patch
  # https://github.com/archlinux/svntogit-packages/blob/packages/perl/trunk/config.over
  # https://salsa.debian.org/perl-team/interpreter/perl/blob/debian-5.26/debian/config.over
  # A ticket has been opened upstream to possibly clean some of this up: https://rt.perl.org/Public/Bug/Display.html?id=133452
  preConfigure = ''
    cat > config.over <<EOF
    ${lib.optionalString (stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isGnu) ''osvers="gnulinux"''}
    myuname="nixpkgs"
    myhostname="nixpkgs"
    cf_by="nixpkgs"
    cf_time="$(date -d "@$SOURCE_DATE_EPOCH")"
    EOF

    # Compress::Raw::Zlib should use our zlib package instead of the one
    # included with the distribution
    cat > ./cpan/Compress-Raw-Zlib/config.in <<EOF
    BUILD_ZLIB   = False
    INCLUDE      = ${zlib.dev}/include
    LIB          = ${zlib.out}/lib
    OLD_ZLIB     = False
    GZIP_OS_CODE = AUTO_DETECT
    USE_ZLIB_NG  = False
    EOF
  '' + lib.optionalString stdenv.isDarwin ''
    substituteInPlace hints/darwin.sh --replace "env MACOSX_DEPLOYMENT_TARGET=10.3" ""
  '' + lib.optionalString (!enableThreading) ''
    # We need to do this because the bootstrap doesn't have a static libpthread
    sed -i 's,\(libswanted.*\)pthread,\1,g' Configure
  '';

  # Default perl does not support --host= & co.
  configurePlatforms = [ ];

  setupHook = ./setup-hook.sh;

  # copied from python
  passthru =
    let
      # When we override the interpreter we also need to override the spliced versions of the interpreter
      inputs' = lib.filterAttrs (n: v: ! lib.isDerivation v && n != "passthruFun") inputs;
      override = attr: let perl = attr.override (inputs' // { self = perl; }); in perl;
    in
    passthruFun rec {
      inherit self perlAttr;
      inherit overrides;
      perlOnBuildForBuild = override pkgsBuildBuild.${perlAttr};
      perlOnBuildForHost = override pkgsBuildHost.${perlAttr};
      perlOnBuildForTarget = override pkgsBuildTarget.${perlAttr};
      perlOnHostForHost = override pkgsHostHost.${perlAttr};
      perlOnTargetForTarget = if lib.hasAttr perlAttr pkgsTargetTarget then (override pkgsTargetTarget.${perlAttr}) else { };
    };

  doCheck = false; # some tests fail, expensive

  # TODO: it seems like absolute paths to some coreutils is required.
  postInstall =
    ''
      # Remove dependency between "out" and "man" outputs.
      rm "$out"/lib/perl5/*/*/.packlist

      # Remove dependencies on glibc and gcc
      sed "/ *libpth =>/c    libpth => ' '," \
        -i "$out"/lib/perl5/*/*/Config.pm
      # TODO: removing those paths would be cleaner than overwriting with nonsense.
      substituteInPlace "$out"/lib/perl5/*/*/Config_heavy.pl \
        --replace "${libcInc}" /no-such-path \
        --replace "${
            if stdenv.hasCC then stdenv.cc else "/no-such-path"
          }" /no-such-path \
        --replace "${
            if stdenv.hasCC && stdenv.cc.cc != null then stdenv.cc.cc else "/no-such-path"
        }" /no-such-path \
        --replace "$man" /no-such-path
    '' + lib.optionalString crossCompiling
      ''
        mkdir -p $mini/lib/perl5/cross_perl/${version}
        for dir in cnf/{stub,cpan}; do
          cp -r $dir/* $mini/lib/perl5/cross_perl/${version}
        done

        mkdir -p $mini/bin
        install -m755 miniperl $mini/bin/perl

        export runtimeArch="$(ls $out/lib/perl5/site_perl/${version})"
        # wrapProgram should use a runtime-native SHELL by default, but
        # it actually uses a buildtime-native one. If we ever fix that,
        # we'll need to fix this to use a buildtime-native one.
        #
        # Adding the arch-specific directory is morally incorrect, as
        # miniperl can't load the native modules there. However, it can
        # (and sometimes needs to) load and run some of the pure perl
        # code there, so we add it anyway. When needed, stubs can be put
        # into $mini/lib/perl5/cross_perl/${version}.
        wrapProgram $mini/bin/perl --prefix PERL5LIB : \
          "$mini/lib/perl5/cross_perl/${version}:$out/lib/perl5/${version}:$out/lib/perl5/${version}/$runtimeArch"
      ''; # */

  meta = with lib; {
    homepage = "https://www.perl.org/";
    description = "The standard implementation of the Perl 5 programming language";
    license = licenses.artistic1;
    maintainers = [ maintainers.eelco ];
    platforms = platforms.all;
    priority = 6; # in `buildEnv' (including the one inside `perl.withPackages') the library files will have priority over files in `perl`
    mainProgram = "perl";
  };
} // lib.optionalAttrs (stdenv.buildPlatform != stdenv.hostPlatform) rec {
  crossVersion = "84db4c71ae3d3b01fb2966cd15a060a7be334710"; # Nov 29, 2023

  perl-cross-src = fetchFromGitHub {
    name = "perl-cross-${crossVersion}";
    owner = "arsv";
    repo = "perl-cross";
    rev = crossVersion;
    sha256 = "sha256-1Zqw4sy/lD2nah0Z8rAE11tSpq1Ym9nBbatDczR+mxs=";
  };

  depsBuildBuild = [ buildPackages.stdenv.cc makeWrapper ];

  postUnpack = ''
    unpackFile ${perl-cross-src}
    chmod -R u+w ${perl-cross-src.name}
    cp -R ${perl-cross-src.name}/* perl-${version}/
  '';

  configurePlatforms = [ "build" "host" "target" ];

  # TODO merge setup hooks
  setupHook = ./setup-hook-cross.sh;
})
