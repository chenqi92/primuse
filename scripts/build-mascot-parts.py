#!/usr/bin/env python3
"""生成「水彩小剧场」的角色纸偶资源：分件 PNG、补画的表情部件和一份部件清单。

    scripts/build-mascot-parts.py <母版目录> [输出目录]

母版目录是四个角色的正面动画母版（每个角色一个子目录，里面有 layers.json、
*_front_master.svg 和 parts_png_4096/）。输出目录默认是
Primuse/Resources/WatercolorTheater，生成：

- <角色>_<部件>.png：从 4096 画布的分件 PNG 按 layers.json 的边界裁下来，缩到
  1024 画布的比例（单件最长边不超过 512 像素），缩放前先预乘透明度，边缘不发黑。
- <角色>_t_<部件>.png：母版里没有的表情（闭眼、笑眼、张嘴、圆嘴、腮红……）。
  按 SVG 片段画好，借母版里的渐变，用 ffmpeg 的 librsvg 栅格化成同样的比例。
- manifest.json：每个角色的骨骼（父件、轴心、拉伸方向）、由底到顶的叠放顺序、
  每个部件在母版坐标里的位置和大小、表情插槽、手和头顶这些锚点。

只用 Python 标准库和 ffmpeg。坐标都是母版 SVG 的单位（viewBox 1600，脚底 y=1460）。
"""
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(ROOT, "Primuse", "Resources", "WatercolorTheater")
CHARACTERS = ["yuanyin", "xiaohei", "ajiu", "xiaohuolv"]

SVG_UNITS = 1600.0
SOURCE_PIXELS = 4096.0
# 1024 画布：每个母版单位 0.64 像素。
PIXELS_PER_UNIT = 1024.0 / SVG_UNITS
MAX_PART_SIDE = 512
# 裁边时在 layers.json 的边界外多留几像素（4096 画布），描边的抗锯齿不被切掉。
CROP_MARGIN = 12

