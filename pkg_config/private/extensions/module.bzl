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
    "compatible_with": attr.label_list(
        doc = "Platform constraints for this directory",
        default = HOST_CONSTRAINTS,
    ),
    "search_paths": attr.string_list(doc = "Subdirectories to search for .pc files", default = ["lib/pkgconfig", "share/pkgconfig"]),
})

_package = tag_class({
    "name": attr.string(doc = "Name of the package", mandatory = True),
})

def _pkg_config_extension_impl(ctx):
    packages = []
    root_packages = []
    host_import = None
    directory_imports = []

    # Read tags
    for mod in ctx.modules:
        if mod.is_root:
            for i in mod.tags.import_from_host:
                host_import = i
            directory_imports = mod.tags.import_from_directory
        packages += mod.tags.package
        if mod.is_root:
            for pkg in mod.tags.package:
                root_packages.append(pkg.name)

    package_names = [p.name for p in packages]
    package_repo_map = {name: {} for name in package_names}

    def _register_repo(package, repo_name):
        config_label = "@{}//:constraints".format(repo_name)
        package_repo_map[package][config_label] = repo_name

    if host_import:
        for package in package_names:
            repo_name = "{}_host".format(package)
            _register_repo(package, repo_name)
            pkg_config_host_repository(
                name = repo_name,
                package = package,
                search_paths = host_import.search_paths,
                constraints = HOST_CONSTRAINTS,
            )

    for directory_import in directory_imports:
        constraints = directory_import.compatible_with
        normalized_constraints = sorted([str(value) for value in constraints])
        constraint_key = "|".join(normalized_constraints)
        for package in package_names:
            identifier_source = "{}|{}|{}".format(package, directory_import.directory, constraint_key)
            identifier = "%x" % abs(hash(identifier_source))
            repo_name = "{}_{}".format(package, identifier)
            _register_repo(package, repo_name)
            pkg_config_directory_repository(
                name = repo_name,
                package = package,
                directory = directory_import.directory,
                search_paths = directory_import.search_paths,
                constraints = constraints,
            )

    for package in package_names:
        repos = package_repo_map.get(package, {})
        if not repos:
            fail("Package `{}` has no pkg-config repositories".format(package))
        pkg_config_repository(
            name = package,
            package = package,
            repos = repos,
        )

    if ctx.root_module_has_non_dev_dependency:
        root_module_direct_deps = root_packages
        root_module_direct_dev_deps = []
    else:
        root_module_direct_deps = []
        root_module_direct_dev_deps = root_packages

    return ctx.extension_metadata(
        root_module_direct_deps = root_module_direct_deps,
        root_module_direct_dev_deps = root_module_direct_dev_deps,
        reproducible = True,
    )

pkg_config_extension = module_extension(
    implementation = _pkg_config_extension_impl,
    tag_classes = {
        "import_from_host": _import_from_host,
        "import_from_directory": _import_from_directory,
        "package": _package,
    },
    doc = "Import packages via pkg-config",
)
