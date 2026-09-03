:: Example batch file for mining Salvium at a pool
::
:: Format:
::	xmrig.exe --coin SAL -a rx/0 -o <pool>:<port> -u <SC1 wallet>.<worker> -p x -k
::
:: Fields:
::	SAL_WALLET		Your primary Salvium Carrot address, beginning with SC1
::	WORKER_NAME		A short name for this machine, without spaces
::
:: The first pool is the primary. XMRig uses the independently operated
:: second pool if the first is unavailable. Both endpoints were confirmed
:: with login-only mainnet checks on 2026-07-24.

cd /d "%~dp0"
set "SAL_WALLET=YOUR_PRIMARY_SC1_CARROT_ADDRESS"
set "WORKER_NAME=YOUR_WORKER_NAME"

xmrig.exe --coin SAL -a rx/0 ^
  -o sal-us.kryptex.network:7028 -u %SAL_WALLET%.%WORKER_NAME% -p x -k ^
  -o stratum-eu.rplant.xyz:7130 -u %SAL_WALLET%.%WORKER_NAME% -p x -k
pause