# 骨骼：名字 -> (父件, 轴心 x, 轴心 y, 选项)。axis 是拉伸的方向（弧度），counter 表示抵消父件的拉伸。
RIGS = {
    "yuanyin": {
        "bones": {
            "root": (None, 800, 1460, {}), "hips": ("root", 800, 1340, {}), "head": ("hips", 800, 1000, {}),
            "phones": ("head", 800, 700, {}), "glasses": ("head", 800, 712, {}), "eyes": ("head", 800, 705, {}),
            "browL": ("head", 630, 592, {}), "browR": ("head", 970, 592, {}), "mouth": ("head", 800, 905, {}),
            "armL": ("hips", 655, 1040, {"axis": 2.09}), "armR": ("hips", 945, 1040, {"axis": 1.05}),
            "handL": ("armL", 560, 1215, {"counter": True}), "handR": ("armR", 1040, 1215, {"counter": True}),
            "legL": ("root", 676, 1270, {}), "legR": ("root", 924, 1270, {}), "tail": ("hips", 975, 1312, {}),
        },
        "order": [
            ("tail", "tail"), ("leg_L", "legL"), ("leg_R", "legR"), ("foot_L", "legL"), ("foot_R", "legR"),
            ("body", "hips"), ("belly", "hips"), ("arm_L", "armL"), ("arm_R", "armR"), ("hand_L", "handL"),
            ("hand_R", "handR"), ("headphone_band", "phones"), ("head_base", "head"), ("face", "head"),
            ("@eyes", "eyes"), ("brow_L", "browL"), ("brow_R", "browR"), ("nose", "head"), ("@mouth", "mouth"),
            ("@blush", "head"), ("earcup_L", "phones"), ("earcup_R", "phones"), ("sunglasses", "glasses"),
        ],
        "slots": {
            "eyes": {"open": ["t:y_eyes_open"], "closed": ["t:y_eyes_closed"], "happy": ["t:y_eyes_happy"],
                     "wide": ["t:y_eyes_wide"], "up": ["t:y_eyes_up"]},
            "mouth": {"rest": ["t:y_mouth_closed"], "smile": ["t:y_mouth_closed"], "open": ["t:y_mouth_small"],
                      "wide": ["mouth"], "O": ["t:y_mouth_O"], "frown": ["t:y_mouth_frown"]},
            "blush": {"on": ["t:y_blush"]},
        },
        "anchors": {"headTop": [800, 120], "handR": [1052, 1240], "handL": [548, 1240], "mouthPt": [800, 915],
                    "eyeL": [640, 705], "eyeR": [960, 705]},
        "tearFrom": [[548, 815], [1052, 815]],
    },
    "xiaohei": {
        "bones": {
            "root": (None, 800, 1460, {}), "hips": ("root", 800, 1200, {}), "head": ("hips", 800, 790, {}),
            "eyes": ("head", 800, 431, {}), "lipU": ("head", 800, 551, {}), "jaw": ("head", 800, 600, {}),
            "inner": ("head", 800, 598, {}),
            "armL": ("hips", 621, 838, {"axis": 1.97}), "armR": ("hips", 979, 838, {"axis": 1.17}),
            "legL": ("root", 650, 1190, {}), "legR": ("root", 950, 1190, {}),
        },
        "order": [
            ("leg_L", "legL"), ("leg_R", "legR"), ("body", "hips"), ("arm_L", "armL"), ("arm_R", "armR"),
            ("head_base", "head"), ("@eyes", "eyes"), ("@blush", "head"), ("@mouth", "lipU"),
        ],
        "slots": {
            "eyes": {"open": ["eye_L", "eye_R"], "closed": ["t:h_eyes_closed"], "happy": ["t:h_eyes_happy"],
                     "wide": ["t:h_eyes_wide"], "up": ["t:h_eyes_up"]},
            "mouth": {
                "rest": [("mouth_upper", "lipU"), ("mouth_lower", "jaw")],
                "frown": [("mouth_upper", "lipU"), ("mouth_lower", "jaw")],
                "open": [("t:h_mouth_inner", "inner"), ("mouth_upper", "lipU"), ("mouth_lower", "jaw")],
                "wide": [("t:h_mouth_inner", "inner"), ("mouth_upper", "lipU"), ("mouth_lower", "jaw")],
                "smile": [("t:h_lips_smile", "lipU")], "O": [("t:h_lips_O", "lipU")],
            },
            "blush": {"on": ["t:h_blush"]},
        },
        "anchors": {"headTop": [800, 110], "handR": [1120, 1130], "handL": [480, 1130], "mouthPt": [800, 600],
                    "eyeL": [696, 431], "eyeR": [904, 431]},
        "tearFrom": [[696, 452], [904, 452]],
    },
    "ajiu": {
        "bones": {
            "root": (None, 800, 1460, {}), "hips": ("root", 800, 1300, {}), "tail": ("hips", 1020, 1194, {}),
            "legL": ("root", 670, 1269, {}), "legR": ("root", 932, 1269, {}),
            "armL": ("hips", 607, 1027, {"axis": 2.07}), "armR": ("hips", 994, 1027, {"axis": 1.07}),
            "sleeveL": ("hips", 601, 999, {}), "sleeveR": ("hips", 1000, 999, {}),
            "potion": ("armR", 1033, 1227, {"counter": True}),
            "head": ("hips", 800, 940, {}), "hat": ("head", 801, 455, {}), "earL": ("head", 531, 463, {}),
            "earR": ("head", 1070, 463, {}), "eyes": ("head", 800, 724, {}), "browL": ("head", 617, 623, {}),
            "browR": ("head", 980, 607, {}), "mouth": ("head", 800, 801, {}),
        },
        "order": [
            ("tail", "tail"), ("leg_L", "legL"), ("leg_R", "legR"), ("body", "hips"), ("cape_back", "hips"),
            ("skirt", "hips"), ("arm_L", "armL"), ("arm_R", "armR"), ("sleeve_L", "sleeveL"), ("sleeve_R", "sleeveR"),
            ("dress_armor_base", "hips"), ("armor", "hips"), ("potion", "potion"), ("cape_front", "hips"),
            ("hat_back", "hat"), ("ear_L", "earL"), ("ear_R", "earR"), ("head_base", "head"), ("blush", "head"),
            ("whisker_L", "head"), ("whisker_R", "head"), ("@eyes", "eyes"), ("brow_L", "browL"), ("brow_R", "browR"),
            ("nose", "head"), ("@mouth", "mouth"), ("@blush", "head"),
            ("hat_band", "hat"), ("hat_front", "hat"), ("goggles", "hat"), ("bow", "hat"),
        ],
        "slots": {
            "eyes": {"open": ["eye_L", "eye_R"], "closed": ["t:a_eyes_closed"], "happy": ["t:a_eyes_happy"],
                     "wide": ["t:a_eyes_wide"], "up": ["t:a_eyes_up"]},
            "mouth": {"rest": ["mouth"], "smile": ["mouth"], "open": ["t:a_mouth_open"], "wide": ["t:a_mouth_open"],
                      "O": ["t:a_mouth_O"], "frown": ["t:a_mouth_frown"]},
            "blush": {"on": ["t:a_blush_strong"]},
        },
        "anchors": {"headTop": [800, 120], "handR": [1110, 1215], "handL": [490, 1215], "potionPt": [1060, 1300],
                    "mouthPt": [800, 812], "eyeL": [628, 727], "eyeR": [972, 727]},
        "tearFrom": [[610, 790], [990, 790]],
    },
    "xiaohuolv": {
        "bones": {
            "root": (None, 800, 1460, {}), "hips": ("root", 800, 1300, {}), "tail": ("hips", 646, 1228, {}),
            "legL": ("root", 660, 1215, {}), "legR": ("root", 940, 1215, {}),
            "armL": ("hips", 630, 975, {"axis": 2.03}), "armR": ("hips", 970, 975, {"axis": 1.11}),
            "head": ("hips", 800, 990, {}), "earL": ("head", 700, 520, {}), "earR": ("head", 900, 520, {}),
            "eyes": ("head", 800, 690, {}), "browL": ("head", 760, 615, {}), "browR": ("head", 843, 615, {}),
            "mouth": ("head", 815, 930, {}),
        },
        "order": [
            ("tail", "tail"), ("leg_L", "legL"), ("leg_R", "legR"), ("body", "hips"), ("arm_L", "armL"),
            ("arm_R", "armR"), ("harness", "hips"), ("mane_back", "head"), ("ear_L", "earL"), ("ear_R", "earR"),
            ("head_base", "head"), ("mane_front", "head"), ("@eyes", "eyes"), ("brow_L", "browL"),
            ("brow_R", "browR"), ("muzzle", "head"), ("nostrils", "head"), ("@mouth", "mouth"), ("@blush", "head"),
        ],
        "slots": {
            "eyes": {"open": ["eye_L", "eye_R"], "closed": ["t:d_eyes_closed"], "happy": ["t:d_eyes_happy"],
                     "wide": ["t:d_eyes_wide"], "up": ["t:d_eyes_up"]},
            "mouth": {"rest": ["mouth"], "smile": ["mouth"], "open": ["t:d_mouth_open"], "wide": ["t:d_mouth_open"],
                      "O": ["t:d_mouth_O"], "frown": ["t:d_mouth_frown"]},
            "blush": {"on": ["t:d_blush"]},
        },
        "anchors": {"headTop": [800, 110], "handR": [1090, 1200], "handL": [510, 1200], "mouthPt": [930, 925],
                    "eyeL": [673, 690], "eyeR": [930, 690]},
        "tearFrom": [[640, 760], [960, 760]],
    },
}

