@ECHO OFF
REM DOS Game Browser kiosk entrypoint (real hardware / CF media)
REM Run from the launcher directory (for example C:\DGB\)
IF EXIST UTILS\ABORT.COM UTILS\ABORT.COM
:LOOP
BROWSER.COM
GOTO LOOP
