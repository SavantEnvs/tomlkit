# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for tomlkit (Python / Atheris). Builds ON TOP of the org base image, which
# already provides debian + clang/llvm + python3 + pip + the non-root identities + the build-contract
# ENV. This layer installs the Python fuzzing toolchain into the SYSTEM interpreter (from an in-image
# wheelhouse) and then runs mayhem/build.sh, which compiles one small ELF exec shim per Atheris
# harness (mayhem/launcher.c) — see the note there on why PyInstaller --onefile is NOT used.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV value breaks clang). build.sh unsets it
# when empty.
ARG SOURCE_DATE_EPOCH
# Sanitizer override knob (undefaulted so the base ENV flows through when not passed). Pure-Python code
# isn't sanitizer-instrumented, but build.sh still honors the contract / DWARF flags.
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# Pinned tomlkit test submodule (tests/toml-test = BurntSushi/toml-test), so the functional suite has its
# known-answer corpus baked in and offline. Matches .gitmodules' pinned commit.
ARG TOML_TEST_COMMIT=08ed8697864548b3cdb4b8decbf496bef47e1c82

# Python fuzzing toolchain + wheelhouse (online, ONCE). Everything the harnesses / test.sh need is
# cached at a fixed $HOME-independent path under /opt/toolchains and installed into the SYSTEM
# interpreter, so the air-gapped PATCH re-run of build.sh resolves offline and independently of $HOME
# (SPEC §6.2 item 8 / §6.5). Re-pin apt to the build's SOURCE_DATE_EPOCH for reproducibility when set.
ENV PY_WHEELHOUSE=/opt/toolchains/python/wheelhouse
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    mkdir -p "$PY_WHEELHOUSE" \
 && pip3 download -d "$PY_WHEELHOUSE" \
      atheris pyinstaller dictgen pytest pyyaml \
 && pip3 install --break-system-packages --no-index --find-links="$PY_WHEELHOUSE" \
      atheris pyinstaller dictgen pytest pyyaml \
 && chown -R 2000:2000 /opt/toolchains

# tomlkit itself is NOT pip-installed: it is a flat pure-Python package at the repo root, so we put the
# source tree on PYTHONPATH. That keeps `import tomlkit` resolving to /mayhem/tomlkit — $HOME-independent
# (an installed copy under ~/.local would vanish under the PATCH tier's build identity) and live, so a
# PATCH agent's edits take effect with no reinstall.
ENV PYTHONPATH=/mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history) is copied
# to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Ensure the test submodule is present (the build context may not include the populated submodule).
USER root
RUN if [ ! -e /mayhem/tests/toml-test/tests/files-toml-1.1.0 ]; then \
        rm -rf /mayhem/tests/toml-test && \
        git clone https://github.com/BurntSushi/toml-test.git /mayhem/tests/toml-test && \
        git -C /mayhem/tests/toml-test checkout -q "$TOML_TEST_COMMIT" ; \
    fi ; \
    chown -R 2000:2000 /mayhem/tests/toml-test
USER mayhem

RUN bash mayhem/build.sh

# Run the project's functional suite at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