# 母版只有一套正面表情，下面这些是补画的（边界框 [x0, y0, x1, y1] + SVG 片段，坐标同母版）。
TEMP_PARTS = {
    "yuanyin": {
        "y_eyes_open": ([560, 620, 1040, 790], '<g stroke="#050505" stroke-width="16"><ellipse cx="640" cy="705" rx="62" ry="70" fill="#FFFDF8"/><ellipse cx="960" cy="705" rx="62" ry="70" fill="#FFFDF8"/></g><circle cx="650" cy="716" r="30" fill="#1B120D"/><circle cx="950" cy="716" r="30" fill="#1B120D"/><circle cx="662" cy="702" r="10" fill="#FFFFFF"/><circle cx="962" cy="702" r="10" fill="#FFFFFF"/>'),
        "y_eyes_closed": ([565, 680, 1035, 770], '<path d="M582 712 Q640 752 698 712 M902 712 Q960 752 1018 712" fill="none" stroke="#050505" stroke-width="17" stroke-linecap="round"/>'),
        "y_eyes_happy": ([565, 660, 1035, 760], '<path d="M582 738 Q640 672 698 738 M902 738 Q960 672 1018 738" fill="none" stroke="#050505" stroke-width="17" stroke-linecap="round"/>'),
        "y_eyes_wide": ([550, 610, 1050, 800], '<g stroke="#050505" stroke-width="16"><ellipse cx="640" cy="705" rx="70" ry="82" fill="#FFFDF8"/><ellipse cx="960" cy="705" rx="70" ry="82" fill="#FFFDF8"/></g><circle cx="640" cy="708" r="20" fill="#1B120D"/><circle cx="960" cy="708" r="20" fill="#1B120D"/><circle cx="648" cy="698" r="7" fill="#FFFFFF"/><circle cx="968" cy="698" r="7" fill="#FFFFFF"/>'),
        "y_eyes_up": ([560, 620, 1040, 790], '<g stroke="#050505" stroke-width="16"><ellipse cx="640" cy="705" rx="62" ry="70" fill="#FFFDF8"/><ellipse cx="960" cy="705" rx="62" ry="70" fill="#FFFDF8"/></g><circle cx="646" cy="672" r="28" fill="#1B120D"/><circle cx="954" cy="672" r="28" fill="#1B120D"/><circle cx="656" cy="662" r="9" fill="#FFFFFF"/><circle cx="964" cy="662" r="9" fill="#FFFFFF"/>'),
        "y_mouth_closed": ([690, 850, 910, 950], '<path d="M712 874 Q800 936 888 874" fill="none" stroke="#050505" stroke-width="18" stroke-linecap="round"/><path d="M700 864 Q706 878 718 881 M900 864 Q894 878 882 881" fill="none" stroke="#050505" stroke-width="10" stroke-linecap="round"/>'),
        "y_mouth_small": ([720, 855, 880, 960], '<path d="M735 868 Q800 886 865 868 C856 920 832 946 800 946 C768 946 744 920 735 868Z" fill="#050505"/><path d="M758 914 C774 898 826 898 842 914 C830 934 816 941 800 941 C784 941 770 934 758 914Z" fill="url(#tongue)"/>'),
        "y_mouth_O": ([748, 846, 852, 972], '<ellipse cx="800" cy="909" rx="42" ry="54" fill="#050505"/><ellipse cx="800" cy="936" rx="26" ry="18" fill="url(#tongue)"/>'),
        "y_mouth_frown": ([700, 860, 900, 950], '<path d="M722 932 Q800 876 878 932" fill="none" stroke="#050505" stroke-width="18" stroke-linecap="round"/>'),
        "y_blush": ([530, 845, 1070, 915], '<ellipse cx="592" cy="880" rx="50" ry="24" fill="#FF7FA0" opacity=".72"/><ellipse cx="1008" cy="880" rx="50" ry="24" fill="#FF7FA0" opacity=".72"/><path d="M568 870 L558 890 M592 868 L582 888 M616 870 L606 890 M984 870 L974 890 M1008 868 L998 888 M1032 870 L1022 890" stroke="#E2557A" stroke-width="6" stroke-linecap="round"/>'),
    },
    "xiaohei": {
        "h_eyes_closed": ([655, 420, 945, 465], '<path d="M670 434 Q696 456 722 434 M878 434 Q904 456 930 434" fill="none" stroke="#FFFDF2" stroke-width="10" stroke-linecap="round"/>'),
        "h_eyes_happy": ([655, 405, 945, 460], '<path d="M670 446 Q696 414 722 446 M878 446 Q904 414 930 446" fill="none" stroke="#FFFDF2" stroke-width="10" stroke-linecap="round"/>'),
        "h_eyes_wide": ([660, 394, 940, 468], '<circle cx="696" cy="431" r="27" fill="#FFFDF2"/><circle cx="904" cy="431" r="27" fill="#FFFDF2"/><circle cx="696" cy="434" r="10" fill="#030303"/><circle cx="904" cy="434" r="10" fill="#030303"/>'),
        "h_eyes_up": ([675, 390, 925, 440], '<ellipse cx="696" cy="412" rx="15.8" ry="16.6" fill="#FFFDF2"/><ellipse cx="904" cy="412" rx="15.8" ry="16.6" fill="#FFFDF2"/>'),
        "h_mouth_inner": ([640, 540, 960, 690], '<ellipse cx="800" cy="610" rx="150" ry="62" fill="#5E0F1A"/><ellipse cx="800" cy="640" rx="78" ry="26" fill="#E0566A"/>'),
        "h_lips_O": ([690, 495, 910, 690], '<ellipse cx="800" cy="592" rx="104" ry="92" fill="url(#lip_upper_color)"/><ellipse cx="800" cy="598" rx="50" ry="46" fill="#5E0F1A"/><path d="M738 548 Q770 528 806 528" fill="none" stroke="#FFB3AA" stroke-width="10" stroke-linecap="round" opacity=".8"/>'),
        "h_lips_smile": ([620, 520, 980, 680], '<path d="M640 535 C700 562 900 562 960 535 C976 562 962 602 930 627 C870 672 730 672 670 627 C638 602 624 562 640 535Z" fill="url(#lip_upper_color)"/><path d="M672 566 C740 592 860 592 928 566" fill="none" stroke="#C9545A" stroke-width="10" stroke-linecap="round"/>'),
        "h_blush": ([490, 570, 1110, 640], '<ellipse cx="560" cy="604" rx="58" ry="26" fill="#FF7F9A" opacity=".6"/><ellipse cx="1040" cy="604" rx="58" ry="26" fill="#FF7F9A" opacity=".6"/>'),
    },
    "ajiu": {
        "a_eyes_closed": ([550, 710, 1052, 780], '<path d="M566 732 Q626 770 688 732 M912 732 Q974 770 1035 732" fill="none" stroke="#62321e" stroke-width="12" stroke-linecap="round"/>'),
        "a_eyes_happy": ([550, 680, 1052, 765], '<path d="M566 750 Q626 690 688 750 M912 750 Q974 690 1035 750" fill="none" stroke="#62321e" stroke-width="12" stroke-linecap="round"/>'),
        "a_eyes_wide": ([548, 640, 1052, 815], '<g stroke="#62321e" stroke-width="9"><ellipse cx="628" cy="727" rx="66" ry="74" fill="#fffdf7"/><ellipse cx="972" cy="727" rx="66" ry="74" fill="#fffdf7"/></g><g stroke="none"><circle cx="630" cy="733" r="44" fill="url(#eyeBrown)"/><circle cx="970" cy="733" r="44" fill="url(#eyeBrown)"/><circle cx="646" cy="712" r="15" fill="#fffdf7"/><circle cx="986" cy="712" r="15" fill="#fffdf7"/><circle cx="616" cy="752" r="6" fill="#fffdf7"/><circle cx="956" cy="752" r="6" fill="#fffdf7"/></g>'),
        "a_eyes_up": ([548, 640, 1052, 815], '<g stroke="#62321e" stroke-width="9"><ellipse cx="628" cy="727" rx="62" ry="70" fill="#fffdf7"/><ellipse cx="972" cy="727" rx="62" ry="70" fill="#fffdf7"/></g><g stroke="none"><circle cx="632" cy="700" r="40" fill="url(#eyeBrown)"/><circle cx="968" cy="700" r="40" fill="url(#eyeBrown)"/><circle cx="646" cy="684" r="13" fill="#fffdf7"/><circle cx="982" cy="684" r="13" fill="#fffdf7"/></g>'),
        "a_mouth_open": ([758, 784, 842, 852], '<path d="M768 798 Q800 790 832 798 Q828 842 800 846 Q772 842 768 798Z" fill="#9b3f4a" stroke="#62321e" stroke-width="7" stroke-linejoin="round"/><path d="M783 829 Q800 819 817 829 Q811 842 800 843 Q789 842 783 829Z" fill="#f59aa5" stroke="none"/>'),
        "a_mouth_O": ([775, 786, 825, 845], '<ellipse cx="800" cy="815" rx="17" ry="21" fill="#7a2c30" stroke="#62321e" stroke-width="7"/>'),
        "a_mouth_frown": ([762, 790, 838, 832], '<path d="M772 824 Q800 798 828 824" fill="none" stroke="#62321e" stroke-width="7" stroke-linecap="round"/>'),
        "a_blush_strong": ([455, 745, 1145, 868], '<ellipse cx="542" cy="806" rx="80" ry="54" fill="#ff8f96" opacity=".55" stroke="none"/><ellipse cx="1058" cy="806" rx="80" ry="54" fill="#ff8f96" opacity=".55" stroke="none"/>'),
    },
    "xiaohuolv": {
        "d_eyes_closed": ([560, 670, 1045, 752], '<path d="M578 692 Q673 742 772 692 M830 692 Q930 742 1026 692" fill="none" stroke="#191611" stroke-width="17" stroke-linecap="round"/>'),
        "d_eyes_happy": ([560, 648, 1045, 735], '<path d="M580 722 Q673 652 770 722 M832 722 Q930 652 1024 722" fill="none" stroke="#191611" stroke-width="17" stroke-linecap="round"/>'),
        "d_eyes_wide": ([560, 600, 1045, 780], '<g stroke="#191611" stroke-width="15"><ellipse cx="673" cy="690" rx="96" ry="78" fill="#FFFDF8"/><ellipse cx="930" cy="690" rx="96" ry="78" fill="#FFFDF8"/></g><circle cx="690" cy="694" r="27" fill="#17140F"/><circle cx="913" cy="694" r="27" fill="#17140F"/><circle cx="700" cy="683" r="8" fill="#FFFFFF"/><circle cx="923" cy="683" r="8" fill="#FFFFFF"/>'),
        "d_eyes_up": ([560, 600, 1045, 780], '<g stroke="#191611" stroke-width="15"><ellipse cx="673" cy="690" rx="96" ry="78" fill="#FFFDF8"/><ellipse cx="930" cy="690" rx="96" ry="78" fill="#FFFDF8"/></g><circle cx="684" cy="648" r="27" fill="#17140F"/><circle cx="919" cy="648" r="27" fill="#17140F"/><circle cx="694" cy="638" r="8" fill="#FFFFFF"/><circle cx="929" cy="638" r="8" fill="#FFFFFF"/>'),
        "d_mouth_open": ([690, 890, 935, 1025], '<path d="M703 905 C760 948 860 948 918 902 C912 980 862 1012 808 1012 C752 1012 712 978 703 905Z" fill="#5b2a26" stroke="#191611" stroke-width="13" stroke-linejoin="round"/><path d="M748 978 C772 958 845 958 868 978 C850 999 830 1005 808 1005 C786 1005 766 997 748 978Z" fill="#F08A8A"/>'),
        "d_mouth_O": ([755, 895, 865, 1005], '<ellipse cx="810" cy="950" rx="40" ry="45" fill="#5b2a26" stroke="#191611" stroke-width="13"/>'),
        "d_mouth_frown": ([705, 905, 915, 975], '<path d="M722 960 C770 920 852 920 900 960" fill="none" stroke="#191611" stroke-width="13" stroke-linecap="round"/>'),
        "d_blush": ([560, 840, 1050, 905], '<ellipse cx="625" cy="872" rx="52" ry="26" fill="#F4A0A0" opacity=".65"/><ellipse cx="985" cy="872" rx="52" ry="26" fill="#F4A0A0" opacity=".65"/>'),
    },
}


