#!/usr/bin/env python3
import atheris
import sys
import fuzz_helpers

with atheris.instrument_imports(include=['tomlkit']):
    import tomlkit
    from tomlkit.exceptions import TOMLKitError


def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    try:
        orig_toml = fdp.ConsumeRemainingString()
        toml_obj = tomlkit.loads(orig_toml)
        dumped_toml = tomlkit.dumps(toml_obj)

        if dumped_toml != orig_toml:
            print(dumped_toml, orig_toml, file=sys.stderr)
            raise AssertionError("Dumped toml does not match original toml")
    except TOMLKitError:
        return -1


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
