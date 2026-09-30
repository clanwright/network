# Architecture

Network supplies six independently selected Clan capabilities. Each capability
keeps its role interface, native NixOS module, scripts and settings reference in
one `clanServices/<service>/` directory. `lib/` contains shared address/interface
types, platform validation and WAN ownership checks. `checks/` owns evaluated
consumer composition; `tests/` contains bounded process/tool fixtures.

Native NixOS owns ACME certificate identity, challenge validation, renewal and
reader notifications. Consumers declare `security.acme.certs` directly. The
Certificates role supplies the contact/resolver defaults and narrowly attaches
the Timeweb credential and IPv4 policy to selected Timeweb certificates. The
host's native ACME module and stock Lego stay together; Network does not replace
Lego or parse generated scripts to infer compatibility.

Caddy uses native `services.caddy.virtualHosts`. Network adds canonical host
validation, one base owner, exclusive forward-proxy identity, listener collision
checks and its shared runtime/log policy. Native ordered route contributions
replace a separate fragment registry. Static sites own artifact validation and
host-guarded serving; website projects own their builds, and consumers own proxy
authentication, publisher routes, transport readiness and exposure.

The locked nixpkgs input is Network's package authority. Network constructs one
specialized Caddy with pinned forward-proxy and rate-limit plugins. Consumer
Caddy overrides are rejected. Other host packages remain native. Clan follows
Network's nixpkgs input. Its pinned unconditional data-mesher import is satisfied
by the minimal function-valued empty module in `flake.nix`; it declares no
service, options or package. The input follows Network itself to avoid a nested
relative source. Lock generation and convergence have a native Git/Nix check.

Firewall composes native port policy with destination-specific exposure and a
private-ingress drop before accepts. Bootstrap SSH is an explicitly created
absolute deadline enforced by nftables, without polling or session termination.
Networkd owns WAN addresses and routes; separately routed additional addresses
carry explicit stable table/rule identities. Native transport selectors and
non-default main routes retain their agreed precedence.

TCP tuning belongs to VPN. Production IPv6 and HTTP/3 require a separate
consumer/transport decision; Caddy currently retains HTTP/1 and HTTP/2.
Other DNS providers use host-native ACME declarations and their own credentials.

Only x86_64-linux is supported. Darwin exposes developer tools. There is no VM
test infrastructure, provider framework, watcher or automatic deployment. Local
source/build/composition evidence and PREDEPLOY behavior acceptance are separate;
their exact boundaries live in [verification](operations/verify.md).
