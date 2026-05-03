;***********************************************************
;*
;*	This is the TRANSMIT skeleton file for Lab 7 of ECE 375
;*
;*  	Rock Paper Scissors
;* 	Requirement:
;* 	1. USART1 communication
;* 	2. Timer/counter1 Normal mode to create a 1.5-sec delay
;***********************************************************
;*
;*	 Author: 
;*	   Date: 
;*
;***********************************************************

.include "m32U4def.inc"         ; Include definition file

;***********************************************************
;*  Internal Register Definitions and Constants
;*
;*  Note: r18 and r19 are reused across routines:
;*    r18 (choice) also acts as 'send' in USART_Send
;*                 and as inner loop counter in HALF_SECOND_WAIT
;*    r19 (opponent) also acts as 'receive' in USART ISR
;*                   and as outer loop counter in HALF_SECOND_WAIT
;***********************************************************
.def    mpr = r16               ; Multi-Purpose Register: general scratch register
.def    choice = r18            ; Player's RPS choice: 1=Rock, 2=Paper, 3=Scissors
.def    opponent = r19          ; Opponent's RPS choice received over USART
.def    waitcnt = r23           ; Wait Loop Counter
.def    temp = r25              ; Temp register used in TIMER1_INT ISR

.equ	But7 = 7				; Bit position of PD7 button (start/ready)
.equ	But2 = 4				; Bit position of PD4 button (cycle choice)
.equ	WTime = 150				; Time to wait in wait loop

.equ	is_ready = 0			; Bit flag for ready state (reserved)

; RPS choice constants
.equ	Rock     = 1
.equ	Paper    = 2
.equ	Scissors = 3

;***********************************************************
;*  Timer1 Preload Value = 0x48E5
;*  Prescaler = 256 => timer tick = 256/8MHz = 32 microseconds
;*  Ticks for 1.5s = 1.5 / 0.000032 = 46875
;*  Preload = 65536 - 46875 = 18661 = 0x48E5
;***********************************************************
.equ PRELOAD_HIGH = 0x48        ; High byte of Timer1 preload value
.equ PRELOAD_LOW  = 0xE5        ; Low byte of Timer1 preload value

; Handshake byte sent between boards to signal "I am ready to play"
.equ    SendReady = 0b11111111


;***********************************************************
;*  Start of Code Segment
;***********************************************************
.cseg                           ; Beginning of code segment

;***********************************************************
;*  Interrupt Vectors
;***********************************************************
.org    $0000                   ; Reset vector
	rjmp    INIT                ; Jump to initialization on reset

.org	$0028                   ; Timer1 overflow interrupt vector
	rcall TIMER1_INT            ; Call timer ISR to update LED countdown
	reti

.org    $0032                   ; USART1 RX complete interrupt vector
    rjmp    USART_Receive_Interrupt   ; Jump to ISR when a byte is received

.org    $0056                   ; End of Interrupt Vectors


