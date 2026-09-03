# Salvium farm topology

## Supported topology: direct solo mining

Run each of the `N` rigs in daemon/solo mode and point it directly at a
Salvium daemon. The rigs may share one trusted daemon, or each rig may use its
own daemon:

```text
rig 1 -- daemon/solo RPC --+                 rig 1 -- daemon/solo RPC --> salviumd 1
rig 2 -- daemon/solo RPC --+--> salviumd     rig 2 -- daemon/solo RPC --> salviumd 2
 ...                       |                  ...
rig N -- daemon/solo RPC --+                 rig N -- daemon/solo RPC --> salviumd N
```

On every `getblocktemplate` request, `DaemonClient::getBlockTemplate()` sends
a fresh random eight-byte `extra_nonce`. A conforming Salvium daemon embeds
those bytes in the coinbase transaction, which changes the Merkle root and
therefore the returned hashing blob. Two rigs then have distinct hashing
domains even when they search the same numeric nonce values. The probability
that a pair independently chooses the same 64-bit value is `1 / 2^64`
(approximately `5.4e-20`), so cross-rig duplicate work from an extra-nonce
collision is effectively zero. This conclusion depends on the deployed
daemon honoring `extra_nonce`; verify that assumption rather than relying on
it.

This is the supported farm layout today. It requires no miner-to-miner
connection and does not divide or otherwise change nonce iteration.

## Verifying no overlap

Enable the miner's HTTP API on a trusted interface with an access token, then
read each rig's authenticated `/2/summary` response. The relevant object is
`connection.work_domain`:

```json
{
  "family_id": "<32 lowercase hex characters>",
  "extra_nonce": "verified",
  "template_age_ms": 123,
  "source": "zmq",
  "nonce_mask": "0xffffffff",
  "height": 123456,
  "prev_hash": "<hex hash>"
}
```

For example, an API configured with `"access-token": "TOKEN"` can be read
with `Authorization: Bearer TOKEN`. Do not expose the API or its token on an
untrusted network.

At the same `height`, `work_domain.family_id` **must differ across rigs**. The
identifier is computed from the returned hashing blob after zeroing the nonce
field, so ordinary nonce iteration cannot make it differ. A repeated family
ID at the same height means the rigs received the same canonical hashing
domain and may duplicate work; stop treating the layout as overlap-free and
investigate the daemon/template source. Compare `prev_hash` too, so samples
from different chain tips are not mistaken for a useful same-template check.
The HTTP API is the canonical source in this build. If a future or locally
modified build prints the optional family-ID suffix on its new-job console
line, the same same-height comparison applies there.

`work_domain.extra_nonce: "verified"` means the daemon returned exactly the
same eight reserved bytes that the miner sent with that template request.
`mismatch` or `missing` means the round trip did not verify. `unsupported`
means the job did not come through the daemon request path and is not evidence
that a daemon ignored the value. Do not infer safety from `family_id` values
collected at different heights.

### Five-minute daemon check

Make two read-only JSON-RPC `getblocktemplate` calls to the deployed
`salviumd`, using the same wallet address but different eight-byte (16 hex
character) `extra_nonce` values. For example, send these request bodies to
the daemon's `/json_rpc` endpoint:

```json
{"jsonrpc":"2.0","id":"a","method":"getblocktemplate","params":{"wallet_address":"<SC1-wallet>","extra_nonce":"0000000000000001"}}
```

```json
{"jsonrpc":"2.0","id":"b","method":"getblocktemplate","params":{"wallet_address":"<SC1-wallet>","extra_nonce":"0000000000000002"}}
```

Compare `result.blockhashing_blob` in the two responses. The values must
differ. This demonstrates that this deployed daemon honors `extra_nonce` for
otherwise adjacent template requests. It is a focused configuration/runtime
check, not a substitute for watching `family_id` on all rigs: a new network
tip arriving between the calls can also change the blob, so repeat the pair
at a stable height if the response heights differ.

## ZMQ freshness

Configure ZMQ push for every direct daemon connection as described in
[SALVIUM_ZMQ.md](SALVIUM_ZMQ.md). Start `salviumd` with `--zmq-pub` and pass
the matching port to the miner with `--daemon-zmq-port`. ZMQ reduces the time
a rig spends on an old template after a new block; it does not create unique
work or coordinate nonce ranges. Confirm `work_domain.source` is `zmq` and
watch `template_age_ms` when checking the deployment. A `poll` source remains
functional but has the periodic polling delay.

## Conditional, untested topology: xmrig-proxy

An upstream `xmrig-proxy` deployment is **conditional and untested**, not a
supported Salvium path today. Upstream xmrig-proxy has no Salvium coin entry
and lacks this fork's SAL block-template parsing branches, including Salvium
transaction and output variants. It will therefore very likely reject SAL
templates. Do not place it between these miners and a Salvium daemon unless a
Salvium-capable proxy is first implemented and validated against real SAL
templates.

## What is deliberately not built

This fork does not add a LAN mesh, `net-chat`, discovery/gossip, or
proportional nonce partitioning. With honored per-request extra nonces, those
features recover approximately no duplicate hashing work while adding
coordination state and network attack surface.

The supporting analysis bounded the recoverable **hash-efficiency** budget
from any LAN coordination in this fork at no more than approximately `0.42%`;
that budget is template staleness and is already addressed by ZMQ. The bound
does not claim that ZMQ supplies unrelated proxy features such as monitoring,
failover, or RPC-load reduction. Proportional partition sizes would not even
constrain nonce exhaustion until aggregate farm speed exceeds approximately
`35.79 MH/s`, about three to four times the entire Salvium network measured by
that analysis and unrealistic for the intended home-farm deployment.

Treat telemetry as the gate for revisiting this decision. Consider
partitioning or a Salvium-capable extra-nonce proxy only if sustained
same-height observations show repeated `work_domain.family_id` values despite
the checks above.
