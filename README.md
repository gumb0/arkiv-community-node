# Arkiv Community Node

Tooling for running an [Arkiv](https://arkiv.network) RPC node outside
Golem/Arkiv infrastructure — and for joining it to the community read endpoint
(`community.rpc.arkiv.network`) as a paid provider.

**Status: under construction.** Nothing here is usable yet.

## What this will contain

- A Docker Compose stack for the Arkiv execution + consensus clients, consumed
  as official images.
- A setup script: fetch the shared network artifacts, render configs, generate
  local secrets, start.
- Healthchecks and a status script ("am I on the right chain, am I current?").
- A tunnel client profile, so a node behind NAT can serve the load balancer
  with no inbound port.
- Provider tooling: post an offer on the Arkiv marketplace, accept terms, check
  agreement and earnings status.

## License

[Apache-2.0](LICENSE)
