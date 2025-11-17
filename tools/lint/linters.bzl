load("@aspect_rules_lint//lint:lint_test.bzl", "lint_test")
load("@aspect_rules_lint//lint:ruff.bzl", "lint_ruff_aspect")

_ruff_aspect = lint_ruff_aspect(
    binary = Label("@multitool//tools/ruff"),
    configs = [],
)

ruff_test = lint_test(aspect = _ruff_aspect)
