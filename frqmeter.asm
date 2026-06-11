;**************************************************************************
; FILE:      frqmeter.asm                                                 *
; CONTENTS:  Digital frequency meter                                      *
; COPYRIGHT: MadLab Ltd. 1996-2005                                        *
; AUTHOR:    James Hutchby                                                *
; UPDATED:   10/07/05                                                     *
;**************************************************************************

     list p=16F628A

     include "p16f628a.inc"

     __config _HS_OSC & _WDT_ON & _PWRTE_ON & _BOREN_ON & _MCLRE_OFF & _LVP_OFF & _CP_ON

     __idlocs h'BA20'

     errorlevel -207,-302,-305,-306


;**************************************************************************
;                                                                         *
; Summary                                                                 *
;                                                                         *
;**************************************************************************

; The following software functions as a frequency meter with an input signal
; range of 1Hz to ~ 8MHz and with an accuracy of +/- 1Hz. Supplementary pulse
; length and pulse count modes are also supported.

; In frequency mode, signal pulses are counted over a fixed time interval of
; 1/8 second or 1 second. High frequency pulses are counted over 1/8 s to make
; the meter more responsive with no loss of displayed accuracy.

; In pulse length mode, pulses are measured to a resolution of 1 microsecond.
; If this mode is selected and no pulses are present then it will lock out.

; All pulses are counted on the rising edge.

; The mode is selected by holding down the pushbutton for about a second.
; The modes are displayed ("FrE", "PulS", "Cntr") and cycled through.

; Pressing and immediately releasing the pushbutton clears the display and
; also resets the count in pulse count mode.

; The display shows the signal frequency in kHz or pulse length in ms,
; according to the following table:

; ----------------------------------
; | Frequency | Pulse    | Display |
; ----------------------------------
; | < 1Hz     | < 1us    |       0 |
; | 1Hz       | 1us      |   0.001 |
; | 10Hz      | 10us     |   0.010 |
; | 100Hz     | 100us    |   0.100 |
; | 1.000kHz  | 1.000ms  |   1.000 |
; | 10.00kHz  | 10.00ms  |   10.00 |
; | 100.0kHz  | 100.0ms  |   100.0 |
; | 1.000MHz  | 1.000s   |   1000. |
; | > ~ 8MHz  | > ~ 8s   |       E |
; ----------------------------------

; Underflows (frequencies less than 1Hz or pulse lengths less than 1us) or no
; signal at all are displayed as a single zero, and overflows (frequencies
; greater than ~ 8MHz or pulse lengths greater than ~ 8s) are displayed as
; the letter 'E' (for error).

; In pulse count mode, if the count exceeds 9999 then it wraps and keeps
; counting but all the decimal points are set.


;**************************************************************************
;                                                                         *
; Port assignments                                                        *
;                                                                         *
;**************************************************************************

PORTA_IO       equ  b'11110000'    ; port A I/O status
PORTB_IO       equ  b'00000000'    ; port B I/O status
PORTB_IN       equ  b'00000001'

LEDS_PORT      equ  PORTB          ; 7-segment LEDs port
ENABLE_PORT    equ  PORTA          ; display enable port (low 4 bits)

DISPLAY0       equ  1              ; display #0 bit (0 = on)
DISPLAY1       equ  0              ; display #1 bit (0 = on)
DISPLAY2       equ  3              ; display #2 bit (0 = on)
DISPLAY3       equ  2              ; display #3 bit (0 = on)

BUTTON         equ  0              ; pushbutton

#define   RTCC      PORTA,4


;**************************************************************************
;                                                                         *
; Constants and timings                                                   *
;                                                                         *
;**************************************************************************

; processor clock frequency in Hz
CLOCK     equ  d'20000000'

; microseconds per timing loop
TIME      equ  d'20'

; clock cycles per timing loop
CYCLES    equ  TIME*CLOCK/d'1000000'

; pushbutton poll frequency in Hz
POLL      equ  d'50'


