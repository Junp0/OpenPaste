"""Write and verify Finder metadata on our mounted installation image."""
import sys
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias

root = Path(sys.argv[2])
positions = {"OpenPaste.app": (184, 224), "应用程序": (496, 224)}
if sys.argv[1] == "write":
    with DSStore.open(str(root / ".DS_Store"), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = {
            "WindowBounds": "{{180, 140}, {680, 440}}",
            "ShowStatusBar": False, "ShowTabView": False, "ShowToolbar": False,
            "ShowPathbar": False, "ShowSidebar": False,
            "ContainerShowSidebar": False, "PreviewPaneVisibility": False,
            "SidebarWidth": 0,
        }
        store["."]["icvp"] = {
            "viewOptionsVersion": 1, "backgroundType": 2,
            "backgroundImageAlias": Alias.for_file(str(root / ".background/background.tiff")).to_bytes(),
            "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
            "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 80.0,
            "arrangeBy": "none", "showIconPreview": False, "showItemInfo": False,
            "labelOnBottom": True, "textSize": 13.0, "iconSize": 104.0,
            "scrollPositionX": 0.0, "scrollPositionY": 0.0,
        }
        store["."]["icvl"] = ("type", b"icnv")
        store["."]["vstl"] = ("type", b"icnv")
        for name, position in positions.items():
            store[name]["Iloc"] = position
elif sys.argv[1] == "verify":
    visible = {p.name for p in root.iterdir() if not p.name.startswith(".")}
    if visible != set(positions):
        raise SystemExit(f"DMG 可见内容异常：{visible}")
    if (root / "应用程序").readlink() != Path("/Applications"):
        raise SystemExit("应用程序快捷入口无效")
    if not (root / ".VolumeIcon.icns").is_file():
        raise SystemExit("缺少磁盘图标")
    with DSStore.open(str(root / ".DS_Store"), "r") as store:
        for name, position in positions.items():
            if store[name]["Iloc"] != position:
                raise SystemExit(f"图标位置异常：{name}")
        options = store["."]["icvp"]
        alias = Alias.from_bytes(options["backgroundImageAlias"])
        if options["backgroundType"] != 2 or alias.target.filename != "background.tiff":
            raise SystemExit("安装背景配置异常")
        if store["."]["bwsp"]["WindowBounds"] != "{{180, 140}, {680, 440}}":
            raise SystemExit("窗口大小异常")
    print("DMG 内容、背景及 Finder 布局校验通过")
else:
    raise SystemExit("用法：configure-dmg.py write|verify 挂载点")