def run(args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        sys.exit("命令失败：" + " ".join(args) + "\n" + result.stderr)
    return result.stdout


def png_size(path):
    with open(path, "rb") as handle:
        header = handle.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"不是 PNG：{path}")
    return int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big")


def fitted_size(width, height):
    """按 1024 画布的比例缩，最长边超过上限时再整体缩小。返回像素尺寸。"""
    scale = 1024.0 / SOURCE_PIXELS
    w = width * scale
    h = height * scale
    longest = max(w, h)
    if longest > MAX_PART_SIDE:
        w *= MAX_PART_SIDE / longest
        h *= MAX_PART_SIDE / longest
    return max(1, int(round(w))), max(1, int(round(h)))


def export_part(source, crop, out_path):
    x0, y0, x1, y1 = crop
    width, height = x1 - x0, y1 - y0
    out_w, out_h = fitted_size(width, height)
    vf = (f"crop={width}:{height}:{x0}:{y0},format=rgba,premultiply=inplace=1,"
          f"scale={out_w}:{out_h}:flags=lanczos,unpremultiply=inplace=1")
    run(["ffmpeg", "-v", "error", "-y", "-i", source, "-vf", vf, "-frames:v", "1",
         "-compression_level", "9", out_path])
    return out_w, out_h


def master_svg_parts(svg_text):
    """母版的 <defs> 和根节点上的绘图属性（阿酒的描边颜色、线宽写在根节点上）。"""
    defs_match = re.search(r"<defs>.*?</defs>", svg_text, re.S)
    defs = defs_match.group(0) if defs_match else ""
    root_match = re.search(r"<svg\b([^>]*)>", svg_text, re.S)
    attributes = ""
    if root_match:
        for name, value in re.findall(r'([\w:-]+)="([^"]*)"', root_match.group(1)):
            if name in ("width", "height", "viewBox") or name.startswith("xmlns"):
                continue
            attributes += f' {name}="{value}"'
    return defs, attributes


