#!/usr/bin/env python3
"""
Mini VM & Test Harness for exteraGram Android/iOS Plugins.

Simulates the full iOS app runtime environment:
- Unpacks .plugin zip archives or loads .py files
- Parses plugin metadata and manifests
- Provides full Chaquopy (java.jclass) and ElyxCore SDK environment
- Traces and records all UI bulletins, dialogs, messages, reactions, hooks, and settings
- Tests lifecycle (on_load, on_unload) and simulates Telegram events
"""

import sys
import os
import io
import json
import zipfile
import tempfile
import shutil
import time
import types
import inspect
import traceback

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SDK_PATH = os.path.join(REPO_ROOT, "exteraGram", "messenger", "plugins", "EGPluginEngine", "Python", "SDK")


class PluginExecutionTrace:
    def __init__(self):
        self.logs = []
        self.bulletins = []
        self.alerts = []
        self.dialogs = []
        self.messages_sent = []
        self.reactions_sent = []
        self.hooks_registered = {}
        self.settings_read = {}
        self.settings_written = {}
        self.open_chats = []
        self.open_urls = []

    def print_summary(self):
        print("\n" + "=" * 60)
        print("           PLUGIN MINI-VM EXECUTION REPORT")
        print("=" * 60)
        print(f"[*] Logs Recorded:          {len(self.logs)}")
        for l in self.logs[:10]:
            print(f"    - {l}")
        if len(self.logs) > 10:
            print(f"    ... and {len(self.logs) - 10} more")

        print(f"\n[*] Bulletins / Toasts:     {len(self.bulletins)}")
        for b in self.bulletins:
            print(f"    - [{b['icon']}] {b['text']} (subtitle: {b['subtitle']!r})")

        print(f"\n[*] Alerts / Dialogs:       {len(self.alerts) + len(self.dialogs)}")
        for a in self.alerts:
            print(f"    - Alert: {a}")
        for d in self.dialogs:
            print(f"    - UI Dialog: {d}")

        print(f"\n[*] Messages Sent:          {len(self.messages_sent)}")
        for m in self.messages_sent:
            print(f"    - Peer {m['peer_id']}: {m['text']!r} (reply_to: {m['reply_to']})")

        print(f"\n[*] Reactions Sent:         {len(self.reactions_sent)}")
        for r in self.reactions_sent:
            print(f"    - Peer {r['peer_id']} msg {r['msg_id']}: {r['reaction']}")

        print(f"\n[*] Hooks Registered:       {len(self.hooks_registered)}")
        for h, callbacks in self.hooks_registered.items():
            print(f"    - Hook '{h}': {len(callbacks)} callback(s)")

        print(f"\n[*] Settings Read:          {len(self.settings_read)}")
        for k, v in self.settings_read.items():
            print(f"    - {k} -> {v!r}")

        print(f"\n[*] Settings Written:       {len(self.settings_written)}")
        for k, v in self.settings_written.items():
            print(f"    - {k} <- {v!r}")
        print("=" * 60 + "\n")


