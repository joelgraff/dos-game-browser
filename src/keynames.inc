;==============================================================================
; keynames.inc - key names and their make-codes, shared by two programs.
;
; ABORT.COM reads it one way (name -> code, parsing ABORT_KEY from DGB.CFG),
; BROWSER.COM the other (code -> name, rendering the on-screen hint). One table
; so the two cannot drift apart and disagree about what a name means.
;
; Each entry is an uppercase name, a NUL, then the make-code. A zero byte where
; a name would start ends the table. Where one code has several names the
; canonical one comes first, because the display takes the first match.
;
; F1..F12 are deliberately absent: both files generate those names from the
; number, so there is nothing here to keep in step.
;
; Everything here is looked up once - at install time in ABORT.COM, at startup
; in BROWSER.COM - so the table costs bytes and no run-time work.
;==============================================================================
keyname_tab:
        db      'ESC',0,        01h
        db      'BKSP',0,       0Eh
        db      'BACKSPACE',0,  0Eh     ; alias, spelled the obvious way
        db      'TAB',0,        0Fh
        db      'ENTER',0,      1Ch
        db      'GRAVE',0,      29h
        db      'BACKTICK',0,   29h     ; alias
        db      'TILDE',0,      29h     ; alias, same physical key
        db      'PRTSC',0,      37h
        db      'SPACE',0,      39h
        db      'CAPSLOCK',0,   3Ah
        db      'NUMLOCK',0,    45h
        db      'SCRLOCK',0,    46h
        db      'SCROLLLOCK',0, 46h     ; alias
        db      'HOME',0,       47h
        db      'UP',0,         48h
        db      'PGUP',0,       49h
        db      'LEFT',0,       4Bh
        db      'RIGHT',0,      4Dh
        db      'END',0,        4Fh
        db      'DOWN',0,       50h
        db      'PGDN',0,       51h
        db      'INS',0,        52h
        db      'DEL',0,        53h
        db      0
