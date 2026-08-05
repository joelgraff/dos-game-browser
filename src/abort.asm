;==============================================================================
; ABORT.COM — Resident force-exit hotkey for kiosk / booth use
;
; Installs as a TSR. While a game is running under the browser:
;   F12, or Ctrl + Alt + Backspace  →  terminate current process
;
; F12 needs no modifier, so it still works when a game's own keyboard handler
; has left the Ctrl/Alt state inconsistent.
;
; Safe for real 8086/286/386 MS-DOS and DOSBox. Calls DOS only when InDOS
; is clear (or via INT 28h idle). Chains prior INT 09h / INT 28h handlers.
;
; ABORT.COM /W enables a timer watchdog that takes INT 09h back from games that
; seize it. Off by default: it puts this handler in front of a game that expects
; exclusive keyboard control, which is a real risk. Try it per-game.
;
; LIMITATION (without /W): games that install their own INT 09h handler and never chain
; (Commander Keen, Digger Remastered, ...) never call this handler, so the
; hotkey cannot work in them. In Keen the chord works on the splash screen and
; dies the instant the game starts -- that is when it takes the vector. Stealing the vector back from a timer tick was
; tried and reverted -- sitting in front of a game that owns the keyboard
; stopped Keen from starting at all. Run BROWSER.COM /T after playing: if it
; reports KBD scancodes=0, the game owned the keyboard outright.
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
SC_F12          equ     58h             ; 101-key F12; no E0 prefix

start:
        push    cs
        pop     ds

        ; /W enables the keyboard-vector watchdog (see the header notes).
        mov     byte [watchdog], 0
        xor     cx, cx
        mov     cl, [80h]               ; PSP command tail length
        or      cl, cl
        jz      .noargs
        mov     si, 81h
.scan:  mov     al, [si]
        cmp     al, '/'
        je      .sw
        cmp     al, '-'
        jne     .next
.sw:    cmp     cx, 1
        jbe     .noargs
        mov     al, [si+1]
        or      al, 20h
        cmp     al, 'w'
        jne     .next
        mov     byte [watchdog], 1
        jmp     .noargs
.next:  inc     si
        dec     cx
        jnz     .scan
.noargs:

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
        ; Save old INT 09h (also kept permanently as the fallback chain)
        mov     ax, 3509h
        int     21h
        mov     [old09], bx
        mov     [old09+2], es
        mov     [orig09], bx
        mov     [orig09+2], es

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

        cmp     byte [watchdog], 0
        je      .no_wd
        mov     ax, 3508h               ; remember the timer chain
        int     21h
        mov     [old08], bx
        mov     [old08+2], es
        mov     ax, 2508h
        mov     dx, int08
        int     21h
.no_wd:

        mov     ax, 252Fh
        mov     dx, int2f
        int     21h

        mov     dx, msg_ok
        mov     ah, 09h
        int     21h
        cmp     byte [watchdog], 0
        je      .banner_done
        mov     dx, msg_wd
        mov     ah, 09h
        int     21h
.banner_done:

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

