# Builds limine with all available features.

{
  # Helpers
  stdenv
, fetchurl
, lib
, # Dependencies
  llvmPackages
, mtools
, nasm
}:

let
  version = "7.3.0";
in
# The output of the derivation is a tool to create bootable images using Limine
# as bootloader for various platforms and corresponding binary and helper files.
stdenv.mkDerivation {
  inherit version;
  pname = "limine";
  # We don't use the Git source but the release tarball, as the source has a
  # `./bootstrap` script performing network access to download resources.
  # Packaging that in Nix is very cumbersome.
  src = fetchurl {
    url = "https://github.com/limine-bootloader/limine/releases/download/v${version}/limine-${version}.tar.gz";
    sha256 = "sha256-iPi6u3iZOJfVRERrJVgH6q16aANnSGgBL5AtNuANrao=";
  };

  nativeBuildInputs = [
    llvmPackages.bintools
    # gcc is used for the host tool, while clang is used for the bootloader.
    llvmPackages.clang
    llvmPackages.lld
    mtools
    nasm
  ];

  configureFlags = [
    "--enable-all"
  ];

  installFlags = [ "destdir=$out" "manprefix=/share" ];

  outputs = [ "out" "doc" "dev" "man" ];

  meta = with lib; {
    homepage = "https://limine-bootloader.org/";
    description = "Limine Bootloader";
    # Caution. Some submodules have different licenses.
    license = licenses.bsd2;
    # The platforms on that the Liminine binary and helper tools can run, not
    # necessarily the platforms for that bootable images can be created.
    platforms = platforms.unix;
    maintainers = [
      maintainers.phip1611
    ];
  };
}
