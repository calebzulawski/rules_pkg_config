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
    repo_name = _repo_from_label(rctx.attr.directory_label)
    root = _repository_root(rctx, repo_name)
    if rctx.attr.search_root not in ["", None]:
        root = root.get_child(rctx.attr.search_root.replace("\\", "/"))
    return root

def _platform_value(rctx):
    if rctx.attr.platform not in ["", None]:
        return rctx.attr.platform
    name = rctx.os.name.lower()
    if name.startswith("mac"):
        return "osx"
    if name.startswith("win"):
        return "win"
    return "linux"

def _write_build_file(rctx, content):
    if content.strip() == "":
        rctx.file("pkg_config/BUILD.bazel", "")
    else:
        rctx.file("pkg_config/BUILD.bazel", content)
    rctx.file("BUILD.bazel", "package(default_visibility = [\"//visibility:public\"])")

def _pkg_config_command(tools, entry_static):
    cmd = [tools.pkg_config, "--print-errors", "--keep-system-cflags", "--keep-system-libs"]
    if entry_static:
        cmd.append("--static")
    return cmd

def _pkg_config_repository_impl(rctx):
    entries = [json.decode(e) for e in rctx.attr.entries]
    if not entries:
        _write_build_file(rctx, "")
        return

    env_root = _repo_root(rctx)
    env_root_str = env_path(str(env_root))
    platform = _platform_value(rctx)
    needs_windows = platform.startswith("win")
    tools = make_tool_config(
        rctx,
        pkg_config_label = rctx.attr.pkg_config,
        tool_repository = rctx.attr.tool_repository,
        pkg_config_candidates = rctx.attr.pkg_config_candidates,
        readelf_label = rctx.attr.readelf,
        readelf_candidates = rctx.attr.readelf_candidates,
        python_label = rctx.attr.python,
        dll_inspector = rctx.attr.dll_inspector,
        otool_label = rctx.attr.otool,
        needs_windows_support = needs_windows,
    )

    lines = ["load(\"@rules_pkg_config//pkg_config/private:rule.bzl\", \"pkg_config_import\")", ""]
    base_paths = rctx.attr.pkg_config_search_paths
    pathsep = ";" if rctx.os.name.startswith("windows") else ":"

    for entry in entries:
        entry_static = entry.get("static", False) and not platform.startswith("win")
        modules = entry.get("modules", [])
        if not modules:
            fail("pkg_config entry `{}` has no modules".format(entry.get("name", "<unnamed>")))

        pkg_paths = pkg_config_paths(env_root, base_paths)
        if not pkg_paths:
            fail("No pkg-config paths found inside {}".format(env_root))

        env = {
            "PKG_CONFIG_PATH": pathsep.join(pkg_paths),
            "PKG_CONFIG_LIBDIR": "disable-the-default",
        }

        base_cmd = _pkg_config_command(tools, entry_static)

        cflag_args = _run_pkg_config(rctx, base_cmd + ["--cflags"] + modules, env)
        lib_args = _run_pkg_config(rctx, base_cmd + ["--libs"] + modules, env)

        cflag_args = relativize_flags(cflag_args, env_root_str)
        link_entries = resolve_link_entries(
            rctx,
            env_root,
            env_root_str,
            lib_args,
            entry_static,
            platform,
            tools,
        )

        lines.append("""pkg_config_import(
    name = "{name}",
    directory = "{directory}",
    cflags = {cflags},
    link_entries = {link_entries},
    visibility = [\"//visibility:public\"],
)""".format(
            name = entry["name"],
            directory = str(rctx.attr.directory_label),
            cflags = _format_string_list(cflag_args),
            link_entries = _format_string_list(link_entries),
        ))
        lines.append("")

    _write_build_file(rctx, "\n".join(lines))

