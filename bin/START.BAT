@ECHO OFF
REM DOS Game Browser kiosk entrypoint (real hardware / CF media)
REM Run from the launcher directory (for example C:\DGB\)
IF EXIST UTILS\ABORT.COM UTILS\ABORT.COM
:LOOP
BROWSER.COM
IF ERRORLEVEL 42 GOTO DONE
IF ERRORLEVEL 1 GOTO FAIL
GOTO LOOP
:FAIL
ECHO.
ECHO Browser exited with an error. Check GAMES.LST and game paths.
:DONE