;***********************************************************
;*  Program Initialization
;***********************************************************
INIT:
	; --- Stack Pointer ---
	; Must be set before any rcall, push, or pop
	ldi		mpr, low(RAMEND)    ; Load low byte of top of SRAM
	out		SPL, mpr            ; Set stack pointer low byte
	ldi		mpr, high(RAMEND)   ; Load high byte of top of SRAM
	out		SPH, mpr            ; Set stack pointer high byte

	; --- Port B: Output (LEDs on PB7:PB4) ---
	ldi		mpr, $FF            ; All pins = output
	out		DDRB, mpr
	ldi		mpr, $00            ; All LEDs off initially
	out		PORTB, mpr

	; --- Port D: Input (Buttons on PD7 and PD4) ---
	ldi		mpr, $00            ; All pins = input
	out		DDRD, mpr
	ldi		mpr, $FF            ; Enable pull-ups on all Port D pins
	out		PORTD, mpr

	; --- USART1: 2400 baud, double-speed mode ---
	ldi		mpr, (1 << U2X1)    ; U2X1=1 enables double-speed (halves baud divider)
	sts		UCSR1A, mpr

	ldi     mpr, high(207)
	sts     UBRR1H, mpr
	ldi		mpr, low(207)
	sts		UBRR1L, mpr
	; Enable RX, TX, and RX complete interrupt
	ldi     mpr, (1 << RXEN1) | (1 << TXEN1) | (1 << RXCIE1)
	sts     UCSR1B, mpr
	; Frame format: 8 data bits, 2 stop bits
	ldi     mpr, (1 << UCSZ11) | (1 << UCSZ10) | (1 << USBS1)
	sts     UCSR1C, mpr

	; --- Timer1: Normal mode, Prescaler = 256 ---
	ldi		mpr, 0x00           ; WGM bits = 0 => Normal mode (counts up, overflows at 0xFFFF)
	sts		TCCR1A, mpr
	ldi		mpr, (1 << CS12)    ; CS12=1, CS11=0, CS10=0 => prescaler = 256
	sts		TCCR1B, mpr
	ldi     mpr, PRELOAD_HIGH   ; Preload timer so it overflows after 1.5s
	sts     TCNT1H, mpr
	ldi     mpr, PRELOAD_LOW
	sts     TCNT1L, mpr
	ldi     mpr, (1 << TOIE1)   ; Enable Timer1 overflow interrupt
	sts     TIMSK1, mpr
	sei                         ; Enable global interrupts

	; --- LCD Initialization ---
	rcall LCDInit

	; --- Display Welcome screen ---
	; Copy 32 bytes (2 lines x 16 chars) from flash into Line1 buffer
	ldi     ZL, low(Welcome_START << 1)  ; << 1 converts word address to byte address
	ldi     ZH, high(Welcome_START << 1)
	ldi     XH, high(Line1)
	ldi     XL, low(Line1)
	ldi     r17, 32             ; 32 bytes = both LCD lines
	rcall   LOAD_STRING         ; Copy flash string into SRAM buffer
	ldi     choice, 1           ; Default choice: Rock
	ldi     opponent, 3         ; Initial test value
	rcall   LCDWrite            ; Render SRAM buffer to LCD


;***********************************************************
;*  Main Program
;***********************************************************
MAIN:
	ldi     choice, 3           ; Reset choice to Rock at top of each loop
	in		mpr, PIND           ; Read Port D button state
	sbrs	mpr, BUT7           ; Skip next if PD7 = 1 (not pressed)
	rjmp	STANDBY             ; PD7 pressed (low) => go to standby/ready state
	rjmp	MAIN                ; Not pressed => keep polling


;***********************************************************
;*  LOAD_STRING
;*  Copies a string from program flash into SRAM.
;***********************************************************
LOAD_STRING:
	push    r15                 ; Save r15 (used as byte transfer buffer)
	push    r17                 ; Save r17 (loop counter, restored for caller)
LS_LOOP:
	lpm     r15, Z+             ; Load 1 byte from flash at Z, then Z++
	st      X+, r15             ; Store byte to SRAM at X, then X++
	dec     r17                 ; Decrement remaining byte count
	brne    LS_LOOP             ; Loop until all bytes copied
	pop     r17                 ; Restore loop counter
	pop     r15                 ; Restore r15
	ret


;***********************************************************
;*  Functions and Subroutines
;***********************************************************

;----------------------------------------------------------------
; Sub:	HALF_SECOND_WAIT
; Desc:	Software busy-wait of ~500ms used for button debouncing.
;       r18 and r19 are temporarily used as loop counters.
;       Their values (choice and opponent) are saved/restored
;       via push/pop so callers are unaffected.
;
;       Cycle count formula:
;       (((((3*r18)-1+4)*r19)-1+4)*waitcnt)-1+16
;----------------------------------------------------------------
HALF_SECOND_WAIT:
	push    waitcnt             ; Save waitcnt
	push    r19                 ; Save opponent (r19 reused as outer loop counter)
	push    r18                 ; Save choice (r18 reused as inner loop counter)

	ldi		waitcnt, 100            ; 100 outer iterations
HWAIT_OUTER:
	ldi		r19, 40                 ; 40 middle iterations per outer loop
HWAIT_LOOP:
	ldi		r18, 200                ; 200 inner iterations per middle loop
HWAIT_INNER:
	dec		r18                     ; Decrement inner counter
	brne	HWAIT_INNER            ; Loop until inner = 0
	dec		r19                     ; Decrement middle counter
	brne	HWAIT_LOOP             ; Loop until middle = 0
	dec		waitcnt                 ; Decrement outer counter
	brne	HWAIT_OUTER            ; Loop until outer = 0

	pop     r18                 ; Restore choice
	pop     r19                 ; Restore opponent
	pop     waitcnt             ; Restore waitcnt
	ret