def export_temp_part(bounds, inner, defs, attributes, out_path, workdir):
    x0, y0, x1, y1 = bounds
    width, height = x1 - x0, y1 - y0
    out_w = max(1, int(round(width * PIXELS_PER_UNIT)))
    out_h = max(1, int(round(height * PIXELS_PER_UNIT)))
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{out_w}" height="{out_h}" '
           f'viewBox="{x0} {y0} {width} {height}"{attributes}>{defs}{inner}</svg>')
    svg_path = os.path.join(workdir, "part.svg")
    with open(svg_path, "w", encoding="utf-8") as handle:
        handle.write(svg)
    run(["ffmpeg", "-v", "error", "-y", "-i", svg_path, "-vf", "format=rgba", "-frames:v", "1",
         "-compression_level", "9", out_path])
    return out_w, out_h


def file_stem(part_id):
    return part_id.replace("t:", "t_")


def slot_entries(slot_table, default_bone):
    result = {}
    for state, items in slot_table.items():
        entries = []
        for item in items:
            if isinstance(item, tuple):
                part, bone = item
                entries.append({"part": part, "bone": bone})
            else:
                entries.append({"part": item})
        result[state] = entries
    return result


def bone_order(bones):
    order, seen = [], set()

    def visit(name):
        if name in seen:
            return
        parent = bones[name][0]
        if parent:
            visit(parent)
        seen.add(name)
        order.append(name)

    for name in bones:
        visit(name)
    return order


