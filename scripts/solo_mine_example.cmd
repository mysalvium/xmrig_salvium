:: Example batch file for mining Salvium mainnet solo
::
:: Format:
::	xmrig.exe -o <node address>:19081 --coin SAL -a rx/0 -u <SC1 wallet> --daemon
::
:: Fields:
::	node address		The IP address of your fully synced Salvium daemon
::	node port		Salvium mainnet RPC normally uses port 19081
::	SAL_WALLET		Your primary Salvium Carrot address, beginning with SC1
::
:: The example assumes salviumd runs on this machine. Do not expose an
:: unrestricted daemon RPC port to the public internet.

cd /d "%~dp0"
set "SAL_WALLET=YOUR_PRIMARY_SC1_CARROT_ADDRESS"

xmrig.exe -o 127.0.0.1:19081 --coin SAL -a rx/0 -u %SAL_WALLET% --daemon
pause
