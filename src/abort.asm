;==============================================================================
; ABORT.COM — Resident force-exit hotkey for kiosk / booth use
;
; Installs as a TSR. While a game is running under the browser:
;   The abort key (Scroll Lock by default), or Ctrl + Alt + Backspace
;                                   →  terminate current process
;
; The single key is configurable, because a game may want that key for play.
; Put ABORT_KEY in DGB.CFG next to BROWSER.COM:
;
;   ABORT_KEY=SCRLOCK    a name from keynames.inc
;   ABORT_KEY=F11        F1 to F12 by number
;   ABORT_KEY=5B         or any raw make-code, in hex
;
; ABORT.COM /K:F11 overrides it for one run. The name table, the parser and the
; config reader all sit below resident_end and are discarded when the TSR
; installs, so names and parsing cost file size only - the resident image is
; the same size with them as without.
;
; The key needs no modifier, so it still works when a game's own keyboard
; handler has left the Ctrl/Alt state inconsistent. Scroll Lock is the default
; because no game in the test catalog reads it, and unlike F11/F12 it is
; present on an 83-key XT keyboard.
;
; Safe for real 8086/286/386 MS-DOS and DOSBox. Calls DOS only when InDOS
; is clear (or via INT 28h idle). Chains prior INT 09h / INT 28h handlers.
;
; Two optional timer-hooked modes, both off by default:
;
;   /W  watchdog - sample, and take INT 09h back from a game that seizes it.
;       Risky per game: it puts this handler in front of one that expects
;       exclusive keyboard control. Stealing the vector back this way once
;       stopped Commander Keen from starting at all.
;   /P  probe - sample only, never touch the vector. Changes nothing about how
;       a game runs, so it is the safe one to leave on while diagnosing.
;
; UNRESOLVED: Digger Remastered never sees the hotkey. Commander Keen, Jill and
; Sopwith are all fine. The measured reading is
;
;   scancodes=2 last=FA grabs=0 irq1off=0
;
; which is not yet explained. grabs=0 says the vector stayed ours and irq1off=0
; says IRQ1 was never masked at the PIC, so the handler was installed and
; reachable and still saw almost nothing. Draining port 60h in a polling loop
; does not account for that on its own: reading the port does not clear the
; request latched in the 8259, so this handler should still have been entered.
;
; last=FA is the keyboard's ACK to a command, so Digger does talk to the
; hardware directly. The leading theory is that it tells the 8042 to stop
; raising IRQ1 and then polls - which every counter above would report as
; innocent, because it is the controller and not the PIC that went quiet. The
; KBC line exists to test exactly that; see docs/DIAGNOSTICS.md.
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
; Scroll Lock is the default trigger: no game in the test catalog reads it, and
; unlike F11/F12 it exists on an 83-key XT keyboard, so the default works on the
; oldest hardware this runs on.
SC_SCRLOCK      equ     46h

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
        cmp     al, 'k'
        je      .keyarg
        cmp     al, 'p'
        je      .probearg
        cmp     al, 'w'
        jne     .next
        mov     byte [reclaim], 1       ; /W also takes the vector back
.probearg:
        mov     byte [watchdog], 1      ; /P only watches and samples
        jmp     .next
.keyarg:
        ; /K:F11 or /K=5B - overrides DGB.CFG for this run
        push    si
        add     si, 2
        cmp     byte [si], ':'
        je      .keyskip
        cmp     byte [si], '='
        jne     .keybad
.keyskip:
        inc     si
        call    parse_key
        jc      .keybad
        mov     [abort_key], al
        mov     byte [key_from_arg], 1
.keybad:
        pop     si
        jmp     .next
.next:  inc     si
        dec     cx
        jnz     .scan
.noargs:
        cmp     byte [key_from_arg], 0
        jne     .key_done
        call    read_cfg_key            ; ABORT_KEY= in DGB.CFG, if present