def _expand_host_search_paths(rctx, python_bin):
    paths = [p for p in rctx.attr.pkg_config_search_paths if p.strip()]
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
    for label in rctx.attr.pkg_config_path_labels:
        path = rctx.path(label)
        candidate = path.dirname
        if candidate != None:
            value = env_path(str(candidate))
            if value not in seen:
                dirs.append(value)
                seen[value] = True
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
    entries = [json.decode(e) for e in rctx.attr.entries]
    if not entries:
        _write_build_file(rctx, "")
        return

    platform = _platform_value(rctx)
    tools = make_tool_config(
        rctx,
        pkg_config_label = rctx.attr.pkg_config,
        tool_repository = rctx.attr.tool_repository,
        pkg_config_candidates = rctx.attr.pkg_config_candidates,
        readelf_label = rctx.attr.readelf,
        readelf_candidates = rctx.attr.readelf_candidates,
        python_label = rctx.attr.python,
        dll_inspector = None,
        otool_label = rctx.attr.otool,
        needs_windows_support = False,
    )

    header_defs = []
    lines = ["load(\"@rules_pkg_config//pkg_config/private:rule.bzl\", \"pkg_config_host_import\")", ""]
    python_bin = python_binary(rctx, rctx.attr.python)
    base_paths = _host_pkg_config_paths(rctx, python_bin)
    pathsep = ";" if rctx.os.name.startswith("windows") else ":"
    include_mirrors = {}
    mirror_queue = []
    rctx.file("pkg_config/host_includes/.keep", "")

    for entry in entries:
        entry_static = entry.get("static", False) and not platform.startswith("win")
        modules = entry.get("modules", [])
        if not modules:
            fail("pkg_config entry `{}` has no modules".format(entry.get("name", "<unnamed>")))

        entry_paths = base_paths
        env = {}
        if entry_paths:
            env["PKG_CONFIG_PATH"] = pathsep.join(entry_paths)

        base_cmd = _pkg_config_command(tools, entry_static)
        include_info = _rewrite_host_includes(rctx, rctx.name, _run_pkg_config(rctx, base_cmd + ["--cflags"] + modules, env), include_mirrors, mirror_queue)
        cflag_args = include_info.flags
        header_groups = sorted(set(include_info.groups))
        lib_args = _run_pkg_config(rctx, base_cmd + ["--libs"] + modules, env)

        lines.append("""pkg_config_host_import(
    name = \"{name}\",
    cflags = {cflags},
    libs = {libs},
    header_groups = {header_groups},
    visibility = [\"//visibility:public\"],
)""".format(
            name = entry["name"],
            cflags = _format_string_list(cflag_args),
            libs = _format_string_list(lib_args),
            header_groups = _format_string_list(header_groups),
        ))
        lines.append("")

    for info in include_mirrors.values():
        relative = info.path[len("pkg_config/"):] if info.path.startswith("pkg_config/") else info.path
        header_defs.append("""filegroup(
    name = \"{target}\",
    srcs = glob([\"{relative}/**\"]),
    visibility = [\"//visibility:public\"],
)""".format(target = info.target, relative = relative))
        header_defs.append("")

    if header_defs:
        lines = [lines[0], ""] + header_defs + lines[1:]

    _mirror_host_paths(rctx, mirror_queue, python_bin)
    _write_build_file(rctx, "\n".join(lines))

pkg_config_repository_impl = repository_rule(
    implementation = _pkg_config_repository_impl,
    attrs = {
        "directory_label": attr.label(mandatory = True, doc = "Label of the DirectoryInfo provider representing the root whose files will be used at build time."),
        "entries": attr.string_list(doc = "JSON encoded pkg-config entry descriptors."),
        "pkg_config": attr.label(doc = "Label of the pkg-config binary to invoke."),
        "tool_repository": attr.string(doc = "Repository containing tool binaries used when explicit labels are not provided."),
        "pkg_config_candidates": attr.string_list(doc = "Candidate paths (relative to `tool_repository`) for the pkg-config binary.", default = [
            "bin/pkg-config",
            "Library/bin/pkg-config",
            "Library/mingw-w64/bin/pkg-config",
            "Scripts/pkg-config",
        ]),
        "readelf": attr.label(doc = "Label of the readelf binary to use when resolving SONAMEs."),
        "readelf_candidates": attr.string_list(doc = "Candidate paths (relative to `tool_repository`) for the readelf binary.", default = [
            "bin/readelf",
            "Library/mingw-w64/bin/readelf",
            "Library/bin/readelf",
            "Scripts/readelf",
        ]),
        "python": attr.label(doc = "Label of the Python interpreter to use for helper scripts."),
        "dll_inspector": attr.label(doc = "Label of the helper script for resolving Windows DLL names.", default = Label("//pkg_config/private/scripts:get_dll_from_import_lib.py")),
        "otool": attr.label(doc = "Label of an otool binary for macOS targets.", default = None),
        "platform": attr.string(doc = "Platform identifier of the inspected repository."),
        "pkg_config_search_paths": attr.string_list(doc = "Additional pkg-config search paths relative to the search root.", default = []),
        "search_root": attr.string(doc = "Subdirectory within the search repository to treat as the pkg-config root.", default = ""),
    },
    doc = "Generates pkg_config_import targets by executing pkg-config against an arbitrary repository root.",
)

pkg_config_host_repository_impl = repository_rule(
    implementation = _pkg_config_host_repository_impl,
    attrs = {
        "entries": attr.string_list(doc = "JSON encoded pkg-config entry descriptors."),
        "pkg_config": attr.label(doc = "Label of the pkg-config binary to invoke."),
        "tool_repository": attr.string(doc = "Repository containing tool binaries used when explicit labels are not provided."),
        "pkg_config_candidates": attr.string_list(doc = "Candidate paths (relative to `tool_repository`) for the pkg-config binary.", default = []),
        "readelf": attr.label(doc = "Unused for host repositories (reserved for compatibility)."),
        "readelf_candidates": attr.string_list(doc = "Unused for host repositories (reserved for compatibility).", default = []),
        "python": attr.label(doc = "Label of the Python interpreter to use for helper scripts."),
        "dll_inspector": attr.label(doc = "Ignored for host repositories."),
        "otool": attr.label(doc = "Label of an otool binary for macOS targets.", default = None),
        "platform": attr.string(doc = "Platform identifier override used only to decide whether to request static libs.", default = ""),
        "pkg_config_search_paths": attr.string_list(doc = "Absolute pkg-config search paths.", default = []),
        "pkg_config_path_labels": attr.label_list(allow_files = True, doc = "Labels whose parent directories will be appended to PKG_CONFIG_PATH.", default = []),
    },
    doc = "Generates pkg_config_host_import targets by executing pkg-config directly against host-installed packages.",
)
pkg_config_repository = pkg_config_repository_impl
pkg_config_host_repository = pkg_config_host_repository_impl
