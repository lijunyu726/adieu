# dmgbuild 配置：安装窗口的背景、大小和图标位置。由 scripts/make-dmg.sh 调用
app = defines["app"]

files = [app]
symlinks = {"应用程序": "/Applications"}
icon = defines["icon"]
format = "UDZO"

# 背景 660×400（另带 2 倍图），两个图标落在背景左右两块空位上，中间是颗粒飘过的方向
background = defines["background"]
window_rect = ((240, 200), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    "Adieu.app": (137, 176),
    "应用程序": (524, 176),
}
