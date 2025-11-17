load("@aspect_rules_lint//format:defs.bzl", "format_multirun")
load("//tools/lint:linters.bzl", "ruff_test")

package(default_visibility = ["//visibility:public"])

format_multirun(
    name = "format",
    python = "@multitool//tools/ruff",
    starlark = "@buildifier_prebuilt//:buildifier",
)

ruff_test(
    name = "lint",
    srcs = [
        "//pkg_config/private/scripts:python_sources",
    ],
)
