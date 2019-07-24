echo  on
echo %time% : Install Msys2
choco install -y --no-progress msys2
SET "PATH=%WIN_MSYS2_ROOT%\mingw64\bin;%WIN_MSYS2_ROOT%\usr\bin;%PATH%"
echo %time% : Install Erlang
choco install -y --no-progress erlang --version=20.3
SET "PATH=%WIN_OTP_PATH%\bin;%WIN_OTP_PATH%\erts-%OTP_VERSION%\bin;%WIN_OTP_PATH%\erts-%OTP_VERSION%;%PATH%"
git config --global --unset url."ssh://git@github.com".insteadOf "https://github.com"
echo %time% : Prepare ENV
call %USERPROFILE%\project\scripts\windows\msys2_prepare.bat
echo %time% : Find and execute the VS env preparation script
FOR /F "usebackq delims=" %%F IN (`where /f /r "C:\Program Files (x86)\Microsoft Visual Studio" vcvarsall`) DO SET vcvarsall=%%F
call %vcvarsall% x64
echo %time% : Build Node
cd %USERPROFILE%\project\
make
echo %time% : Package
call %USERPROFILE%\project\ci\appveyor\package.bat
exit /b 0
