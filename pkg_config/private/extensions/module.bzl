"""Module extension helpers for pkg-config repositories."""

load("@bazel_skylib//rules/directory:providers.bzl", "DirectoryInfo")
load("@platforms//host:constraints.bzl", "HOST_CONSTRAINTS")
load(
    "//pkg_config/private:repository.bzl",
    "pkg_config_directory_repository",
    "pkg_config_host_repository",
    "pkg_config_repository",
)

_import_from_host = tag_class({
    "search_paths": attr.string_list(doc = "Extra directories to search for .pc files"),
})

_import_from_directory = tag_class({
    "directory": attr.label(doc = "Directory containing packages", providers = [DirectoryInfo], mandatory = True),
    "compatible_with": attr.label(doc = "Platform constraints for this directory", mandatory = True),
    "search_paths": attr.string_list(doc = "Subdirectories to search for .pc files", default = ["lib/pkgconfig", "share/pkgconfig"]),
})

_package = tag_class({
    "name": attr.string(doc = "Name of the package", mandatory = True),
})

_toolchain = tag_class({
    "pkgconfig": attr.label(),
    "readelf": attr.label(),
    "otool": attr.label(),
})

def _pkg_config_extension_impl(ctx):
    root_direct = {}
    root_dev = {}
    packages = []
    host_import = None
    directory_imports = []
    toolchain = struct(
        pkg_config = None,
        readelf = None,
        otool = None,
    )

    # Read tags
    for mod in ctx.modules:
        if mod.is_root:
            for t in mod.tags.toolchain:
                toolchain = struct(
                    pkg_config = t.pkg_config,
                    readelf = t.readelf,
                    otool = t.otool,
                )
            for i in mod.tags.import_from_host:
                host_import = i
            directory_imports = mod.tags.import_from_directory
        packages += mod.tags.package

    # Create repos
    repos = {}
    if host_import:
        repos["pkg_config_host"] = "//conditions:default"
        pkg_config_host_repository(
            name = "pkg_config_host",
            packages = [p.name for p in packages],
            search_paths = host_import.search_paths,
            pkg_config = toolchain.pkg_config,
            readelf = toolchain.readelf,
            otool = toolchain.otool,
        )

    for directory_import in directory_imports:
        name = "pkg_config_" + str(hash(str(directory_import.compatible_with)))
        repos[name] = directory_import.compatible_with
        pkg_config_directory_repository(
            name = name,
            packages = [p.name for p in packages],
            directory = directory_import.directory,
            search_paths = directory_import.search_paths,
            pkg_config = toolchain.pkg_config,
            readelf = toolchain.readelf,
            otool = toolchain.otool,
        )

    pkg_config_repository(
        name = "pkg_config",
        packages = [p.name for p in packages],
        repos = repos,
    )

    if ctx.root_module_has_non_dev_dependency:
        root_module_direct_deps = ["pkg_config"]
        root_module_direct_dev_deps = []
    else:
        root_module_direct_deps = []
        root_module_direct_dev_deps = ["pkg_config"]

    return ctx.extension_metadata(
        root_module_direct_deps = root_module_direct_dev_deps,
        root_module_direct_dev_deps = root_module_direct_dev_deps,
        reproducible = True,
    )

pkg_config_extension = module_extension(
    implementation = _pkg_config_extension_impl,
    tag_classes = {
        "import_from_host": _import_from_host,
        "import_from_directory": _import_from_directory,
        "package": _package,
        "toolchain": _toolchain,
    },
    doc = "Import packages via pkg-config",
)