def build_character(character, source_dir, out_dir, workdir):
    rig = RIGS[character]
    folder = os.path.join(source_dir, character)
    with open(os.path.join(folder, "layers.json"), encoding="utf-8") as handle:
        layers = json.load(handle)["layers_bottom_to_top"]
    with open(os.path.join(folder, f"{character}_front_master.svg"), encoding="utf-8") as handle:
        defs, attributes = master_svg_parts(handle.read())

    unit = SVG_UNITS / SOURCE_PIXELS
    parts = {}
    for layer in layers:
        part_id = layer["id"]
        source = os.path.join(folder, layer["png"])
        full_w, full_h = png_size(source)
        bx0, by0, bx1, by1 = layer["bounds_px"]
        crop = (max(0, bx0 - CROP_MARGIN), max(0, by0 - CROP_MARGIN),
                min(full_w, bx1 + CROP_MARGIN), min(full_h, by1 + CROP_MARGIN))
        name = f"{character}_{file_stem(part_id)}.png"
        pixel_w, pixel_h = export_part(source, crop, os.path.join(out_dir, name))
        parts[part_id] = {
            "file": name,
            "rect": [round(crop[0] * unit, 2), round(crop[1] * unit, 2),
                     round((crop[2] - crop[0]) * unit, 2), round((crop[3] - crop[1]) * unit, 2)],
            "pixels": [pixel_w, pixel_h],
            "layer": layer["order_bottom_to_top"],
        }
    for key, (bounds, inner) in TEMP_PARTS[character].items():
        part_id = "t:" + key
        name = f"{character}_{file_stem(part_id)}.png"
        pixel_w, pixel_h = export_temp_part(bounds, inner, defs, attributes, os.path.join(out_dir, name), workdir)
        x0, y0, x1, y1 = bounds
        parts[part_id] = {
            "file": name,
            "rect": [x0, y0, x1 - x0, y1 - y0],
            "pixels": [pixel_w, pixel_h],
            "layer": 0,
            "temporary": True,
        }

    bones = []
    for name in bone_order(rig["bones"]):
        parent, px, py, options = rig["bones"][name]
        bones.append({
            "name": name,
            "parent": parent,
            "pivot": [px, py],
            "axis": options.get("axis", 0),
            "counter": bool(options.get("counter", False)),
        })
    order = []
    for index, (reference, bone) in enumerate(rig["order"]):
        if reference.startswith("@"):
            order.append({"slot": reference[1:], "bone": bone})
        else:
            if reference not in parts:
                sys.exit(f"{character} 的叠放顺序里有不存在的部件：{reference}")
            order.append({"part": reference, "bone": bone})
    slots = {name: slot_entries(table, None) for name, table in rig["slots"].items()}
    for table in slots.values():
        for entries in table.values():
            for entry in entries:
                if entry["part"] not in parts:
                    sys.exit(f"{character} 的表情插槽里有不存在的部件：{entry['part']}")
    return {
        "bones": bones,
        "parts": parts,
        "order": order,
        "slots": slots,
        "anchors": rig["anchors"],
        "tearFrom": rig["tearFrom"],
    }


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    source_dir = os.path.abspath(sys.argv[1])
    out_dir = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_OUT
    os.makedirs(out_dir, exist_ok=True)
    for name in os.listdir(out_dir):
        if name.endswith(".png") or name == "manifest.json":
            os.remove(os.path.join(out_dir, name))
    manifest = {
        "format": 1,
        "canvas": SVG_UNITS,
        "footY": 1460,
        "pixelsPerUnit": PIXELS_PER_UNIT,
        "characters": {},
    }
    with tempfile.TemporaryDirectory() as workdir:
        for character in CHARACTERS:
            manifest["characters"][character] = build_character(character, source_dir, out_dir, workdir)
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        handle.write("\n")
    total = sum(os.path.getsize(os.path.join(out_dir, name)) for name in os.listdir(out_dir))
    count = len([name for name in os.listdir(out_dir) if name.endswith(".png")])
    print(f"写出 {count} 张部件图和 manifest.json，共 {total / 1024:.0f} KB -> {out_dir}")


if __name__ == "__main__":
    main()
