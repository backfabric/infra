# Facts of a `nixosConfigurations.<host>` entry that may not be installable
# yet: its nixos-facter report and public key files may be missing. Read by
# the backfabric command (each subcommand reads only the attributes it needs)
# and by the fleet dev shell. `hostPublicKey` and `initrdPublicKey` require
# the host's public key files.
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
  inherit (config.backfabric) access network;
in
{
  address = network.ipv4.address;
  macAddress = network.macAddress;
  sshPort = access.ssh.port;
  initrdPort = access.initrdSsh.port;
  initrdHostKey = access.initrdSsh.hostKey;
  hostPublicKey = access.hostKey.publicKey;
  initrdPublicKey = access.initrdSsh.publicKey;
  reportPath =
    if config.hardware.facter.reportPath == null then
      null
    else
      toString config.hardware.facter.reportPath;
}
