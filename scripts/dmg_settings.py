"""dmgbuild 使用的安装画布；与原生图稿共用布局源。"""
import json
from pathlib import Path

layout = json.loads(Path(defines["layout"]).read_text())
application = Path(defines["app"])
artwork = Path(defines["artwork"])
destination = layout["destinationName"]
files = [str(application)]
symlinks = {destination: "/Applications"}
icon = str(artwork / "AppIcon.icns")
background = str(artwork / "installer-background.tiff")
icon_locations = {application.name: tuple(layout["appPosition"]),
                  destination: tuple(layout["destinationPosition"])}
window_rect = ((160, 160), (layout["window"]["width"], layout["window"]["height"]))
default_view = "icon-view"
icon_size = layout["iconSize"]
text_size = layout["textSize"]
label_pos = "bottom"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
hide_extensions = [application.name]
format = "UDZO"
filesystem = "HFS+"
