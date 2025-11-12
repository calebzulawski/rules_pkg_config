"""Module extension helpers for pkg-config repositories."""
load("@bazel_skylib//rules/directory:providers.bzl", "DirectoryInfo")
load(
    "//pkg_config/private:repository.bzl",
    "pkg_config_host_repository",
    "pkg_config_repository",
)

_location = tag_class(
    attrs = {
        "name": attr.string(mandatory = True, doc = "Name that packages use to reference this location."),
        "directory": attr.label(doc = "DirectoryInfo root that backs this location.", providers = [DirectoryInfo]),
        "paths": attr.string_list(doc = "Absolute pkg-config search paths on the host system."),
        "labels": attr.label_list(allow_files = True, doc = "DirectoryInfo labels whose directories should augment PKG_CONFIG_PATH.", providers = [DirectoryInfo], default = []),
        "pkg_config": attr.label(doc = "Label of the pkg-config binary to invoke."),
        "tool_repository": attr.string(doc = "Repository that hosts the pkg-config toolchain."),
        "pkg_config_candidates": attr.string_list(doc = "Fallback pkg-config paths inside `tool_repository`.", default = []),
        "readelf": attr.label(doc = "Label of the readelf binary."),
        "readelf_candidates": attr.string_list(doc = "Fallback readelf paths inside `tool_repository`.", default = []),
        "python": attr.label(doc = "Label of the Python interpreter for helper scripts."),
        "dll_inspector": attr.label(doc = "Helper script for discovering Windows DLL names."),
        "otool_path": attr.string(doc = "Path to an otool binary when targeting macOS.", default = ""),
        "platform": attr.string(doc = "Override for the detected platform identifier.", default = ""),
        "pkg_config_search_paths": attr.string_list(doc = "Additional pkg-config lookup paths relative to the search root.", default = []),
        "search_root": attr.string(doc = "Subdirectory of the directory label that hosts pkg-config files.", default = ""),
    },
    doc = "Describe pkg-config search roots (either repository-based or host-based).",
)

_package = tag_class(
    attrs = {
        "name": attr.string(mandatory = True, doc = "pkg_config_import target name."),
        "modules": attr.string_list(doc = "pkg-config modules to query. Defaults to [name]."),
        "static": attr.bool(default = False, doc = "Request static linking when supported."),
    },
    doc = "Declare a pkg-config module to import (applies to every location).",
)


def _encode_entry(entry):
    modules = entry.modules if entry.modules else [entry.name]
    data = {
        "name": entry.name,
        "modules": modules,
    }
    if entry.static:
        data["static"] = True
    return json.encode(data)


def _pkg_config_extension_impl(ctx):
    root_direct = {}
    root_dev = {}
    packages = []
    locations = {}
    location_modules = {}

    for mod in ctx.modules:
        for location in mod.tags.location:
            if not mod.is_root:
                fail("pkg_config.search_location may only appear in the root module")
            if location.name in locations:
                fail("pkg_config.search_location `{}` already defined".format(location.name))
            locations[location.name] = location
            location_modules.setdefault(location.name, []).append(mod)
        for entry in mod.tags.package:
            packages.append(entry)

    def _assign_root(modules, tag, repo_name):
        for mod in modules:
            if not mod.is_root:
                continue
            if ctx.is_dev_dependency(tag):
                root_dev[repo_name] = True
            else:
                root_direct[repo_name] = True

    for location_name, location in locations.items():
        encoded_entries = [_encode_entry(entry) for entry in packages]
        if not encoded_entries:
            continue
        repo_name = location_name + "_pkg_config"

        if location.directory not in ["", None]:
            if location.paths or location.labels:
                fail("pkg_config.search_location `{}` cannot mix directory roots with host paths".format(location_name))
            pkg_config_repository(
                name = repo_name,
                directory_label = location.directory,
                entries = encoded_entries,
                pkg_config = location.pkg_config,
                tool_repository = location.tool_repository,
                pkg_config_candidates = location.pkg_config_candidates,
                readelf = location.readelf,
                readelf_candidates = location.readelf_candidates,
                python = location.python,
                dll_inspector = location.dll_inspector,
                otool_path = location.otool_path,
                platform = location.platform,
                pkg_config_search_paths = location.pkg_config_search_paths,
                search_root = location.search_root,
            )
            _assign_root(location_modules.get(location_name, []), location, repo_name)
            continue

        if not location.paths and not location.labels:
            fail("pkg_config.search_location `{}` must provide either a directory or host paths".format(location_name))

        pkg_config_host_repository(
            name = repo_name,
            entries = encoded_entries,
            pkg_config_search_paths = location.paths,
            pkg_config_path_labels = location.labels,
            pkg_config = location.pkg_config,
            tool_repository = location.tool_repository,
            pkg_config_candidates = location.pkg_config_candidates,
            readelf = location.readelf,
            readelf_candidates = location.readelf_candidates,
            python = location.python,
            dll_inspector = location.dll_inspector,
            otool_path = location.otool_path,
            platform = location.platform,
        )
        _assign_root(location_modules.get(location_name, []), location, repo_name)

    return ctx.extension_metadata(
        root_module_direct_deps = sorted(root_direct.keys()),
        root_module_direct_dev_deps = sorted(root_dev.keys()),
        reproducible = True,
    )

pkg_config_extension = module_extension(
    implementation = _pkg_config_extension_impl,
    tag_classes = {
        "location": _location,
        "package": _package,
    },
    doc = "Expose pkg-config imports via named search locations.",
)

__all__ = ["pkg_config_extension"]