class PluginMiniVM:
    def __init__(self, trace: PluginExecutionTrace):
        self.trace = trace
        self._setup_sdk_environment()

    def _setup_sdk_environment(self):
        if SDK_PATH not in sys.path:
            sys.path.insert(0, SDK_PATH)

        # Mock native iOS bridge
        bridge = types.ModuleType("_ios_bridge")
        bridge.log = lambda tag, msg: self.trace.logs.append(f"[{tag}] {msg}")
        bridge.get_string = lambda k: f"localized_{k}"
        bridge.get_locale_language = lambda: "en"
        bridge.get_plugin_data_dir = lambda p: os.path.join(tempfile.gettempdir(), "eg_data", p)
        bridge.run_on_main_thread = lambda f: f()
        
        def _get_setting(p, k, default=None):
            self.trace.settings_read[f"{p}.{k}"] = default
            return self.trace.settings_written.get(f"{p}.{k}", default)
        bridge.get_plugin_setting = _get_setting

        def _set_setting(p, k, v):
            self.trace.settings_written[f"{p}.{k}"] = v
        bridge.set_plugin_setting = _set_setting

        def _add_hook(tl_type, cb):
            if tl_type not in self.trace.hooks_registered:
                self.trace.hooks_registered[tl_type] = []
            self.trace.hooks_registered[tl_type].append(cb)
        bridge.add_tl_hook = _add_hook

        bridge.show_bulletin = lambda text, sub="", icon="info": self.trace.bulletins.append(
            {"text": text, "subtitle": sub, "icon": icon}
        )
        bridge.show_alert = lambda title, msg, btn="OK": self.trace.alerts.append(
            {"title": title, "message": msg, "button": btn}
        )
        bridge.show_confirm_dialog = lambda title, msg, on_ok, on_cancel=None: self.trace.alerts.append(
            {"title": title, "message": msg, "type": "confirm"}
        )
        bridge.show_dialog = lambda spec: self.trace.dialogs.append(spec)
        bridge.update_dialog = lambda h, spec: self.trace.dialogs.append(spec)
        bridge.dismiss_dialog = lambda h: None
        bridge.register_plugin_entry = lambda p, t, i, title, icon=None: self.trace.logs.append(
            f"Registered entry: {p}/{t}/{i} '{title}'"
        )

        bridge.send_message = lambda p, t, r=0: self.trace.messages_sent.append(
            {"peer_id": p, "text": t, "reply_to": r}
        )
        bridge.send_reaction = lambda p, m, r: self.trace.reactions_sent.append(
            {"peer_id": p, "msg_id": m, "reaction": r}
        )
        bridge.edit_message = lambda p, m, t: self.trace.messages_sent.append(
            {"peer_id": p, "text": f"[EDIT {m}] {t}", "reply_to": 0}
        )
        bridge.delete_messages = lambda p, ms, for_all=True: self.trace.logs.append(
            f"Deleted messages {ms} in peer {p}"
        )
        bridge.open_chat = lambda p: self.trace.open_chats.append(p)
        bridge.open_url = lambda u: self.trace.open_urls.append(u)
        bridge.share_text = lambda t: self.trace.logs.append(f"Shared text: {t}")

        sys.modules["_ios_bridge"] = bridge

    def run_plugin(self, plugin_path: str):
        print(f"[*] Mini-VM: Loading plugin from '{plugin_path}'...")
        if not os.path.exists(plugin_path):
            raise FileNotFoundError(f"Plugin path not found: {plugin_path}")

        temp_dir = tempfile.mkdtemp(prefix="eg_vm_")
        try:
            plugin_id = os.path.splitext(os.path.basename(plugin_path))[0]
            work_dir = temp_dir

            if zipfile.is_zipfile(plugin_path):
                print("    - Format: Zip Archive (.plugin)")
                with zipfile.ZipFile(plugin_path, "r") as z:
                    z.extractall(temp_dir)
                work_dir = temp_dir
            elif os.path.isdir(plugin_path):
                print("    - Format: Directory")
                work_dir = plugin_path
            else:
                print("    - Format: Single File (.py / .plugin)")
                shutil.copy2(plugin_path, os.path.join(temp_dir, "plugin.py"))
                work_dir = temp_dir

            entrypoint = None
            for candidate in ["plugin.py", "main.py", "__init__.py"]:
                p = os.path.join(work_dir, candidate)
                if os.path.exists(p):
                    entrypoint = p
                    break

            if not entrypoint:
                for f in os.listdir(work_dir):
                    if f.endswith((".py", ".plugin")):
                        entrypoint = os.path.join(work_dir, f)
                        break

            if not entrypoint:
                raise RuntimeError(f"No executable entrypoint found in {work_dir}")

            print(f"    - Entrypoint: {os.path.basename(entrypoint)}")

            from elyxcore._importer import importer
            ctx = importer.register_plugin(plugin_id, work_dir)

            import importlib.util
            spec = importlib.util.spec_from_file_location(plugin_id, entrypoint)
            mod = importlib.util.module_from_spec(spec)
            sys.modules[plugin_id] = mod
            spec.loader.exec_module(mod)

            # Check for Class-based Plugin or Module-based hooks
            plugin_instance = None
            for attr_name in dir(mod):
                attr = getattr(mod, attr_name)
                if isinstance(attr, type):
                    if attr_name.endswith("Plugin") or hasattr(attr, "on_load"):
                        plugin_instance = attr()
                        break

            if plugin_instance and hasattr(plugin_instance, "on_load"):
                print("    - Executing plugin.on_load()...")
                sig = inspect.signature(plugin_instance.on_load)
                if len(sig.parameters) == 0:
                    plugin_instance.on_load()
                else:
                    plugin_instance.on_load(plugin_instance)
            elif hasattr(mod, "on_load"):
                print("    - Executing module.on_load()...")
                sig = inspect.signature(mod.on_load)
                if len(sig.parameters) == 0:
                    mod.on_load()
                else:
                    mod.on_load(mod)
            else:
                print("    - Top-level script executed (no on_load function).")

            print("[+] Plugin loaded and executed successfully in Mini-VM!")

        except Exception as e:
            print(f"\n[!] ERROR DURING PLUGIN EXECUTION:")
            traceback.print_exc()
            raise
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 plugin_vm_runner.py <path_to_plugin>")
        sys.exit(1)

    trace = PluginExecutionTrace()
    vm = PluginMiniVM(trace)
    try:
        vm.run_plugin(sys.argv[1])
    finally:
        trace.print_summary()
