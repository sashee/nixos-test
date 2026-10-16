# The test-only oops module (tests/crash-recovery-oops/), built against the kernel of the node
# that loads it: `config.boot.kernelPackages.callPackage`. On the aarch64 node that is the Pi
# kernel's own `dev` output, which the same derivation already produces for the node's kernel,
# so this costs a small module build and no kernel build.
{ stdenv, kernel, kernelModuleMakeFlags }:

stdenv.mkDerivation {
  pname = "crash-recovery-oops";
  version = "1-${kernel.version}";
  src = ./crash-recovery-oops;

  hardeningDisable = [ "pic" ];
  nativeBuildInputs = kernel.moduleBuildDependencies;

  buildPhase = ''
    runHook preBuild
    make $makeFlags -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build M="$PWD" modules
    runHook postBuild
  '';
  makeFlags = kernelModuleMakeFlags;

  installPhase = ''
    runHook preInstall
    install -D -m 0644 crash_recovery_oops.ko \
      $out/lib/modules/${kernel.modDirVersion}/extra/crash_recovery_oops.ko
    runHook postInstall
  '';
}
