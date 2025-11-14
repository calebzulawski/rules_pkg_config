"""Standalone repository rule for generating pkg-config based targets."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//pkg_config/private:linker.bzl", "relativize_flags", "resolve_link_entries")
load("//pkg_config/private:paths.bzl", "env_path", "pkg_config_paths")
load("//pkg_config/private:tools.bzl", "make_tool_config", "python_binary")

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

def _write_pkg_config_build_file(rctx, content):
    if content.strip() == "":
        rctx.file("pkg_config/BUILD.bazel", "")
    else:
        rctx.file("pkg_config/BUILD.bazel", content)

def _write_package_build_file(rctx, package, content):
    _write_root_build_file(rctx)
    path = "{package}/BUILD.bazel".format(package = package)
    if content.strip() == "":
        rctx.file(path, "")
    else:
        rctx.file(path, content)

def _pkg_config_command(tools, entry_static):
    cmd = [tools.pkg_config, "--print-errors", "--keep-system-cflags", "--keep-system-libs"]
    if entry_static:
        cmd.append("--static")
    return cmd

def _pkg_config_directory_repository_impl(rctx):
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

    load_line = "load(\"@rules_pkg_config//pkg_config/private:rule.bzl\", \"pkg_config_import\")"
    for package in rctx.attr.packages:
        package_lines = [load_line, ""]
        for static in [False, True]:
            target_name = "static" if static else "dynamic"
            pkg_paths = pkg_config_paths(env_root, base_paths)
            if not pkg_paths:
                fail("No pkg-config paths found inside {}".format(env_root))

            env = {
                "PKG_CONFIG_PATH": pathsep.join(pkg_paths),
                "PKG_CONFIG_LIBDIR": "disable-the-default",
            }

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

            package_lines.append("""pkg_config_import(
    name = "{name}",
    directory = "{directory}",
    cflags = {cflags},
    link_entries = {link_entries},
    visibility = ["//visibility:public"],
)""".format(
                name = target_name,
                directory = str(rctx.attr.directory),
                cflags = _format_string_list(cflag_args),
                link_entries = _format_string_list(link_entries),
            ))
            package_lines.append("")
        _write_package_build_file(rctx, package, "\n".join(package_lines))

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

def _is_include_flag(flag):
    return flag.startswith("-I") and len(flag) > 2

def _rewrite_host_includes(rctx, repo_name, cflags, mirrors, mirror_queue):
    rewritten = []
    groups = []
    prefix = "external/{}/".format(repo_name)
    for flag in cflags:
        if _is_include_flag(flag):
            include_path = flag[2:]
            if include_path == "":
                fail("`-I` flag must be immediately followed by a path")
            source = include_path
            if not paths.is_absolute(source):
                source = str(rctx.path(include_path))
            info = mirrors.get(source)
            if info == None:
                index = len(mirrors)
                dest = "pkg_config/host_includes/{}".format(index)
                target = "host_headers_{}".format(index)
                info = struct(path = dest, target = target)
                mirrors[source] = info
                mirror_queue.append({"src": source, "dest": dest})
            rewritten.append("-I" + prefix + info.path)
            groups.append(info.target)
        else:
            rewritten.append(flag)
    return struct(flags = rewritten, groups = groups)

def _mirror_host_paths(rctx, entries, python_bin):
    if not entries:
        return
    spec_path = "pkg_config/host_includes/_mirror_spec.json"
    rctx.file(spec_path, json.encode(entries))
    script = rctx.path(Label("//pkg_config/private/scripts:mirror_paths.py"))
    rctx.watch(Label("//pkg_config/private/scripts:mirror_paths.py"))
    result = rctx.execute([python_bin, str(script), spec_path])
    if result.return_code != 0:
        fail("Failed to mirror host include paths:\nstdout:\n{}\nstderr:\n{}".format(result.stdout, result.stderr))

def _pkg_config_host_repository_impl(rctx):
    tools = make_tool_config(
        rctx,
        pkg_config_label = rctx.attr.pkg_config,
        readelf_label = rctx.attr.readelf,
        otool_label = rctx.attr.otool,
    )

    _write_root_build_file(rctx)
    python_bin = python_binary(rctx)
    header_defs = []
    base_paths = _host_pkg_config_paths(rctx, python_bin)
    pathsep = ";" if rctx.os.name.startswith("windows") else ":"
    include_mirrors = {}
    mirror_queue = []
    rctx.file("pkg_config/host_includes/.keep", "")
    load_line = "load(\"@rules_pkg_config//pkg_config/private:rule.bzl\", \"pkg_config_host_import\")"

    for package in rctx.attr.packages:
        package_lines = [load_line, ""]
        for static in [True, False]:
            target_name = "static" if static else "dynamic"
            entry_paths = base_paths
            env = {}
            if entry_paths:
                env["PKG_CONFIG_PATH"] = pathsep.join(entry_paths)

            base_cmd = _pkg_config_command(tools, static)
            include_info = _rewrite_host_includes(rctx, rctx.name, _run_pkg_config(rctx, base_cmd + ["--cflags", package], env), include_mirrors, mirror_queue)
            cflag_args = include_info.flags
            header_groups = sorted(set(include_info.groups))
            lib_args = _run_pkg_config(rctx, base_cmd + ["--libs", package], env)

            formatted_header_groups = _format_string_list(["//pkg_config:{}".format(group) for group in header_groups])
            package_lines.append("""pkg_config_host_import(
    name = \"{name}\",
    cflags = {cflags},
    libs = {libs},
    header_groups = {header_groups},
    visibility = [\"//visibility:public\"],
)""".format(
                name = target_name,
                cflags = _format_string_list(cflag_args),
                libs = _format_string_list(lib_args),
                header_groups = formatted_header_groups,
            ))
            package_lines.append("")
        _write_package_build_file(rctx, package, "\n".join(package_lines))

    for info in include_mirrors.values():
        relative = info.path[len("pkg_config/"):] if info.path.startswith("pkg_config/") else info.path
        header_defs.append("""filegroup(
    name = \"{target}\",
    srcs = glob([\"{relative}/**\"]),
    visibility = [\"//visibility:public\"],
)""".format(target = info.target, relative = relative))
        header_defs.append("")

    _mirror_host_paths(rctx, mirror_queue, python_bin)
    _write_pkg_config_build_file(rctx, "\n".join(header_defs))

def _pkg_config_repository_impl(rctx):
    _write_root_build_file(rctx)
    for package in rctx.attr.packages:
        lines = []

        def _select_alias_block(name, target):
            lines.extend([
                "alias(",
                '    name = "{name}",'.format(name = name),
                "    actual = select({",
            ])
            for repo, constraint in rctx.attr.repos.items():
                lines.append('        "{constraint}": "@{repo}//{package}:{target}",'.format(
                    constraint = constraint,
                    repo = repo,
                    package = package,
                    target = target,
                ))
            lines.extend([
                "    }),",
                '    visibility = ["//visibility:public"],',
                ")",
                "",
            ])

        _select_alias_block("dynamic", "dynamic")
        _select_alias_block("static", "static")
        lines.extend([
            "alias(",
            '    name = "{name}",'.format(name = package),
            '    actual = ":dynamic",',
            '    visibility = ["//visibility:public"],',
            ")",
            "",
        ])

        rctx.file("{}/BUILD.bazel".format(package), "\n".join(lines))

pkg_config_directory_repository = repository_rule(
    implementation = _pkg_config_directory_repository_impl,
    attrs = {
        "directory": attr.label(),
        "packages": attr.string_list(),
        "pkg_config": attr.label(),
        "readelf": attr.label(),
        "otool": attr.label(),
        "search_paths": attr.string_list(),
    },
    doc = "Generates pkg_config_import targets by executing pkg-config against an arbitrary repository root.",
)

pkg_config_host_repository = repository_rule(
    implementation = _pkg_config_host_repository_impl,
    attrs = {
        "packages": attr.string_list(),
        "pkg_config": attr.label(),
        "readelf": attr.label(),
        "otool": attr.label(),
        "search_paths": attr.string_list(),
    },
    doc = "Generates pkg_config_host_import targets by executing pkg-config directly against host-installed packages.",
)

pkg_config_repository = repository_rule(
    implementation = _pkg_config_repository_impl,
    attrs = {
        "packages": attr.string_list(),
        "repos": attr.string_keyed_label_dict(),
    },
    doc = "Aliases packages per platform constraint set.",
)