.key_done:

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

        ; Take one reading now, before any game has run. Without it a dash in
        ; the KBC line is ambiguous - it could mean "no game started" or "this
        ; machine will not answer the query" - and those need different
        ; conclusions. AB03h overwrites this at each game start.
        call    kbc_read
        jc      .no_base
        mov     [kbc_base], al
        or      byte [kbc_ok], 1
.no_base:

        mov     dx, msg_ok
        mov     ah, 09h
        int     21h
        cmp     byte [watchdog], 0
        je      .banner_done
        mov     dx, msg_probe
        cmp     byte [reclaim], 0
        je      .banner_msg
        mov     dx, msg_wd
.banner_msg:
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
watchdog        db      0               ; 1 = INT 08h hooked (/W or /P)
reclaim         db      0               ; 1 = /W: also take INT 09h back

; 8042 keyboard-controller command byte, sampled around a game. Bit 0 is the
; keyboard interrupt enable: a game that clears it stops IRQ1 being raised at
; all, and then no INT 09h handler can see the keyboard however firmly it holds
; the vector. That is invisible in every other counter here -- the PIC mask
; reads clear, the vector reads ours -- which is why it gets its own sample.
kbc_base        db      0               ; read at game start, before EXEC
kbc_game        db      0               ; first successful in-game sample
kbc_last        db      0               ; most recent in-game sample
kbc_ok          db      0               ; bit0 base, bit1 game, bit2 last
kbc_next        db      0               ; ticks until the next sample
wd_grabs        dw      0               ; times the watchdog reclaimed INT 09h
counting        db      1               ; gate so a reading can cover one game
indos_blk       dw      0               ; times an abort was recognised but DOS
                                        ; was too busy to enter
irq1_off        dw      0               ; timer ticks seen with IRQ1 masked at
                                        ; the PIC (a game polling the keyboard
                                        ; itself); needs /W to be sampled
wd_ticks        dw      0               ; timer ticks our watchdog actually ran.
                                        ; Zero means the game owns INT 08h too,
                                        ; which makes the other two meaningless.
old28           dd      0
old2f           dd      0
indos_off       dw      0
indos_seg       dw      0
pending         db      0               ; 1 = abort requested
busy            db      0               ; set while terminating; cleared by
                                        ; INT 2Fh AB01h/AB03h when the browser
                                        ; regains control. Without that the
                                        ; hotkey only ever fires once.
abort_key       db      SC_SCRLOCK      ; the configured single-key trigger
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
        cmp     ax, 0AB06h              ; watchdog tick count
        je      .ticks
        cmp     ax, 0AB07h              ; which key is the abort key
        je      .whichkey
        cmp     ax, 0AB08h              ; 8042 command byte samples
        je      .kbcrep
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
        mov     word [cs:indos_blk], 0
        mov     word [cs:irq1_off], 0
        mov     word [cs:wd_ticks], 0
        mov     byte [cs:counting], 1

        ; Baseline the controller before the game gets a chance to touch it.
        ; Taken here, outside any interrupt, where nothing is competing for the
        ; output buffer; the in-game samples come from the timer tick.
        mov     byte [cs:kbc_ok], 0
        mov     byte [cs:kbc_next], 36  ; ~2s, after the game has set itself up
        call    kbc_read
        jc      .zero_done
        mov     [cs:kbc_base], al
        or      byte [cs:kbc_ok], 1
.zero_done:
        mov     al, 0ABh
        iret
.stop:                                  ; AB04h: stop, so the reading is frozen
        mov     byte [cs:counting], 0
        mov     al, 0ABh
        iret
.ticks:                                 ; AB06h: BX = watchdog ticks
        mov     bx, [cs:wd_ticks]
        mov     al, 0ABh
        iret
.whichkey:                              ; AB07h: BL = the configured scancode
        mov     bl, [cs:abort_key]
        mov     al, 0ABh
        iret
