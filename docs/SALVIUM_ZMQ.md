# ZMQ for solo mining

Solo miners should subscribe to the Salvium daemon's ZMQ publisher so a new
block triggers an immediate template request. This avoids waiting for the
miner's periodic HTTP poll and reduces work on a stale template. ZMQ changes
template delivery latency only; it does not change the
hashing or nonce search behavior.

For a mainnet daemon and miner on the same machine, start the daemon with a
local ZMQ publisher:

```text
salviumd --zmq-pub tcp://127.0.0.1:19082 ...
```

Then pass the matching port to XMRig:

```text
xmrig.exe -o 127.0.0.1:19081 --coin SAL -a rx/0 -u <SC1-wallet> --daemon --daemon-zmq-port 19082
```

The equivalent pool-object configuration key is `"daemon-zmq-port": 19082`.
Keep both the daemon RPC and ZMQ publisher bound to trusted interfaces; the
example uses loopback intentionally.
