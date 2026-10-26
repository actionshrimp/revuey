# Changelog

## 0.17.2

Released on 2026-10-22.

### Preview features

- \[`complexity`\] Add `unnecessary-regular-expression-compile` ([#25533](https://github.com/astral-sh/ruff/pull/25533))

### Bug fixes

- Avoid syntax errors for type variables with starred constraints (`UP040`, `UP046`, `UP047`, `RUF053`) ([#28362](https://github.com/astral-sh/ruff/pull/28362))
- \[`pydocstyle`\] Treat backslash-escaped `*args` and `**kwargs` as documented (`D417`) ([#29536](https://github.com/astral-sh/ruff/pull/29536))
- \[`pylint`\] Avoid false positive on starred elements (`PLE0643`) ([#29483](https://github.com/astral-sh/ruff/pull/29483))
- \[`pylint`\] Mark fixes unsafe when deleting comments (`PLR5501`, `PLW0120`) ([#29414](https://github.com/astral-sh/ruff/pull/29414))
- \[`pyupgrade`\] Mark fix unsafe when deleting comments (`UP035`) ([#29413](https://github.com/astral-sh/ruff/pull/29413))

### Performance

- Avoid intermediate names in lint name resolution ([#29506](https://github.com/astral-sh/ruff/pull/29506))
- Prefilter bidirectional Unicode checks by UTF-8 leading bytes ([#29561](https://github.com/astral-sh/ruff/pull/29561))
- Share postfix parsing and reduce expression copies ([#29480](https://github.com/astral-sh/ruff/pull/29480))

### Configuration

- \[`pylint`\] Add a configurable allowlist for `magic-value-comparison` (`PLR2004`) ([#18961](https://github.com/astral-sh/ruff/pull/18961))

### Documentation

- Clarify documentation and correct stale guidance ([#29374](https://github.com/astral-sh/ruff/pull/29374))
- \[`pyupgrade`\] Remove mentions of variance related to fix safety (`UP040`, `UP047`) ([#29592](https://github.com/astral-sh/ruff/pull/29592))

### Contributors

- [@fixfon](https://github.com/fixfon)
- [@MichaReiser](https://github.com/MichaReiser)
- [@zaniebot](https://github.com/zaniebot)
- [@FrancescoPezzella](https://github.com/FrancescoPezzella)
- [@anishgirianish](https://github.com/anishgirianish)
- [@rajveer3x](https://github.com/rajveer3x)
- [@charliermarsh](https://github.com/charliermarsh)
- [@LckyLike](https://github.com/LckyLke)
- [@DaniBodor](https://github.com/DaniBodor)

## 0.17.1

Released on 2026-10-15.

### Preview features

- \[`pycodestyle`\] Don't treat `None`, `True`, or `False` as keywords (`E271`-`E274`) ([#29322](https://github.com/astral-sh/ruff/pull/29322))

### Bug fixes

- Fix dedent with multiple leading comments ([#29382](https://github.com/astral-sh/ruff/pull/29382))
- \[`flake8-pyi`\] Detect legacy positional-only parameters in `__new__` methods (`PYI063`) ([#28502](https://github.com/astral-sh/ruff/pull/28502))
- \[`flake8-pyi`\] Fix false positives on quoted annotations (`PYI036`) ([#29274](https://github.com/astral-sh/ruff/pull/29274))
- \[`perflint`\] Avoid invalid comprehension suggestions (`PERF401`, `PERF403`) ([#29366](https://github.com/astral-sh/ruff/pull/29366))

### Rule changes

- Treat more `collections` and `weakref` containers as mutable ([#29213](https://github.com/astral-sh/ruff/pull/29213))

### Documentation

- \[`flake8-import-conventions`\] Update default and example `aliases` ([#29333](https://github.com/astral-sh/ruff/pull/29333))

### Contributors

- [@fixfon](https://github.com/fixfon)
- [@mmaxjr](https://github.com/mmaxjr)
- [@joshuavetos](https://github.com/joshuavetos)
- [@nekomario28](https://github.com/nekomario28)
- [@ntBre](https://github.com/ntBre)
- [@shan3520](https://github.com/shan3520)

## 0.17.0

Released on 2026-10-09.

The executables in our macOS and Windows release archives and `ruff` wheels are now code-signed.
macOS executables are signed with an Apple Developer ID certificate and notarized by Apple. Windows
executables have timestamped Authenticode signatures from Azure Artifact Signing. This enables
verification of the release publisher and binary integrity, supports publisher-based allowlisting,
and should reduce security warnings and antivirus false positives.

### Breaking changes

- Update the default and latest Python versions for 3.15 ([#28792](https://github.com/astral-sh/ruff/pull/28792))

    Ruff now defaults to Python 3.11 instead of 3.10 when no Python version is configured through
    [`target-version`](https://docs.astral.sh/ruff/settings/#target-version) or
    [`requires-python`](https://docs.astral.sh/ruff/configuration/#inferring-the-python-version). When
    checking for syntax errors without a configured Python version, Ruff now defaults to Python 3.15
    instead of 3.14.

- Update the default rule set ([#28786](https://github.com/astral-sh/ruff/pull/28786))

    Several of the `flake8-datetimez` rules
    ([`DTZ001`](https://docs.astral.sh/ruff/rules/call-datetime-without-tzinfo/),
    [`DTZ005`](https://docs.astral.sh/ruff/rules/call-datetime-now-without-tzinfo/),
    [`DTZ006`](https://docs.astral.sh/ruff/rules/call-datetime-fromtimestamp/),
    [`DTZ007`](https://docs.astral.sh/ruff/rules/call-datetime-strptime-without-zone/),
    [`DTZ011`](https://docs.astral.sh/ruff/rules/call-date-today/),
    [`DTZ012`](https://docs.astral.sh/ruff/rules/call-date-fromtimestamp/), and
    [`DTZ901`](https://docs.astral.sh/ruff/rules/datetime-min-max/)) are no longer enabled by default,
    while [`undefined-local-with-nested-import-star-usage`](https://docs.astral.sh/ruff/rules/undefined-local-with-nested-import-star-usage/)
    (`F406`), which corresponds to a syntax error, is now enabled by default.

- Update Rust crate quick-junit to 0.8.0 ([#27295](https://github.com/astral-sh/ruff/pull/27295))

    JUnit output now uses a `skipped` attribute instead of `disabled` on `<testsuite>` elements and
    includes a `skipped` attribute on the root `<testsuites>` element.

- \[`flake8-import-conventions`\] Add `datetime as dt` as a conventional alias (`ICN001`) ([#28790](https://github.com/astral-sh/ruff/pull/28790))

- Support Unicode dummy variable names ([#28722](https://github.com/astral-sh/ruff/pull/28722))

    The default [`lint.dummy-variable-rgx`](https://docs.astral.sh/ruff/settings/#lint_dummy-variable-rgx)
    now recognizes underscore-prefixed Unicode names, such as `_次`, as dummy variables.

- Update to Unicode 17 ([#21229](https://github.com/astral-sh/ruff/pull/21229), [#28784](https://github.com/astral-sh/ruff/pull/28784))

    Ruff now uses Unicode 17 data for identifier normalization and named character escapes (`"\N{...}"`).

- Always show unsafe and display-only fixes in the CLI ([#27810](https://github.com/astral-sh/ruff/pull/27810))
