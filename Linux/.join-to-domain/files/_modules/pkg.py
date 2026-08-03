# -*- coding: utf-8 -*-
"""
Universal fallback Salt pkg execution module.

Зачем нужен:
  Для Salt onedir, где штатный pkg module не грузится из-за отсутствия
  python bindings пакетного менеджера:
    - apt_pkg / apt_inst на DEB-like
    - rpm / dnf / libdnf / hawkey на RPM-like

Этот модуль подменяет Salt execution module "pkg" и работает через CLI:
  DEB-like:
    apt-get, apt-cache, dpkg-query, dpkg

  RPM-like:
    dnf/yum, rpm

Поддерживает базовые функции, нужные для SLS:
  pkg.installed
  pkg.latest
  pkg.removed
  pkg.purged

Не является полной заменой штатного Salt aptpkg/yumpkg/dnfpkg.
"""

import os
import re
import shlex
import subprocess

__virtualname__ = "pkg"


def __virtual__():
    if _cmd_exists("apt-get") and _cmd_exists("dpkg-query"):
        return __virtualname__

    if _cmd_exists("dnf") and _cmd_exists("rpm"):
        return __virtualname__

    if _cmd_exists("yum") and _cmd_exists("rpm"):
        return __virtualname__

    if _cmd_exists("apt-get") and _cmd_exists("rpm"):
        return __virtualname__

    return False, "No supported package backend found"


