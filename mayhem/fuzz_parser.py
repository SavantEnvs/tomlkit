#!/usr/bin/python3
# OSS-Fuzz harness for tomlkit (ported from google/oss-fuzz projects/tomlkit/fuzz_parser.py).
# Drives tomlkit.parser.Parser on arbitrary unicode input.
#
# Uses atheris.instrument_imports(include=['tomlkit']) so that only tomlkit's bytecode is
# coverage-instrumented. This avoids the instrument_all() + PyInstaller custom-loader interaction
# where instrument_all() called inside main() (after import) only sees bootstrap stubs and records
# too few edges to satisfy Mayhem's coverage gate.
import sys
import atheris

with atheris.instrument_imports(include=['tomlkit']):
    import tomlkit


def TestOneInput(data):
    fdp = atheris.FuzzedDataProvider(data)
    parser = tomlkit.parser.Parser(fdp.ConsumeUnicodeNoSurrogates(sys.maxsize))
    try:
        parser.parse()
    except (
        tomlkit.exceptions.TOMLKitError,
        RecursionError,
    ):
        # Recursion errors are not interesting
        pass


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