;**************************************************************************
;                                                                         *
; File register usage                                                     *
;                                                                         *
;**************************************************************************

     cblock h'20'

     mode                     ; mode (0 = frequency, 1 = pulse, 2 = count)
     wrapped                  ; non-zero if pulse count wrapped

     tens_index               ; index into the powers-of-ten table
     divi:3                   ; power of ten (24 bits)

     TMR0_                    ; previous RTCC

     counter:2                ; 16-bit counter (msb first)
     delay                    ; delay loop counter
     repeat                   ; repeat counter

     reading:3                ; reading in binary (24 bits)
     digits:7                 ; reading as decimal digits (7 bytes)
     pulses:2                 ; pulse count

     disp_timer               ; display multiplexing timer (5 bits)
     disp_mask                ; display multiplexing mask

     char                     ; display character
     work                     ; temporary register

     endc

     cblock h'40'             ; 8-byte boundary (2 address bits + 1 guard bit)

     displays:4               ; display data

     endc


;**************************************************************************
;                                                                         *
; Macros                                                                  *
;                                                                         *
;**************************************************************************

routine   macro label              ; routine
label
          endm

table     macro label              ; define lookup table
label     addwf PCL
          endm

entry     macro value              ; define table entry
          retlw value
          endm

index     macro label              ; index lookup table
          call label
          endm

jump      macro label              ; jump through table
          goto label
          endm

tstw      macro                    ; test w register
          iorlw 0
          endm

movff     macro f1,f2              ; move file to file
          movfw f1
          movwf f2
          endm

movlf     macro n,f                ; move literal to file
          movlw n
          movwf f
          endm

tris_A    macro                    ; tristate port A
          bsf STATUS,RP0
          movwf TRISA&h'7f'
          bcf STATUS,RP0
          endm

tris_B    macro                    ; tristate port B
          bsf STATUS,RP0
          movwf TRISB&h'7f'
          bcf STATUS,RP0
          endm

option_   macro                    ; set options
          bsf STATUS,RP0
          movwf OPTION_REG&h'7f'
          bcf STATUS,RP0
          endm


;--------------------------------------------------------------------------
; add with carry - adds the w register and the carry flag to the file
; register f, returns the result in f with the carry flag set if overflow
;--------------------------------------------------------------------------

addcwf    macro f

          local add1,add2

          bnc add1                      ; branch if no carry set

          addwf f                       ; add byte

          incf f                        ; add carry
          skpnz
          setc

          goto add2

add1      addwf f                       ; add byte

add2
          endm


;--------------------------------------------------------------------------
; subtract with no carry - subtracts the w register and the no carry flag
; from the file register f, returns the result in f with the no carry flag
; set if underflow
;--------------------------------------------------------------------------

subncwf   macro f

          local sub1,sub2

          bc sub1                       ; branch if carry set

          subwf f                       ; subtract byte

          skpnz                         ; subtract no carry
          clrc
          decf f

          goto sub2

sub1      subwf f                       ; subtract byte

sub2
          endm


;--------------------------------------------------------------------------
; 24-bit addition - adds the three bytes at op2 to the three bytes at
; op1 (most significant bytes first), returns the result in op1 with
; op2 unchanged and the carry flag set if overflow
;--------------------------------------------------------------------------

add24     macro op1,op2                 ; op1 <= op1 + op2

          movfw op2+2                   ; add low byte
          addwf op1+2

          movfw op2+1                   ; add middle byte
          addcwf op1+1

          movfw op2+0                   ; add high byte
          addcwf op1+0

          endm


;--------------------------------------------------------------------------
; 24-bit subtraction - subtracts the three bytes at op2 from the three
; bytes at op1 (most significant bytes first), returns the result in op1
; with op2 unchanged and the no carry flag set if underflow
;--------------------------------------------------------------------------

sub24     macro op1,op2                 ; op1 <= op1 - op2

          movfw op2+2                   ; subtract low byte
          subwf op1+2

          movfw op2+1                   ; subtract middle byte
          subncwf op1+1

          movfw op2+0                   ; subtract high byte
          subncwf op1+0

          endm


;--------------------------------------------------------------------------
; reset vector
;--------------------------------------------------------------------------

          org 0

          goto main_entry


;**************************************************************************
;                                                                         *
; Lookup tables                                                           *
;                                                                         *
;**************************************************************************

;--------------------------------------------------------------------------
; 7-segment LED data tables
;--------------------------------------------------------------------------

BLANK     equ  d'10'               ; blank display
ERR       equ  d'11'               ; indicates overflow
TEST      equ  d'12'               ; power-on display test

DP0       equ  7                   ; display #0 decimal point bit
DP1       equ  1                   ; display #1 decimal point bit
DP2       equ  7                   ; display #2 decimal point bit
DP3       equ  1                   ; display #3 decimal point bit


          table LEDS0