def _cmd_exists(cmd):
    search_path = os.environ.get(
        "PATH",
        "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    )

    for path in search_path.split(":"):
        full = os.path.join(path, cmd)

        if os.path.exists(full) and os.access(full, os.X_OK):
            return True

    return False


def _backend():
    if _cmd_exists("apt-get") and _cmd_exists("dpkg-query"):
        return "apt"

    if _cmd_exists("dnf") and _cmd_exists("rpm"):
        return "dnf"

    if _cmd_exists("yum") and _cmd_exists("rpm"):
        return "yum"

    if _cmd_exists("apt-get") and _cmd_exists("rpm"):
        return "apt_rpm"

    return "unknown"


def _pm_cmd():
    backend = _backend()

    if backend == "dnf":
        return "dnf"

    if backend == "yum":
        return "yum"

    return ""


def _run(cmd, timeout=1800):
    env = dict(os.environ)
    env["DEBIAN_FRONTEND"] = "noninteractive"
    env["LC_ALL"] = "C"
    env["LANG"] = "C"

    proc = subprocess.run(
        cmd,
        shell=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        env=env,
    )

    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def _q(value):
    return shlex.quote(str(value))


def _normalize_targets(name=None, pkgs=None, sources=None, **kwargs):
    targets = []

    if pkgs:
        if isinstance(pkgs, str):
            targets.append(pkgs)
        elif isinstance(pkgs, (list, tuple)):
            for item in pkgs:
                if isinstance(item, str):
                    targets.append(item)
                elif isinstance(item, dict):
                    for key in item:
                        targets.append(key)

    if sources:
        if isinstance(sources, str):
            targets.append(sources)
        elif isinstance(sources, (list, tuple)):
            for item in sources:
                if isinstance(item, str):
                    targets.append(item)
                elif isinstance(item, dict):
                    for key in item:
                        targets.append(key)

    if name:
        targets.append(name)

    result = []
    seen = set()

    for target in targets:
        if not target:
            continue

        target = str(target).strip()

        if not target:
            continue

        if target in seen:
            continue

        seen.add(target)
        result.append(target)

    return result


def _apt_installed_version(name):
    code, out, err = _run(
        "dpkg-query -W -f='${{Version}}' {} 2>/dev/null".format(_q(name)),
        timeout=60,
    )

    return out if code == 0 else ""


def _rpm_installed_version(name):
    code, out, err = _run(
        "rpm -q --qf '%{VERSION}-%{RELEASE}' {} 2>/dev/null".format(_q(name)),
        timeout=60,
    )

    if code != 0:
        return ""

    if "is not installed" in out:
        return ""

    return out


def refresh_db(**kwargs):
    backend = _backend()

    if backend in ("apt", "apt_rpm"):
        code, out, err = _run("apt-get update", timeout=1800)
        return code == 0

    if backend in ("dnf", "yum"):
        pm = _pm_cmd()
        code, out, err = _run("{} -y makecache".format(pm), timeout=1800)
        return code == 0

    return False


def list_pkgs(versions_as_list=False, **kwargs):
    backend = _backend()
    ret = {}

    if backend == "apt":
        code, out, err = _run(
            "dpkg-query -W -f='${{binary:Package}} ${{Version}}\\n'",
            timeout=300,
        )

        if code != 0:
            return ret

        for line in out.splitlines():
            line = line.strip()

            if not line:
                continue

            parts = line.split(None, 1)

            if len(parts) != 2:
                continue

            pkg_name, version = parts
            ret[pkg_name] = [version] if versions_as_list else version

        return ret

    if backend in ("apt_rpm", "dnf", "yum"):
        code, out, err = _run(
            "rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\\n'",
            timeout=300,
        )

        if code != 0:
            return ret

        for line in out.splitlines():
            line = line.strip()

            if not line:
                continue

            parts = line.split(None, 1)

            if len(parts) != 2:
                continue

            pkg_name, version = parts
            ret[pkg_name] = [version] if versions_as_list else version

        return ret

    return ret


def version(*names, **kwargs):
    if not names:
        return list_pkgs(**kwargs)

    backend = _backend()
    ret = {}

    for name in names:
        if backend == "apt":
            ret[name] = _apt_installed_version(name)
        elif backend in ("apt_rpm", "dnf", "yum"):
            ret[name] = _rpm_installed_version(name)
        else:
            ret[name] = ""

    if len(names) == 1:
        return ret[names[0]]

    return ret


def latest_version(*names, **kwargs):
    refresh = kwargs.get("refresh", False)

    if refresh:
        refresh_db()

    backend = _backend()
    ret = {}

    if backend in ("apt", "apt_rpm"):
        for name in names:
            code, out, err = _run(
                "apt-cache policy {}".format(_q(name)),
                timeout=120,
            )

            candidate = ""

            if code == 0:
                for line in out.splitlines():
                    line = line.strip()

                    if line.startswith("Candidate:"):
                        candidate = line.split(":", 1)[1].strip()

                        if candidate == "(none)":
                            candidate = ""

                        break

            installed = _apt_installed_version(name) if backend == "apt" else _rpm_installed_version(name)

            if installed and candidate and installed == candidate:
                ret[name] = ""
            else:
                ret[name] = candidate

    elif backend in ("dnf", "yum"):
        pm = _pm_cmd()

        for name in names:
            candidate = ""

            code, out, err = _run(
                "{} repoquery --qf '%{{VERSION}}-%{{RELEASE}}' {} 2>/dev/null | sort -V | tail -n1".format(
                    pm,
                    _q(name),
                ),
                timeout=300,
            )

            if code == 0 and out:
                candidate = out.splitlines()[-1].strip()

            if not candidate:
                code, out, err = _run(
                    "{} info {} 2>/dev/null".format(pm, _q(name)),
                    timeout=300,
                )

                version_s = ""
                release_s = ""

                if code == 0:
                    for line in out.splitlines():
                        line = line.strip()

                        if line.startswith("Version"):
                            version_s = line.split(":", 1)[1].strip()
                        elif line.startswith("Release"):
                            release_s = line.split(":", 1)[1].strip()

                    if version_s and release_s:
                        candidate = "{}-{}".format(version_s, release_s)
                    elif version_s:
                        candidate = version_s

            ret[name] = candidate

    else:
        for name in names:
            ret[name] = ""

    if len(names) == 1:
        return ret[names[0]]

    return ret


def version_cmp(ver1, ver2, **kwargs):
    if ver1 == ver2:
        return 0

    backend = _backend()

    if backend == "apt" and _cmd_exists("dpkg"):
        code, out, err = _run(
            "dpkg --compare-versions {} lt {}".format(_q(ver1), _q(ver2)),
            timeout=60,
        )

        if code == 0:
            return -1

        code, out, err = _run(
            "dpkg --compare-versions {} gt {}".format(_q(ver1), _q(ver2)),
            timeout=60,
        )

        if code == 0:
            return 1

        return 0

    if backend in ("apt_rpm", "dnf", "yum") and _cmd_exists("rpmdev-vercmp"):
        code, out, err = _run(
            "rpmdev-vercmp {} {}".format(_q(ver1), _q(ver2)),
            timeout=60,
        )

        text = "{}\n{}".format(out, err)

        if "<" in text:
            return -1

        if ">" in text:
            return 1

        if "=" in text:
            return 0

    def split_version(value):
        return [
            int(part) if part.isdigit() else part
            for part in re.split(r"([0-9]+)", str(value))
        ]

    a = split_version(ver1)
    b = split_version(ver2)

    if a < b:
        return -1

    if a > b:
        return 1

    return 0


def upgrade_available(name, **kwargs):
    installed = version(name)
    candidate = latest_version(name, refresh=kwargs.get("refresh", False))

    if not candidate:
        return False

    if not installed:
        return True

    return version_cmp(installed, candidate) < 0


def list_upgrades(refresh=True, **kwargs):
    backend = _backend()
    ret = {}

    if refresh:
        refresh_db()

    if backend == "apt":
        code, out, err = _run("apt list --upgradable 2>/dev/null", timeout=300)

        if code != 0:
            return ret

        for line in out.splitlines():
            line = line.strip()

            if not line:
                continue

            if line.startswith("Listing"):
                continue

            pkg_name = line.split("/", 1)[0]
            parts = line.split()

            if len(parts) >= 2:
                ret[pkg_name] = parts[1]

        return ret

    if backend in ("dnf", "yum"):
        pm = _pm_cmd()
        code, out, err = _run(
            "{} check-update 2>/dev/null || true".format(pm),
            timeout=600,
        )

        for line in out.splitlines():
            line = line.strip()

            if not line:
                continue

            if line.startswith(("Last metadata", "Loaded plugins", "Obsoleting")):
                continue

            parts = line.split()

            if len(parts) < 2:
                continue

            pkg_name = parts[0]

            if "." in pkg_name:
                pkg_name = pkg_name.rsplit(".", 1)[0]

            ret[pkg_name] = parts[1]

        return ret

    return ret


def install(name=None, pkgs=None, sources=None, refresh=False, **kwargs):
    targets = _normalize_targets(name=name, pkgs=pkgs, sources=sources, **kwargs)

    if not targets:
        return {}

    old = list_pkgs()

    if refresh:
        refresh_db()

    backend = _backend()

    if backend in ("apt", "apt_rpm"):
        cmd = "apt-get install -y {}".format(" ".join(_q(x) for x in targets))
    elif backend in ("dnf", "yum"):
        pm = _pm_cmd()
        cmd = "{} install -y {}".format(pm, " ".join(_q(x) for x in targets))
    else:
        return {}

    code, out, err = _run(cmd, timeout=1800)

    new = list_pkgs()
    changes = {}

    for pkg_name in targets:
        old_ver = old.get(pkg_name, "")
        new_ver = new.get(pkg_name, "")

        if old_ver != new_ver:
            changes[pkg_name] = {
                "old": old_ver,
                "new": new_ver,
            }

    return changes


def latest(name=None, pkgs=None, refresh=True, **kwargs):
    return install(name=name, pkgs=pkgs, refresh=refresh, **kwargs)


def remove(name=None, pkgs=None, **kwargs):
    targets = _normalize_targets(name=name, pkgs=pkgs, **kwargs)

    if not targets:
        return {}

    old = list_pkgs()
    backend = _backend()

    if backend in ("apt", "apt_rpm"):
        cmd = "apt-get remove -y {}".format(" ".join(_q(x) for x in targets))
    elif backend in ("dnf", "yum"):
        pm = _pm_cmd()
        cmd = "{} remove -y {}".format(pm, " ".join(_q(x) for x in targets))
    else:
        return {}

    code, out, err = _run(cmd, timeout=1800)

    new = list_pkgs()
    changes = {}

    for pkg_name in targets:
        old_ver = old.get(pkg_name, "")
        new_ver = new.get(pkg_name, "")

        if old_ver != new_ver:
            changes[pkg_name] = {
                "old": old_ver,
                "new": new_ver,
            }

    return changes


def purge(name=None, pkgs=None, **kwargs):
    targets = _normalize_targets(name=name, pkgs=pkgs, **kwargs)

    if not targets:
        return {}

    old = list_pkgs()
    backend = _backend()

    if backend in ("apt", "apt_rpm"):
        cmd = "apt-get purge -y {}".format(" ".join(_q(x) for x in targets))
    elif backend in ("dnf", "yum"):
        pm = _pm_cmd()
        cmd = "{} remove -y {}".format(pm, " ".join(_q(x) for x in targets))
    else:
        return {}

    code, out, err = _run(cmd, timeout=1800)

    new = list_pkgs()
    changes = {}

    for pkg_name in targets:
        old_ver = old.get(pkg_name, "")
        new_ver = new.get(pkg_name, "")

        if old_ver != new_ver:
            changes[pkg_name] = {
                "old": old_ver,
                "new": new_ver,
            }

    return changes


def normalize_name(name):
    return name


def check_db(*args, **kwargs):
    return True


def owner(*paths, **kwargs):
    backend = _backend()
    ret = {}

    if backend == "apt":
        for path in paths:
            code, out, err = _run(
                "dpkg-query -S {} 2>/dev/null".format(_q(path)),
                timeout=60,
            )

            if code == 0 and ":" in out:
                ret[path] = out.split(":", 1)[0].split(",")[0].strip()
            else:
                ret[path] = ""

        return ret

    if backend in ("apt_rpm", "dnf", "yum"):
        for path in paths:
            code, out, err = _run(
                "rpm -qf {} 2>/dev/null".format(_q(path)),
                timeout=60,
            )

            ret[path] = out.strip() if code == 0 else ""

        return ret

    return {path: "" for path in paths}


def file_list(*packages, **kwargs):
    backend = _backend()
    ret = {}

    for package in packages:
        if backend == "apt":
            code, out, err = _run("dpkg -L {}".format(_q(package)), timeout=120)
        elif backend in ("apt_rpm", "dnf", "yum"):
            code, out, err = _run("rpm -ql {}".format(_q(package)), timeout=120)
        else:
            code, out, err = 1, "", ""

        ret[package] = out.splitlines() if code == 0 else []

    return ret


def info_installed(*names, **kwargs):
    backend = _backend()
    ret = {}

    for name in names:
        if backend == "apt":
            code, out, err = _run(
                "dpkg-query -s {}".format(_q(name)),
                timeout=120,
            )

            if code != 0:
                continue

            data = {}
            current_key = None

            for line in out.splitlines():
                if not line:
                    continue

                if line.startswith(" ") and current_key:
                    data[current_key] += "\n" + line
                    continue

                if ":" in line:
                    key, value = line.split(":", 1)
                    current_key = key.lower()
                    data[current_key] = value.strip()

            ret[name] = data

        elif backend in ("apt_rpm", "dnf", "yum"):
            code, out, err = _run("rpm -qi {}".format(_q(name)), timeout=120)

            if code != 0:
                continue

            data = {}

            for line in out.splitlines():
                if ":" in line:
                    key, value = line.split(":", 1)
                    data[key.strip().lower().replace(" ", "_")] = value.strip()

            ret[name] = data

    return ret


def info_available(*names, **kwargs):
    backend = _backend()
    ret = {}

    for name in names:
        if backend in ("apt", "apt_rpm"):
            code, out, err = _run(
                "apt-cache show {}".format(_q(name)),
                timeout=120,
            )

            if code != 0:
                continue

            data = {}
            current_key = None

            for line in out.splitlines():
                if not line:
                    break

                if line.startswith(" ") and current_key:
                    data[current_key] += "\n" + line
                    continue

                if ":" in line:
                    key, value = line.split(":", 1)
                    current_key = key.lower()
                    data[current_key] = value.strip()

            ret[name] = data

        elif backend in ("dnf", "yum"):
            pm = _pm_cmd()
            code, out, err = _run(
                "{} info {}".format(pm, _q(name)),
                timeout=300,
            )

            if code != 0:
                continue

            data = {}

            for line in out.splitlines():
                if ":" in line:
                    key, value = line.split(":", 1)
                    data[key.strip().lower().replace(" ", "_")] = value.strip()

            ret[name] = data

    return ret
