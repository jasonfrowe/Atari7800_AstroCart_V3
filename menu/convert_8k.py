#!/usr/bin/env python3
import sys, os

script_dir = os.path.dirname(os.path.abspath(__file__))
src_path = os.path.join(script_dir, "menu.bas.asm")
dst_path = os.path.join(script_dir, "menu_8k.asm")

if not os.path.exists(src_path):
    print(f"Error: {src_path} does not exist.")
    sys.exit(1)

with open(src_path, "r") as f:
    content = f.read()

# 1. Replace ROM32K symbol declaration with ROM8K
content = content.replace("ROM32K     = 1", "ROM8K      = 1")
content = content.replace("ROM32K = 1", "ROM8K = 1")
content = content.replace("ifconst ROM32K", "ifconst DIS_ROM32K")

# 2. Replace plotchars addresses from $6000-$60E0 to $E800-$E8E0
addr_map = {
    "$6000": "$E800",
    "$6020": "$E820",
    "$6040": "$E840",
    "$6060": "$E860",
    "$6080": "$E880",
    "$60A0": "$E8A0",
    "$60C0": "$E8C0",
    "$60E0": "$E8E0"
}

for old_addr, new_addr in addr_map.items():
    content = content.replace(f"#<{old_addr}", f"#<{new_addr}")
    content = content.replace(f"#>{old_addr}", f"#>{new_addr}")
    content = content.replace(f"plotchars {old_addr}", f"plotchars {new_addr}")

# 3. Extract menufont graphics block (starts at ORG $E000,0)
gfx_start_marker = " ORG $E000,0  ; *************"
gfx_end_marker = " if SPACEOVERFLOW > 0"

start_idx = content.find(gfx_start_marker)
end_idx = content.find(gfx_end_marker, start_idx)

if start_idx != -1 and end_idx != -1:
    gfx_block = content[start_idx:end_idx]
    content_without_gfx = content[:start_idx] + content[end_idx:]
else:
    print("Could not find GFX block boundaries!")
    sys.exit(1)

# 4. Define reserved 256-byte game list buffer at $E800 in ROM, and set game code start to ORG $E900,0
gamelist_rom_block = """
; --- RESERVED GAME LIST ROM BUFFER AT $E800-$E8FF (256 BYTES) ---
 ORG $E800,0
gamelist_buffer
 .repeat 256
    .byte $00
 .repend

"""

old_org_block = """     ifconst ROM8K
         ORG $E000,0
BANK_WAS_SET SET 1
     endif ; ROM8K"""

new_org_block = """     ifconst ROM8K
         ORG $E900,0
BANK_WAS_SET SET 1
     endif ; ROM8K"""

content_without_gfx = content_without_gfx.replace(old_org_block, new_org_block)
content_without_gfx = content_without_gfx.replace("($E000 - gameend)", "($F000 - gameend)")

# 5. Insert GFX block at $E000, then gamelist_rom_block at $E800, before game code at $E900
header_marker = " ;start address of cart..."
header_idx = content_without_gfx.find(header_marker)

final_content = (
    "ROM8K = 1\nROM8K SET 1\n"
    + content_without_gfx[:header_idx]
    + "\n; --- GFX BLOCK AT $E000-$E7FF ---\n"
    + gfx_block
    + gamelist_rom_block
    + content_without_gfx[header_idx:]
)

with open(dst_path, "w") as f:
    f.write(final_content)

print(f"Wrote updated 8K assembly (with $E800-$E8FF ROM buffer) to {dst_path}")
