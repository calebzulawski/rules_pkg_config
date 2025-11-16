"""Filesystem helpers for pkg-config repository logic."""

load("@bazel_skylib//lib:paths.bzl", "paths")

def _normalize_relative_path(path):
    normalized = path.replace("\\", "/")
    if normalized in ["", ".", "./"]:
        return ""
    result = paths.normalize(normalized)
    return "" if result in ["", "."] else result

def relativize_to_env(path, env_root):
    normalized_root = paths.normalize(env_root.replace("\\", "/"))
    normalized_path = paths.normalize(path.replace("\\", "/"))
    if normalized_path == normalized_root:
        return ""
    if paths.starts_with(normalized_path, normalized_root):
        remainder = paths.relativize(normalized_path, normalized_root)
        return "" if remainder in ["", "."] else remainder
    if paths.is_absolute(normalized_path):
        return None
    relative = _normalize_relative_path(path)
    return relative if relative != "" else None

def env_path(str_path):
    return paths.normalize(str_path.replace("\\", "/"))

def _get_directory(env_root, relative):
    if env_root == None:
        return None
    if relative in ["", "."]:
        return env_root
    return env_root.get_child(relative)

def _list_directory_entries(path_obj):
    if not path_obj.exists:
        return []
    if hasattr(path_obj, "is_dir") and not path_obj.is_dir:
        return []
    return path_obj.readdir()

def _path_info(path_obj, env_root_str):
    if env_root_str in ["", None]:
        normalized = paths.normalize(str(path_obj))
        return struct(relative = normalized, absolute = normalized)
    rel = relativize_to_env(str(path_obj), env_root_str)
    if rel == None:
        return None
    return struct(
        relative = rel,
        absolute = str(path_obj),
    )

def _match_file(dir_path, env_root_str, base, extension):
    wildcard_index = extension.find("*")
    if wildcard_index == -1:
        candidate = dir_path.get_child(base + extension)
        if candidate.exists:
            return _path_info(candidate, env_root_str)
        return None

    before = extension[:wildcard_index]
    after = extension[wildcard_index + 1:]
    best = None
    entries = _list_directory_entries(dir_path)
    for entry in entries:
        info = _path_info(entry, env_root_str)
        if info == None:
            continue
        name = paths.basename(info.relative)
        if not name.startswith(base + before):
            continue
        if after and not name.endswith(after):
            continue
        if best == None or info.relative < best.relative:
            best = info
    return best

def find_file_with_extensions(env_root, env_root_str, directories, candidates, extensions, *, rctx = None):
    search_dirs = directories if directories else [""]
    for directory in search_dirs:
        dir_path = _get_directory(env_root, directory)
        env_str = env_root_str
        if dir_path == None:
            if rctx == None:
                fail("find_file_with_extensions requires rctx when env_root is None")
            dir_path = rctx.path(directory)
            env_str = None
        if not dir_path.exists:
            continue
        for base in candidates:
            for extension in extensions:
                match = _match_file(dir_path, env_str, base, extension)
                if match:
                    return match
    return None

def find_file_by_name(env_root, env_root_str, directories, filename, *, rctx = None):
    search_dirs = directories if directories else [""]
    lowered = filename.lower()
    for directory in search_dirs:
        dir_path = _get_directory(env_root, directory)
        env_str = env_root_str
        if dir_path == None:
            if rctx == None:
                fail("find_file_by_name requires rctx when env_root is None")
            dir_path = rctx.path(directory)
            env_str = None
        if not dir_path.exists:
            continue
        candidate = dir_path.get_child(filename)
        if candidate.exists:
            match = _path_info(candidate, env_str)
            if match:
                return match
        entries = _list_directory_entries(dir_path)
        for entry in entries:
            info = _path_info(entry, env_str)
            if info == None:
                continue
            name = paths.basename(info.relative)
            if name.lower() == lowered:
                return info
    return None

def pkg_config_paths(root, search_paths):
    dirs = []
    for p in search_paths:
        candidate = root.get_child(p.replace("//", "/"))
        if candidate.exists:
            dirs.append(str(candidate))
    return dirs

def absolute_path(rctx, path):
    normalized = env_path(path)
    if paths.is_absolute(normalized):
        return normalized
    resolved = rctx.path(normalized)
    return env_path(str(resolved))

def absolutize_cflags(rctx, cflags):
    normalized = []
    for flag in cflags:
        if flag.startswith("-I"):
            include_path = flag[2:]
            if include_path == "":
                fail("`-I` flag must be immediately followed by a path")
            normalized.append("-I" + absolute_path(rctx, include_path))
        else:
            normalized.append(flag)
    return normalized

def collect_absolute_library_dirs(rctx, lib_args):
    dirs = []
    seen = {}
    for flag in lib_args:
        if flag.startswith("-L"):
            directory = flag.removeprefix("-L")
            if directory == "":
                fail("`-L` flag must be immediately followed by a path")
            abs_dir = absolute_path(rctx, directory)
            if abs_dir not in seen:
                seen[abs_dir] = True
                dirs.append(abs_dir)
    return dirs