.kbcrep:                                ; AB08h: the 8042 command byte samples
        ; BL = at game start, BH = first in-game, CL = last in-game,
        ; CH = which of those are valid (bit0/bit1/bit2).
        mov     bl, [cs:kbc_base]
        mov     bh, [cs:kbc_game]
        mov     cl, [cs:kbc_last]
        mov     ch, [cs:kbc_ok]
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
        cmp     byte [cs:busy], 0       ; SI low = armed, SI high = pending
        je      .diag_armed
        xor     si, si
.diag_armed:
        cmp     byte [cs:pending], 0
        je      .diag_pend
        or      si, 0100h
.diag_pend:
        mov     di, [cs:indos_blk]
        mov     bp, [cs:irq1_off]
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
        ; The configured key fires on its own. Needing no modifier means it
        ; still works when a game's own handler has mangled the Ctrl/Alt state.
        cmp     al, [cs:abort_key]
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

        cmp     byte [cs:counting], 0
        je      .nomask
        inc     word [cs:wd_ticks]      ; prove the watchdog is running at all

        ; Is the game polling the keyboard with IRQ1 masked off? If so no
        ; keyboard interrupt happens at all and no handler can see keys.
        in      al, 21h                 ; PIC 1 interrupt mask
        test    al, 02h                 ; bit 1 = IRQ1 (keyboard)
        jz      .kbc
        inc     word [cs:irq1_off]

        ; About once a second, sample the controller's command byte. The PIC
        ; mask above only catches a game that masks IRQ1; a game that instead
        ; tells the 8042 to stop raising it looks completely innocent here.
.kbc:   dec     byte [cs:kbc_next]
        jnz     .nomask
        mov     byte [cs:kbc_next], 18
        call    kbc_read
        jc      .nomask                 ; controller busy; try again next tick
        mov     [cs:kbc_last], al
        or      byte [cs:kbc_ok], 4
        test    byte [cs:kbc_ok], 2
        jnz     .nomask
        mov     [cs:kbc_game], al       ; first in-game reading, kept separately
        or      byte [cs:kbc_ok], 2
.nomask:

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
        ; /P watches without touching anything: wd_grabs then counts ticks on
        ; which the vector was somebody else's, rather than times we took it
        ; back. Only /W actually reclaims.
        cmp     byte [cs:reclaim], 0
        je      .out

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
; kbc_read - AL = the 8042 command byte. CF=1 if it could not be read.
;
; Diagnosing a game must not change how it plays, so this refuses to run unless
; the controller is idle in both directions. If a scancode is already sitting in
; the output buffer we skip the sample entirely rather than consume a keystroke
; the game is polling for.
;
; An XT has no 8042 at all; port 64h floats high there, so the first test sees
; both busy bits set and gives up immediately, which is the right answer.
;------------------------------------------------------------------------------
kbc_read:
        push    cx

        in      al, 64h
        test    al, 03h                 ; bit0 output full, bit1 input full
        jnz     .busy

        mov     al, 20h                 ; "read command byte"
        out     64h, al

        ; Bounded wait: this runs inside a timer interrupt, so never spin on
        ; hardware that is not going to answer.
        mov     cx, 1000
.wait:  in      al, 64h
        test    al, 01h
        jnz     .got
        loop    .wait
        jmp     .busy

.got:   in      al, 60h
        pop     cx
        clc
        ret

.busy:  pop     cx
        stc
        ret

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
        jbe     .go
        cmp     byte [cs:counting], 0   ; recognised, but DOS was busy
        je      .out
        inc     word [cs:indos_blk]
        jmp     .out
