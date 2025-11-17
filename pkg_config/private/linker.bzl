"""Link-entry helpers for pkg-config repository logic."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//pkg_config/private:paths.bzl", "absolute_path", "find_file_by_name", "find_file_with_extensions", "relativize_to_env")

_ENV_ROOT_PLACEHOLDER = "__rules_conda_env__"

def _library_config():
    return struct(
        prefixes = ["", "lib"],
        shared_exts = [".*.dylib", ".dylib", ".so.*", ".so"],
        static_exts = [".a", ".lib"],
        interface_exts = [".lib"],
    )

def with_placeholder(flag, root):
    if root in ["", None]:
        return flag
    normalized = root.rstrip("/\\")
    variants = [normalized]
    forward = normalized.replace("\\", "/")
    backward = normalized.replace("/", "\\")
    if forward not in variants:
        variants.append(forward)
    if backward not in variants:
        variants.append(backward)

    rewritten = flag
    for variant in variants:
        rewritten = rewritten.replace(variant, _ENV_ROOT_PLACEHOLDER)
    return rewritten

def relativize_flags(flags, root):
    return [with_placeholder(flag, root) for flag in flags]

def flag_entry(flag, env_root_str):
    return with_placeholder(flag, env_root_str)

def static_entry(path):
    return "|".join(["S", path])

def dynamic_entry(library, interface):
    interface_field = interface if interface else ""
    return "|".join(["D", library, interface_field])

def _resolve_windows_dynamic_library(find_file_by_name_fn, lib_dirs, interface, dll_dirs, tools):
    if tools.identify_windows_dll == None:
        return None
    dll_name = tools.identify_windows_dll(interface.absolute)
    if not dll_name:
        return None

    interface_dir = paths.dirname(interface.relative)
    candidate_dirs = []
    if interface_dir not in ["", "."]:
        candidate_dirs.append(interface_dir)
    candidate_dirs.extend(lib_dirs)
    for lib_dir in lib_dirs:
        stripped = lib_dir.removesuffix("/lib")
        if stripped != lib_dir:
            candidate_dirs.append(paths.join(stripped, "bin"))
    candidate_dirs.extend(dll_dirs)
    candidate_dirs = [d for d in candidate_dirs if d not in ["", None]]

    dll_entry = find_file_by_name_fn(candidate_dirs, dll_name)
    if not dll_entry:
        return None

    return dynamic_entry(dll_entry.relative, interface.relative)

def _resolve_posix_shared_library(find_file_by_name_fn, lib_dirs, match, tools):
    soname = tools.shared_library_name(match.absolute)
    if soname == None:
        return None
    if soname == match.absolute:
        return match.relative
    if "/" in soname or "\\" in soname or soname.startswith("@"):
        return match.relative

    match_dir = paths.dirname(match.relative)
    candidate_dirs = []
    if match_dir not in ["", "."]:
        candidate_dirs.append(match_dir)
    candidate_dirs.extend(lib_dirs)
    replacement = find_file_by_name_fn(candidate_dirs, soname)
    if replacement:
        return replacement.relative
    return match.relative

def _resolve_library_entry(rctx, env_root, env_root_str, lib_dirs, lib_name, static, tools):
    platform_config = _library_config()
    literal = lib_name.startswith(":")
    normalized_name = lib_name.removeprefix(":") if literal else lib_name
    candidate_bases = [normalized_name] if literal else [prefix + normalized_name for prefix in platform_config.prefixes]

    find_with_ext = lambda directories, candidates, extensions: find_file_with_extensions(env_root, env_root_str, directories, candidates, extensions, rctx = rctx)
    find_by_name = lambda directories, filename: find_file_by_name(env_root, env_root_str, directories, filename, rctx = rctx)

    if static:
        match = find_with_ext(lib_dirs, candidate_bases, platform_config.static_exts)
        if match:
            return static_entry(match.relative)
        return None

    if platform_config.interface_exts:
        interface = find_with_ext(lib_dirs, candidate_bases, platform_config.interface_exts)
        if interface:
            resolved = _resolve_windows_dynamic_library(find_by_name, lib_dirs, interface, platform_config.dll_dirs, tools)
            if resolved:
                return resolved
            return dynamic_entry(interface.relative, "")

    match = find_with_ext(lib_dirs, candidate_bases, platform_config.shared_exts)
    if match:
        shared_path = _resolve_posix_shared_library(find_by_name, lib_dirs, match, tools)
        if shared_path != None:
            return dynamic_entry(shared_path, "")
    return None

def resolve_link_entries(rctx, env_root, env_root_str, lib_args, static, tools):
    lib_dirs = []
    abs_dirs = []
    for flag in lib_args:
        if flag.startswith("-L"):
            directory = flag.removeprefix("-L")
            if directory == "":
                fail("`-L` flag must be immediately followed by a path")
            rel = relativize_to_env(directory, env_root_str) if env_root_str not in ["", None] else None
            if rel != None:
                lib_dirs.append(rel)
            else:
                abs_dirs.append(absolute_path(rctx, directory))

    entries = []
    for flag in lib_args:
        if flag.startswith("-L"):
            continue
        if flag.startswith("-l"):
            lib_name = flag.removeprefix("-l")
            if lib_name == "":
                fail("`-l` flag must be immediately followed by a library")
            resolved = None
            if env_root != None:
                resolved = _resolve_library_entry(
                    rctx,
                    env_root,
                    env_root_str,
                    lib_dirs,
                    lib_name,
                    static,
                    tools,
                )
            if not resolved and abs_dirs:
                resolved = _resolve_library_entry(
                    rctx,
                    None,
                    None,
                    abs_dirs,
                    lib_name,
                    static,
                    tools,
                )
            if resolved:
                entries.append(resolved)
            else:
                entries.append(flag_entry(flag, env_root_str))
        else:
            entries.append(flag_entry(flag, env_root_str))
    return entries