;***********************************************************
;*  USART Communication
;***********************************************************
USART_Send:
	lds		mpr, UCSR1A
	sbrs	mpr, UDRE1              ; Skip next if transmit buffer empty
	rjmp	USART_Send              ; Not empty yet, keep waiting
	sts		UDR1, r18               ; Write byte to USART data register (r18 = choice = send)
WAIT_TX:
	lds		mpr, UCSR1A
	sbrs	mpr, TXC1               ; Skip next if transmission complete
	rjmp	WAIT_TX                 ; Not done yet, keep waiting
	ret

USART_Receive:
	lds		mpr, UCSR1A
	sbrs	mpr, RXC1               ; Skip next if receive complete flag set
	rjmp	USART_Receive           ; Not received yet, keep waiting
	lds		opponent, UDR1          ; Read received byte into opponent register
	ret

USART_Receive_Interrupt:
	push	mpr
	in		mpr, SREG
	push	mpr

	lds		mpr, UDR1
	sts		OpponentByte, mpr

	pop		mpr
	out		SREG, mpr
	pop		mpr
	reti

;-----------------------------------------------------------
; STANDBY
; Displays "Ready, Waiting / For the Opponent" on the LCD,
; sends the SendReady handshake byte to the opponent,
; then spins until the opponent also sends SendReady.
;-----------------------------------------------------------
STANDBY:
	ldi		mpr, 0
	sts		OpponentByte, mpr
	; Load and display the standby message (32 bytes = 2 LCD lines)
	ldi     ZL, low(Standby_START << 1)
	ldi     ZH, high(Standby_START << 1)
	ldi     XH, high(Line1)
	ldi     XL, low(Line1)
	ldi     r17, 32             ; Two full lines
	rcall   LOAD_STRING
	rcall   LCDWrite

STANDBY_LOOP:
    ; send ready byte
    push r18
    ldi  r18, SendReady
    rcall USART_Send
    pop  r18

    ; check if opponent sent ready
    lds  mpr, OpponentByte
    cpi  mpr, SendReady
    brne STANDBY_LOOP

    rjmp START

;-----------------------------------------------------------
; START
; Displays "Game Start!" and fires the 1.5s LED countdown.
; Then enters CHOICE_LOOP where the player cycles their pick.
;-----------------------------------------------------------
START:
	; Line1: "Game Start!"
	ldi     ZL, low(Game_Start << 1)
	ldi     ZH, high(Game_Start << 1)
	ldi     XH, high(Line1)
	ldi     XL, low(Line1)
	ldi     r17, 16
	rcall   LOAD_STRING

	; Line2: blank
	ldi     ZL, low(Blank_Line_Start << 1)
	ldi     ZH, high(Blank_Line_Start << 1)
	ldi     XH, high(Line2)
	ldi     XL, low(Line2)
	ldi     r17, 16
	rcall   LOAD_STRING

	rcall	LCDWrite
	rcall   START_TIMER         ; Light all 4 LEDs and begin 1.5s countdown

CHOICE_LOOP:
	in		mpr, PIND           ; Read Port D button state
	sbrs	mpr, But2           ; Skip next if PD4 = 1 (not pressed)
	rjmp	BUTTON_PRESSED      ; PD4 low (pressed) => update and display choice
	rjmp	AFTER_CHOICE        ; Not pressed => just check the timer

BUTTON_PRESSED:
	; Only update and redisplay when button was actually pressed	
	cpi		choice, 3
	breq	DISPLAY_ROCK
	cpi		choice, 1
	breq	DISPLAY_PAPER
	cpi		choice, 2
	breq	DISPLAY_SCISSORS

AFTER_CHOICE:
	; Read PORTB (output register) 
	in		mpr, PORTB          ; Read current LED output state
	andi	mpr, $F0            ; Isolate upper nibble (LED bits PB7:PB4)
	sbrc	mpr, 4              ; Skip next if bit 4 is clear
	rjmp	CHOICE_LOOP         ; Bit 4 set => at least one LED on => keep looping
	rjmp	USE_CHOICE          ; All LEDs off => timer expired => lock in choice

