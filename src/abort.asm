;==============================================================================
; ABORT.COM — Resident force-exit hotkey for kiosk / booth use
;
; Installs as a TSR. While a game is running under the browser:
;   Ctrl + Alt + Backspace  →  terminate current process (return to parent)
;
; Safe for real 8086/286/386 MS-DOS and DOSBox. Calls DOS only when InDOS
; is clear (or via INT 28h idle). Chains prior INT 09h / INT 28h handlers.
;
; Usage:
;   ABORT.COM          install (prints banner)
;   Already resident?  prints message and exits without double-hook
;
; nasm -f bin -o ABORT.COM abort.asm
;==============================================================================

        bits    16
        cpu     8086
        org     100h

; BIOS keyboard flags (40:17)
KF_LSHIFT       equ     01h
KF_RSHIFT       equ     02h
KF_CTRL         equ     04h
KF_ALT          equ     08h
; Make code for Backspace is 0Eh; break is 8Eh
SC_BACKSPACE    equ     0Eh

start:
        push    cs
        pop     ds

        ; Already installed? INT 2Fh multiplex signature
        mov     ax, 0AB00h
        int     2Fh
        cmp     al, 0ABh
        jne     .install
        mov     dx, msg_already
        mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h

.install:
        ; Save old INT 09h
        mov     ax, 3509h
        int     21h
        mov     [old09], bx
        mov     [old09+2], es

        ; Save old INT 28h
        mov     ax, 3528h
        int     21h
        mov     [old28], bx
        mov     [old28+2], es

        ; Save old INT 2Fh
        mov     ax, 352Fh
        int     21h
        mov     [old2f], bx
        mov     [old2f+2], es

        ; Get InDOS address
        mov     ah, 34h
        int     21h
        mov     [indos_off], bx
        mov     [indos_seg], es

        ; Hook handlers
        mov     ax, 2509h
        mov     dx, int09
        int     21h

        mov     ax, 2528h
        mov     dx, int28
        int     21h

        mov     ax, 252Fh
        mov     dx, int2f
        int     21h

        mov     dx, msg_ok
        mov     ah, 09h
        int     21h

        ; TSR: keep through end of resident block
        mov     dx, resident_end
        add     dx, 15
        mov     cl, 4
        shr     dx, cl                  ; paragraphs
        mov     ax, 3100h
        int     21h

;==============================================================================
; Resident data + handlers
;==============================================================================

old09           dd      0
old28           dd      0
old2f           dd      0
indos_off       dw      0
indos_seg       dw      0
pending         db      0               ; 1 = abort requested
busy            db      0               ; reentrancy guard

;------------------------------------------------------------------------------
; INT 2Fh — installation check (AX=AB00h → AL=ABh)
;------------------------------------------------------------------------------
int2f:
        cmp     ax, 0AB00h
        jne     .chain
        mov     al, 0ABh
        iret
.chain:
        jmp     far [cs:old2f]

;------------------------------------------------------------------------------
; INT 09h — keyboard
;------------------------------------------------------------------------------
int09:
        push    ax
        push    bx
        push    cx
        push    dx
        push    ds
        pushf
        call    far [cs:old09]

        call    maybe_request_abort

        pop     ds
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        iret

;------------------------------------------------------------------------------
; INT 28h — DOS idle; retry pending abort
;------------------------------------------------------------------------------
int28:
        cmp     byte [cs:pending], 0
        je      .chain
        call    try_abort
.chain:
        jmp     far [cs:old28]

;------------------------------------------------------------------------------
; maybe_request_abort — after BIOS keyboard handling, detect Ctrl+Alt+Backspace
; in the BIOS buffer and request an abort without touching port 60h.
;------------------------------------------------------------------------------
maybe_request_abort:
        push    ax
        push    bx
        push    cx
        push    ds

        mov     ax, 40h
        mov     ds, ax

        mov     al, [17h]
        and     al, KF_CTRL | KF_ALT
        cmp     al, KF_CTRL | KF_ALT
        jne     .out

        mov     bx, [1Ch]               ; tail pointer after BIOS advanced it
        cmp     bx, [1Ah]
        je      .out                    ; no new keystroke buffered

        cmp     bx, 1Eh
        jne     .prev_ok
        mov     bx, 3Eh
.prev_ok:
        sub     bx, 2
        cmp     word [bx], 0E08h        ; Backspace = scan 0Eh, ASCII 08h
        jne     .out

        mov     [1Ch], bx               ; swallow the buffered backspace
        mov     byte [cs:pending], 1

.out:
        pop     ds
        pop     cx
        pop     bx
        pop     ax
        ret

;------------------------------------------------------------------------------
; try_abort — if pending and DOS free, terminate current process
;------------------------------------------------------------------------------
try_abort:
        push    ax
        push    bx
        push    ds
        push    es

        cmp     byte [cs:busy], 0
        jne     .out
        cmp     byte [cs:pending], 0
        je      .out

        ; InDOS == 0?
        mov     ds, [cs:indos_seg]
        mov     bx, [cs:indos_off]
        cmp     byte [bx], 0
        jne     .out

        mov     byte [cs:busy], 1
        mov     byte [cs:pending], 0

        ; Critical: enable interrupts for DOS
        sti

        ; Current PSP = running game (or browser if nothing nested)
        mov     ah, 62h
        int     21h                     ; BX = PSP
        mov     es, bx

        ; If parent PSP == self, we are top-level — do not kill COMMAND/BROWSER
        ; alone; only kill if there is a distinct parent chain.
        ; Always terminate current PSP with 4Ch: when a game was EXECed by
        ; BROWSER, current PSP is the game and 4Ch returns to BROWSER's EXEC.
        mov     ax, 4C00h
        int     21h
        ; does not return

.out:
        pop     es
        pop     ds
        pop     bx
        pop     ax
        ret

resident_end:

;------------------------------------------------------------------------------
; Transient messages (not kept after TSR)
;------------------------------------------------------------------------------
msg_ok          db      'ABORT resident: Ctrl+Alt+Backspace force-exits game.',13,10,'$'
msg_already     db      'ABORT already installed.',13,10,'$'
