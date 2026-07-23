        push    si
        mov     si, di
        call    ent_addr_ax
        mov     byte [di], 0
        push    di
        add     si, 2
        mov     bx, di
        add     bx, OFF_DIR
        mov     di, bx
        mov     cx, DLEN
        call    store_pipe
        pop     bx
        push    bx
        mov     di, bx
        add     di, OFF_EXE
        mov     cx, ELEN
        call    store_pipe
        pop     bx
        push    bx
        mov     di, bx
        add     di, OFF_TITLE
        mov     cx, TLEN
        call    store_pipe
        pop     bx
        push    bx
        mov     di, bx
        add     di, OFF_YEAR
        mov     cx, YLEN
        call    store_pipe
        pop     bx
        push    bx
        mov     di, bx
        add     di, OFF_GENRE
        mov     cx, GLEN
        call    store_pipe
        pop     bx
        push    bx
        mov     di, bx
        add     di, OFF_PUB
        mov     cx, PLEN
        call    store_pipe
        pop     bx
        mov     di, bx
        add     di, OFF_NOTE
        mov     cx, NLEN
        call    store_str
        inc     word [n_ent]
        pop     si
        jmp     .loop
.done:
        clc
        ret
.fail_rd:
        mov     ah, 3Eh
        mov     bx, [fh]
        int     21h
        stc
        ret

next_line:
        mov     [lineptr], si
        cmp     byte [si], 0
        jne     .nl1
        stc
        ret
.nl1:   mov     al, [si]
        cmp     al, 0
        je      .nl_eof
        cmp     al, 13
        je      .nl_cr
        cmp     al, 10
        je      .nl_lf
        inc     si
        jmp     .nl1
.nl_cr: mov     byte [si], 0
        inc     si
        cmp     byte [si], 10
        jne     .nl_ok
        inc     si
        jmp     .nl_ok
.nl_lf: mov     byte [si], 0
        inc     si
.nl_ok: clc
        ret
.nl_eof:
        mov     byte [si], 0
        clc
        ret

; SI points to field start, DI dest, CX max, stops at | or 0
store_pipe:
.sp1:   lodsb
        cmp     al, 0
        je      .sp3
        cmp     al, '|'
        je      .sp2
        or      cx, cx
        jz      .sp1
        stosb
        dec     cx
        jmp     .sp1
.sp2:   xor     al, al
        stosb
        ret
.sp3:   xor     al, al
        stosb
        ret

; SI string to end of line, DI dest, CX max
store_str:
.ss1:   lodsb
        cmp     al, 0
        je      .ss2
        or      cx, cx
        jz      .ss1
        stosb
        dec     cx
        jmp     .ss1
.ss2:   xor     al, al
        stosb
        ret

ent_addr_ax:
        push    ax
        push    cx
        push    dx
        mov     cx, ENT_SIZE
        mul     cx
        mov     di, entries
        add     di, ax
        pop     dx
        pop     cx
        pop     ax
        ret

;------------------------------------------------------------------------------
; Navigation
;------------------------------------------------------------------------------
; CF=1 if not a playable game (section header type 1 or blank spacer type 2)
is_hdr:
        push    ax
        push    cx
        push    dx
        push    si
        mov     ax, bx
        mov     cx, ENT_SIZE
        mul     cx
        mov     si, entries
        add     si, ax
        cmp     byte [si], 0
        pop     si
        pop     dx
        pop     cx
        pop     ax
        je      .ih0
        stc
        ret
.ih0:   clc
        ret

; CF=1 if section header (type 1) — for yellow label / show_with_header
is_sect:
        push    ax
        push    cx
        push    dx
        push    si
        mov     ax, bx
        mov     cx, ENT_SIZE
        mul     cx
        mov     si, entries
        add     si, ax
        cmp     byte [si], 1
        pop     si
        pop     dx
        pop     cx
        pop     ax
        jne     .is0
        stc
        ret
.is0:   clc
        ret

first_game:
        xor     ax, ax
.fg:    cmp     ax, [n_ent]
        jae     .fgn
        mov     bx, ax
        call    is_hdr
        jnc     .fgo
        inc     ax
        jmp     .fg
.fgn:   xor     ax, ax
.fgo:   ret

next_game:
.ng:    inc     ax
        cmp     ax, [n_ent]
        jae     .ngn
        mov     bx, ax
        call    is_hdr
        jnc     .ngo
        jmp     .ng
.ngn:   mov     ax, 0FFFFh
.ngo:   ret

prev_game:
.pg:    cmp     ax, 0
        je      .pgf
        dec     ax
        mov     bx, ax
        call    is_hdr
        jnc     .pgo
        jmp     .pg
.pgf:   call    first_game
.pgo:   ret

last_game:
        mov     ax, [n_ent]
        or      ax, ax
        jz      .lgn
        dec     ax
.lg:    mov     bx, ax
        call    is_hdr
        jnc     .lgo
        or      ax, ax
        jz      .lgn
        dec     ax
        jmp     .lg
.lgn:   call    first_game
.lgo:   ret

jump_let:
        mov     dl, [jch]
        and     dl, 0DFh
        xor     ax, ax
.jl:    cmp     ax, [n_ent]
        jae     .jld
        mov     bx, ax
        call    is_hdr
        jc      .jln
        push    ax
        push    dx
        mov     ax, bx
        mov     cx, ENT_SIZE
        mul     cx
        mov     si, entries
        add     si, ax
        mov     al, [si+OFF_TITLE]
        and     al, 0DFh
        pop     dx
        cmp     al, dl
        pop     ax
        jne     .jln
        mov     [cur], bx
        call    show_with_header
        ret
.jln:   inc     ax
        jmp     .jl
.jld:   ret

; Include blank spacer + section header above current game when possible
show_with_header:
        mov     ax, [cur]
        or      ax, ax
        jz      .sw0
        call    find_sect_above         ; BX = header index or FFFF
        cmp     bx, 0FFFFh
        je      .sw1