;-----------------------------------------------------------
; DISPLAY_ROCK / DISPLAY_PAPER / DISPLAY_SCISSORS
; Show the player's current choice on Line2 of the LCD,
; wait 500ms to debounce, then return to AFTER_CHOICE.
;-----------------------------------------------------------
DISPLAY_ROCK:
	ldi		choice, 1           ; pre increment so opponent display displays the correct choice.
	ldi     ZL, low(Rock_Start << 1)
	ldi     ZH, high(Rock_Start << 1)
	ldi     XH, high(Line2)     ; Write to bottom LCD line
	ldi     XL, low(Line2)
	ldi     r17, 16
	rcall   LOAD_STRING
	rcall   LCDWrite
	rcall   HALF_SECOND_WAIT    ; Debounce delay

	rjmp    AFTER_CHOICE

DISPLAY_PAPER:
	inc		choice
	ldi     ZL, low(Paper_Start << 1)
	ldi     ZH, high(Paper_Start << 1)
	ldi     XH, high(Line2)
	ldi     XL, low(Line2)
	ldi     r17, 16
	rcall   LOAD_STRING
	rcall   LCDWrite
	rcall   HALF_SECOND_WAIT

	rjmp    AFTER_CHOICE

DISPLAY_SCISSORS:
	inc		choice
	ldi     ZL, low(Scissors_Start << 1)
	ldi     ZH, high(Scissors_Start << 1)
	ldi     XH, high(Line2)
	ldi     XL, low(Line2)
	ldi     r17, 16
	rcall   LOAD_STRING
	rcall   LCDWrite
	rcall   HALF_SECOND_WAIT

	rjmp    AFTER_CHOICE

;-----------------------------------------------------------
; START_TIMER
; Reloads Timer1 with the preload value, enables the
; overflow interrupt, starts the clock, and turns on
; all 4 LEDs (PB7:PB4) to begin the visual countdown.
;-----------------------------------------------------------
START_TIMER:
	push	mpr
	ldi     waitcnt, 4          ; 4 LEDs = 4 countdown steps

	; Reload Timer1 so it overflows after exactly 1.5s
	ldi     mpr, PRELOAD_HIGH
	sts     TCNT1H, mpr
	ldi     mpr, PRELOAD_LOW
	sts     TCNT1L, mpr

	ldi     mpr, (1 << TOIE1)   ; Enable Timer1 overflow interrupt
	sts     TIMSK1, mpr

	ldi		mpr, (1 << CS12)    ; Start Timer1 with prescaler = 256
	sts		TCCR1B, mpr

	; Turn on all 4 LEDs (PB7:PB4), preserve lower nibble (PB3:PB0)
	in		mpr, PORTB
	andi	mpr, $0F            ; Clear upper nibble
	ori		mpr, $F0            ; Set all 4 LED bits high
	out		PORTB, mpr

	pop		mpr
	ret


;-----------------------------------------------------------
; TIMER1_INT (Timer1 Overflow ISR)
; Called every 1.5s by Timer1 overflow.
; Shifts the LED pattern right by one (turns off one LED).
; When all LEDs are off, stops the timer entirely.
;-----------------------------------------------------------
TIMER1_INT:
	push    mpr
	push    temp

	; Read LEDs, shift right to turn off the highest lit LED
	in      mpr, PORTB              ; Read current PORTB output state
	andi    mpr, 0xF0               ; Isolate upper nibble (LED bits PB7:PB4)
	mov     temp, mpr               ; Copy LED bits to temp
	lsr     temp                    ; Shift right => turns off one LED
	andi    temp, 0xF0              ; Clear any bit that shifted into lower nibble

	; Merge new LED state back with unchanged lower nibble
	in      mpr, PORTB              ; Re-read PORTB to get PB3:PB0
	andi    mpr, 0x0F               ; Keep only lower nibble
	or      mpr, temp               ; Combine with shifted LED bits
	out     PORTB, mpr              ; Write updated state back to PORTB

	; Check if all LEDs are now off (upper nibble = 0x00)
	andi	mpr, $F0
	cpi		mpr, 0
	brne    TIMER_CONTINUE          ; LEDs still on => keep timer running

	; All LEDs off: disable timer completely
	ldi     mpr, 0x00
	sts     TIMSK1, mpr             ; Disable Timer1 overflow interrupt
	ldi     mpr, 0x00
	sts     TCCR1B, mpr             ; Stop Timer1 clock (remove prescaler)
	rjmp    END_TIMER

