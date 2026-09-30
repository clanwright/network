# Compare lock graphs after resolving native follows edges. Node names may differ,
# but sources, input names, flake flags and dependency sharing must be identical.
{
  candidateLock,
  consumerLock,
  candidateRevision,
  wrapperRevision,
}:
let
  candidate = builtins.fromJSON (builtins.readFile candidateLock);
  consumer = builtins.fromJSON (builtins.readFile consumerLock);
  require =
    condition: message: value:
    if condition then value else throw message;
  resolve =
    lock: node: name:
    resolveSeen lock [ ] node name;
  resolveSeen =
    lock: seen: node: name:
    let
      marker = "${node}.${name}";
      edge = lock.nodes.${node}.inputs.${name};
    in
    require (!builtins.elem marker seen) "cyclic follows at ${marker}" (
      if builtins.isString edge then
        edge
      else
        require (builtins.isList edge) "invalid lock edge ${marker}" (
          builtins.foldl' (
            current: component: resolveSeen lock (seen ++ [ marker ]) current component
          ) lock.root edge
        )
    );
  graph =
    selected:
    let
      pairs = builtins.genericClosure {
        startSet = [
          {
            key = [
              candidate.root
              selected
            ];
          }
        ];
        operator =
          pair:
          let
            left = builtins.elemAt pair.key 0;
            right = builtins.elemAt pair.key 1;
            a = candidate.nodes.${left};
            b = consumer.nodes.${right};
            names = builtins.attrNames (a.inputs or { });
          in
          require (names == builtins.attrNames (b.inputs or { })) "dependency input names differ: ${left}" (
            map (name: {
              key = [
                (resolve candidate left name)
                (resolve consumer right name)
              ];
            }) names
          );
      };
      identities = builtins.all (
        pair:
        let
          left = builtins.elemAt pair.key 0;
          right = builtins.elemAt pair.key 1;
          a = candidate.nodes.${left};
          b = consumer.nodes.${right};
        in
        (a.flake or true) == (b.flake or true)
        && (left == candidate.root || (a.locked == b.locked && a.original == b.original))
      ) pairs;
      uniqueCount =
        index:
        builtins.length (
          builtins.attrNames (
            builtins.listToAttrs (
              map (pair: {
                name = builtins.elemAt pair.key index;
                value = true;
              }) pairs
            )
          )
        );
      count = builtins.length pairs;
    in
    require identities "dependency source or flake identity differs" (
      require (uniqueCount 0 == count && uniqueCount 1 == count) "dependency convergence differs" (
        count - 1
      )
    );
  network = resolve consumer consumer.root "network";
  wrapper = resolve consumer consumer.root "wrapper";
  nested = resolve consumer wrapper "network";
  directSource = consumer.nodes.${network};
  nestedSource = consumer.nodes.${nested};
  follows =
    selected:
    let
      clan = resolve consumer selected "clan-core";
    in
    resolve consumer clan "data-mesher" == selected
    && resolve consumer clan "nixpkgs" == resolve consumer selected "nixpkgs";
  # The candidate owns ordinary source pins; no relative path dependency may
  # silently rely on a consumer's directory structure.
  noRelative = builtins.all (
    node:
    !(node ? locked && node.locked.type == "path" && builtins.substring 0 1 node.locked.path != "/")
  ) (builtins.attrValues candidate.nodes);
in
require
  (
    directSource.locked == nestedSource.locked
    && directSource.original == nestedSource.original
    && directSource.locked.rev == candidateRevision
    && consumer.nodes.${wrapper}.locked.rev == wrapperRevision
  )
  "direct/wrapper candidate source identity differs"
  (
    require (follows network && follows nested) "Clan follows do not resolve to Network/nixpkgs" (
      require noRelative "candidate contains a relative locked source" {
        directDependencies = graph network;
        nestedDependencies = graph nested;
        inherit candidateRevision wrapperRevision;
      }
    )
  )
