"""External tool discovery helpers for pkg-config repository logic."""

def _binary_from_label(rctx, label):
    if label == None:
        return None
    path = rctx.path(label)
    if not path.exists:
        fail("label `{}` did not resolve to an existing file".format(label))
    return str(path)

def _normalize_repo(repo_name):
    if repo_name in ["", None]:
        return None
    if not repo_name.startswith("@"):
        return "@" + repo_name
    return repo_name

def _find_in_repo(rctx, repo_name, candidates):
    workspace = _normalize_repo(repo_name)
    if workspace == None:
        return None
    for rel in candidates:
        label = Label("{}//:{}".format(workspace, rel))
        path = rctx.path(label)
        if path.exists:
            return str(path)
    return None

def _which(rctx, candidates):
    for name in candidates:
        tool = rctx.which(name)
        if tool:
            return tool
    return None

def pkg_config_binary(rctx, label, repo_name, candidates):
    path = _binary_from_label(rctx, label)
    if path:
        return path
    repo_path = _find_in_repo(rctx, repo_name, candidates)
    if repo_path:
        return repo_path
    tool = _which(rctx, ["pkg-config"])
    if tool:
        return tool
    fail("pkg-config binary not provided and could not be found on PATH")

def readelf_binary(rctx, label, repo_name, candidates):
    path = _binary_from_label(rctx, label)
    if path:
        return path
    repo_path = _find_in_repo(rctx, repo_name, candidates)
    if repo_path:
        return repo_path
    tool = _which(rctx, ["readelf"])
    if tool:
        return tool
    fail("readelf binary not provided and could not be found on PATH")

def python_binary(rctx, label):
    path = _binary_from_label(rctx, label)
    if path:
        return path
    if rctx.os.name.startswith("windows"):
        candidates = ["python.exe", "python"]
    else:
        candidates = ["python3", "python"]
    tool = _which(rctx, candidates)
    if tool:
        return tool
    fail("Python interpreter not provided and could not be found on PATH")

def _otool_binary(rctx, override):
    if override not in ["", None]:
        return override
    tool = _which(rctx, ["otool"])
    if tool:
        return tool
    return "/usr/bin/otool"

def identify_windows_dll(rctx, python_bin, dll_inspector, interface_path):
    script = rctx.path(dll_inspector)
    rctx.watch(dll_inspector)
    result = rctx.execute([python_bin, str(script), interface_path])
    if result.return_code != 0:
        fail("get_dll_from_import_lib.py failed with {}\nstdout:\n{}\nstderr:\n{}".format(result.return_code, result.stdout, result.stderr))
    dll_name = result.stdout.strip()
    return dll_name if dll_name != "" else None

def shared_library_name(rctx, shared_path, platform, readelf_bin, otool_path):
    if platform.startswith("osx"):
        tool = _otool_binary(rctx, otool_path)
        result = rctx.execute([tool, "-D", shared_path])
        if result.return_code != 0:
            fail("otool failed with {}\nstdout:\n{}\nstderr:\n{}".format(result.return_code, result.stdout, result.stderr))
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if len(lines) >= 2:
            return lines[-1]
        return None

    if readelf_bin == None:
        fail("readelf binary not provided (required when targeting Linux or Windows shared libraries)")
    result = rctx.execute([readelf_bin, "-d", shared_path])
    if result.return_code != 0:
        fail("readelf failed with {}\nstdout:\n{}\nstderr:\n{}".format(result.return_code, result.stdout, result.stderr))
    for line in result.stdout.splitlines():
        if "SONAME" not in line:
            continue
        start = line.find("[")
        end = line.find("]", start + 1)
        if start != -1 and end != -1:
            return line[start + 1:end].strip()
    return None

def make_tool_config(
        rctx,
        *,
        pkg_config_label,
        tool_repository,
        pkg_config_candidates,
        readelf_label,
        readelf_candidates,
        python_label,
        dll_inspector,
        otool_path,
        needs_windows_support):
    pkg_config_bin = pkg_config_binary(rctx, pkg_config_label, tool_repository, pkg_config_candidates)
    dll_script = dll_inspector or Label("//pkg_config/private/scripts:get_dll_from_import_lib.py")
    resolved_otool_path = _otool_binary(rctx, otool_path)

    def _identify_windows_dll(interface_path):
        python_bin = python_binary(rctx, python_label)
        return identify_windows_dll(rctx, python_bin, dll_script, interface_path)

    def _shared_library_name(shared_path, platform):
        readelf_bin = None
        if not platform.startswith("osx"):
            readelf_bin = readelf_binary(rctx, readelf_label, tool_repository, readelf_candidates)
        return shared_library_name(
            rctx,
            shared_path,
            platform,
            readelf_bin,
            resolved_otool_path,
        )

    identify_fn = _identify_windows_dll if needs_windows_support else None

    return struct(
        pkg_config = pkg_config_bin,
        identify_windows_dll = identify_fn,
        shared_library_name = _shared_library_name,
    )