TIMER_CONTINUE:
	; Reload preload so next overflow also takes 1.5s
	ldi     mpr, PRELOAD_HIGH
	sts     TCNT1H, mpr
	ldi     mpr, PRELOAD_LOW
	sts     TCNT1L, mpr

END_TIMER:
	pop     temp
	pop     mpr
	ret                             ; Caller (interrupt vector) does reti


;-----------------------------------------------------------
; USE_CHOICE
; Sends the player's locked-in choice to the opponent,
; starts the suspense countdown, then waits for the
; opponent's choice to arrive via the USART ISR.
;-----------------------------------------------------------
USE_CHOICE:
	rcall USART_Send            ; Transmit choice (r18) to opponent

GET_OPPONENT:
	rcall START_TIMER           ; Start LED countdown while waiting

RECEIVE_LOOP:
	; Spin until opponent register holds a valid choice (1, 2, or 3)
	; opponent is updated by USART_Receive_Interrupt ISR
	lds		opponent, OpponentByte
	cpi		opponent, 1
	breq	DISPLAY_OPP_ROCK
	lds		opponent, OpponentByte
	cpi		opponent, 2
	breq	DISPLAY_OPP_PAPER
	lds		opponent, OpponentByte
	cpi		opponent, 3
	breq	DISPLAY_OPP_SCISSORS
	rjmp    RECEIVE_LOOP        ; Not valid yet => keep polling

GameTIMER_LOOP:
	; Wait here until the suspense timer expires
	in		mpr, PINB
	andi	mpr, $F0            ; Check LED bits
	sbrc	mpr, 4              ; If bit 4 clear, timer has finished
	rjmp	GameTIMER_LOOP       ; Still running => wait
	rjmp    GAME_LOGIC          ; Timer done => evaluate the result


;-----------------------------------------------------------
; Show the opponent's choice on Line1 while in GameTIMER_LOOP.
;-----------------------------------------------------------
DISPLAY_OPP_ROCK:
	ldi		ZL, low(Rock_Start << 1)
	ldi		ZH, high(Rock_Start << 1)
	rcall	UPDATE_OPP_LCD      ; Call a shared update routine
	rjmp	GameTIMER_LOOP      ; Go wait for the timer to finish

DISPLAY_OPP_PAPER:
	ldi		ZL, low(Paper_Start << 1)
	ldi		ZH, high(Paper_Start << 1)
	rcall	UPDATE_OPP_LCD
	rjmp	GameTIMER_LOOP

DISPLAY_OPP_SCISSORS:
	ldi		ZL, low(Scissors_Start << 1)
	ldi		ZH, high(Scissors_Start << 1)
	rcall	UPDATE_OPP_LCD
	rjmp	GameTIMER_LOOP


;-----------------------------------------------------------
; UPDATE_OPP_LCD
; Helper to avoid repeating the same 6 lines of code
;-----------------------------------------------------------
UPDATE_OPP_LCD:
	ldi		XH, high(Line1)
	ldi		XL, low(Line1)
	ldi		r17, 16
	rcall	LOAD_STRING
	rcall	LCDWrite
	ret                         


;-----------------------------------------------------------
; GAME_LOGIC
; Determines win/lose/tie using modular arithmetic:
;   diff = (choice - opponent) mod 3
;   diff == 0 => Tie
;   diff == 1 => Win  (e.g. Rock beats Scissors)
;   diff == 2 => Lose (e.g. Rock loses to Paper)
;-----------------------------------------------------------
GAME_LOGIC:	
	sub		choice, opponent       ; diff = choice - opponent
	brpl	MODULO                 ; If result >= 0, skip the wrap
	ldi		opponent, 3
	add		choice, opponent       ; Negative result => add 3 to wrap into 0..2

MODULO:
	cpi		choice, 1
	breq	DISPLAY_WIN            ; diff == 1 => player wins
	cpi		choice, 2
	breq	DISPLAY_LOSE           ; diff == 2 => player loses
	rjmp	DISPLAY_TIE            ; diff == 0 => tie


;-----------------------------------------------------------
; DISPLAY_TIE / DISPLAY_WIN / DISPLAY_LOSE
; Start the LED timer, loop displaying the result on Line1
; until the timer expires, then restart the game.
;-----------------------------------------------------------
DISPLAY_TIE:
	rcall	START_TIMER           ; Start LED countdown
