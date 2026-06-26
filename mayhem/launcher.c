/* launcher.c — a tiny ELF that exec()s an Atheris Python harness, forwarding argv.
 *
 * WHY THIS EXISTS (and why we do NOT freeze the harness with PyInstaller):
 *   Mayhem requires every fuzz target `cmd:` to be an ELF binary (it rejects a script /
 *   shebang wrapper, and fuzz-smoke.sh checks the ELF magic). tomlkit is pure Python, so the
 *   Atheris libFuzzer harnesses are `.py` files. The obvious packaging — PyInstaller
 *   `--onefile` — produces an ELF, but its bootloader must UNPACK the whole bundle (CPython +
 *   atheris' native .so + the stdlib) into a writable temp dir on every start. Mayhem mounts
 *   the image READ-ONLY for coverage collection, so the unpack fails
 *   ("[PYI-1:ERROR] Could not create temporary directory!") and the target dies with exit 255
 *   before libFuzzer ever starts -> a 0-edge "Run Failed". Pointing TMPDIR at /dev/shm does not
 *   save it either: /dev/shm is a 64 MB tmpfs by default and the bundle does not fit
 *   ("decompression resulted in return code -1"). See the run-3/run-13 event logs.
 *
 *   This shim writes NOTHING at runtime: it immediately execs `python3 <PY_SCRIPT> <args...>`,
 *   handing the libFuzzer/Atheris flags straight through. The Python process then IS the
 *   libFuzzer target (it iterates inputs and reports coverage). Same pattern as the other
 *   pure-Python integrations in the fleet (luqum, defusedxml).
 *
 * Built with $DEBUG_FLAGS (DWARF < 4) per SPEC §6.2 item 10, and dynamically linked so the
 * verify-repo sabotage oracle (LD_PRELOAD constructor) can neuter it.
 */
#include <stdlib.h>
#include <unistd.h>

#ifndef PY_SCRIPT
#define PY_SCRIPT "/mayhem/mayhem/fuzz_toml.py"
#endif

int main(int argc, char **argv) {
    char **nv = (char **)malloc((size_t)(argc + 2) * sizeof(char *));
    if (!nv) return 1;
    nv[0] = (char *)"python3";
    nv[1] = (char *)PY_SCRIPT;
    for (int i = 1; i < argc; i++) nv[i + 1] = argv[i];
    nv[argc + 1] = NULL;
    execvp("python3", nv);
    return 127; /* exec failed */
}
