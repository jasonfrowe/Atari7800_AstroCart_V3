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
 game_count = 5  
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

draw_title
 ;
 ; Draw title and instructions
 ;
 plotchars 'GAME LOADER' 0 60 0
 plotchars 'SELECT A GAME' 1 56 2
 return

draw_game_list
 ;
 ; Display available games
 ;
 ; plotchars 'ASTRO WING'       0 10 4
 ; plotchars 'DONKEY KONG'       0 10 6
 ; plotchars 'GALAGA'           0 10 8
 ; plotchars 'MS PAC-MAN'       0 10 10
 ; plotchars 'DEFENDER'         0 10 12
 plotchars $E800 0 10 4
 plotchars $E820 0 10 5
 plotchars $E840 0 10 6
 plotchars $E860 0 10 7
 plotchars $E880 0 10 8
 plotchars $E8A0 0 10 9
 plotchars $E8C0 0 10 10
 plotchars $E8E0 0 10 11

 return

draw_cursor
 ;
 ; Clear all cursor positions first
 ;
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

check_input
 ;
 ; Simple joystick check - delay prevents rapid repeats
 ;
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

select_game
 ;
 ; Visual feedback: flash background briefly
 ;
 flash_count = 8
flash_loop
 BACKGRND=$22
 drawscreen
 BACKGRND=$00
 drawscreen
 flash_count = flash_count - 1
 if flash_count > 0 then goto flash_loop
 
 ;
 ; Trigger FPGA: for now every slot still hands off to the fixed Astrowing image.
 ; Bit 7 marks the write as a load request.
 ;
 fpga_trigger = selected_game + 128

 ; Wait for load to finish (poll $7FF0)
wait_loop
 restorescreen
 drawscreen
 asm
   lda $7FF0
   bpl .keep_waiting

   ; Copy 6-byte handover stub to Zero-Page RAM ($80-$85)
   ldx #0
.copy_handover_stub
   lda .handover_stub_code,x
   sta $80,x
   inx
   cpx #6
   bcc .copy_handover_stub

   lda #$A5
   jmp $80

.handover_stub_code
   sta $2200
   jmp ($FFFC)

.keep_waiting
end
 goto wait_loop