TIE_LOOP:
	ldi     ZL, low(Draw_Start << 1)
	ldi     ZH, high(Draw_Start << 1)
	ldi     XH, high(Line1)
	ldi     XL, low(Line1)
	ldi     r17, 16
	rcall   LOAD_STRING
	rcall   LCDWrite
	in		mpr, PINB
	andi	mpr, $F0            ; Check if LEDs are still on
	sbrc	mpr, 4              ; If bit 4 clear, timer done
	rjmp    TIE_LOOP
	rjmp    RESTART_GAME


DISPLAY_WIN:
	rcall	START_TIMER
WIN_LOOP:
	ldi     ZL, low(Win_Start << 1)
	ldi     ZH, high(Win_Start << 1)
	ldi     XH, high(Line1)
	ldi     XL, low(Line1)
	ldi     r17, 16
	rcall   LOAD_STRING
	rcall   LCDWrite
	in		mpr, PINB
	andi	mpr, $F0
	sbrc	mpr, 4              ; If bit 4 clear, timer done
	rjmp    WIN_LOOP
	rjmp    RESTART_GAME


DISPLAY_LOSE:
	rcall	START_TIMER
LOSE_LOOP:
	ldi     ZL, low(Lose_Start << 1)
	ldi     ZH, high(Lose_Start << 1)
	ldi     XH, high(Line1)
	ldi     XL, low(Line1)
	ldi     r17, 16
	rcall   LOAD_STRING
	rcall   LCDWrite
	in		mpr, PINB
	andi	mpr, $F0
	sbrc	mpr, 4              ; If bit 4 clear, timer done
	rjmp    LOSE_LOOP
	rjmp    RESTART_GAME


;-----------------------------------------------------------
; RESTART_GAME
; Resets choice, opponent, waitcnt, and LEDs back to
; their initial state, reloads the welcome screen,
; then jumps back to MAIN.
;-----------------------------------------------------------
RESTART_GAME:
	ldi     choice, 1           ; Reset player choice to Rock
	ldi     opponent, 1         ; Reset opponent choice
	clr     waitcnt             ; Clear timer countdown counter
	ldi     mpr, 0x00
	out     PORTB, mpr          ; Turn off all LEDs

	; Reload and display the welcome message
	ldi     ZL, low(Welcome_START << 1)
	ldi     ZH, high(Welcome_START << 1)
	ldi     XH, high(Line1)
	ldi     XL, low(Line1)
	ldi     r17, 32             ; Two lines
	rcall   LOAD_STRING
	rcall   LCDWrite

	jmp     MAIN                ; Return to main polling loop


;***********************************************************
;*  Stored Program Data
;*  All strings are exactly 16 chars (padded with spaces)
;*  to fill one full LCD line without overflow.
;***********************************************************
Welcome_START:
	.DB		"Welcome!        "  ; Line 1
	.DB		"Please Press PD7"  ; Line 2
Welcome_END:

Standby_START:
	.DB		"Ready, Waiting  "  ; Line 1
	.DB		"For the Opponent"  ; Line 2
Standby_END:

Game_Start:
	.DB		"Game Start!     "  

Rock_Start:
	.DB		"Rock            "
Rock_END:

Paper_Start:
	.DB		"Paper           "
Paper_END:

Scissors_Start:
	.DB		"Scissors        "
Scissors_END:

Win_Start:
	.DB		"You Won!!       "
Win_END:

Lose_Start:
	.DB		"You Lost        "
Lose_END:

Draw_Start:
	.DB		"Draw!           "
Draw_END:

Blank_Line_Start:
	.DB		"                "
Blanck_Line_End:

;***********************************************************
;*  Additional Program Includes
;***********************************************************
.include "LCDDriver.asm"		; Include the LCD Driver

;***********************************************************
;*  SRAM Data Segment
;*  Line1 and Line2 are the LCD display buffers.
;*  LOAD_STRING copies flash strings here before LCDWrite.
;***********************************************************
.dseg
.org $0100
Line1:
	.byte 16                    ; 16-byte buffer for top LCD row
Line2:
	.byte 16                    ; 16-byte buffer for bottom LCD row

OpponentByte: 
	.byte 1	