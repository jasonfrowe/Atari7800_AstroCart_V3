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
 game_count = 8
 selected_game = 0
 joy_delay = 0
 
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
 ; Keep selected_game in bounds
 ;
 if selected_game > 7 then selected_game = 0
 if selected_game > 127 then selected_game = 7
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
 
 asm
   sei

   ; Copy 18-byte handover stub to Zero-Page RAM ($80-$91)
   ldx #0
.copy_handover_stub
   lda .handover_stub_code,x
   sta $80,x
   inx
   cpx #18
   bcc .copy_handover_stub

   ; Disable MARIA DMA so Maria doesn't access Cart RAM while SD card is loading
   lda #0
   sta $3C

   ; Pass selected_game + 128 in accumulator A and jump to Zero-Page RAM
   lda selected_game
   ora #$80
   jmp $80

.handover_stub_code
   sta $2200        ; $80: Trigger load on FPGA / FemtoRV
.wait_loaded
   lda $7FF0        ; $83: Poll FPGA status register
   sta $20          ; $86: Visual feedback: display status on TV background color!
   bpl .wait_loaded ; $88: Loop until bit 7 is set (game loaded)
   lda #$A5         ; $8A: Acknowledge byte
   sta $2200        ; $8C: Switch FPGA to game mode immediately
   jmp ($FFFC)      ; $8F: Jump to new game reset vector
end
 return