old09           dd      0               ; current chain target (may be a game's)
orig09          dd      0               ; handler present when we installed
old08           dd      0               ; only used when the watchdog is on
watchdog        db      0               ; 1 = /W given
wd_grabs        dw      0               ; times the watchdog reclaimed INT 09h
counting        db      1               ; gate so a reading can cover one game
old28           dd      0
old2f           dd      0
indos_off       dw      0
indos_seg       dw      0
pending         db      0               ; 1 = abort requested
busy            db      0               ; set while terminating; cleared by
                                        ; INT 2Fh AB01h/AB03h when the browser
                                        ; regains control. Without that the
                                        ; hotkey only ever fires once.
kf_own          db      0               ; Ctrl/Alt tracked from scancodes
sc_count        dw      0               ; scancodes seen (diagnostic)
sc_last         db      0               ; last scancode seen (diagnostic)

;------------------------------------------------------------------------------
; INT 2Fh — installation check (AX=AB00h → AL=ABh)
;------------------------------------------------------------------------------
int2f:
        cmp     ax, 0AB00h
        je      .present
        cmp     ax, 0AB01h              ; reset keyboard chain
        je      .reset
        cmp     ax, 0AB02h              ; report what the handler has seen
        je      .diag
        cmp     ax, 0AB03h              ; zero the counters, start counting
        je      .zero
        cmp     ax, 0AB04h              ; stop counting
        je      .stop
        cmp     ax, 0AB05h              ; mark spent (as a real abort does)
        je      .spend
        jmp     far [cs:old2f]
.present:
        mov     al, 0ABh
        iret
.reset:
        call    reset_kbd_chain
        mov     byte [cs:busy], 0       ; re-arm; the previous game is gone
        mov     al, 0ABh
        iret
.zero:                                  ; AB03h: arm, reset and start counting
        mov     byte [cs:busy], 0
        mov     word [cs:sc_count], 0
        mov     byte [cs:sc_last], 0
        mov     word [cs:wd_grabs], 0
        mov     byte [cs:counting], 1
        mov     al, 0ABh
        iret
.stop:                                  ; AB04h: stop, so the reading is frozen
        mov     byte [cs:counting], 0
        mov     al, 0ABh
        iret
.spend:                                 ; AB05h: leave the hotkey disarmed, the
        mov     byte [cs:busy], 1       ; state a completed abort leaves behind.
        mov     al, 0ABh                ; Exists so the re-arm can be tested
        iret                            ; without synthesising a keystroke.
.diag:
        ; BX = scancodes seen, CL = last scancode, CH = tracked Ctrl/Alt bits.
        ; Lets BROWSER.COM /T show whether the TSR is being called at all.
        mov     bx, [cs:sc_count]
        mov     cl, [cs:sc_last]
        mov     ch, [cs:kf_own]
        mov     dx, [cs:wd_grabs]
        mov     si, 1
        cmp     byte [cs:busy], 0       ; SI = 1 when armed, 0 when spent
        je      .diag_armed
        xor     si, si
.diag_armed:
        mov     al, 0ABh
        iret

;------------------------------------------------------------------------------
; INT 09h — keyboard
;------------------------------------------------------------------------------
; Peek the raw scancode before the BIOS consumes it.
;
; Do not be tempted to inspect the BIOS keyboard buffer instead: with Alt held
; the BIOS produces no ASCII for Backspace, so the chord never reaches the
; buffer and a buffer comparison can never match. The scancode is the only
; reliable source. (This is exactly how it regressed once already.)
; Track Ctrl and Alt from raw scancodes rather than the BIOS shift flags at
; 0040:0017. Once a game installs its own INT 09h the BIOS handler stops being
; called, so nothing maintains those flags and they read as zero -- the chord
; then goes unrecognised even though we are seeing every scancode.
;
; E0 prefixes are ignored: right Ctrl and right Alt carry the same base codes
; as the left ones, and no other extended key collides with 1Dh/38h/0Eh.
int09:
        push    ax
        push    ds

        in      al, 60h

        cmp     byte [cs:counting], 0   ; diagnostics (INT 2Fh AB02h/03h/04h)
        je      .nocount
        inc     word [cs:sc_count]
        mov     [cs:sc_last], al
.nocount:

        cmp     al, 1Dh                 ; Ctrl make
        jne     .nc1
        or      byte [cs:kf_own], KF_CTRL
        jmp     .chain
.nc1:   cmp     al, 9Dh                 ; Ctrl break
        jne     .nc2
        and     byte [cs:kf_own], 0FBh
        jmp     .chain
.nc2:   cmp     al, 38h                 ; Alt make
        jne     .nc3
        or      byte [cs:kf_own], KF_ALT
        jmp     .chain
.nc3:   cmp     al, 0B8h                ; Alt break
        jne     .nc4
        and     byte [cs:kf_own], 0F7h
        jmp     .chain
.nc4:
        ; F12 fires on its own. Old DOS games predate the 101-key layout and
        ; almost never use it, and needing no modifier means it still works if a
        ; game's own handler has mangled the Ctrl/Alt state.
        cmp     al, SC_F12
        je      .hit

        cmp     al, SC_BACKSPACE
        jne     .chain

        ; Our own tracking first; fall back to the BIOS flags for the case
        ; where we were installed after the modifiers were already down.
        mov     al, [cs:kf_own]
        and     al, KF_CTRL | KF_ALT
        cmp     al, KF_CTRL | KF_ALT
        je      .hit

        push    bx
        mov     ax, 40h
        mov     ds, ax
        mov     al, [17h]               ; BIOS shift flags
        pop     bx
        and     al, KF_CTRL | KF_ALT
        cmp     al, KF_CTRL | KF_ALT
        jne     .chain
.hit:

        ; Hotkey hit. Acknowledge the keyboard, EOI the PIC, and do not chain,
        ; so the keystroke is swallowed rather than reaching the game.
        in      al, 61h
        mov     ah, al
        or      al, 80h
        out     61h, al
        mov     al, ah
        out     61h, al
        mov     al, 20h
        out     20h, al

        mov     byte [cs:pending], 1
        call    try_abort_irq           ; the path that runs during a game

        pop     ds
        pop     ax
        iret

.chain:
        pop     ds
        pop     ax
        jmp     far [cs:old09]

;------------------------------------------------------------------------------
; INT 08h — timer. Keyboard-vector watchdog (only hooked when /W is given).
;
; Games that install their own INT 09h and never chain stop calling us, and the
; hotkey goes dead. Eighteen times a second, check whether INT 09h still points
; here; if not, adopt whatever took it as the chain target and get back in front.
;
; The vector table is edited directly because INT 21h is not safe to call from a
; timer interrupt.
;------------------------------------------------------------------------------
int08:
        pushf
        call    far [cs:old08]          ; keep system timing intact first

        push    ax
        push    bx
        push    dx
        push    ds

        mov     dx, cs
        xor     ax, ax
        mov     ds, ax
        mov     ax, [24h]               ; INT 09h offset
        mov     bx, [26h]               ; INT 09h segment
        cmp     bx, dx
        jne     .grab
        cmp     ax, int09
        je      .out
.grab:
        cmp     byte [cs:counting], 0
        je      .grab_go
        inc     word [cs:wd_grabs]
.grab_go:
        mov     [cs:old09], ax
        mov     [cs:old09+2], bx
        cli
        mov     word [24h], int09
        mov     [26h], dx
        sti
.out:
        pop     ds
        pop     dx
        pop     bx
        pop     ax
        iret

;------------------------------------------------------------------------------
; Point INT 09h back at us, chaining to the handler that existed at install.
; Used before terminating a game (whose handler is about to be freed) and via
; INT 2Fh AB01h, which BROWSER.COM calls after a game exits normally.
;------------------------------------------------------------------------------
reset_kbd_chain:
        push    ax
        push    dx
        push    ds

        mov     ax, [cs:orig09]
        mov     [cs:old09], ax
        mov     ax, [cs:orig09+2]
        mov     [cs:old09+2], ax

        mov     dx, cs
        xor     ax, ax
        mov     ds, ax
        cli
        mov     word [24h], int09
        mov     [26h], dx
        sti

        pop     ds
        pop     dx
        pop     ax
        ret

;------------------------------------------------------------------------------
; INT 28h — DOS idle; retry pending abort
;------------------------------------------------------------------------------
int28:
        cmp     byte [cs:pending], 0
        je      .chain
        call    try_abort_idle
.chain:
        jmp     far [cs:old28]

;------------------------------------------------------------------------------
; try_abort — if pending and DOS is safe to enter, terminate current process.
;
; The safe InDOS value differs by caller, which is why there are two entries:
;   from INT 09h  DOS must be completely free      (InDOS == 0)
;   from INT 28h  DOS is idling inside a call      (InDOS <= 1)
;
; Requiring InDOS == 0 on the INT 28h path is what made this a no-op: INT 28h
; is issued from within a DOS call, so InDOS is never 0 there.
;------------------------------------------------------------------------------
try_abort_irq:
        push    ax
        mov     al, 0
        call    try_abort
        pop     ax
        ret

try_abort_idle:
        push    ax
        mov     al, 1
        call    try_abort
        pop     ax
        ret

; AL = highest InDOS value considered safe.
try_abort:
        push    ax
        push    bx
        push    ds
        push    es
        mov     ah, al                  ; threshold

        cmp     byte [cs:busy], 0
        jne     .out
        cmp     byte [cs:pending], 0
        je      .out

        mov     ds, [cs:indos_seg]
        mov     bx, [cs:indos_off]
        mov     al, [bx]
        cmp     al, ah
        ja      .out

        mov     byte [cs:busy], 1
        mov     byte [cs:pending], 0

        ; The game we are about to kill may own INT 09h. Drop its handler from
        ; our chain now, or the vector would point into freed memory.
        call    reset_kbd_chain

        ; Critical: enable interrupts for DOS
        sti

        ; Terminate the current PSP. When a game was EXECed by BROWSER the
        ; current PSP is the game, so 4Ch returns control to BROWSER's EXEC.
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
msg_ok          db      'ABORT resident: F12 or Ctrl+Alt+Backspace force-exits game.',13,10,'$'
msg_already     db      'ABORT already installed.',13,10,'$'
msg_wd          db      'Watchdog on: reclaiming INT 09h from games.',13,10,'$'
