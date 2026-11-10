# Facts the backfabric command needs, from a `nixosConfigurations.<host>`
# entry that may not be installable yet: its nixos-facter report and public key
# files may be missing. Each subcommand reads only the attributes it needs;
# `hostPublicKey` requires the host's public key file.
#
# Any access to `config` first runs the module system's check for
# definitions of undeclared options, which evaluates the condition of every
# definition. Those conditions reach `pkgs`, hence `nixpkgs.hostPlatform`,
# which a real host takes from its facter report, so a missing report would
# fail the evaluation. The check is irrelevant for reading a few declared
# options, so it is disabled here. Assertions do not run either.
system:
let
  inherit
    (system.extendModules {
      modules = [ { _module.check = false; } ];
    })
    config
    ;
in
{
  address = config.backfabric.network.ipv4.address;
  initrdHostKey = config.backfabric.access.initrdSsh.hostKey;
  hostPublicKey = config.backfabric.access.hostKey.publicKey;
  reportPath =
    if config.hardware.facter.reportPath == null then
      null
    else
      toString config.hardware.facter.reportPath;
}
