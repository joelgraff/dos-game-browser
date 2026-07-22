;==============================================================================
; VDETECT.COM — Detect MDA/CGA/EGA/VGA and write VIDEO.CFG
;
; Usage (optional helper for multi-profile launchers):
;   VDETECT.COM
; Prints: VIDEO=MDA|CGA|EGA|VGA
; Writes: VIDEO.CFG  with  MODE=...
;
; Detection order:
;   1. INT 10h AH=1Ah (VGA/MCGA display combination) → VGA
;   2. INT 10h AH=12h BL=10h (EGA info) → EGA if BL returns 00..0F
;   3. INT 10h AH=0Fh mode 7, or BDA equipment mono → MDA
;   4. else CGA
;
; nasm -f bin -o VDETECT.COM vdetect.asm
;==============================================================================

        bits    16
        cpu     8086
        org     100h

start:
        push    cs
        pop     ds

        ; --- VGA/MCGA? INT 10h AH=1Ah ---
        mov     ax, 1A00h
        int     10h
        cmp     al, 1Ah
        jne     .try_ega
        mov     byte [mode_id], 4       ; VGA
        mov     si, name_vga
        jmp     .announce

.try_ega:
        ; --- EGA? INT 10h AH=12h BL=10h ---
        mov     ah, 12h
        mov     bl, 10h
        int     10h
        cmp     bl, 10h                 ; BL unchanged → not EGA
        je      .try_mda
        mov     byte [mode_id], 3       ; EGA
        mov     si, name_ega
        jmp     .announce

.try_mda:
        ; Current video mode 7 → mono
        mov     ah, 0Fh
        int     10h
        cmp     al, 7
        je      .is_mda
        ; Equipment word bits 4-5 == 11b → mono adapter
        mov     ax, 40h
        mov     es, ax
        mov     al, [es:10h]
        and     al, 30h
        cmp     al, 30h
        je      .is_mda
        mov     byte [mode_id], 2       ; CGA
        mov     si, name_cga
        jmp     .announce

.is_mda:
        mov     byte [mode_id], 1       ; MDA
        mov     si, name_mda

.announce:
        ; Print "VIDEO=" + name + CRLF via DOS AH=09
        mov     dx, msg_video
        mov     ah, 09h
        int     21h

        mov     di, outbuf
.copy:  lodsb
        cmp     al, 0
        je      .cend
        stosb
        jmp     .copy
.cend:  mov     al, '$'
        stosb
        mov     dx, outbuf
        mov     ah, 09h
        int     21h

        mov     dx, msg_crlf
        mov     ah, 09h
        int     21h

        call    write_cfg

        mov     al, [mode_id]
        mov     ah, 4Ch
        int     21h

;------------------------------------------------------------------------------
; Create/overwrite VIDEO.CFG with MODE=<name>\r\n
;------------------------------------------------------------------------------
write_cfg:
        mov     ah, 3Ch                 ; creat
        xor     cx, cx                  ; normal attr
        mov     dx, fname
        int     21h
        jc      .fail
        mov     [handle], ax

        ; write "MODE="
        mov     dx, mode_eq
        mov     cx, 5
        mov     bx, [handle]
        mov     ah, 40h
        int     21h

        ; pick name pointer from mode_id
        mov     si, name_mda
        cmp     byte [mode_id], 1
        je      .wn
        mov     si, name_cga
        cmp     byte [mode_id], 2
        je      .wn
        mov     si, name_ega
        cmp     byte [mode_id], 3
        je      .wn
        mov     si, name_vga
.wn:
        mov     di, outbuf
        xor     cx, cx
.wcopy: lodsb
        cmp     al, 0
        je      .wdone
        stosb
        inc     cx
        jmp     .wcopy
.wdone: mov     al, 13
        stosb
        mov     al, 10
        stosb
        add     cx, 2

        mov     dx, outbuf
        mov     bx, [handle]
        mov     ah, 40h
        int     21h

        mov     bx, [handle]
        mov     ah, 3Eh
        int     21h
.fail:  ret

;------------------------------------------------------------------------------
; Data (layout matches original VDETECT.COM strings)
;------------------------------------------------------------------------------
handle          dw      0
mode_id         db      0
                times 14 db 0           ; pad so strings land similarly

outbuf          times 16 db 0

msg_video       db      'VIDEO=$'
msg_crlf        db      13,10,'$'
fname           db      'VIDEO.CFG',0
mode_eq         db      'MODE='
name_mda        db      'MDA',0
name_cga        db      'CGA',0
name_ega        db      'EGA',0
name_vga        db      'VGA',0
