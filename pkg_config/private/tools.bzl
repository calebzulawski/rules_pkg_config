"""External tools for interacting with shared libraries."""

def python_binary(rctx):
    if rctx.os.name.startswith("windows"):
        return Label("@python_3_11_host//:python.exe")
    return Label("@python_3_11_host//:bin/python3")

def identify_windows_dll(rctx, interface_path):
    dll_inspector = Label("//pkg_config/private/scripts:get_dll_from_import_lib.py")
    python_bin = python_binary(rctx)
    rctx.watch(dll_inspector)
    result = rctx.execute([python_bin, str(rctx.path(dll_inspector)), interface_path])
    if result.return_code != 0:
        fail("get_dll_from_import_lib.py failed with {}\nstdout:\n{}\nstderr:\n{}".format(result.return_code, result.stdout, result.stderr))
    dll_name = result.stdout.strip()
    return dll_name if dll_name != "" else None

def shared_library_name(rctx, shared_path, readelf_bin, otool_bin):
    if shared_path.endswith(".dylib"):
        # head -c 0 will fail on dyld-cache placeholders because the file can't be opened.
        probe = rctx.execute(["head", "-c", "0", shared_path])
        if probe.return_code != 0:
            return None
        result = rctx.execute([otool_bin, "-D", shared_path])
        if result.return_code != 0:
            fail("otool failed with {}\nstdout:\n{}\nstderr:\n{}".format(result.return_code, result.stdout, result.stderr))
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if len(lines) >= 2:
            return lines[-1]
        return shared_path
    else:
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
        return shared_path

def make_tool_config(rctx):
    otool = rctx.which("otool")

    if rctx.os.name.startswith("windows"):
        pkg_config = "@rules_pkg_config_pkg_config//:pkgconf.exe"
        readelf = "@rules_pkg_config_binutils//:readelf.exe"
    else:
        pkg_config = "@rules_pkg_config_pkg_config//:bin/pkgconf"
        readelf = "@rules_pkg_config_binutils//:bin/readelf"
    pkg_config = rctx.path(Label(pkg_config))
    readelf = rctx.path(Label(readelf))

    def _identify_windows_dll(interface_path):
        return identify_windows_dll(rctx, interface_path)

    def _shared_library_name(shared_path):
        return shared_library_name(
            rctx,
            shared_path,
            readelf,
            otool,
        )

    identify_fn = _identify_windows_dll

    return struct(
        pkg_config = pkg_config,
        identify_windows_dll = identify_fn,
        shared_library_name = _shared_library_name,
    )
