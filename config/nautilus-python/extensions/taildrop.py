import shutil
import subprocess
import time

from gi import require_version

require_version("Nautilus", "4.1")

from gi.repository import GObject, Gio, Nautilus

# Nautilus asks for menu items on every right-click, and listing Taildrop
# targets is a round trip to tailscaled, so the list is reused this long.
TARGETS_TTL_SECONDS = 30


class SendViaTaildropAction(GObject.GObject, Nautilus.MenuProvider):
    def __init__(self):
        super().__init__()
        self._targets = []
        self._fetched_at = None

    def _online_targets(self):
        now = time.monotonic()
        if self._fetched_at is not None and now - self._fetched_at < TARGETS_TTL_SECONDS:
            return self._targets

        tailscale = shutil.which("tailscale")
        output = ""
        if tailscale:
            try:
                output = subprocess.run(
                    [tailscale, "file", "cp", "--targets"],
                    capture_output=True,
                    text=True,
                    timeout=3,
                ).stdout
            except (OSError, subprocess.TimeoutExpired):
                output = ""

        # Each line is "<ip>\t<name>"; a third field ("offline; last seen ...")
        # marks a peer that cannot receive right now, so it is left out.
        targets = []
        for line in output.splitlines():
            fields = line.split("\t")
            if len(fields) == 2 and fields[1]:
                targets.append(fields[1])

        self._targets = sorted(targets)
        self._fetched_at = now
        return self._targets

    def _selected_paths(self, files):
        paths = []

        for file in files:
            # Taildrop sends files, not folders, so a folder in the selection
            # means the whole menu stays hidden rather than failing on send.
            if file.is_directory():
                return []

            location = file.get_location()
            path = location.get_path() if location else None
            if not path:
                return []

            if path not in paths:
                paths.append(path)

        return paths

    def _make_item(self, sender, targets, paths):
        label = "Send via Taildrop" if len(paths) == 1 else "Send selected via Taildrop"
        item = Nautilus.MenuItem(name="TaildropNautilus::send_via_taildrop", label=label)

        submenu = Nautilus.Menu()
        for target in targets:
            target_item = Nautilus.MenuItem(
                name=f"TaildropNautilus::send_to_{target}",
                label=target,
            )
            target_item.connect("activate", self._on_activate, sender, target, paths)
            submenu.append_item(target_item)

        item.set_submenu(submenu)
        return item

    def _on_activate(self, _menu, sender, target, paths):
        # omarchy-tailscale-send runs the transfer and posts the sent/failed
        # notification, the same path as `omarchy tailscale send`.
        Gio.Subprocess.new([sender, target, *paths], Gio.SubprocessFlags.NONE)

    def get_file_items(self, *args):
        files = args[0] if len(args) == 1 else args[1]
        paths = self._selected_paths(files)
        sender = shutil.which("omarchy-tailscale-send")

        if not paths or not sender:
            return []

        targets = self._online_targets()
        if not targets:
            return []

        return [self._make_item(sender, targets, paths)]