; A = 3, B = 0, C = 6, D = 5, E = 4, F = 1, G = 2, DP = 7

          entry b'01111011'        ; ABCDEF. = '0'
          entry b'01000001'        ; .BC.... = '1'
          entry b'00111101'        ; AB.DE.G = '2'
          entry b'01101101'        ; ABCD..G = '3'
          entry b'01000111'        ; .BC..FG = '4'
          entry b'01101110'        ; A.CD.FG = '5'
          entry b'01110110'        ; ..CDEFG = '6'
          entry b'01001001'        ; ABC.... = '7'
          entry b'01111111'        ; ABCDEFG = '8'
          entry b'01001111'        ; ABC..FG = '9'

          entry b'00000000'        ; ....... = ' '
          entry b'00111110'        ; A..DEFG = 'E'
          entry b'11111111'        ; all segments on


          table LEDS1

; A = 3, B = 2, C = 4, D = 6, E = 7, F = 0, G = 5, DP = 1

          entry b'11011101'        ; ABCDEF. = '0'
          entry b'00010100'        ; .BC.... = '1'
          entry b'11101100'        ; AB.DE.G = '2'
          entry b'01111100'        ; ABCD..G = '3'
          entry b'00110101'        ; .BC..FG = '4'
          entry b'01111001'        ; A.CD.FG = '5'
          entry b'11110001'        ; ..CDEFG = '6'
          entry b'00011100'        ; ABC.... = '7'
          entry b'11111101'        ; ABCDEFG = '8'
          entry b'00111101'        ; ABC..FG = '9'

          entry b'00000000'        ; ....... = ' '
          entry b'11101001'        ; A..DEFG = 'E'
          entry b'11111111'        ; all segments on


          table LEDS2

; A = 3, B = 0, C = 6, D = 5, E = 4, F = 1, G = 2, DP = 7

          entry b'01111011'        ; ABCDEF. = '0'
          entry b'01000001'        ; .BC.... = '1'
          entry b'00111101'        ; AB.DE.G = '2'
          entry b'01101101'        ; ABCD..G = '3'
          entry b'01000111'        ; .BC..FG = '4'
          entry b'01101110'        ; A.CD.FG = '5'
          entry b'01110110'        ; ..CDEFG = '6'
          entry b'01001001'        ; ABC.... = '7'
          entry b'01111111'        ; ABCDEFG = '8'
          entry b'01001111'        ; ABC..FG = '9'

          entry b'00000000'        ; ....... = ' '
          entry b'00111110'        ; A..DEFG = 'E'
          entry b'11111111'        ; all segments on


          table LEDS3

; A = 3, B = 2, C = 4, D = 6, E = 7, F = 0, G = 5, DP = 1

          entry b'11011101'        ; ABCDEF. = '0'
          entry b'00010100'        ; .BC.... = '1'
          entry b'11101100'        ; AB.DE.G = '2'
          entry b'01111100'        ; ABCD..G = '3'
          entry b'00110101'        ; .BC..FG = '4'
          entry b'01111001'        ; A.CD.FG = '5'
          entry b'11110001'        ; ..CDEFG = '6'
          entry b'00011100'        ; ABC.... = '7'
          entry b'11111101'        ; ABCDEFG = '8'
          entry b'00111101'        ; ABC..FG = '9'

          entry b'00000000'        ; ....... = ' '
          entry b'11101001'        ; A..DEFG = 'E'
          entry b'11111111'        ; all segments on


;--------------------------------------------------------------------------
; mode indicators
;--------------------------------------------------------------------------

          table modes

; frequency
          entry b'00011110'        ; A...EFG = 'F'
          entry b'10100000'        ; ....E.G = 'r'
          entry b'00111110'        ; A..DEFG = 'E'
          entry b'00000000'        ; ....... = ' '

; pulse
          entry b'00011111'        ; AB..EFG = 'P'
          entry b'11010000'        ; ..CDE.. = 'u'
          entry b'00010010'        ; ....EF. = 'l'
          entry b'01111001'        ; A.CD.FG = 'S'

; count
          entry b'00111010'        ; A..DEF. = 'C'
          entry b'10110000'        ; ..C.E.G = 'n'
          entry b'00110110'        ; ...DEFG = 't'
          entry b'10100000'        ; ....E.G = 'r'


;--------------------------------------------------------------------------
; powers-of-ten table
;--------------------------------------------------------------------------

          table tens_table

