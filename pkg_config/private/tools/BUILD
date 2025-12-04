load("@rules_conda//conda/environment:defs.bzl", "lock_environments")

lock_environments(
    name = "lock",
    environments = [
        "pkg-config.yml",
        "readelf.yml",
    ],
    glibc_version = "2.17",
    macos_version = "11",
)
