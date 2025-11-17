"""Standalone repository rule for generating pkg-config based targets."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//pkg_config/private:linker.bzl", "relativize_flags", "resolve_link_entries")
load("//pkg_config/private:paths.bzl", "absolutize_cflags", "env_path", "pkg_config_paths")
load("//pkg_config/private:tools.bzl", "make_tool_config", "python_binary")

_PKG_CONFIG_LOAD = "load(\"@rules_pkg_config//pkg_config/private:rule.bzl\", \"pkg_config_import\")"

def _quote_string(value):
    escaped = (
        value
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\b", "\\b")
            .replace("\f", "\\f")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
    )
    return "\"{}\"".format(escaped)

def _format_string_list(values):
    return "[" + ", ".join([_quote_string(v) for v in values]) + "]"

def _run_pkg_config(rctx, argv, env):
    result = rctx.execute(argv, environment = env)
    if result.return_code != 0:
        fail("pkg-config failed with {}\nstdout:\n{}\nstderr:\n{}".format(result.return_code, result.stdout, result.stderr))
    output = result.stdout.replace("\n", " ").strip()
    if output == "":
        return []
    return [flag.strip() for flag in output.split(" ")]

def _repo_from_label(label):
    label_str = str(label)
    if not label_str.startswith("@"):
        return "@"
    sep = label_str.find("//")
    if sep == -1:
        return "@"
    return label_str[:sep]

def _repo_label(repo_name, target):
    workspace = repo_name
    if workspace == "":
        workspace = "@"
    if not workspace.startswith("@"):
        workspace = "@" + workspace
    return "{}//:{}".format(workspace, target)

def _repository_root(rctx, repo_name):
    candidates = ["BUILD.bazel", "BUILD"]
    for candidate in candidates:
        label = Label(_repo_label(repo_name, candidate))
        path = rctx.path(label)
        if path.exists:
            parent = path.dirname
            if parent != None and parent.exists:
                return parent
    fail("Could not locate a BUILD file inside repository `{}`".format(repo_name))

def _repo_root(rctx):
    repo_name = _repo_from_label(rctx.attr.directory)
    root = _repository_root(rctx, repo_name)
    return root

def _write_root_build_file(rctx):
    rctx.file("BUILD.bazel", "package(default_visibility = [\"//visibility:public\"])")

def _write_pkg_config_targets(rctx, entries, constraints):
    lines = []
    constraint_values = [str(value) for value in constraints]
    if constraint_values:
        lines.extend([
            "config_setting(",
            '    name = "constraints",',
            "    constraint_values = {values},".format(values = _format_string_list(constraint_values)),
            ")",
            "",
        ])
    lines.extend([_PKG_CONFIG_LOAD, ""])
    for entry in entries:
        lines.append("pkg_config_import(")
        lines.append('    name = "{name}",'.format(name = entry.name))
        if entry.directory:
            lines.append('    directory = "{directory}",'.format(directory = entry.directory))
        lines.append("    cflags = {cflags},".format(cflags = _format_string_list(entry.cflags)))
        lines.append("    link_entries = {link_entries},".format(link_entries = _format_string_list(entry.link_entries)))
        lines.append('    visibility = ["//visibility:public"],')
        lines.append(")")
        lines.append("")
    _write_root_build_file(rctx)
    rctx.file("BUILD.bazel", "\n".join(lines))

def _pkg_config_command(tools, entry_static):
    cmd = [tools.pkg_config, "--print-errors", "--keep-system-cflags", "--keep-system-libs"]
    if entry_static:
        cmd.append("--static")
    return cmd

def _pkg_config_directory_repository_impl(rctx):
    package = rctx.attr.package
    env_root = _repo_root(rctx)
    env_root_str = env_path(str(env_root))
    tools = make_tool_config(
        rctx,
        pkg_config_label = rctx.attr.pkg_config,
        readelf_label = rctx.attr.readelf,
        otool_label = rctx.attr.otool,
    )

    base_paths = rctx.attr.search_paths
    pathsep = ";" if rctx.os.name.startswith("windows") else ":"

    pkg_paths = pkg_config_paths(env_root, base_paths)
    if not pkg_paths:
        fail("No pkg-config paths found inside {}".format(env_root))

    env = {
        "PKG_CONFIG_PATH": pathsep.join(pkg_paths),
        "PKG_CONFIG_LIBDIR": "disable-the-default",
    }

    entries = []
    for static in [False, True]:
        target_name = "static" if static else "dynamic"
        base_cmd = _pkg_config_command(tools, static)

        cflag_args = _run_pkg_config(rctx, base_cmd + ["--cflags", package], env)
        lib_args = _run_pkg_config(rctx, base_cmd + ["--libs", package], env)

        cflag_args = relativize_flags(cflag_args, env_root_str)
        link_entries = resolve_link_entries(
            rctx,
            env_root,
            env_root_str,
            lib_args,
            static,
            tools,
        )

        entries.append(struct(
            name = target_name,
            directory = str(rctx.attr.directory),
            cflags = cflag_args,
            link_entries = link_entries,
        ))
    _write_pkg_config_targets(rctx, entries, rctx.attr.constraints)

def _expand_host_search_paths(rctx, python_bin):
    paths = [p for p in rctx.attr.search_paths if p.strip()]
    if not paths:
        return []
    spec_path = "pkg_config/expand_paths.json"
    rctx.file(spec_path, json.encode(paths))
    script = rctx.path(Label("//pkg_config/private/scripts:expand_globs.py"))
    rctx.watch(Label("//pkg_config/private/scripts:expand_globs.py"))
    result = rctx.execute([python_bin, str(script), spec_path])
    if result.return_code != 0:
        fail("expand_globs.py failed with {}\nstdout:\n{}\nstderr:\n{}".format(result.return_code, result.stdout, result.stderr))
    output = result.stdout
    if output.strip() == "":
        return []
    return json.decode(output)

def _host_pkg_config_paths(rctx, python_bin):
    dirs = []
    seen = {}
    for path in _expand_host_search_paths(rctx, python_bin):
        normalized = env_path(path)
        if normalized and normalized not in seen:
            dirs.append(normalized)
            seen[normalized] = True
    return dirs

def _pkg_config_host_repository_impl(rctx):
    tools = make_tool_config(
        rctx,
        pkg_config_label = rctx.attr.pkg_config,
        readelf_label = rctx.attr.readelf,
        otool_label = rctx.attr.otool,
    )

    _write_root_build_file(rctx)
    python_bin = python_binary(rctx)
    package = rctx.attr.package
    base_paths = _host_pkg_config_paths(rctx, python_bin)
    pathsep = ";" if rctx.os.name.startswith("windows") else ":"
    shared_env = None
    if base_paths:
        shared_env = pathsep.join(base_paths)

    entries = []
    for static in [False, True]:
        target_name = "static" if static else "dynamic"
        env = {}
        if shared_env:
            env["PKG_CONFIG_PATH"] = shared_env

        base_cmd = _pkg_config_command(tools, static)
        raw_cflags = _run_pkg_config(rctx, base_cmd + ["--cflags", package], env)
        cflag_args = absolutize_cflags(rctx, raw_cflags)
        raw_libs = _run_pkg_config(rctx, base_cmd + ["--libs", package], env)
        link_entries = resolve_link_entries(
            rctx,
            env_root = None,
            env_root_str = None,
            lib_args = raw_libs,
            static = static,
            tools = tools,
        )

        entries.append(struct(
            name = target_name,
            directory = None,
            cflags = cflag_args,
            link_entries = link_entries,
        ))
    _write_pkg_config_targets(rctx, entries, rctx.attr.constraints)

def _pkg_config_repository_impl(rctx):
    package = rctx.attr.package
    _write_root_build_file(rctx)
    lines = []
    def _alias_block(name, target):
        lines.extend([
            "alias(",
            '    name = "{name}",'.format(name = name),
            "    actual = select({",
        ])
        for config_label, repo in sorted(rctx.attr.repos.items()):
            lines.append('        "{config}": "@{repo}//:{target}",'.format(
                config = config_label,
                repo = repo,
                target = target,
            ))
        lines.extend([
            "    }),",
            '    visibility = ["//visibility:public"],',
            ")",
            "",
        ])

    _alias_block("dynamic", "dynamic")
    _alias_block("static", "static")
    lines.extend([
        "alias(",
        '    name = "{name}",'.format(name = package),
        '    actual = ":dynamic",',
        '    visibility = ["//visibility:public"],',
        ")",
        "",
    ])

    rctx.file("BUILD.bazel", "\n".join(lines))

pkg_config_directory_repository = repository_rule(
    implementation = _pkg_config_directory_repository_impl,
    attrs = {
        "directory": attr.label(),
        "package": attr.string(),
        "pkg_config": attr.label(),
        "readelf": attr.label(),
        "otool": attr.label(),
        "search_paths": attr.string_list(),
        "constraints": attr.label_list(mandatory = True),
    },
    doc = "Generates pkg_config_import targets by executing pkg-config against an arbitrary repository root.",
)

pkg_config_host_repository = repository_rule(
    implementation = _pkg_config_host_repository_impl,
    attrs = {
        "package": attr.string(),
        "pkg_config": attr.label(),
        "readelf": attr.label(),
        "otool": attr.label(),
        "search_paths": attr.string_list(),
        "constraints": attr.label_list(mandatory = True),
    },
    doc = "Generates pkg_config_import targets by executing pkg-config directly against host-installed packages.",
)

pkg_config_repository = repository_rule(
    implementation = _pkg_config_repository_impl,
    attrs = {
        "package": attr.string(),
        "repos": attr.string_dict(),
    },
    doc = "Aliases packages per platform constraint set.",
)