power     macro value

          entry value>>d'16'            ; high byte
          entry (value>>8)&h'ff'        ; middle byte
          entry value&h'ff'             ; low byte

          endm

          power d'1000000'
          power d'100000'
          power d'10000'
          power d'1000'
          power d'100'
          power d'10'
          power d'1'


;**************************************************************************
;                                                                         *
; Procedures                                                              *
;                                                                         *
;**************************************************************************

;--------------------------------------------------------------------------
; polls the pushbutton, returns the carry flag set if pressed
;--------------------------------------------------------------------------

          routine poll_button

          clrf LEDS_PORT                ; displays off [4]
          movlf b'1111',ENABLE_PORT     ; [8]

          movlw PORTB_IN                ; [4]
          tris_B                        ; [12]

          clrc                          ; [4]
          btfss LEDS_PORT,BUTTON        ; [8/4]
          setc                          ; [0/4]

          movlw PORTB_IO                ; [4]
          tris_B                        ; [12]

          return                        ; [8]

POLL_BUTTON    equ  d'64'               ; total clock cycles


;--------------------------------------------------------------------------
; converts a character into LEDs data for the 7-segment displays and
; shows the character, fed with the character in w
;--------------------------------------------------------------------------

conv_     macro LEDS,DP
          movwf char                    ; save decimal point bit (msb)
          andlw h'7f'                   ; mask bit
          index LEDS                    ; index LEDs table
          btfsc char,7
          iorlw 1<<DP                   ; include decimal point
          endm

          routine conv_char0            ; display #0
          conv_ LEDS0,DP0
          routine show_char0
          movwf displays+DISPLAY0
          return

          routine conv_char1            ; display #1
          conv_ LEDS1,DP1
          routine show_char1
          movwf displays+DISPLAY1
          return

          routine conv_char2            ; display #2
          conv_ LEDS2,DP2
          routine show_char2
          movwf displays+DISPLAY2
          return

          routine conv_char3            ; display #3
          conv_ LEDS3,DP3
          routine show_char3
          movwf displays+DISPLAY3
          return


;--------------------------------------------------------------------------
; multiplexes the displays
;--------------------------------------------------------------------------

          routine mux_displays

          movff 0,LEDS_PORT             ; set the LEDs [8]
          movff disp_mask,ENABLE_PORT   ; enable the display [8]

          incf disp_timer               ; increment display timer [4]
          rlf disp_mask,w               ; [4]
          btfsc disp_timer,5            ; rotate display mask if [8/4]
          rlf disp_mask                 ; rolled over [0/4]
          btfsc disp_timer,5            ; advance display pointer [8/4]
          incf FSR                      ; if rolled over [0/4]
          bcf FSR,2                     ; clear guard bit [4]
          bcf disp_timer,5              ; [4]

          return                        ; [8]

MUX_DISPLAYS   equ  d'56'               ; total clock cycles


;--------------------------------------------------------------------------
; waits, fed with the number of loop iterations in 'counter'
;--------------------------------------------------------------------------

          routine wait

          movlf displays,FSR            ; initialise display pointer,
          movlf b'11101110',disp_mask   ; mask and timer
          clrf disp_timer

WAIT      set  CYCLES-d'16'-MUX_DISPLAYS-d'36'

wait1     call mux_displays             ; multiplex the displays [8 + MUX_DISPLAYS]

          movlf (WAIT/d'12'),delay      ; delay loop [8]
wait2     decfsz delay                  ; [8/4]
          goto wait2                    ; [0/8]
          clrwdt                        ; [4/0]

          variable i = WAIT % d'12'
          while i > 0
          nop                           ; [4]
          i -= d'4'
          endw

          tstf counter+1                ; decrement loop counter [4]
          skpnz                         ; [8/4]
          decf counter+0                ; [0/4]
          decf counter+1                ; [4]

          movfw counter+0               ; counter = 0 ? [4]
          iorwf counter+1,w             ; [4]
          bnz wait1                     ; loop if not [12]

          return


;--------------------------------------------------------------------------
; counts pulses, fed with the number of loop iterations in 'counter',
; returns the number of pulses in 'reading'
;--------------------------------------------------------------------------

          routine count_pulses

          movlf displays,FSR            ; initialise display pointer,
          movlf b'11101110',disp_mask   ; mask and timer
          clrf disp_timer

          clrf reading+0                ; clear pulse counter
          clrf reading+1
          clrf reading+2

          clrf TMR0_                    ; initialise RTCC
          clrf TMR0

          nop                           ; 2 instruction cycle delay
          nop                           ; after writing to RTCC