.go:

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
; Transient: parsing helpers and messages. Everything below resident_end runs
; during installation and is then discarded, so it costs file size only.
;------------------------------------------------------------------------------
; parse_key - SI = text, returns AL = make-code. CF=1 if unrecognised.
; Accepts a name from keynames.inc, F1..F12, or a one or two digit hex
; make-code. The whole token must be consumed, so "banana" is rejected rather
; than read as BAh.
;
; Names are tried first because several of them start with a hex digit or an F
; - DEL, END, ESC - and would otherwise be read as numbers.
parse_key:
        push    bx
        push    cx
        push    dx
        push    si

        call    lookup_name
        jnc     .ok

        mov     al, [si]
        or      al, 20h
        cmp     al, 'f'
        jne     .hex

        inc     si
        xor     cx, cx
        xor     bx, bx                  ; digit count
.fdig:  mov     al, [si]
        cmp     al, '0'
        jb      .fdone
        cmp     al, '9'
        ja      .fdone
        sub     al, '0'
        mov     dx, cx
        add     cx, cx                  ; x2
        add     cx, cx                  ; x4
        add     cx, dx                  ; x5
        add     cx, cx                  ; x10
        xor     ah, ah
        add     cx, ax
        inc     bx
        inc     si
        cmp     bx, 2
        ja      .bad
        jmp     .fdig
.fdone:
        or      bx, bx
        jz      .bad
        call    at_end                  ; nothing may follow the number
        jc      .bad
        or      cx, cx
        jz      .bad
        cmp     cx, 12
        ja      .bad
        mov     bx, cx
        dec     bx
        mov     al, [fkey_tab + bx]
        jmp     .ok

.hex:   xor     cx, cx
        xor     bx, bx
.hdig:  mov     al, [si]
        call    hexval
        jc      .hdone
        mov     ah, cl
        mov     cl, 4
        shl     ah, cl
        mov     cl, ah
        or      cl, al
        inc     bx
        inc     si
        cmp     bx, 2
        ja      .bad
        jmp     .hdig
.hdone:
        or      bx, bx
        jz      .bad
        call    at_end                  ; reject trailing rubbish
        jc      .bad
        mov     al, cl
        or      al, al
        jz      .bad
.ok:    clc
        pop     si
        pop     dx
        pop     cx
        pop     bx
        ret
.bad:   stc
        pop     si
        pop     dx
        pop     cx
        pop     bx
        ret

; lookup_name - SI = text. Returns AL = make-code and CF=0 if the whole token
; is a name from keynames.inc, CF=1 otherwise. SI is preserved either way, so a
; miss costs the caller nothing.
;
; Matching is case-insensitive and must consume the token: SCRLOCK matches,
; SCRLOCKS does not. Folding stops naturally at the token terminator, because a
; terminator folds to a value no letter can equal.
lookup_name:
        push    bx
        push    cx
        push    dx
        push    si

        mov     dx, si                  ; token start, to restart each entry
        mov     bx, keyname_tab
.entry:
        cmp     byte [bx], 0
        je      .nomatch                ; end of table
        mov     si, dx
.cmp:   mov     al, [bx]
        or      al, al
        jz      .endname
        mov     ah, [si]
        or      ah, 20h                 ; fold the input
        mov     cl, al
        or      cl, 20h                 ; fold the table entry
        cmp     ah, cl
        jne     .skip
        inc     bx
        inc     si
        jmp     .cmp

.endname:
        ; The name ran out. Unless the token ends here too this is a prefix
        ; match - UP against UPPER - and must not count.
        call    at_end
        jc      .next
        mov     al, [bx+1]              ; the code byte follows the NUL
        clc
        jmp     .out

.skip:  cmp     byte [bx], 0            ; walk to the end of this name
        je      .next
        inc     bx
        jmp     .skip
.next:  inc     bx                      ; past the NUL
        inc     bx                      ; past the code
        jmp     .entry

.nomatch:
        stc
.out:   pop     si
        pop     dx
        pop     cx
        pop     bx
        ret

; at_end - CF=0 when SI is at the end of a config value or argument.
at_end:
        push    ax
        mov     al, [si]
        cmp     al, 0
        je      .yes
        cmp     al, 13
        je      .yes
        cmp     al, 10
        je      .yes
        cmp     al, ' '
        je      .yes
        cmp     al, 9
        je      .yes
        cmp     al, ';'
        je      .yes
        cmp     al, '#'
        je      .yes
        pop     ax
        stc
        ret
