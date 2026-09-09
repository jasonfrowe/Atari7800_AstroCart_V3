 set romsize 32k
 displaymode 320A
 set zoneheight 8
 set screenheight 192
 
 BACKGRND=$00
 
 incgraphic gfx/menufont.png 320A
 
 P0C1=$0F : P0C2=$3F : P0C3=$6F
 P1C1=$0F : P1C2=$1F : P1C3=$4F
 
 characterset menufont
 alphachars ASCII
 
 ;
 ; Variables - using longer names to avoid conflicts
 ;
 dim game_count = a
 dim selected_game = b
 dim joy_delay = c
 dim temp_y = d
 dim flash_count = e
 dim status_temp = f
 
 ;
 ; FPGA trigger address - just accessing this address triggers FPGA detection
 ;
 dim fpga_trigger = $2200
 
 ;
 ; Initialize variables
 ;
 ; game_count is set below, from the real SD-scanned count at $7FF1 --
 ; not hardcoded, so it matches however many titles actually exist.
 selected_game = 0
 joy_delay = 0
 
 ;
 ; Wait for the SD scan to actually finish before drawing anything: this
 ; program starts running as soon as the FPGA boots, racing the firmware's
 ; own SD scan on a completely separate RISC-V core. Without this wait,
 ; draw_game_list below (called exactly once, then frozen forever by
 ; savescreen/restorescreen) could run before the scan has written any --
 ; or all -- of the real titles, showing whatever stale/partial data
 ; happened to be there. $7FF1 (entry_count) starts at 0 and firmware
 ; writes the real scanned count there right after the scan completes
 ; (success or failure), so waiting for it to go nonzero is a reliable
 ; "scan is done" signal for the known current setup (a always-populated
 ; SD card) -- an SD card with zero valid entries would hang here forever,
 ; not a concern for the current fixed 8-cart test card.
 ;
 asm
.wait_scan_ready
   lda $7FF1
   beq .wait_scan_ready
   sta game_count
end

 ;
 ; Draw initial screen once and save it
 ;
 clearscreen
 gosub draw_title
 gosub draw_game_list
 savescreen

main_loop
 ;
 ; Restore background, then draw dynamic elements
 ;
 restorescreen
 gosub draw_cursor
 ; gosub draw_hud
 
 ;
 ; Countdown input delay
 ;
 if joy_delay > 0 then joy_delay = joy_delay - 1
 
 ;
 ; Check for joystick input only when not delayed
 ;
 if joy_delay = 0 then gosub check_input
 
 drawscreen
 goto main_loop
 
 ;
 ; Draw title and instructions
 ;
draw_title
 plotchars 'GAME LOADER' 0 60 0
 plotchars 'SELECT A GAME' 1 56 2
 return
 
 ;
 ; Display titles from the metadata window populated by the A78 scan.
 ;
draw_game_list
 if game_count > 0 then plotchars $E800 0 10 4
 if game_count > 1 then plotchars $E820 0 10 5
 if game_count > 2 then plotchars $E840 0 10 6
 if game_count > 3 then plotchars $E860 0 10 7
 if game_count > 4 then plotchars $E880 0 10 8
 if game_count > 5 then plotchars $E8A0 0 10 9
 if game_count > 6 then plotchars $E8C0 0 10 10
 if game_count > 7 then plotchars $E8E0 0 10 11
 return
 
 ;
 ; Clear all cursor positions first
 ;
draw_cursor
 plotchars ' ' 0 0 4
 plotchars ' ' 0 0 5
 plotchars ' ' 0 0 6
 plotchars ' ' 0 0 7
 plotchars ' ' 0 0 8
 plotchars ' ' 0 0 9
 plotchars ' ' 0 0 10
 plotchars ' ' 0 0 11
 plotchars ' ' 0 0 12
 
 ;
 ; Calculate and draw cursor at current selection
 ;
 temp_y = selected_game * 1 + 4
 plotchars '>' 0 0 temp_y
 return
 
 ;
 ; Simple joystick check - delay prevents rapid repeats
 ;
check_input
 if joy0up then selected_game = selected_game - 1 : joy_delay = 15
 if joy0down then selected_game = selected_game + 1 : joy_delay = 15
 
 ; Trigger Reload (Right + Fire)
 if joy0fire0 && joy0right then fpga_trigger = 64 : joy_delay = 30 : goto select_game_end
 
 if joy0fire0 then gosub select_game : joy_delay = 15
 
select_game_end
 
 ;
 ; Keep selected_game in bounds (game_count is the real SD-scanned count,
 ; not a hardcoded 8, so this stays correct if fewer than 8 titles exist)
 ;
 if selected_game >= game_count then selected_game = 0
 if selected_game > 127 then selected_game = game_count - 1
 return
 
 ;
 ; Flash the screen and keep the original Astrowing handoff behavior intact.
 ;
select_game
 flash_count = 8
flash_loop
 BACKGRND=$22
 drawscreen
 BACKGRND=$00
 drawscreen
 flash_count = flash_count - 1
 if flash_count > 0 then goto flash_loop
 
 ; Trigger FPGA: bit 7 marks the write as a load request; low bits pick the slot.
 fpga_trigger = selected_game + 128

 ; CRITICAL: the menu ROM and the loaded game share the SAME physical BRAM
 ; (chunks 20-23 / Atari $E000-$FFFF -- there isn't room for both at once).
 ; load_game() overwrites the menu's own running code as its copy loop
 ; reaches that range, which is the LAST ~8KB of a 48K linear cart like
 ; astrowing. Confirmed via a real-hardware recording: the screen renders
 ; correctly for most of the transfer, then corrupts and crashes right as
 ; the copy would reach offset $A000+ ($E000+ in Atari address space) --
 ; exactly where the menu program (and this very loop) lives. So NOTHING
 ; from here to the handoff jump can execute out of cart ROM -- no
 ; restorescreen/drawscreen/plotchars, and not even this polling loop's own
 ; code, since it would get overwritten mid-poll too.
 ;
 ; Fix: copy the ENTIRE wait+handoff routine into scratch RAM and run it
 ; from there, and disable MARIA DMA so it stops trying to render from cart
 ; RAM once the transfer starts overwriting it. This restores the structure
 ; from commit 420d2d8 (the last version that got past this wait without
 ; crashing -- its bug was a *separate*, later issue: the copied stub lived
 ; at zero page $80-$91, colliding with 7800basic's own dlendsave kernel
 ; array). Using $2210+ instead avoids that collision.
 asm
   ; $7F (not $00) per 7800basic's own startup.asm/CTRL bit layout comment:
   ; bits 6,5 are a 2-bit DMA-control field where only 2=normal DMA and
   ; 3=no DMA are valid/documented, both requiring bit 6 set. Writing $00
   ; clears bit 6 too, landing MARIA in an undefined state that isn't
   ; either documented value -- some games' own init code tolerates this,
   ; but it's not the correct "DMA off" value.
   lda #$7F
   sta $3C                 ; disable MARIA DMA

   ldx #0
.copy_handover_stub
   lda .handover_stub_code,x
   sta $2210,x
   inx
   cpx #(.handover_stub_end - .handover_stub_code)
   bcc .copy_handover_stub

   jmp $2210

.handover_stub_code
.wait_loaded
   lda $7FF0                ; poll FPGA status register
   sta $20                  ; crude visual feedback: raw status as background color
   cmp #$80
   bne .wait_loaded
   lda #$A5                 ; acknowledge byte
   sta $2200                ; switch FPGA to game mode
   jmp ($FFFC)               ; jump into the freshly loaded game
.handover_stub_end
end