; -- start of timing loop --

WAIT      set  CYCLES-d'32'-POLL_BUTTON-MUX_DISPLAYS-d'92'

count1    call poll_button              ; poll pushbutton [8 + POLL_BUTTON]
          bc do_mode                    ; branch if pressed [8]

          call mux_displays             ; multiplex the displays [8 + MUX_DISPLAYS]

          movlf (WAIT/d'12'),delay      ; delay loop [8]
count2    decfsz delay                  ; [8/4]
          goto count2                   ; [0/8]
          clrwdt                        ; [4/0]

          variable i = WAIT % d'12'
          while i > 0
          nop                           ; [4]
          i -= d'4'
          endw

          movff TMR0,reading+2          ; least significant byte of pulse counter [8]

          movlw 1                       ; determine if RTCC has rolled [4]
          btfss TMR0_,7                 ; over (rolled over if msb was [8/4]
          clrw                          ; previously set and now isn't) [0/4]
          btfsc reading+2,7             ; [8/4]
          clrw                          ; [0/4]

          addwf reading+1               ; increment high bytes of pulse [4]
          skpnc                         ; counter if low byte rolled [8/4]
          incf reading+0                ; over [0/4]

          btfsc reading+0,7             ; overflow (frequency > 7fffffh) ? [8]
          goto count3                   ; branch if yes

          movff reading+2,TMR0_         ; save previous RTCC [8]

          tstf counter+1                ; decrement loop counter [4]
          skpnz                         ; [8/4]
          decf counter+0                ; [0/4]
          decf counter+1                ; [4]

          movfw counter+0               ; counter = 0 ? [4]
          iorwf counter+1,w             ; [4]
          bnz count1                    ; loop if not [12]

; -- end of timing loop --

          movff TMR0,reading+2          ; get final RTCC

          movlw 1                       ; determine if RTCC has rolled
          btfss TMR0_,7                 ; over (rolled over if msb was
          clrw                          ; previously set and now isn't)
          btfsc reading+2,7
          clrw

          addwf reading+1               ; increment high bytes of pulse
          skpnc                         ; counter if low byte rolled
          incf reading+0                ; over

count3    return


;--------------------------------------------------------------------------
; times a pulse, returns the pulse length in us in 'reading'
;--------------------------------------------------------------------------

          routine time_pulse

          movlf displays,FSR            ; initialise display pointer
          movlf b'11101110',disp_mask   ; and mask

          movlw -1                      ; initialise pulse timer
          movwf reading+0
          movwf reading+1
          clrf reading+2

time1     btfss RTCC                    ; wait for previous pulse end
          goto time3
          movff 0,LEDS_PORT             ; set the LEDs

          btfss RTCC                    ; wait for previous pulse end
          goto time3
          movff disp_mask,ENABLE_PORT   ; enable the display

          btfss RTCC                    ; wait for previous pulse end
          goto time3
          incf FSR                      ; advance display pointer
          bcf FSR,2
          rlf disp_mask,w               ; rotate display mask
          rlf disp_mask

          clrf counter
time2     btfss RTCC                    ; wait for previous pulse end
          goto time3
          decfsz counter
          goto time2
          clrwdt

          goto time1

time3     btfsc RTCC                    ; wait for pulse start
          goto time5
          movff 0,LEDS_PORT             ; set the LEDs

          btfsc RTCC                    ; wait for pulse start
          goto time5
          movff disp_mask,ENABLE_PORT   ; enable the display

          btfsc RTCC                    ; wait for pulse start
          goto time5
          incf FSR                      ; advance display pointer
          bcf FSR,2
          rlf disp_mask,w               ; rotate display mask
          rlf disp_mask

          clrf counter
time4     btfsc RTCC                    ; wait for pulse start
          goto time5
          decfsz counter
          goto time4
          clrwdt

          goto time3

; 20 clock cycles (= 1us) between successive polls of RTCC

time5     btfss RTCC                    ; wait for pulse end [8]
          goto time8
          incf reading+1                ; increment timer high bytes [4]
          skpnz                         ; [8/4]
          incf reading+0                ; [0/4]

          btfss RTCC                    ; wait for pulse end [8]
          goto time7
          btfsc reading+0,7             ; timeout (pulse > 7fffffh) ? [8]
          goto time9                    ; branch if yes
          incf reading+2                ; increment timer low byte [4]

          btfss RTCC                    ; wait for pulse end [8]
          goto time7
          movff 0,LEDS_PORT             ; set the LEDs [8]
          incf reading+2                ; increment timer low byte [4]

          btfss RTCC                    ; wait for pulse end [8]
          goto time7
          movff disp_mask,ENABLE_PORT   ; enable the display [8]
          incf reading+2                ; increment timer low byte [4]

          btfss RTCC                    ; wait for pulse end [8]
          goto time7
          incf FSR                      ; advance display pointer [4]
          bcf FSR,2                     ; [4]
          incf reading+2                ; increment timer low byte [4]

          btfss RTCC                    ; wait for pulse end [8]
          goto time7
          rlf disp_mask,w               ; rotate display mask [4]
          rlf disp_mask                 ; [4]
          incf reading+2                ; increment timer low byte [4]

          btfss RTCC                    ; wait for pulse end [8]
          goto time7
          incf reading+2                ; delayed increment [4]
          incf reading+2                ; increment timer low byte [4]
          clrwdt                        ; [4]

time6     btfss RTCC                    ; wait for pulse end [8]
          goto time9
          incfsz reading+2              ; increment timer low byte [8/4]
          goto time6                    ; [0/8]

          goto time5

time7     incf reading+2                ; delayed increment

          goto time9

time8     incf reading+1                ; increment timer high bytes
          skpnz
          incf reading+0

time9     clrf LEDS_PORT                ; blank displays

          return


;--------------------------------------------------------------------------
; converts the reading from 24-bit binary to decimal digits
;--------------------------------------------------------------------------

          routine convert_reading

          clrf tens_index               ; initialise the table index

          movlf digits,FSR              ; initialise the indirection register

conv1     movfw tens_index              ; fetch the next power of ten
          index tens_table              ; (24 bits) from the lookup table
          movwf divi+0                  ; and store in divi
          incf tens_index

          movfw tens_index
          index tens_table
          movwf divi+1
          incf tens_index

          movfw tens_index
          index tens_table
          movwf divi+2
          incf tens_index

          clrf 0                        ; clear the decimal digit

conv2     call pulse_counter            ; count pulses if count mode

          sub24 reading,divi            ; repeatedly subtract divi from
          bnc conv3                     ; reading (24-bit subtraction) until
          incf 0                        ; underflow while incrementing
          goto conv2                    ; the decimal digit

conv3     add24 reading,divi            ; ready for next digit

          incf FSR                      ; step to next decimal digit

          movlw 7*3                     ; 7 x 3-byte entries in the table
          subwf tens_index,w
          bnz conv1                     ; loop until end of table

          return


;--------------------------------------------------------------------------
; displays the reading in decimal
;--------------------------------------------------------------------------

          routine display_reading

          bsf digits+3,7                ; set the decimal point indicating
                                        ; the frequency in kHz or pulse in ms

; display the decimal digits according to the following rules:

; 000000A => "0.00A"
; 00000AB => "0.0AB"
; 0000ABC => "0.ABC"
; 000ABCD => "A.BCD"
; 00ABCDE => "AB.CD"
; 0ABCDEF => "ABC.D"
; ABCDEFG => "ABCD."

          movlf digits,FSR              ; find the first significant
          tstf 0                        ; digit by stepping over leading
          bnz disp1                     ; zeroes
          incf FSR
          tstf 0
          bnz disp1
          incf FSR
          tstf 0
          skpnz
          incf FSR

disp1     movfw 0                       ; convert the four digits to
          call conv_char0               ; LED display data
          incf FSR
          movfw 0
          call conv_char1
          incf FSR
          movfw 0
          call conv_char2
          incf FSR
          movfw 0
          call conv_char3

          return


;--------------------------------------------------------------------------
; select mode
;--------------------------------------------------------------------------

          routine do_mode

          call show_mode                ; show the current mode

          movlf POLL,repeat

ITERS     set  d'1000000'/(POLL*TIME)

dom1      movlf high ITERS,counter+0    ; poll delay
          movlf low ITERS,counter+1
          call wait

          call poll_button              ; button released ?
          bnc dom2                      ; branch if yes

          decfsz repeat                 ; button held down for 1s ?
          goto dom1                     ; loop if not

          incf mode                     ; next mode
          movlw 3
          subwf mode,w
          skpnz
          clrf mode

          goto do_mode

ITERS     set  d'1000000'/(d'5'*TIME)

dom2      movlf high ITERS,counter+0    ; short delay
          movlf low ITERS,counter+1
          call wait

          movlw BLANK                   ; blank the display
          call conv_char0
          movlw BLANK
          call conv_char1
          movlw BLANK
          call conv_char2
          movlw BLANK
          call conv_char3

          goto main_loop


          routine show_mode

          movfw mode                    ; current mode
          addwf mode,w
          movwf work
          addwf work                    ; * 4

          movfw work                    ; show the mode
          index modes
          call show_char0
          incf work
          movfw work
          index modes
          call show_char1
          incf work
          movfw work
          index modes
          call show_char2
          incf work,w
          index modes
          call show_char3

          return


;--------------------------------------------------------------------------
; main entry point
;--------------------------------------------------------------------------

          routine main_entry

          clrf PORTA                    ; initialise ports
          movlw PORTA_IO
          tris_A
          clrf PORTB
          movlw PORTB_IO
          tris_B

          bcf INTCON,GIE                ; disable interrupts

          movlf h'07',CMCON             ; disable comparators

          clrf mode                     ; frequency mode

          movlw TEST                    ; test all LED segments
          call conv_char0
          movlw TEST
          call conv_char1
          movlw TEST
          call conv_char2
          movlw TEST
          call conv_char3

          movlw b'00000111'             ; display the test pattern
          option_
          clrf counter+0
          clrf counter+1
          call wait

          movlw BLANK                   ; blank the display
          call conv_char0
          movlw BLANK
          call conv_char1
          movlw BLANK
          call conv_char2
          movlw BLANK
          call conv_char3


;--------------------------------------------------------------------------
; main loop
;--------------------------------------------------------------------------

          routine main_loop

          movlw PORTA_IO                ; re-initialise ports
          tris_A
          movlw PORTB_IO
          tris_B

          bcf INTCON,GIE                ; disable interrupts

          movlf h'07',CMCON             ; disable comparators

          tstf mode                     ; frequency mode ?
          bz mode0                      ; branch if yes
          decf mode,w                   ; pulse mode ?
          bz mode1                      ; branch if yes
          goto mode2                    ; count mode


;--------------------------------------------------------------------------
; frequency mode
;--------------------------------------------------------------------------

          routine mode0

ITERS     set  CLOCK/CYCLES             ; number of loop iterations

          clrwdt                        ; source - transition on RTCC pin
          movlw b'00100000'             ; edge - low-to-high transition
          option_                       ; prescaler - assigned to RTCC, 1:2

          movlf high (ITERS/8),counter+0
          movlf low (ITERS/8),counter+1

          call count_pulses             ; count pulses for 1/8 s

          movlf 4,repeat                ; multiply reading by 16 to adjust
loop1     clrc                          ; for the prescaling (1:2) and
          rlf reading+2                 ; the timing period (1/8 s)
          rlf reading+1
          rlf reading+0
          decfsz repeat
          goto loop1

          tstf reading+0                ; no loss of displayed accuracy
          bnz loop2                     ; (4 significant digits) if the
          movlw high d'10000'           ; error is 1 part in 10000
          subwf reading+1,w
          bc loop2                      ; branch if frequency > 10kHz

          clrwdt                        ; recommended when changing prescaler
          clrf TMR0                     ; assignment from RTCC to WDT

          movlw b'00101111'             ; source - transition on RTCC pin
          option_                       ; edge - low-to-high transition
          clrwdt                        ; prescaler - not assigned to RTCC

          movlf high ITERS,counter+0
          movlf low ITERS,counter+1

          call count_pulses             ; count pulses for 1 s

loop2     movfw reading+0               ; underflow (reading = 0) ?
          iorwf reading+1,w
          iorwf reading+2,w
          bz underflow                  ; branch if yes

          btfsc reading+0,7             ; overflow (reading > 7fffffh) ?
          goto overflow                 ; branch if yes

          call convert_reading          ; convert reading

          call display_reading          ; display reading

          goto mode0                    ; loop


;--------------------------------------------------------------------------
; pulse length mode
;--------------------------------------------------------------------------

          routine mode1

          call poll_button              ; poll pushbutton
          bc do_mode                    ; branch if pressed

          clrwdt                        ; recommended when changing prescaler
          clrf TMR0                     ; assignment from RTCC to WDT

          movlw b'00001111'             ; assign prescaler to WDT
          option_
          clrwdt

          call time_pulse               ; time pulse

          movfw reading+0               ; underflow (reading = 0) ?
          iorwf reading+1,w
          iorwf reading+2,w
          bz underflow                  ; branch if yes

          btfsc reading+0,7             ; overflow (reading > 7fffffh) ?
          goto overflow                 ; branch if yes

          call convert_reading          ; convert reading

          call display_reading          ; display reading

ITERS     set  d'1000000'/(d'10'*TIME)

          movlf high ITERS,counter+0    ; short delay
          movlf low ITERS,counter+1
          call wait

          goto mode1                    ; loop


;--------------------------------------------------------------------------
; pulse count mode
;--------------------------------------------------------------------------

          routine pulse_counter

          movlw 2                       ; count mode ?
          subwf mode,w
          bnz cnt2                      ; branch if not

          movff TMR0,work               ; capture RTCC

          movfw TMR0_                   ; change from previous value
          subwf work,w

          addwf pulses+1                ; add to pulse counter
          skpnc
          incf pulses+0

          movlw high d'10000'           ; overflow (> 9999) ?
          subwf pulses+0,w
          movlw low d'10000'
          skpnz
          subwf pulses+1,w
          bnc cnt1                      ; branch if not

          movlw high d'10000'           ; subtract 10000
          subwf pulses+0
          movlw low d'10000'
          subwf pulses+1
          skpc
          decf pulses+0

          bsf wrapped,0                 ; signal wrapped

cnt1      movff work,TMR0_

cnt2      return


          routine mode2

          clrwdt                        ; recommended when changing prescaler
          clrf TMR0                     ; assignment from RTCC to WDT

          movlw b'00101111'             ; source - transition on RTCC pin
          option_                       ; edge - low-to-high transition
          clrwdt                        ; prescaler - not assigned to RTCC

          clrf pulses+0                 ; clear pulse counter
          clrf pulses+1

          clrf wrapped                  ; not wrapped

          clrf TMR0_                    ; initialise RTCC
          clrf TMR0

loop3     movlf displays,FSR            ; initialise display pointer,
          movlf b'11101110',disp_mask   ; mask and timer
          clrf disp_timer

ITERS     set  d'5000'

          movlf high ITERS,counter+0
          movlf low ITERS,counter+1

loop4     clrwdt

          call pulse_counter            ; count pulses

          call poll_button              ; poll pushbutton
          bc do_mode                    ; branch if pressed

          call pulse_counter            ; count pulses

          call mux_displays             ; multiplex the displays

          call pulse_counter            ; count pulses

          tstf counter+1                ; decrement loop counter
          skpnz
          decf counter+0
          decf counter+1

          movfw counter+0               ; counter = 0 ?
          iorwf counter+1,w
          bnz loop4                     ; loop if not

          clrf reading+0                ; snapshot of pulse counter
          movff pulses+0,reading+1
          movff pulses+1,reading+2

          call convert_reading          ; convert reading

          call pulse_counter            ; count pulses

          bcf digits+3,7                ; all decimal points on if
          btfsc wrapped,0               ; pulse count wrapped
          bsf digits+3,7
          bcf digits+4,7
          btfsc wrapped,0
          bsf digits+4,7
          bcf digits+5,7
          btfsc wrapped,0
          bsf digits+5,7
          bcf digits+6,7
          btfsc wrapped,0
          bsf digits+6,7

          movfw digits+3                ; convert the four digits to
          call conv_char0               ; LED display data
          movfw digits+4
          call conv_char1
          movfw digits+5
          call conv_char2
          movfw digits+6
          call conv_char3

          goto loop3                    ; loop


;--------------------------------------------------------------------------
; underflow (frequency < 1Hz or pulse < 1us)
;--------------------------------------------------------------------------

          routine underflow

          movlw BLANK                   ; display underflow as "   0"
          call conv_char0
          movlw BLANK
          call conv_char1
          movlw BLANK
          call conv_char2
          movlw 0
          call conv_char3

          goto main_loop


;--------------------------------------------------------------------------
; overflow (frequency > ~ 8MHz or pulse > ~ 8s)
;--------------------------------------------------------------------------

          routine overflow

          movlw BLANK                   ; display overflow as "   E"
          call conv_char0
          movlw BLANK
          call conv_char1
          movlw BLANK
          call conv_char2
          movlw ERR
          call conv_char3

          goto main_loop


          end
