.8086
.model tiny

; ==== Defines ====
RTC_INDEX_PORT  equ 070h
RTC_DATA_PORT   equ 071h

RTC_SEC_REG     equ 00h
RTC_MIN_REG     equ 02h
RTC_HR_REG      equ 04h
RTC_A_REG       equ 0Ah
RTC_B_REG       equ 0Bh
RTC_C_REG       equ 0Ch

RTC_RS_MASK     equ 0F0h
RTC_IE_MASK     equ 08Fh
RTC_PIE_BIT     equ 040h
RTC_UIE_BIT     equ 010h
RTC_PF_BIT      equ 040h
RTC_UF_BIT      equ 010h
RTC_RS_256HZ    equ 08h

PIC1_CMD_PORT   equ 020h
PIC1_DATA_PORT  equ 021h
PIC2_CMD_PORT   equ 0A0h
PIC2_DATA_PORT  equ 0A1h
PIC_EOI_CMD     equ 020h

NMI_MASK        equ 080h

LPT_DATA_PORT   equ 0378h
LPT_CTRL_PORT	equ 037Ah

.code
org 100h

; The initial entry point *must* be placed at 100h, but we don't need to keep
; the initialization part resident. Let's just jump to it instead and place it
; further in code so we can just ignore it when determining TSR size.
entry_point:
	jmp init

; ==== Resident variables ====
disp_digits     db 0, 0, 0, 0                   ; Time digits (stored in upper nibbles)
disp_index      db 0                            ; Display index for multiplexing
disp_anode_lut  db 1110b, 1101b, 1011b, 0111b   ; LUT for enabling display anodes

; ==== Resident procedures ====

; Clobbers AX, CL
rtc_get_time proc
	mov al, RTC_MIN_REG
	out RTC_INDEX_PORT, al
	in al, RTC_DATA_PORT        ; Read minutes from RTC

	mov ah, al
	mov cl, 4
	shl ah, cl                  ; Get ones digit
	mov disp_digits + 3, ah     ; Store in memory in upper nibble
	and al, 0F0h                ; Get tens digit
	mov disp_digits + 2, al     ; Store in memory in upper nibble

	mov al, RTC_HR_REG
	out RTC_INDEX_PORT, al
	in al, RTC_DATA_PORT        ; Read hours from RTC
	mov ah, al
	mov cl, 4
	shl ah, cl                  ; Get ones digit
	mov disp_digits + 1, ah     ; Store in memory in upper nibble
	and al, 0F0h                ; Get tens digit
	mov disp_digits + 0, al     ; Store in memory in upper nibble

	ret
rtc_get_time endp

rtc_isr proc
	; Preserve used registers
	pushf
	push ax
	push bx
	push cx
	push dx
	push ds
	push cs
	pop ds  ; Set DS = CS

	; Read RTC register C
	mov al, RTC_C_REG
	out RTC_INDEX_PORT, al
	in al, RTC_DATA_PORT
	mov bl, al

	; If update interrupt, update time variables and colon state
	test bl, RTC_UF_BIT
	jz check_pf
	call rtc_get_time

	; Update colon state - turn on if seconds value is odd
	; TODO this should be RMW, but I have some issues reading
	; TODO from LPT control port. Needs further investigation.
	mov al, RTC_SEC_REG
	out RTC_INDEX_PORT, al
	in al, RTC_DATA_PORT	; Read RTC seconds register
	and al, 1				; Keep only LSB
	xor al, 1               ; Invert it, as AUTOLF LPT line is inverted too
	shl al, 1               ; Shift to bit 1 to align with AUTOLF bit
	mov dx, LPT_CTRL_PORT
	out dx, al				; Write to LPT

check_pf:
	; If periodic interrupt, update display
	test bl, RTC_PF_BIT
	jz isr_exit

	; Create control word and send to LPT port
	mov al, disp_index
	mov bx, offset disp_anode_lut
	xlatb                       ; AL = anode_lut[anode] (bottom nibble)
	mov ah, al
	mov al, disp_index
	mov bx, offset disp_digits
	xlatb                       ; AL = digits[anode] (top nibble)
	or al, ah
	mov dx, LPT_DATA_PORT
	out dx, al

	; Select next display mod 4
	inc disp_index
	and disp_index, 3

isr_exit:
	; Send EOI to PICs
	mov al, PIC_EOI_CMD
	out PIC2_CMD_PORT, al   ; EOI to slave PIC
	out PIC1_CMD_PORT, al   ; EOI to master PIC

	; Restore registers
	pop ds
	pop dx
	pop cx
	pop bx
	pop ax
	popf
	iret
rtc_isr endp

; ==== End of resident code ====
resident_end:

; ==== Non-resident variables ====
startup_msg db 'LPT clock TSR',0Dh,0Ah,'(C) Lefucjusz, Warszawa 2025',0Dh,0Ah,'$'
success_msg db 'Clock TSR up and running!',0Dh,0Ah,'$'

; ==== Non-resident initialization code ====
init:
	; Display startup message
	mov ah, 09h
	mov dx, offset startup_msg
	int 21h

	; Disable interrupts
	cli

	; Install RTC IRQ8 handler (INT 70h)
	mov dx, offset rtc_isr
	mov ax, 2570h                       ; Set interrupt vector function (25h) for INT 70h
	int 21h

	; Configure RTC to generate periodic interrupt with 256Hz rate and update-ended interrupt
	mov al, RTC_A_REG + NMI_MASK        ; Select RTC register A, mask NMI
	out RTC_INDEX_PORT, al
	in al, RTC_DATA_PORT                ; Read the register
	and al, RTC_RS_MASK                 ; Clear Rate Selector bits
	or al, RTC_RS_256HZ                 ; Set periodic interrupt rate to 256Hz
	out RTC_DATA_PORT, al               ; Write to RTC

	mov al, RTC_B_REG + NMI_MASK        ; Select RTC register B, mask NMI
	out RTC_INDEX_PORT, al
	in al, RTC_DATA_PORT                ; Read the register
	and al, RTC_IE_MASK                 ; Clear interrupt enable flags
	or al, RTC_PIE_BIT + RTC_UIE_BIT    ; Enable periodic interrupt and update-ended interrupt
	out RTC_DATA_PORT, al               ; Write to RTC

	; Unmask IRQ8
	in al, PIC2_DATA_PORT               ; Read slave PIC data port
	and al, 0FEh                        ; Unmask IRQ line 0 (IRQ8)
	out PIC2_DATA_PORT, al              ; Write to PIC

	; Pre-fetch time
	call rtc_get_time

	; Enable interrupts
	sti

	; Display success message
	mov ah, 09h
	mov dx, offset success_msg
	int 21h

	; Stay resident
	mov dx, offset resident_end     ; Get offset of the end of resident part
	add dx, 15
	mov cl, 4
	shr dx, cl                      ; Convert to paragraphs using (offset + 15) / 16 formula
	mov ax, 3100h                   ; Terminate & stay resident (31h) with return code 0
	int 21h
end entry_point