.yes:   pop     ax
        clc
        ret

; hexval - AL = character, returns AL = 0..15. CF=1 if not a hex digit.
hexval:
        cmp     al, '0'
        jb      .no
        cmp     al, '9'
        ja      .alpha
        sub     al, '0'
        clc
        ret
.alpha: or      al, 20h
        cmp     al, 'a'
        jb      .no
        cmp     al, 'f'
        ja      .no
        sub     al, 'a' - 10
        clc
        ret
.no:    stc
        ret

; read_cfg_key - look for ABORT_KEY= in DGB.CFG in the current directory.
; Runs before the TSR goes resident, so none of this stays in memory.
read_cfg_key:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     ax, 3D00h
        mov     dx, cfg_name
        int     21h
        jc      .out
        mov     bx, ax

        push    bx
        mov     ah, 3Fh
        mov     cx, CFGBUF_MAX
        mov     dx, cfgbuf
        int     21h
        pop     bx
        jc      .close
        mov     si, cfgbuf
        add     si, ax
        mov     byte [si], 0
.close:
        mov     ah, 3Eh
        int     21h

        ; line by line, so a commented-out key cannot win
        mov     si, cfgbuf
.line:  cmp     byte [si], 0
        je      .out
.lsp:   mov     al, [si]
        cmp     al, ' '
        je      .lsp_adv
        cmp     al, 9
        jne     .lchk
.lsp_adv:
        inc     si
        jmp     .lsp
.lchk:  cmp     al, 0
        je      .out
        cmp     al, ';'
        je      .next_line
        cmp     al, '#'
        je      .next_line
        cmp     al, 13
        je      .next_line
        cmp     al, 10
        je      .next_line

        mov     di, cfg_keyname
        push    si
        call    match_lit_ci
        jc      .found
        pop     si
.next_line:
        mov     al, [si]
        cmp     al, 0
        je      .out
        inc     si
        cmp     al, 10
        je      .line
        jmp     .next_line

.found:
        add     sp, 2
.vsp:   mov     al, [si]
        cmp     al, ' '
        je      .vsp_adv
        cmp     al, 9
        jne     .parse
.vsp_adv:
        inc     si
        jmp     .vsp
.parse:
        call    parse_key
        jc      .out
        mov     [abort_key], al
.out:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; match_lit_ci - DI = literal, SI = text. CF=1 and SI advanced on a match.
match_lit_ci:
        push    ax
        push    bx
.m1:    mov     al, [di]
        cmp     al, 0
        je      .ok
        mov     bl, [si]
        or      al, 20h
        or      bl, 20h
        cmp     bl, al
        jne     .bad
        inc     si
        inc     di
        jmp     .m1
.ok:    stc
        pop     bx
        pop     ax
        ret
.bad:   clc
        pop     bx
        pop     ax
        ret


msg_ok          db      'ABORT resident: force-exit hotkey armed.',13,10,'$'
msg_already     db      'ABORT already installed.',13,10,'$'

; --- transient: used while parsing, gone once resident --------------------
CFGBUF_MAX      equ     2048
key_from_arg    db      0
cfg_name        db      'DGB.CFG',0
cfg_keyname     db      'ABORT_KEY=',0
fkey_tab        db      3Bh,3Ch,3Dh,3Eh,3Fh,40h     ; F1..F6
                db      41h,42h,43h,44h,57h,58h     ; F7..F12

%include        "keynames.inc"

cfgbuf          times CFGBUF_MAX+2 db 0
msg_wd          db      'Watchdog on: reclaiming INT 09h from games.',13,10,'$'
msg_probe       db      'Probe on: sampling the keyboard controller, changing nothing.',13,10,'$'
